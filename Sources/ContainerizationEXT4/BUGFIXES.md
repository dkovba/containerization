# ContainerizationEXT4 — Verified Bug Report

Consolidated from 9 analysis branches and verified against the `main` branch source code.
Issues are ordered by severity (CRITICAL → HIGH → MEDIUM → LOW).

Issues merged during verification:
- **Former #10 + #30** merged: both concern `uint32(self.inodes.count) * EXT4.InodeSize` on the same line — the C-alias naming and the potential overflow.
- **Former #32 + #56** merged: the ceiling-division off-by-one (#32) directly causes the `last!` force-unwrap crash (#56) when it creates an empty leaf block.
- **Former #15 + #16** merged: both are the same class of bug — Swift `Array` used instead of fixed-size tuple in on-disk structs.
- **Former #25 + #26** merged: both are safety-guard gaps in the `Ptr` class — `deallocate()` skips `deinitialize`, and `move()` has no guards.
- **sonnet-fix** mapped to merged doc entries: #1 (pre-1970 crash), #3 (timestamp precision), #4 (crtime), #5 (xattr sort), #6 (Array structs), #7 (linksCount), #8 (inodeNumber guard), #9 (visited set), #10 (5-byte xattr slice), #12 (FilePath bindMemory), #14 (getDirEntries break), #15 (Ptr safety gaps), #16 (parent retain cycle), #17 (Ptr.initialize count), #21 (uint32), #25 (xattr off-by-one), #32 (ExtentLeaf/Index load), #42 (FilePath.bytes loop). One new issue found: see #23.

---

## 1. CRITICAL: `Date.fs()` crashes on pre-1970 dates

**File:** `EXT4+Formatter.swift:1329`
**Bug:** `UInt64(s)` traps when `s` is negative. The guard at line 1321 only catches `s < -0x8000_0000`, leaving the range `[-0x8000_0000, 0)` unhandled. Any negative `s` in this range reaches `UInt64(s)`, which crashes because `UInt64` cannot represent negative values. The nanosecond computation `truncatingRemainder(dividingBy: 1)` also returns a negative fractional part.
**Fix:** Add `guard s >= 0 else { return 0 }` before the `UInt64` conversions.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk X
opus-1m X
opus-1m-bulk X
sonnet-fix X
sonnet-fix-bulk X

---

## 2. CRITICAL: Extent block start double-counted, corrupting data in large files

**File:** `EXT4+Formatter.swift:1138`
**Bug:** `fillExtents` is called with `start: blocks.start + offset`. Inside `fillExtents`, `extentStart = start + extentBlock` where `extentBlock = offset + i * MaxBlocksPerExtent`. Since `start` already includes `offset`, the result is `blocks.start + 2*offset + i*MaxBlocksPerExtent`. Every extent in depth-1 trees points to the wrong physical block.
**Fix:** Pass `start: blocks.start` so `offset` is applied only once inside `fillExtents`.

sonnet X
sonnet-bulk X
sonnet-1m X
sonnet-1m-bulk X
opus X
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 3. CRITICAL: Exported timestamps lose all sub-second precision and post-2038 range

**File:** `EXT4Reader+Export.swift:76–78`
**Bug:** `UInt64((inode.ctimeExtra << 32) | inode.ctime)` — the shift `inode.ctimeExtra << 32` is performed as `UInt32` arithmetic, which always produces 0 (shifting a 32-bit value left by 32). The `Extra` field (nanoseconds and epoch-extension bits) is silently discarded. All six timestamp assignments across both export paths are affected.
**Fix:** Cast before shifting: `(UInt64(inode.ctimeExtra) << 32) | UInt64(inode.ctime)`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk X

---

## 4. CRITICAL: Creation date uses inode change time (`ctime`) instead of birth time (`crtime`)

**File:** `EXT4Reader+Export.swift:76`
**Bug:** `entry.creationDate` is set from `inode.ctimeExtra`/`inode.ctime`, which is the inode *change* time (last chmod/chown/link), not the file *creation/birth* time stored in `crtime`/`crtimeExtra`.
**Fix:** Use `inode.crtimeExtra` and `inode.crtime` for `creationDate`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus X
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 5. CRITICAL: Block xattr sort comparator violates strict weak ordering

