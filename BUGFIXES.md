# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `XAttrHeader.reserved` wrong in-memory layout breaks all xattr I/O
**File:** `EXT4+Types.swift:592`
**Bug:** `reserved` was declared as `[UInt32]` — a Swift heap-allocated Array (24 bytes on 64-bit). The ext4 on-disk format requires exactly 12 bytes (three `UInt32` fields). Every `withUnsafeBytes(of:)` call on `XAttrHeader` produced garbage: magic, reference count, and hash were read from wrong byte offsets.
**Impact:** Every extended-attribute block header — read or written — was corrupted. This affects security labels, capabilities, and any other xattr on every container image.
**Fix:** Changed `let reserved: [UInt32]` to `let reserved: (UInt32, UInt32, UInt32)`, which has the required fixed 12-byte layout.

---

## 2. CRITICAL: Extent block start double-counted, corrupting data in large files
**File:** `EXT4+Formatter.swift:1135`
**Bug:** `fillExtents` was called with `start: blocks.start + offset`. Inside `fillExtents`, each extent's physical start is computed as `start + extentBlock` where `extentBlock = offset + i * MaxBlocksPerExtent`. This double-counts `offset`, so every extent in the second and subsequent leaf blocks points to the wrong physical disk location.
**Impact:** Silent data corruption for any file large enough to require more than one extent leaf block (roughly > 500 MB at the default block size). The written extent tree directs reads to wrong disk blocks.
**Fix:** Changed to `start: blocks.start` so `fillExtents` computes the correct absolute address itself.

---

## 3. CRITICAL: `Date.fs()` traps at runtime for any date before 1970
**File:** `EXT4+Formatter.swift:1328`
**Bug:** `UInt64(s)` traps when `s < 0` (any timestamp before the Unix epoch). `truncatingRemainder(dividingBy: 1)` also returns a negative fractional part for negative `s`, making the nanosecond conversion trap as well. These paths were reachable without any guard.
**Impact:** Runtime crash when formatting a filesystem containing any file with a pre-1970 modification, access, or creation timestamp. Reproducible with standard container base images whose package metadata predates 1970.
**Fix:** Added `guard s >= 0 else { return 0 }` before the `UInt64` conversions.

---

## 4. HIGH: Inode timestamps lose all sub-second precision and post-2038 range
**File:** `EXT4Reader+Export.swift:76–78, 161–163`
**Bug:** `UInt64((inode.ctimeExtra << 32) | inode.ctime)` — the shift `inode.ctimeExtra << 32` is performed as `UInt32` arithmetic, where shifting a 32-bit value left by 32 bits always produces 0. The `Extra` field (which encodes nanoseconds and epoch-extension bits) was silently discarded.
**Impact:** All exported file timestamps lose sub-second precision and are clamped to 32-bit epoch range (max year 2038). Affects all six timestamps across the two export paths.
**Fix:** Changed to `(UInt64(inode.ctimeExtra) << 32) | UInt64(inode.ctime)` so the shift is performed in 64-bit arithmetic.

---

## 5. HIGH: ARC objects inside `Ptr<T>` leaked because destructor is never called
**File:** `EXT4+Ptr.swift:53–65`
**Bug:** `deallocate()` called `self.underlying.deallocate()` before `deinitialize()`. Swift's `UnsafeMutablePointer.deallocate()` releases the raw memory without running any destructors; `deinitialize()` is required first to decrement ARC reference counts on any reference-type members. Skipping it leaks every ARC-managed value inside `T`.
**Impact:** `FileTreeNode` contains a `[Ptr<FileTreeNode>]` children array (an ARC-managed type). Every node in every file tree was leaked for the lifetime of the process, accumulating unbounded memory for repeated formatter runs.
**Fix:** Moved `deinitialize(count:)` before `deallocate()` inside `deallocate()`.

---

## 6. HIGH: `Ptr` state machine allows use-after-move: `allocated` incorrectly set to `true`
**File:** `EXT4+Ptr.swift:49, 73, 82`
**Bug:** `initialize()`, `deinitialize()`, and `move()` each unconditionally set `self.allocated = true`. After `move()` transfers ownership out of the pointer and then sets `allocated = true`, the `Ptr` appears valid. A subsequent `initialize()` call passes its guard and writes to the now-unowned memory location.
**Impact:** Potential use-after-move write: any call to `initialize()` on a moved-from `Ptr` overwrites memory whose ownership has been transferred elsewhere, causing heap corruption or silent data overwrite.
**Fix:** Removed all three spurious `self.allocated = true` assignments. Added a `guard self.allocated && self.initialized` precondition in `move()` that calls `fatalError` on invalid use.

---

