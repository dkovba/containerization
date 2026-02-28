# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `Date.fs()` crashes on pre-1970 timestamps
**File:** `EXT4+Formatter.swift` (`Date.fs()`)
**Bug:** `UInt64(s)` traps at runtime for any negative `timeIntervalSince1970` (dates before January 1 1970). Additionally, `truncatingRemainder(dividingBy: 1)` returns a negative fractional part for negative `s`, so the `UInt64(…)` conversion of nanoseconds also traps.
**Impact:** Runtime crash when formatting any file whose access, modification, or creation timestamp predates the Unix epoch. Container images sourced from archives with such timestamps cannot be formatted.
**Fix:** Use `floor(s)` to extract integer seconds, `UInt64(bitPattern: Int64(floorS))` masked to 34 bits for two's-complement encoding of negative seconds, and `s - floor(s)` for the always-non-negative nanosecond remainder.

---

## 2. CRITICAL: `writeExtents` writes large files to wrong physical blocks
**File:** `EXT4+Formatter.swift` (`writeExtents`)
**Bug:** When building indirect extent blocks (≥5 extents), `fillExtents` is called with `start: blocks.start + offset`. Inside `fillExtents`, `extentStart` is computed as `start + extentBlock` where `extentBlock` already includes `offset`. The `offset` value is therefore added twice, making every extent in every indirect leaf block point to a physical block address that is `offset` blocks too high.
**Impact:** Corrupted filesystem: large files (typically >16 MiB) have their data extents pointing at wrong disk locations. Reading such files from the formatted image returns garbage or causes an I/O error.
**Fix:** Pass `start: blocks.start` (without adding `offset`), so the offset is applied only once inside `fillExtents`.

---

## 3. CRITICAL: `writeExtents` crashes when extent count is an exact multiple of extents-per-block
**File:** `EXT4+Formatter.swift` (`writeExtents`)
**Bug:** `let extentBlocks = numExtents / extentsPerBlock + 1` always rounds up by one, even when `numExtents` is exactly divisible by `extentsPerBlock`. The final iteration allocates an extent leaf block whose `extentsInBlock` is zero, so `leafNode.leaves` is empty and `leafNode.leaves.last!` force-unwraps `nil`.
**Impact:** Runtime crash (`EXC_BAD_INSTRUCTION`) when writing a file whose size happens to produce a number of extents exactly divisible by the per-block capacity (e.g. exactly 341 extents with a 4 KiB block size).
**Fix:** Replace with proper ceiling division: `(numExtents + extentsPerBlock - 1) / extentsPerBlock`.

---

## 4. CRITICAL: Exported timestamps discard nanoseconds and high seconds bits
**File:** `EXT4Reader+Export.swift` (`export`)
**Bug:** `UInt64((inode.ctimeExtra << 32) | inode.ctime)` — `inode.ctimeExtra` is `UInt32`. Shifting a `UInt32` left by 32 produces 0 in Swift (the entire value is shifted out). The result is `UInt64(inode.ctime)` only: the upper two seconds bits and all 30 nanosecond bits stored in `*Extra` are silently lost. All six timestamp assignments in `export` (creation, modification, access for both regular entries and hardlinks) are affected.
**Impact:** Every timestamp written into exported archives has incorrect precision: nanoseconds are always zero and sub-32-bit seconds rollover is wrong, producing timestamps that are off by up to ~136 years for files with timestamps in certain ranges.
**Fix:** Widen to `UInt64` before shifting: `(UInt64(inode.ctimeExtra) << 32) | UInt64(inode.ctime)`.

---

## 5. CRITICAL: `Date(fsTimestamp:)` decodes pre-1970 timestamps as far-future dates
**File:** `EXT4Reader+Export.swift` (`Date(fsTimestamp:)`)
**Bug:** `Int64(fsTimestamp & 0x3_ffff_ffff)` zero-extends the 34-bit seconds field to 64 bits. For any timestamp before the Unix epoch the high bit of the 34-bit field (bit 33) is set, representing a negative two's-complement value. Zero-extension produces a large positive number instead (e.g. −1 second becomes +17,179,869,183).
**Impact:** Any file with a pre-1970 timestamp is exported with a wildly wrong date (hundreds of years in the future) rather than the correct pre-epoch date.
**Fix:** Sign-extend: if bit 33 is set, OR the raw bits with `0xFFFF_FFFC_0000_0000` before casting to `Int64(bitPattern:)`.