**File:** `EXT4+Xattrs.swift:180`
**Bug:** The sort closure `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)` uses `||` to chain criteria. When `a.index > b.index` but `a.name.count < b.name.count`, the comparator returns `true` (a < b), contradicting the primary sort key. This violates strict weak ordering.
**Fix:** Use proper lexicographic chaining with `!=` guards.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk X
opus-1m X
opus-1m-bulk X
sonnet-fix X
sonnet-fix-bulk X

---

## 6. CRITICAL: On-disk struct fields use `[UInt8]`/`[UInt32]` instead of fixed-size tuples

**File:** `EXT4+Types.swift:543, 545, 593`
**Bug:** `DirectoryTreeRoot.dotName`, `dotDotName` are `[UInt8]`, and `XAttrHeader.reserved` is `[UInt32]`. Swift `Array` is a heap-allocated reference type (pointer + length + capacity), not inline storage. `MemoryLayout<T>.size` returns the wrong size and `withUnsafeBytes(of:)` serializes pointer metadata instead of inline values.
**Fix:** Replace `[UInt8]` with `(UInt8, UInt8, UInt8, UInt8)` and `[UInt32]` with `(UInt32, UInt32, UInt32)`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 7. HIGH: Hardlink `linksCount` never decremented (threshold > 2 should be > 1)

**File:** `EXT4+Formatter.swift:238`
**Bug:** `if linkedInode.linksCount > 2 { linkedInode.linksCount -= 1 }`. A file with exactly 2 links (original + 1 hardlink) has `linksCount = 2`; `2 > 2` is false, so the count is never decremented. The inode remains marked as in-use.
**Fix:** Change to `linksCount > 1`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk X
sonnet-fix X
sonnet-fix-bulk X

---

## 8. HIGH: Off-by-one in unlink guard prevents block freeing for first user inodes

**File:** `EXT4+Formatter.swift:244`
**Bug:** `guard inodeNumber > FirstInode` where `inodeNumber = Int(pathNode.inode) - 1` (0-based) and `FirstInode = 11` (1-based). For inode 11: `inodeNumber = 10`, `10 > 11` is false — blocks are never freed. For inode 12: `inodeNumber = 11`, `11 > 11` is false — same problem.
**Fix:** Compare using the 1-based inode number: `guard pathNode.inode > EXT4.FirstInode`.

sonnet X
sonnet-bulk X
sonnet-1m X
sonnet-1m-bulk X
opus X
opus-bulk
opus-1m
opus-1m-bulk X
sonnet-fix X
sonnet-fix-bulk

---

## 9. HIGH: Hardlink `resolve()` uses immutable `visited` set — cycle detection broken

**File:** `Formatter+Unpack.swift:185`
**Bug:** `let visited: Set<FilePath> = [next]` is immutable. The loop checks `visited.contains(item)` but never inserts new items. Only direct self-loops (A→A) are detected; longer cycles (A→B→C→B) cause infinite loops.
**Fix:** Change to `var visited` and add `visited.insert(next)` inside the loop.

sonnet X
sonnet-bulk X
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk X
opus-1m X
opus-1m-bulk X
sonnet-fix X
sonnet-fix-bulk X

---

## 10. HIGH: Xattr header read uses 5-byte slice (`buffer[0...4]`) for a 4-byte UInt32

**File:** `EXT4Reader+Export.swift:173, 186`
**Bug:** `buffer[0...4]` is a closed range producing 5 bytes (indices 0–4). A `UInt32` requires 4 bytes. On a 4-byte buffer this causes an out-of-bounds crash.
**Fix:** Change to `buffer[0..<4]`.

sonnet X
sonnet-bulk X
sonnet-1m X
sonnet-1m-bulk X
opus X
opus-bulk X
opus-1m X
opus-1m-bulk X
sonnet-fix X
sonnet-fix-bulk X

---

## 11. HIGH: Inline symlink target includes up to 59 trailing null bytes

