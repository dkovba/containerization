# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: Wrong inode fields used for file creation timestamp
**File:** EXT4Reader+Export.swift:76, 159
**Bug:** `inode.ctimeExtra` and `inode.ctime` are the *change-time* (metadata change) fields. The file creation timestamp is stored in `inode.crtimeExtra` / `inode.crtime`. Using the wrong fields silently exports incorrect creation dates for every file and directory.
**Impact:** Every exported tar/OCI entry carries the wrong creation timestamp. Downstream tools or runtimes that rely on creation dates (e.g. make-style dependency checks, provenance auditing) receive corrupt data for the entire container image.
**Fix:** Replace `inode.ctimeExtra`/`inode.ctime` with `inode.crtimeExtra`/`inode.crtime`.

---

## 2. CRITICAL: Unaligned memory loads produce undefined behavior on all architectures
**Files:** EXT4+Extensions.swift:80-83, EXT4+Xattrs.swift:64, 74, EXT4Reader+Export.swift:173, 186, EXT4+Reader.swift:215, 224
**Bug:** `withUnsafeBytes { $0.load(as: UInt16/UInt32.self) }` requires the buffer to be naturally aligned (2-byte for `UInt16`, 4-byte for `UInt32`). Sub-slices of `Data` or `[UInt8]` carry no alignment guarantee. On ARM64 this is a bus error / hardware trap; on x86 it produces silently wrong values under certain compiler optimization levels.
**Impact:** Crashes or silent data corruption when parsing xattr entries, extent headers, extent leaves, extent indices, and the xattr block/inline header magic. Affects every file that has extended attributes and every file whose data spans more than one extent block.
**Fix:** Replace all `$0.load(as:)` calls on unaligned byte slices with explicit byte-shift assembly (`UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | ...`).

---

## 3. CRITICAL: `Date(fsTimestamp:)` does not sign-extend the 34-bit seconds field
**File:** EXT4Reader+Export.swift:206-209
**Bug:** The EXT4 filesystem timestamp encodes seconds as a 34-bit two's-complement signed integer in bits 0–33. The code read it as `Int64(fsTimestamp & 0x3_ffff_ffff)`, which always produces a non-negative value. Any timestamp with bit 33 set (dates before 1970 or after ~2378 in the high range) is decoded as the wrong positive number.
**Impact:** All files with pre-1970 creation/modification/access times get exported with incorrect dates. Container images that originate from sources using pre-epoch timestamps are silently corrupted.
**Fix:** Sign-extend bit 33: if `raw34 & (1 << 33) != 0`, OR in `0xFFFF_FFFC_0000_0000` before casting to `Int64`.

---

## 4. CRITICAL: `Date.fs()` clamps negative timestamps incorrectly, allowing later trap
**File:** EXT4+Formatter.swift:1329-1331
**Bug:** `Date.fs()` converts a `TimeInterval` (a `Double`) to the packed EXT4 timestamp format. For any date before 1970, `s = floor(timeIntervalSince1970)` is negative. The code checked `s > 0x3_ffff_ffff` to clamp the high end, but had no guard for negative values before calling `UInt64(s)`, which traps at runtime.
**Impact:** Writing any file with a pre-1970 mtime/atime/ctime to an EXT4 image crashes the process. Container image creation fails entirely if any source layer contains such files (e.g. files copied from certain legacy archives or synthetic test data).
**Fix:** Add `if s < 0 { return 0 }` before the `UInt64(s)` conversion.

---

## 5. CRITICAL: `Date.fs()` wrong upper clamp allows `UInt64` overflow trap
**File:** EXT4+Formatter.swift:1322-1326
**Bug:** The EXT4 34-bit seconds field holds a maximum value of `0x3_ffff_ffff`. The code clamped at `0x3_7fff_ffff`, a value 25% larger than the field capacity. Any timestamp between `0x3_7fff_ffff` and `0x3_ffff_ffff` was passed through unclamped, overflowing the 34-bit field when packed.
**Impact:** Timestamps in the year range ~2242–2378 are packed incorrectly, corrupting mtime/atime/ctime in the generated filesystem image. The overflow also produces incorrect nanosecond values in bits 34–63.
**Fix:** Change the clamp constant to `0x3_ffff_ffff`.

---

## 6. CRITICAL: Directory scan stops at first deleted entry, silently losing remaining files
**File:** EXT4+Reader.swift:179-181
**Bug:** When parsing a directory block, an inode number of 0 means the entry is a deleted/unused slot. The code `break`ed out of the entire loop on the first such entry. Deleted entries can appear anywhere in the block, not just at the end; entries after the first deletion are never visited.
**Impact:** Any directory that had files deleted from it will have those and all subsequent entries missing from the in-memory tree. Files that happen to sort alphabetically after deleted files become invisible to the reader and formatter.
**Fix:** Replace `break` with `offset += Int(dirEntry.recordLength); continue` to skip the deleted entry and continue scanning.