---

## 6. HIGH: Hardlink `linksCount` never decremented for files with exactly two links
**File:** `EXT4+Formatter.swift` (`unlink`)
**Bug:** `if linkedInode.linksCount > 2` means the decrement only fires when the count is 3 or more. A file with exactly two links (one original + one hardlink) has `linksCount = 2`; `2 > 2` is false so `linksCount` stays at 2 after the hardlink is removed.
**Impact:** After unlinking a hardlink, the target inode retains a phantom link count of 2. The block bitmap marks it as still in use, leaking disk blocks and causing e2fsck to report a link count mismatch.
**Fix:** Change the threshold to `> 1`.

---

## 7. HIGH: `unlink` never frees blocks for inodes 11 and 12
**File:** `EXT4+Formatter.swift` (`unlink`)
**Bug:** `guard inodeNumber > FirstInode` compares a 0-indexed value (`inodeNumber = Int(pathNode.inode) - 1`) against the 1-indexed constant `EXT4.FirstInode = 11`. For inode 11 (lost+found): `10 > 11` → false. For inode 12 (first user file): `11 > 11` → false. Neither has its blocks freed on `unlink`.
**Impact:** Unlinking the first two user-accessible inodes leaks their disk blocks. Any container layer that whiteouts a file created as inode 11 or 12 leaves those blocks permanently marked as used.
**Fix:** Use the 1-indexed inode number directly: `guard pathNode.inode >= EXT4.FirstInode`.

---

## 8. HIGH: `resolve()` loops infinitely on cycles not involving the first target
**File:** `Formatter+Unpack.swift` (`resolve`)
**Bug:** `let visited: Set<FilePath> = [next]` is immutable and never updated inside the loop. The cycle guard `visited.contains(item)` can only detect a revisit of the initial target node. A cycle such as `A → B → C → D → C` loops forever because neither C nor D is ever inserted into `visited`.
**Impact:** Infinite loop during hardlink resolution if a cycle exists that does not pass through the first target. The `acyclic` pre-check prevents this in practice, but `resolve` is logically incorrect and would hang if called independently.
**Fix:** Change `let visited` to `var visited` and add `visited.insert(next)` after each hop.

---

## 9. HIGH: `XAttrHeader.reserved` wrong type breaks binary layout
**File:** `EXT4+Types.swift`
**Bug:** `let reserved: [UInt32]` declares a Swift heap-allocated `Array`. On a 64-bit platform this field is 24 bytes (pointer + count + capacity) instead of the 12 bytes (`__u32[3]`) in the on-disk `ext4_xattr_header`. Any future use with `withUnsafeLittleEndianBytes` would produce a 44-byte blob with a heap pointer in the reserved field rather than the correct 32-byte header.
**Impact:** Potential filesystem corruption if the struct is ever serialised directly. Incorrect `MemoryLayout<XAttrHeader>.size` misleads any size-based logic.
**Fix:** Replace with a fixed-size tuple: `let reserved: (UInt32, UInt32, UInt32)`.

---

## 10. HIGH: Extent leaf and index nodes parsed with wrong byte order
**File:** `EXT4+Reader.swift` (`getExtents`)
**Bug:** `$0.load(as: ExtentLeaf.self)` and `$0.load(as: ExtentIndex.self)` are used for depth-0 leaf nodes and depth-1 index nodes respectively. All other EXT4 on-disk struct reads use `.loadLittleEndian`. On a big-endian host these two calls return multi-byte fields with swapped bytes, producing wrong physical block addresses and block counts.
**Impact:** Incorrect extent mapping on big-endian hosts: reads and writes go to the wrong physical blocks, causing data corruption or crashes.
**Fix:** Use `.loadLittleEndian(as:)` for both calls, consistent with every other on-disk struct parse in the reader.

---