**File:** `EXT4Reader+Export.swift:133`
**Bug:** `EXT4.tupleToArray(inode.block)` returns all 60 bytes. `String(bytes: linkBytes, encoding: .utf8)` includes the null padding. Symlink targets become unresolvable.
**Fix:** Use `linkBytes.prefix(Int(size))`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk X
sonnet-fix
sonnet-fix-bulk X

---

## 12. HIGH: `FilePath.init?(_ data: Data)` reads past buffer boundary

**File:** `FilePath+Extensions.swift:56`
**Bug:** `String(cString:)` reads until a null terminator with no bounds check. If the `Data` has no null byte, reads continue into adjacent heap memory — undefined behaviour.
**Fix:** Use `String(bytes: data, encoding: .utf8)` which reads exactly `data.count` bytes.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 13. HIGH: UID/GID truncated to 16 bits during export

**File:** `EXT4Reader+Export.swift:74–75`
**Bug:** `uid_t(inode.uid)` and `gid_t(inode.gid)` use only the low 16-bit fields, discarding `uidHigh`/`gidHigh`. UIDs/GIDs above 65535 are silently truncated.
**Fix:** Combine: `uid_t(UInt32(inode.uidHigh) << 16 | UInt32(inode.uid))`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 14. HIGH: `getDirEntries` stops at first deleted entry, losing subsequent valid entries

**File:** `EXT4+Reader.swift:179`
**Bug:** `if dirEntry.inode == 0 { break }` stops parsing the entire block. In ext4, deleted entries (inode 0) can appear mid-block with valid entries following.
**Fix:** Skip deleted entries with `continue` after advancing by `recordLength`. Also guard `recordLength == 0` to avoid infinite loops.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 15. HIGH: `Ptr<T>` safety gaps: `deallocate()` skips deinitialize, `move()` has no guards

**File:** `EXT4+Ptr.swift:53–78`
**Bug:** (a) `deallocate()` calls `self.underlying.deallocate()` directly without first calling `deinitialize()`, leaking ARC-managed values inside `T`. (b) `move()` has no `guard self.allocated && self.initialized` check, risking undefined behaviour on deallocated or uninitialized memory.
**Fix:** Call `deinitialize` before `deallocate` in `deallocate()`. Add guards to `move()`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 16. HIGH: `FileTreeNode.parent` strong reference creates ARC retain cycle

**File:** `EXT4+FileTree.swift:29`
**Bug:** `parent` is `var Ptr<FileTreeNode>?` (strong). Every child holds a strong `Ptr` to its parent; the parent holds children in a `[Ptr<FileTreeNode>]` array. This forms a cycle that ARC cannot break.
**Fix:** Declare as `weak var parent: Ptr<FileTreeNode>?`.

sonnet X
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 17. HIGH: `Ptr.initialize(to:)` deinitializes wrong count

**File:** `EXT4+Ptr.swift:46`
**Bug:** `self.underlying.deinitialize(count: self.capacity)` but `initialize(to:)` only initializes 1 element. If `capacity > 1`, this deinitializes uninitialized memory (undefined behaviour). In practice capacity is always 1, making this latent.
**Fix:** Use `deinitialize(count: 1)`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 18. HIGH: Ceiling-division off-by-one allocates extra extent block, causing `last!` crash

**File:** `EXT4+Formatter.swift:1104, 1148`
**Bug:** `numExtents / extentsPerBlock + 1` always adds 1, even when evenly divisible. The extra empty leaf block has zero extents, so `leafNode.leaves.last!` force-unwraps `nil` and crashes.
**Fix:** Use proper ceiling division: `(numExtents + extentsPerBlock - 1) / extentsPerBlock`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk X
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 19. HIGH: Dead condition in last block group bitmap — special handling never executes

**File:** `EXT4+Formatter.swift:808, 841`
**Bug:** Inside `for group in blockGroupSize.blockGroups..<totalGroups.lo`, the conditions `if group == totalGroups.lo` can never be true (exclusive upper bound). The last block group's partial bitmap is never written correctly.
**Fix:** Change to `group == totalGroups.lo - 1`.