## 7. HIGH: `FileTreeNode.parent` strong reference creates permanent ARC cycle
**File:** `EXT4+FileTree.swift:29`
**Bug:** `parent` was a strong `var Ptr<FileTreeNode>?`. Every child held a strong reference to its parent's `Ptr`, while the parent's `Ptr` was also owned by the grandparent's `children` array. This formed a cycle that ARC cannot break, so the entire tree was never released.
**Impact:** The complete formatter file tree (one node per file and directory) leaked on every `EXT4.Formatter` instantiation. For a container image with tens of thousands of files, this is megabytes of leaked memory per format operation.
**Fix:** Changed to `private weak var parent: Ptr<FileTreeNode>?`.

---

## 8. HIGH: Hardlink `linksCount` never decremented, inodes never freed
**File:** `EXT4+Formatter.swift:238`
**Bug:** When unlinking a hardlink, the linked inode's reference count was decremented only if `linksCount > 2`. But `linksCount` starts at 1 (when the original file is created) and is incremented to 2 when `link()` is called. The threshold to decrement is therefore `> 1`, not `> 2`. The condition `> 2` meant the count was never decremented for a singly hard-linked file.
**Impact:** Removing a hardlink did not decrement the target inode's link count. The inode's count remained at 2 instead of returning to 1, so the inode was never marked as freed in the bitmap. Every hardlinked file leaked one inode permanently.
**Fix:** Changed `linksCount > 2` to `linksCount > 1`.

---

## 9. HIGH: Inline symlink target includes up to 59 trailing null bytes
**File:** `EXT4Reader+Export.swift:133`
**Bug:** For inline symlinks (target < 60 bytes), the target string was read from all 60 bytes of `inode.block`. `String(bytes: linkBytes, encoding: .utf8)` converts all 60 bytes including the null padding after the actual target. The resulting string has embedded null bytes appended.
**Impact:** All exported inline symlinks (the common case for short targets) had corrupted paths with trailing null bytes, making them unresolvable by any consumer.
**Fix:** Changed to `linkBytes.prefix(Int(size))` to read only the valid bytes.

---

## 10. HIGH: Inode table size computation overflows for large filesystems
**File:** `EXT4+Formatter.swift:953`
**Bug:** `uint32(self.inodes.count) * EXT4.InodeSize` performed the multiplication as 32-bit arithmetic. With `EXT4.InodeSize = 256`, overflow occurs at approximately 16.7 million inodes (UInt32.max / 256). The result silently wraps, producing a wrong `rest` value that truncates the zero-fill for the inode table.
**Impact:** Formatting a large container image with millions of inodes wrote a truncated inode table, corrupting the filesystem. The formatter would also `e2fsck`-fail with inode table size mismatches.
**Fix:** Changed to `UInt64(self.inodes.count) * UInt64(EXT4.InodeSize)`.

---

## 11. HIGH: Zero or undersized `recordLength` causes infinite loop reading directories
**File:** `EXT4+Reader.swift:179`
**Bug:** If a directory entry's `recordLength` was 0 or smaller than the fixed header size, `offset += Int(dirEntry.recordLength)` would never advance. The `while offset < dirTree.count` loop ran forever, hanging the reader process.
**Impact:** Any malformed or truncated directory block (e.g., from a partially-written image or filesystem corruption) caused an unrecoverable hang when listing directory contents.
**Fix:** Added `guard dirEntry.recordLength >= headerSize else { break }` before consuming the entry.

---

## 12. HIGH: `Hardlinks.resolve` does not track visited nodes, loops on indirect cycles
**File:** `Formatter+Unpack.swift:184`
**Bug:** `visited` was declared as `let`, so it was never updated inside the loop. Only a cycle that led back to the very first node could be detected. Any cycle among intermediate nodes (A→B→C→B) caused `resolve` to loop forever.
**Impact:** Unpacking an archive with an indirect hardlink cycle (possible with a crafted or corrupt archive) hung the process. The `acyclic` check above used `var` correctly and would catch the cycle, but `resolve` was called after that check passed, leaving a gap if `acyclic` had a false negative.
**Fix:** Changed `let visited` to `var visited` and added `visited.insert(next)` after advancing.

---

## 13. HIGH: `FilePath.init?(_ data: Data)` reads past the buffer boundary
**File:** `FilePath+Extensions.swift:56`
**Bug:** The original implementation bound the `Data` buffer to `CChar` and called `String(cString:)`, which reads bytes until a null terminator is found with no bounds check against `data.count`. If the buffer is not null-terminated (normal for filesystem-sourced byte arrays), the read continues into adjacent heap memory.
**Impact:** Buffer over-read / undefined behaviour when constructing `FilePath` from any non-null-terminated `Data`, which is the common case for paths read from an ext4 directory entry or xattr value.
**Fix:** Replaced with `String(bytes: data, encoding: .utf8)`, which reads exactly `data.count` bytes.