## 11. HIGH: `FilePath.init?(_ data:)` reads past end of buffer (undefined behaviour)
**File:** `FilePath+Extensions.swift`
**Bug:** `String(cString: cString)` scans for a `\0` terminator with no knowledge of the buffer's length. If `data` does not end with a null byte — the common case for paths constructed from raw byte arrays — the pointer is dereferenced past the end of the allocation.
**Impact:** Undefined behaviour: garbage characters appended to the path, or a crash from an out-of-bounds memory read, depending on what happens to lie beyond the buffer.
**Fix:** Use `String(data: data, encoding: .utf8)` which reads exactly `data.count` bytes.

---

## 12. HIGH: `xattr` hash computation crashes on non-ASCII attribute names
**File:** `EXT4+Xattrs.swift` (`ExtendedAttribute.hash`)
**Bug:** `UInt32(char.asciiValue!)` force-unwraps `asciiValue`, which is `nil` for any non-ASCII Unicode character. Any xattr name containing a character outside ASCII triggers a runtime trap.
**Impact:** Runtime crash (`EXC_BAD_INSTRUCTION`) when computing the hash of an xattr whose name contains a non-ASCII character.
**Fix:** Iterate over `name.utf8` raw bytes instead of Unicode `Character` values.

---

## 13. HIGH: Descriptor-block bitmap range crashes when range is empty
**File:** `EXT4+Formatter.swift` (`close`)
**Bug:** `for i in usedGroupDescriptorBlocks + 1...self.groupDescriptorBlocks` — Swift's `a...b` closed range traps at runtime when `a > b`. When `usedGroupDescriptorBlocks == groupDescriptorBlocks` (all reserved descriptor blocks are actually used) the range lower bound exceeds the upper bound.
**Impact:** Runtime crash during `close()` on any filesystem where the number of block groups exactly fills the reserved descriptor table space.
**Fix:** Guard the loop: `if usedGroupDescriptorBlocks + 1 <= self.groupDescriptorBlocks { … }`.

---