---

## 7. HIGH: `XAttrBlock` struct has wrong size due to `[UInt32]` array field
**File:** EXT4+Types.swift:593
**Bug:** `XAttrHeader.reserved` was declared as `[UInt32]` (a Swift `Array`—a heap-allocated reference type with 8-byte pointer size on 64-bit) instead of a fixed-size inline tuple `(UInt32, UInt32, UInt32)`. Because `XAttrHeader` is loaded with `loadLittleEndian(as:)` directly from raw filesystem bytes, `MemoryLayout<XAttrHeader>.size` must exactly match the on-disk structure (28 bytes). With `[UInt32]` it is 16+8=24 bytes and the field contains a dangling Swift object pointer instead of three reserved words.
**Impact:** Any access to xattr block headers reads garbage data, corrupting the magic comparison and all fields that follow the reserved words. Xattr reads and writes are silently broken for all files with block-stored extended attributes.
**Fix:** Change `let reserved: [UInt32]` to `let reserved: (UInt32, UInt32, UInt32)`.

---

## 8. HIGH: `Ptr.initialize(to:)` deinitializes `capacity` elements instead of 1
**File:** EXT4+Ptr.swift:46
**Bug:** `Ptr<T>` always allocates exactly 1 element (`capacity: 1` at every call site). When re-initializing an already-initialized pointer, the code called `underlying.deinitialize(count: self.capacity)`. If `capacity` were ever greater than 1 this would run destructors on uninitialized memory. Even for `capacity == 1` the intent is clearly to deinitialize the single live element.
**Impact:** Latent memory corruption / double-free if `Ptr` is ever allocated with `capacity > 1`. The current code happens to be safe only by coincidence.
**Fix:** Change `deinitialize(count: self.capacity)` to `deinitialize(count: 1)`.

---

## 9. HIGH: `Ptr.move()` invokes undefined behavior on uninitialized pointer
**File:** EXT4+Ptr.swift:74-80
**Bug:** `move()` called `underlying.move()` unconditionally, including when `self.initialized == false`. Moving from uninitialized memory is undefined behavior in Swift's ownership model and can produce arbitrary values or corrupt the allocator.
**Impact:** If `move()` is called after `deinitialize()` or before `initialize()`, the returned value is garbage and the allocator state may be corrupted.
**Fix:** Add `guard self.initialized else { fatalError("attempt to move from uninitialized Ptr") }` at the top of `move()`.

---

## 10. HIGH: Hardlink deletion decrements link count with wrong threshold
**File:** EXT4+Formatter.swift:238
**Bug:** When deleting a hardlink the code checked `linkedInode.linksCount > 2` before decrementing. The correct threshold is `> 0`—a link count of 1 or 2 is valid and the count should still be decremented (a count of 0 means the inode is already unlinked). With the `> 2` guard, files with 1 or 2 remaining links are never decremented, leaving them permanently over-counted and preventing inode reclamation.
**Impact:** Deleting hardlinked files with few links produces a corrupt filesystem image with incorrect link counts. Hardlinks with `linksCount <= 2` are never properly freed.
**Fix:** Change `linkedInode.linksCount > 2` to `linkedInode.linksCount > 0`.

---

## 11. HIGH: `delete()` uses wrong variable for inode guard, allowing reserved inode deletion
**File:** EXT4+Formatter.swift:244
**Bug:** The guard `guard inodeNumber > FirstInode` referenced a local `Int` variable `inodeNumber` (computed from `pathNode.inode - 1` as a zero-based index) rather than `pathNode.inode` (the 1-based EXT4 inode number). Since `inodeNumber = pathNode.inode - 1`, the guard allowed deletion of inode 12 (which maps to `inodeNumber = 11`, passing `> 11` when `FirstInode = 11`). Additionally `inodeNumber` is an `Int` while `FirstInode` is a `UInt32`, relying on implicit conversion.
**Impact:** Reserved system inodes (inode ≤ 11) could be freed, corrupting the filesystem structure. The lost+found inode (inode 11) is particularly at risk.
**Fix:** Change `guard inodeNumber > FirstInode` to `guard pathNode.inode > EXT4.FirstInode`.

---

## 12. HIGH: `uint32` identifier used instead of `UInt32`, causing silent type mismatch
**File:** EXT4+Formatter.swift:955
**Bug:** `uint32` was used as a function call (`uint32(self.inodes.count)`), but no such function exists in scope. The code should use `UInt32(self.inodes.count)`. This appears to have compiled only because some other symbol named `uint32` happened to be in scope; the computation `tableSize - uint32(...) * EXT4.InodeSize` could silently produce the wrong arithmetic type or value.
**Impact:** Inode table padding calculation is wrong, potentially writing too few or too many zero-padding bytes and producing a malformed filesystem image.
**Fix:** Replace `uint32(self.inodes.count)` with `UInt32(self.inodes.count)`.