---

## 14. HIGH: Xattr block-attribute sort comparator violates strict weak ordering
**File:** `EXT4+Xattrs.swift:180`
**Bug:** The comparator `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)` uses `||` to chain criteria. This violates strict weak ordering: when `A.index > B.index` but `A.name < B.name`, the comparator returns `true` (A < B), contradicting the primary sort key. Swift's sort is not required to be safe under such a comparator.
**Impact:** Undefined behaviour in `Array.sort(by:)`. In practice this can produce an incorrectly ordered xattr block (causing `e2fsck` failures) or, in debug builds, trigger a precondition failure.
**Fix:** Replaced with proper lexicographic chaining using `!=` guards.

---

## 15. MEDIUM: `visitedInodes` not cleared after absolute symlink resets traversal to root
**File:** `EXT4Reader+IO.swift:362`
**Bug:** When an absolute symlink reset the path traversal to root, `visitedInodes` retained inodes from the pre-reset traversal. If a hard-linked symlink with the same inode was encountered after the reset, `visitedInodes.contains` produced a false positive and threw `symlinkLoop`.
**Impact:** Valid paths of the form `/real/path → /abs/symlink → /other/path` where `/abs/symlink` is a hardlink to a symlink seen earlier could throw a false `symlinkLoop` error, making those paths unresolvable.
**Fix:** Added `visitedInodes = []` alongside the existing `current = EXT4.RootInode` reset.

---

## 16. MEDIUM: Off-by-one in inode guard allows first user inode to bypass unlink protection
**File:** `EXT4+Formatter.swift:248`
**Bug:** `guard inodeNumber > FirstInode` where `inodeNumber = Int(pathNode.inode) - 1` (0-based) and `FirstInode = 11`. This translates to `inode - 1 > 11`, i.e., `inode > 12`. The protection should cover inodes 1–11; inode 12 was accidentally excluded and could never be freed by `unlink`.
**Impact:** Unlinking the first user-allocated file (inode 12) did not zero its inode or release its blocks. The inode appeared deleted in directory listings but remained in the inode table with stale data.
**Fix:** Changed to compare `pathNode.inode > EXT4.FirstInode` (both values 1-based).

---

## 17. MEDIUM: `buffer[0...4]` reads 5 bytes to decode a 4-byte magic number
**File:** `EXT4Reader+Export.swift:173, 186`
**Bug:** `buffer[0...4]` is a closed range covering 5 bytes (indices 0–4). `$0.load(as: UInt32.self)` only consumes the first 4 bytes, but constructing the 5-element slice panics with an index-out-of-range if the buffer is exactly 4 bytes long.
**Impact:** `readInlineExtendedAttributes` and `readBlockExtendedAttributes` crash when given the minimum-valid input (a 4-byte buffer containing only the magic value).
**Fix:** Changed to `buffer[0..<4]`.

---

## 18. MEDIUM: Force-unwrap `asciiValue!` crashes on non-ASCII xattr names
**File:** `EXT4+Xattrs.swift:60`
**Bug:** `UInt32(char.asciiValue!)` force-unwraps the optional `asciiValue`. Any character without an ASCII scalar value (multi-byte UTF-8 sequences that may appear in non-conforming images) causes an immediate crash.
**Impact:** Computing the hash for an `ExtendedAttribute` whose name contains a non-ASCII byte crashes the process, making the entire image unreadable.
**Fix:** Changed to `char.asciiValue ?? 0`.

---

## 19. MEDIUM: Force-unwrap `String(..., encoding: .ascii)!` crashes on non-ASCII xattr names
**File:** `EXT4+Xattrs.swift:264`
**Bug:** `String(bytes: rawName, encoding: .ascii)!` force-unwraps. If the raw name bytes from the on-disk xattr entry are not valid ASCII, the initializer returns `nil` and the force-unwrap crashes.
**Impact:** Reading any extended attribute whose on-disk name contains a non-ASCII byte (possible in malformed or foreign-produced images) crashes the process.
**Fix:** Changed to `String(bytes: rawName, encoding: .ascii) ?? ""`.

---

## 20. MEDIUM: `UInt64 / UInt32` operator silently truncates quotient
**File:** `Integer+Extensions.swift:37`
**Bug:** `(lhs / UInt64(rhs)).lo` silently discards the upper 32 bits of the quotient by taking only `.lo`. When the true quotient exceeds `UInt32.max` the returned value is completely wrong, with no trap or error.
**Impact:** Any code path using this operator for a division whose result exceeds ~4 billion receives a silently wrong value. In the formatter, this affects inode-count and block-count divisions in the layout optimizer.
**Fix:** Changed to `UInt32(lhs / UInt64(rhs))`, which traps visibly on overflow.