## 14. MEDIUM: `getDirEntries` stops at first deleted entry, losing valid entries that follow
**File:** `EXT4+Reader.swift` (`getDirEntries`)
**Bug:** `if dirEntry.inode == 0 { break }` — a zero inode marks a deleted or free directory entry, but valid entries can follow it within the same block (the entry's `rec_len` field is still valid). Breaking out stops the scan prematurely.
**Impact:** Files or directories that happen to follow a deleted entry in a block are silently invisible to the reader. Hardlink detection and archive export both miss them.
**Fix:** Skip deleted entries with `offset += Int(dirEntry.recordLength); continue` rather than breaking. Additionally guard against `recordLength == 0` to prevent an infinite loop on corrupted data.

---

## 15. MEDIUM: `FileTree.path` always returns `"/"` when tree root is `"/"`
**File:** `EXT4+FileTree.swift` (`FileTreeNode.path`)
**Bug:** `FilePath(dataPath).pushing(FilePath(last)).lexicallyNormalized()` — `FilePath.pushing` replaces the receiver with the argument when the argument is an absolute path. When the root node's name is `"/"` (as used by `EXT4.Formatter`), `pushing(FilePath("/"))` replaces the entire built path with `"/"`, so every node's `path` property returns the root rather than the actual path.
**Impact:** Latent data-loss bug: any code calling `.path` on formatter tree nodes (e.g. future tooling) would receive `"/"` for every file. Currently unexploited because the formatter does not call `.path`.
**Fix:** When the root name is `"/"`, construct the absolute path directly as `FilePath("/" + joined)` instead of using `pushing`.

---

## 16. MEDIUM: `EXT4+Reader.swift` also includes a pointless `String→Data→String` round-trip
**File:** `EXT4+FileTree.swift` (`FileTreeNode.path`)
**Bug:** `path.data(using: .utf8)` followed immediately by `String(data: data, encoding: .utf8)` is an unconditional no-op — a Swift `String` is always valid Unicode and therefore always valid UTF-8. Both guards can never fire. The round-trip added a Foundation dependency for no benefit.
**Impact:** Two dead guard branches and an unnecessary Foundation import in a file that otherwise needs only `SystemPackage`.
**Fix:** Remove the round-trip; use the joined string directly.

---

## 17. MEDIUM: `GDT offset formula` is wrong for 1024-byte-block filesystems
**File:** `EXT4+Reader.swift` (`readGroupDescriptor`)
**Bug:** `let bs = UInt64(1024 * (1 << _superBlock.logBlockSize)); let offset = bs + …` uses `blockSize` as the GDT start offset. For 1024-byte blocks (`logBlockSize = 0`), the superblock occupies block 1 and the GDT starts at block 2 (offset 2048). The formula gives offset 1024, pointing one block too early.
**Impact:** On a 1024-byte-block ext4 image the reader interprets the superblock's second half as the first group descriptor, corrupting every group descriptor lookup and making the image unreadable.
**Fix:** Use `(UInt64(_superBlock.firstDataBlock) + 1) * blockSize`, which correctly handles all block sizes.

---

## 18. MEDIUM: Exported symlink targets contain trailing null bytes
**File:** `EXT4Reader+Export.swift` (`export`)
**Bug:** `EXT4.tupleToArray(inode.block)` returns all 60 bytes of the inline block field. For a 5-byte symlink target, the remaining 55 bytes are zero padding. `String(bytes: linkBytes, encoding: .utf8)` in Swift does not stop at `\0`; it includes null characters, so the archive entry's `symlinkTarget` is the real target concatenated with embedded NUL characters.
**Impact:** Archives exported from an ext4 image have corrupted symlink targets for all fast symlinks (target length < 60 bytes), breaking symlink resolution in any consumer of the archive.
**Fix:** Use `linkBytes.prefix(Int(size))` to read exactly `size` bytes as recorded in the inode.

---

## 19. MEDIUM: `xattr` sort comparator violates strict-weak-ordering
**File:** `EXT4+Xattrs.swift` (`writeBlockAttributes`)
**Bug:** `if ($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)` — an OR-based comparator is not a valid strict weak ordering. For attributes A (index=1, name.count=5) and B (index=2, name.count=3), both `compare(A,B)` and `compare(B,A)` return `true`, violating asymmetry. Swift's sort algorithm requires a strict weak ordering and produces undefined results (possibly wrong order or a crash in debug builds) when given an invalid comparator.
**Impact:** Block-level xattrs may be written in the wrong order or trigger a debug assertion. The kernel's xattr lookup relies on sorted entries for efficiency.
**Fix:** Use a cascaded comparison that checks fields sequentially, only moving to the next key on equality.

---

## 20. MEDIUM: `xattr` read loop has off-by-one, skipping last entry
**File:** `EXT4+Xattrs.swift` (`FileXattrsState.read`)
**Bug:** `while i + 16 < buffer.count` — `buffer[i..<i+16]` is valid when `i + 16 == buffer.count`, but the `<` condition excludes exactly this case. An xattr entry whose last header byte lands at `buffer[buffer.count - 1]` is silently skipped.
**Impact:** The final xattr in a tightly-packed inline or block xattr area is never parsed or exported.
**Fix:** Change to `i + 16 <= buffer.count`.

---

## 21. MEDIUM: `xattr` magic header read uses a 5-byte slice for a 4-byte value
**File:** `EXT4Reader+Export.swift` (`readInlineExtendedAttributes`, `readBlockExtendedAttributes`)
**Bug:** `buffer[0...4]` is a closed range producing 5 bytes. Only 4 bytes are needed to load a `UInt32`. On a buffer of exactly 4 bytes this crashes with an index-out-of-bounds error.
**Impact:** If the xattr buffer is exactly 4 bytes (header only, no entries), both read functions crash rather than returning the correct "no attributes" result.
**Fix:** Use the half-open range `buffer[0..<4]`.

---

## 22. MEDIUM: `Endian` global recomputed on every call via `CFByteOrderGetCurrent()`
**File:** `UnsafeLittleEndianBytes.swift`
**Bug:** `public var Endian: Endianness { switch CFByteOrderGetCurrent() … }` is a computed property re-evaluated on every access. Every call to `withUnsafeLittleEndianBytes`, `withUnsafeLittleEndianBuffer`, and `loadLittleEndian` triggers a CoreFoundation call. Hardware byte order is a physical constant that never changes at runtime.
**Impact:** Unnecessary overhead on every struct serialisation and deserialisation. Across a large filesystem format operation this amounts to many thousands of redundant CoreFoundation calls.
**Fix:** Change to `public let Endian: Endianness = { … }()` — a lazily-initialised constant evaluated exactly once. Also requires `Endianness: Sendable` for concurrency safety.

---

## 23. LOW: `Ptr.move()` has no guards against use on deallocated or uninitialised memory
**File:** `EXT4+Ptr.swift` (`move`)
**Bug:** Unlike every other mutating method on `Ptr` (`initialize`, `deinitialize`, `deallocate`), `move()` does not check `self.allocated` or `self.initialized` before calling `self.underlying.move()`. Calling it on a deallocated pointer dereferences freed memory; calling it on an uninitialised pointer reads undefined bytes.
**Impact:** Undefined behaviour (silent memory corruption or crash) if `move()` is ever called incorrectly. Currently all call sites are correct, so the impact is latent.
**Fix:** Add `guard self.allocated` and `guard self.initialized` checks with `fatalError` messages, consistent with the other methods.

---

## 24. LOW: `Ptr.underlying` and `capacity` exposed with insufficient access control
**File:** `EXT4+Ptr.swift`
**Bug:** `let underlying: UnsafeMutablePointer<T>` is internal (not `private`). External code can call `underlying.pointee`, `underlying.move()`, etc., bypassing all the `allocated`/`initialized` state tracking. `capacity` is `private var` but never mutated after init.
**Impact:** Bypassing the state flags via `underlying` is unsafe. `var capacity` misleads readers into thinking mutation is possible.
**Fix:** Make `underlying` `private let` and `capacity` `private let`.

---

## 25. LOW: Dead private methods `walkWithParents` and `walk` in `EXT4Reader+IO`
**File:** `EXT4Reader+IO.swift`
**Bug:** `walkWithParents` and `walk` are private methods that are never called anywhere in the codebase. They duplicate traversal logic already present in `resolvePath` and are logically incorrect (they do not follow symlinks). Their presence implies a second traversal path that does not exist.
**Impact:** Code maintenance burden and potential confusion about which traversal implementation is authoritative.
**Fix:** Remove both dead methods.

---

## 26. LOW: `superBlock.rootBlocksCountLow` misidentifies the EXT4 field
**File:** `EXT4+Types.swift`
**Bug:** The on-disk field `s_r_blocks_count_lo` is the count of blocks **reserved** for privileged users. The "r" stands for "reserved", not "root". The Swift name `rootBlocksCountLow` is incorrect.
**Impact:** Misleading field name that could cause callers to misinterpret the field's purpose.
**Fix:** Rename to `reservedBlocksCountLow`.

---

## 27. LOW: `uint32` Darwin C type alias used instead of Swift `UInt32`
**File:** `EXT4+Formatter.swift` (`commitInodeTable`)
**Bug:** `uint32(self.inodes.count)` uses the Darwin C type alias `uint32` imported from macOS system headers via Foundation. This is equivalent to `UInt32` on macOS but is not available on Linux (no `uint32` type alias in swift-corelibs-foundation).
**Impact:** Compilation failure on Linux. The code is silently platform-specific despite no `#if os(macOS)` guard.
**Fix:** Use the Swift standard type `UInt32(self.inodes.count)`.

---

## 28. LOW: `FilePath.bytes` loop condition checks pointer address instead of byte value
**File:** `FilePath+Extensions.swift` (`bytes`)
**Bug:** `while UInt(bitPattern: ptr) != 0` tests whether the pointer *address* is null. `withCString` always provides a non-null pointer and `ptr.successor()` never produces a null address. The inner `if ptr.pointee == 0x00 { break }` is doing the actual work; the outer condition is always `true` and is dead code.
**Impact:** The code works correctly but the misleading outer condition implies a null-pointer-sentinel iteration pattern that does not exist here.
**Fix:** Remove the outer condition; use `while ptr.pointee != 0` as the sole loop guard.