---

## 13. HIGH: `FileTreeNode.parent` is a strong reference, causing reference cycle and memory leak
**File:** EXT4+FileTree.swift:29
**Bug:** `FileTreeNode.parent` was a strong `var parent: Ptr<FileTreeNode>?`. Each node holds a strong reference to its parent via `Ptr`, and the parent holds strong references to children via `children: [Ptr<FileTreeNode>]`. This creates a reference cycle: parent → child (`children` array) and child → parent (`parent` field). Swift ARC cannot break cycles, so the entire tree leaks on deallocation.
**Impact:** The full file tree (one node per filesystem entry) is leaked every time an `EXT4Reader` or `EXT4Formatter` is deallocated. For large container images this can be hundreds of megabytes.
**Fix:** Change `private var parent` to `private weak var parent`.

---

## 14. MEDIUM: Xattr attribute sort comparator is incorrect (non-strict weak ordering)
**File:** EXT4+Xattrs.swift:178-184
**Bug:** The sort comparator used `||` (OR) across three independent conditions: `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)`. This is not a strict weak ordering—e.g. an entry with a smaller index but longer name would compare as both less-than and greater-than another entry depending on which pair is presented to the comparator, violating the sort contract and producing undefined behavior in Swift's sort algorithm.
**Impact:** Xattr entries may be written to the filesystem in a non-deterministic or incorrect order, producing images that differ across runs and potentially violating the EXT4 on-disk ordering requirement for binary search in xattr blocks.
**Fix:** Sort lexicographically with proper precedence: first by `index`, then by `name.count`, then by `name`.

---

## 15. MEDIUM: Xattr block parse loop has off-by-one, dropping last entry
**File:** EXT4+Xattrs.swift:255
**Bug:** The loop condition was `while i + 16 < buffer.count`, which stops when exactly 16 bytes remain. An xattr entry is exactly 16 bytes, so the last entry is always skipped.
**Impact:** The final extended attribute in any xattr block is silently ignored on read. Files with a single xattr or whose last attribute is significant (e.g. SELinux labels, capabilities) are read incorrectly.
**Fix:** Change `<` to `<=`: `while i + 16 <= buffer.count`.

---

## 16. MEDIUM: `FilePath.init?(_ data: Data)` uses `bindMemory` without null-terminator guarantee
**File:** FilePath+Extensions.swift:56-63
**Bug:** `baseAddress.bindMemory(to: CChar.self, capacity: data.count)` followed by `String(cString:)` assumes the `Data` buffer is null-terminated. `Data` objects derived from filesystem reads carry no such guarantee. If the data contains no null byte, `String(cString:)` reads past the buffer boundary, invoking undefined behavior.
**Impact:** Reading symlink targets or path data from certain filesystem structures can cause out-of-bounds reads, potentially crashing or leaking adjacent memory contents.
**Fix:** Use `data.prefix(while: { $0 != 0 })` to explicitly truncate at the first null byte, then construct the string with `String(bytes:encoding: .utf8)`.

---

## 17. LOW: `FilePath.bytes` loop condition checks pointer address, not pointed-to value
**File:** FilePath+Extensions.swift:27
**Bug:** `while UInt(bitPattern: ptr) != 0` converts the pointer itself to an integer and checks whether it is non-null. For any valid allocated C string this is always true, so the loop never terminates via this condition. The actual termination relied on a second inner check `if ptr.pointee == 0x00 { break }`, making the outer condition redundant and misleading. The inner `break` was also unnecessary since `while ptr.pointee != 0` handles both cases cleanly.
**Impact:** No functional bug at runtime (the inner `break` prevents infinite looping), but the code is fragile and misleading. A future refactor removing the inner guard would introduce an infinite loop.
**Fix:** Simplify to `while ptr.pointee != 0`.

---

## 18. LOW: Circular symlink detection in `Hardlinks.resolve` never inserts visited nodes
**File:** Formatter+Unpack.swift:185-191
**Bug:** `visited` was declared as `let` (immutable), so `visited.insert(next)` was missing and the set always contained only the initial `target`. For a chain `A → B → C → D → C`, starting from `key = A`, the visited set is `{B}`. The loop visits C, D, C, D... infinitely since neither C nor D is ever recorded as visited.
**Impact:** Any symlink chain with a cycle that does not include the first hop target will loop forever, hanging the process during image unpack.
**Fix:** Change `let visited` to `var visited` and add `visited.insert(next)` inside the loop after advancing `next`.