sonnet
sonnet-bulk X
sonnet-1m
sonnet-1m-bulk X
opus
opus-bulk
opus-1m
opus-1m-bulk X
sonnet-fix
sonnet-fix-bulk

---

## 20. HIGH: Crash on empty range when all group descriptor blocks are used

**File:** `EXT4+Formatter.swift:702`
**Bug:** `for i in usedGroupDescriptorBlocks + 1...self.groupDescriptorBlocks` — Swift closed ranges crash when lower > upper. When all descriptor blocks are used, `usedGroupDescriptorBlocks + 1 > self.groupDescriptorBlocks`.
**Fix:** Guard with `if usedGroupDescriptorBlocks < self.groupDescriptorBlocks`.

sonnet
sonnet-bulk X
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 21. HIGH: `uint32` C type alias and potential UInt32 overflow in inode table computation

**File:** `EXT4+Formatter.swift:955`
**Bug:** `uint32(self.inodes.count) * EXT4.InodeSize` uses the lowercase `uint32` (a Darwin C type alias, not available on Linux) and the UInt32 multiplication can overflow at ~16.7M inodes (`UInt32.max / 256`).
**Fix:** Use `UInt64(self.inodes.count) * UInt64(EXT4.InodeSize)`.

sonnet X
sonnet-bulk X
sonnet-1m X
sonnet-1m-bulk X
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk X

---

## 22. HIGH: Wrong `freeBlocksCount` written to group descriptor

**File:** `EXT4+Formatter.swift:774–782`
**Bug:** A `freeBlocks` variable is computed with careful edge-case logic (lines 758–769) but is never used. A separate `freeBlocksCount = UInt32(self.blocksPerGroup - blocks)` ignores those edge cases and is used for the group descriptor.
**Fix:** Use the `freeBlocks` variable for the group descriptor.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk X
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk X

---

## 23. HIGH: `Date.fs()` wrong upper clamp silently corrupts far-future timestamps

**File:** `EXT4+Formatter.swift:1325`
**Bug:** The upper clamp for the EXT4 34-bit seconds field used `0x3_7fff_ffff` instead of the correct maximum `0x3_ffff_ffff` (2^34 − 1). Any `TimeInterval` whose floor exceeds `0x3_7fff_ffff` (≈ year 2446) but is below `0x3_ffff_ffff` passes the clamp unchecked. The packed result then has bits set above bit 33, overwriting the nanosecond field in bits 34–63.
**Fix:** Change the clamp constant and return value from `0x3_7fff_ffff` to `0x3_ffff_ffff`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 24. MEDIUM: Force-unwrap `asciiValue!` crashes on non-ASCII xattr names

**File:** `EXT4+Xattrs.swift:60`
**Bug:** `UInt32(char.asciiValue!)` force-unwraps. Any non-ASCII character in an xattr name crashes the process.
**Fix:** Use `char.asciiValue ?? 0` or iterate over `.utf8`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk X

---

## 25. MEDIUM: Force-unwrap `String(bytes:encoding:.ascii)!` crashes on non-ASCII xattr names

**File:** `EXT4+Xattrs.swift:264`
**Bug:** `String(bytes: rawName, encoding: .ascii)!` force-unwraps. Non-ASCII bytes crash the process.
**Fix:** Use `String(bytes: rawName, encoding: .ascii) ?? ""` or `guard let`.

sonnet X
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk X

---

## 26. MEDIUM: Xattr read loop off-by-one skips last entry at buffer boundary

**File:** `EXT4+Xattrs.swift:256`
**Bug:** `while i + 16 < buffer.count` uses strict `<`. When exactly 16 bytes remain (`i + 16 == buffer.count`), the valid last entry is skipped.
**Fix:** Change to `i + 16 <= buffer.count`.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk X
opus-1m X
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 27. MEDIUM: Xattr value slice has no bounds check

**File:** `EXT4+Xattrs.swift:269`
**Bug:** `buffer[valueStart..<valueEnd]` is created without verifying `valueEnd <= buffer.count`. Corrupted xattr entries with invalid offset/size cause out-of-bounds crashes.
**Fix:** Add `guard valueEnd <= buffer.count`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus X
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 28. MEDIUM: `visitedInodes` not cleared after absolute symlink resets traversal to root