---

## 21. LOW: Ceiling-division off-by-one allocates one extra extent-index block
**File:** `EXT4+Formatter.swift:1101`
**Bug:** `numExtents / extentsPerBlock + 1` always adds 1. When `numExtents` is exactly divisible by `extentsPerBlock`, the correct number of leaf blocks is `numExtents / extentsPerBlock`, but the formula allocates one more. The extra index entry points to an empty, garbage-filled leaf block.
**Impact:** Files whose extent count is exactly a multiple of `extentsPerBlock` have one spurious empty extent leaf block written to disk, causing `e2fsck` to report an extent-tree inconsistency.
**Fix:** Changed to `(numExtents - 1) / extentsPerBlock + 1` (standard ceiling-division formula).

---

## 22. LOW: `loadLittleEndian` reads wrong bytes on big-endian platforms
**File:** `UnsafeLittleEndianBytes.swift:61`
**Bug:** `Array(self.reversed())` reversed all bytes in the buffer regardless of `sizeof(T)`. When `self.count > MemoryLayout<T>.size`, `ptr.load(as: T.self)` loaded from what were originally the *last* bytes of the buffer (now first after full reversal), rather than the first `sizeof(T)` bytes byte-swapped.
**Impact:** On big-endian hardware, reading any ext4 struct field via `loadLittleEndian` produced a value from the wrong region of the buffer. All extent headers, directory entries, and xattr entries would be misread.
**Fix:** Changed to `Array(self.prefix(size).reversed())` to byte-swap only the relevant bytes.

---

## 23. LOW: `ExtentLeaf` and `ExtentIndex` loaded without endian conversion
**File:** `EXT4+Reader.swift:217, 226`
**Bug:** `$0.load(as: ExtentLeaf.self)` and `$0.load(as: ExtentIndex.self)` perform a raw memory load without byte-swapping. The ext4 format is little-endian; on big-endian platforms all extent fields (block numbers, lengths) would be byte-reversed.
**Impact:** On big-endian hardware, extent tree traversal reads wrong block numbers, causing every read of any non-trivially-small file to access incorrect disk blocks.
**Fix:** Changed both calls to `$0.loadLittleEndian(as:)`.

---

## 24. LOW: Off-by-one errors skip xattr entries at buffer boundaries
**File:** `EXT4+Xattrs.swift:256, 260, 273`
**Bug:** Three related off-by-one errors: (a) `while i + 16 < buffer.count` should be `<=`, missing an entry that starts exactly 16 bytes before the end; (b) `guard endIndex < buffer.count` should be `<=`, skipping an entry whose name ends exactly at the buffer boundary; (c) `endIndex = i + 3` with `guard endIndex < buffer.count` checked only 3 bytes ahead for a 4-byte sentinel, and used `continue` instead of `break` when near the end.
**Impact:** One or more xattr entries silently dropped when they fall at the end of a buffer. Attribute names of the correct length would be incorrectly skipped, causing those attributes to appear missing.
**Fix:** Changed comparisons to `<=` and the sentinel guard to `guard i + 4 <= buffer.count else { break }`.

---

## 25. LOW: Missing `verity` and `casefold` inode flag constants
**File:** `EXT4+Types.swift:466, 474`
**Bug:** `InodeFlag` was missing constants for `0x100000` (FS_VERITY_FL — fs-verity enabled) and `0x4000_0000` (CASEFOLD_FL — case-insensitive directory). The gap between `extents` (0x80000) and `eaInode` (0x200000) and between `projectIDInherit` (0x2000_0000) and `reserved` (0x8000_0000) left those flags unnamed.
**Impact:** Code inspecting inode flags on images created with fs-verity or case-folding could silently misinterpret or ignore those files.
**Fix:** Added `static let verity` and `static let casefold` with their correct raw values.

---

## 26. LOW: `FilePath.bytes` loop termination relies on dead outer condition
**File:** `FilePath+Extensions.swift:27`
**Bug:** `while UInt(bitPattern: ptr) != 0` tests whether the pointer's numeric address is zero. `withCString` never returns a null pointer, so the condition is always `true`. The loop terminated solely via an inner `if ptr.pointee == 0x00 { break }`.
**Impact:** No runtime bug in the current implementation — the inner break correctly terminates at the null byte. However, the dead outer condition masks the real termination logic and could cause an infinite loop if the inner break were ever removed.
**Fix:** Replaced with `while ptr.pointee != 0`, making the single correct termination condition explicit.