**File:** `EXT4Reader+IO.swift:362`
**Bug:** When an absolute symlink resets `current = EXT4.RootInode`, `visitedInodes` retains inode numbers from the pre-reset traversal. Legitimate re-visits via a different path falsely trigger `symlinkLoop`.
**Fix:** Add `visitedInodes = []` alongside the root reset.

sonnet X
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 29. MEDIUM: `seek(block:)` missing on non-macOS platforms

**File:** `EXT4Reader+Export.swift`, `EXT4+Reader.swift`
**Bug:** `seek(block:)` is defined inside `#if os(macOS)` in `EXT4Reader+Export.swift`, but called from platform-independent code in `EXT4+Reader.swift` (`getDirTree`, `getExtents`). Fails to compile on Linux.
**Fix:** Move `seek(block:)` outside the platform guard.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk X
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 30. MEDIUM: Hardcoded `logBlockSize = 2` only correct for 4096-byte blocks

**File:** `EXT4+Formatter.swift:889`
**Bug:** `superblock.logBlockSize = 2` is hardcoded. The ext4 formula is `blockSize = 1024 << logBlockSize`. For 1024-byte blocks it should be 0, for 2048 it should be 1. The formatter accepts configurable `blockSize` but always writes 2.
**Fix:** Compute dynamically: `UInt32((self.blockSize / 1024).trailingZeroBitCount)`.

sonnet
sonnet-bulk X
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 31. MEDIUM: Mixed UInt64/UInt32 comparisons in `close()` rely on custom operators

**File:** `EXT4+Formatter.swift` (various lines in `close()`)
**Bug:** Several comparisons mix `UInt64` and `UInt32` without explicit casts (e.g., `self.size < minimumDiskSize`). Custom operator overloads in `Integer+Extensions.swift` handle conversions but can silently truncate via `.lo`.
**Fix:** Use explicit type conversions at each comparison.

sonnet
sonnet-bulk X
sonnet-1m
sonnet-1m-bulk X
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 32. MEDIUM: `UInt64 / UInt32` operator silently truncates quotient via `.lo`

**File:** `Integer+Extensions.swift:37`
**Bug:** `(lhs / UInt64(rhs)).lo` silently discards the upper 32 bits. If the quotient exceeds `UInt32.max`, the result is wrong with no trap.
**Fix:** Use `UInt32(lhs / UInt64(rhs))`, which traps visibly on overflow.

sonnet X
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 33. MEDIUM: ExtentLeaf and ExtentIndex loaded without endian conversion

**File:** `EXT4+Reader.swift:217, 226`
**Bug:** Inline extent data uses `$0.load(as: ExtentLeaf.self)` and `$0.load(as: ExtentIndex.self)` while on-disk block data uses `$0.loadLittleEndian(as:)`. Inconsistent; incorrect on big-endian platforms.
**Fix:** Use `$0.loadLittleEndian(as:)` consistently.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus X
opus-bulk X
opus-1m X
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 34. MEDIUM: `finishDirEntryBlock` writes past block end when `left < 8`

**File:** `EXT4+Formatter.swift:1231–1248`
**Bug:** The guard `left <= 0` does not catch `left` between 1 and 7. A DirectoryEntry is 8 bytes; writing it when `left < 8` overflows into the next block. The `if left < 4` check fires too late — after the write.
**Fix:** Add `guard left >= MemoryLayout<DirectoryEntry>.size` before writing.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk X
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 35. MEDIUM: GDT offset formula wrong for 1024-byte-block filesystems

**File:** `EXT4+Reader.swift:123`
**Bug:** `offset = bs + number * groupDescriptorSize` uses `bs` (block size) as the GDT start. For 1024-byte blocks, the superblock is at block 1 and the GDT starts at block 2 (offset 2048). The formula gives offset 1024, overlapping the superblock.
**Fix:** Use `(UInt64(_superBlock.firstDataBlock) + 1) * blockSize`.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 36. MEDIUM: `Endian` global recomputed on every call

**File:** `UnsafeLittleEndianBytes.swift:73`
**Bug:** `public var Endian: Endianness` is a computed property calling `CFByteOrderGetCurrent()` on every access. Endianness never changes at runtime. Thousands of redundant CoreFoundation calls per format operation.
**Fix:** Change to `public let Endian: Endianness = { ... }()`.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 37. MEDIUM: `loadLittleEndian` reverses entire buffer on big-endian platforms

**File:** `UnsafeLittleEndianBytes.swift:61`
**Bug:** `Array(self.reversed())` reverses all bytes. For multi-field structs this is incorrect — it swaps both field order and byte order within fields. Only single-scalar loads are handled correctly.
**Fix:** Use `Array(self.prefix(size).reversed())` or per-field byte swapping.

sonnet X
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 38. MEDIUM: `copyMemory` precondition violation on partial reads

**File:** `EXT4Reader+IO.swift:228–245`
**Bug:** `dest` is allocated with `count: chunk` before reading. If `FileHandle.read` returns fewer bytes, `dest.copyMemory(from: sourceBytes)` copies `sourceBytes.count` bytes into a `dest` of size `chunk`. While `copyMemory(from:)` copies `from.count` bytes (safe), the `dest` buffer has uninitialized trailing bytes that are later included in the output.
**Fix:** Size `dest` to `data.count` after the read, or copy only `data.count` bytes.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 39. LOW: `tupleToArray` uses Mirror reflection

**File:** `EXT4+Extensions.swift:95–98`
**Bug:** Uses `Mirror(reflecting: tuple)` which is slow, not type-safe, and not guaranteed to preserve element order across Swift versions.
**Fix:** Use `withUnsafeBytes(of: tuple) { Array($0) }`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 40. LOW: `XAttrEntry.init` uses unbounded range `bytes[12...]`

**File:** `EXT4+Extensions.swift:89`
**Bug:** `bytes[12...]` is unbounded. The `guard bytes.count == 16` ensures correctness, but the pattern is fragile — removing the guard would silently include extra bytes.
**Fix:** Use `bytes[12..<16]`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk X
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 41. LOW: `FileTree.path` always returns `"/"` when root name is `"/"`

**File:** `EXT4+FileTree.swift:78`
**Bug:** `pushing(FilePath(last))` where `last` is `"/"` pushes an absolute path, which replaces the entire base path per `FilePath.pushing` semantics. Every node's `path` returns `"/"`. Currently unexploited because the formatter does not call `.path`.
**Fix:** Handle root name `"/"` specially or use a different joining strategy.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 42. LOW: Pointless String→Data→String round-trip in `FileTree.path`

**File:** `EXT4+FileTree.swift:72–78`
**Bug:** `path.data(using: .utf8)` followed by `String(data: data, encoding: .utf8)` is a no-op that adds two unnecessary `nil` failure paths.
**Fix:** Use the string directly.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 43. LOW: `FilePath.bytes` loop condition checks pointer address instead of byte value

**File:** `FilePath+Extensions.swift:27`
**Bug:** `while UInt(bitPattern: ptr) != 0` tests if the pointer *address* is null. `withCString` never returns null, so this is always true. The loop terminates only via the inner `if ptr.pointee == 0x00 { break }`.
**Fix:** Use `while ptr.pointee != 0` as the loop condition.

sonnet X
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk

---

## 44. LOW: `Ptr.underlying` access control too permissive

**File:** `EXT4+Ptr.swift:21`
**Bug:** `let underlying: UnsafeMutablePointer<T>` has default internal access, allowing module code to bypass `Ptr`'s `allocated`/`initialized` safety guards.
**Fix:** Declare as `private let underlying`.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 45. LOW: Dead private methods `walkWithParents` and `walk` in EXT4Reader+IO

**File:** `EXT4Reader+IO.swift:383–443`
**Bug:** These private methods are defined but never called. `resolvePath` implements its own inline traversal logic.
**Fix:** Remove both methods.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 46. LOW: `superBlock.rootBlocksCountLow` field name is misleading

**File:** `EXT4+Types.swift`
**Bug:** Named `rootBlocksCountLow` but the ext4 field is `s_r_blocks_count_lo` (reserved blocks count). "root" is a misnomer for "reserved".
**Fix:** Rename to `reservedBlocksCountLow`.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 47. LOW: Typo `breathWiseChildTree` → `breadthWiseChildTree`

**File:** `EXT4+Formatter.swift:598`
**Bug:** Variable named `breathWiseChildTree` (breath) instead of `breadthWiseChildTree` (breadth-first traversal).

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 48. LOW: Typo "directory entrees" → "directory entries"

**File:** `EXT4.swift:213`
**Bug:** Documentation says "directory entrees" (a culinary term) instead of "directory entries".

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 49. LOW: Typo "a inode" → "an inode"

**File:** `EXT4.swift:116`
**Bug:** Documentation says "represents a inode" instead of "an inode".

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 50. LOW: Garbled comment "less than not a multiple of 4"

**File:** `EXT4+Xattrs.swift:21`
**Bug:** Comment reads "is less than not a multiple of 4" — should be "is not a multiple of 4".

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 51. FALSE POSITIVE: `sizeEntry` operator precedence

**File:** `EXT4+Xattrs.swift:46`
**Claimed bug:** `(name.count + 3) & ~3 + 16` was claimed to parse as `(name.count + 3) & (~3 + 16)` because `+` supposedly binds tighter than `&`.
**Why invalid:** In Swift, `&` (bitwise AND) has **higher** precedence than `+` (addition). The expression parses as `((name.count + 3) & ~3) + 16`, which is the intended round-up-to-multiple-of-4-then-add-16 computation. Verified empirically: `8 & 5 + 4` evaluates to `(8 & 5) + 4 = 4` in Swift, not `8 & (5 + 4) = 8`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus X
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 52. FALSE POSITIVE: `copyMemory` precondition violation on partial reads

**File:** `EXT4Reader+IO.swift:228–245`
**Claimed bug:** `dest.copyMemory(from: sourceBytes)` was claimed to violate a precondition when `sourceBytes.count < dest.count` (partial read).
**Why invalid:** `UnsafeMutableRawBufferPointer.copyMemory(from:)` copies exactly `from.count` bytes. When `from.count < dest.count`, only the first `from.count` bytes of `dest` are written — this is safe and well-defined. The remaining bytes in `dest` are unused because the caller tracks `bytesWritten` based on `data.count`.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m X
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 53. FALSE POSITIVE: Missing `verity` and `casefold` inode flag constants

**File:** `EXT4+Types.swift:466, 474`
**Claimed bug:** `InodeFlag` was claimed to be missing constants for `verity` (0x100000) and `casefold` (0x40000000).
**Why invalid:** These are optional ext4 features (`FS_VERITY_FL`, `EXT4_CASEFOLD_FL`) that this implementation does not support. The formatter never creates verity-enabled or case-folded filesystems, and the reader does not need to interpret these flags. Omitting unused feature constants is intentional scope limitation, not a bug.

sonnet X
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk

---

## 54. FALSE POSITIVE: `Date(fsTimestamp:)` zero-extends 34-bit seconds field

**File:** `EXT4Reader+Export.swift:206`
**Claimed bug:** `Int64(fsTimestamp & 0x3_ffff_ffff)` was claimed to zero-extend a 34-bit seconds field instead of sign-extending, causing pre-1970 dates to decode as far-future values.
**Why invalid:** Per the ext4 specification, the 34-bit seconds field is **unsigned**. The 2-bit epoch extension (bits 32–33 of the extra field) extends the timestamp range forward (to year 2446), not backward into negative territory. Zero-extension is the correct behavior. Additionally, this code path is unreachable in practice because issue #3 (the `extra << 32` UInt32 shift) causes the extra bits to always be 0.

sonnet
sonnet-bulk
sonnet-1m X
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix X
sonnet-fix-bulk X

---

## 55. CRITICAL: Unoccupied block group inode tables left as sparse holes, corrupting block allocator

**File:** `EXT4+Formatter.swift:871`
**Bug:** In the loop over unoccupied block groups (`blockGroupSize.blockGroups..<totalGroups.lo`), the code seeked directly to the bitmap position (`group * blocksPerGroup + inodeTableSizePerGroup`) without writing the preceding inode table blocks. Those blocks remained as sparse holes in the file and read back as zeros. The group descriptor correctly recorded `inodeTableLow = group * blocksPerGroup`, but the kernel read zeros from those hole-backed blocks and treated all blocks in the group as free. The block allocator then attempted to allocate blocks that overlap the inode table metadata, producing:
```
ext4_mb_mark_diskspace_used: Allocating blocks N–M which overlap fs metadata
EXT4-fs: Delayed block allocation failed ... with error 117
EXT4-fs: This should not happen!! Data will be lost
```
Every unoccupied block group (groups 8, 9, 10, … up to the last) was affected, as confirmed by 4090 evenly-spaced 4-block holes at `N * 32768` offsets in the sparse image.
**Fix:** Seek to `group * blocksPerGroup` (start of the inode table) and explicitly write `inodeTableSizePerGroup` zero blocks before writing the bitmaps, materializing the inode table region as real data rather than sparse holes.

sonnet
sonnet-bulk
sonnet-1m
sonnet-1m-bulk
opus
opus-bulk
opus-1m
opus-1m-bulk
sonnet-fix
sonnet-fix-bulk
ext4-bugs X

---

## 56. MEDIUM: `groupDescriptorBlocks` multiplied by 32, inflating GDT block count 32×

**File:** `EXT4+Formatter.swift:52, 963`
**Bug:** `groupDescriptorBlocks` is computed as `((groupCount - 1) / groupsPerDescriptorBlock + 1) * 32`. The trailing `* 32` confuses `groupDescriptorSize` (32 bytes per `GroupDescriptor` struct) with a block-count multiplier. The correct value is the ceiling-divided block count alone: `(groupCount - 1) / groupsPerDescriptorBlock + 1`. For a 512 GiB disk (4096 groups, 128 groups/block, blockSize = 4096): correct = 32, buggy = 1024. Three downstream effects:
1. `init` seeks to block 1025 instead of block 33, so all initial content (`lost+found`, etc.) is placed 992 blocks later than necessary.
2. The group 0 block bitmap loop (Bug #20 fix site) frees bits 33–1024 as "unused reserved-GDT expansion space", reporting 992 extra free blocks in group 0.
3. Groups 0 and 1 end up with their inode tables, block bitmaps, and inode bitmaps placed 61639–62699 blocks into the image — physically inside group 1's block range rather than within their own. The Linux kernel's `ext4_check_descriptors()` normally rejects this as `EFSCORRUPTED` and aborts the mount. To mask this, `logGroupsPerFlex` was set to 31, widening the flex_bg range check to `[0, 2^46 − 1]` so any block position passes. With Bug #56 fixed, the metadata is at standard positions and `logGroupsPerFlex` must be changed from 31 to 0 (disabling flex_bg processing, since `groups_per_flex = 1 << 0 = 1 < 2`).
All three effects leave the filesystem self-consistent (the 992 freed blocks are genuine sparse holes that the formatter never wrote to, so the kernel may freely allocate them), but the `init` seek is 992 blocks too far, group 0's first-data-block position is wrong, and the flex_bg workaround leaves all block groups in a single enormous flex group.
**Fix:** Remove `* 32`: `(groupCount - 1) / groupsPerDescriptorBlock + 1`. Also change `superblock.logGroupsPerFlex = 31` to `superblock.logGroupsPerFlex = 0`.

ext4-bugs X

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 7 |
| HIGH | 17 |
| MEDIUM | 16 |
| LOW | 12 |
| FALSE POSITIVE | 4 |
| **Total** | **56** |

### Merged (4 pairs → 4 entries)
| Merged | Into | Reason |
|--------|------|--------|
| 10 + 30 | #21 | Same line: `uint32` alias + overflow risk |
| 32 + 56 | #18 | Root cause (ceiling division) causes crash (force unwrap) |
| 15 + 16 | #6 | Same bug class: Array instead of tuple in on-disk structs |
| 25 + 26 | #15 | Both are Ptr safety-guard gaps |
