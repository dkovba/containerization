# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `uint32` typo prevents compilation
**File:** EXT4+Formatter.swift:958
**Bug:** `uint32(self.inodes.count)` references an undefined symbol. Swift has no `uint32` function or type; the correct spelling is `UInt32`. The entire module fails to compile.
**Impact:** The module cannot be built at all.
**Fix:** Replace `uint32(self.inodes.count)` with `UInt32(self.inodes.count)`.

---

## 2. CRITICAL: Type mismatch `UInt64 < UInt32` on minimum disk size check
**File:** EXT4+Formatter.swift:630
**Bug:** `if self.size < minimumDiskSize` compares `self.size: UInt64` against `minimumDiskSize: UInt32`. Swift does not allow mixed-type comparisons; this is a compile error.
**Impact:** Compilation failure. Additionally, even if it compiled, comparing bytes (`self.size`) to a block count (`minimumDiskSize`) would be semantically wrong: a 64 MiB disk (size = 67108864) would compare falsely smaller than a 1-block minimum (minimumDiskSize = 1), preventing the size from ever being correctly enforced.
**Fix:** `if self.size < UInt64(minimumDiskSize) * UInt64(self.blockSize)`.

---

## 3. CRITICAL: Type mismatch `UInt32 > Int` in inode bitmap
**File:** EXT4+Formatter.swift:735
**Bug:** `if ino > self.inodes.count` compares `ino: InodeNumber (UInt32)` against `self.inodes.count: Int`. Swift rejects this comparison.
**Impact:** Compilation failure. The inode bitmap loop cannot be built, blocking all filesystem formatting.
**Fix:** `if Int(ino) > self.inodes.count`.

---

## 4. CRITICAL: Type mismatch `Int > UInt32` and off-by-one in `unlink`
**File:** EXT4+Formatter.swift:244
**Bug:** `guard inodeNumber > FirstInode else { return }` compares `inodeNumber: Int` against `EXT4.FirstInode: UInt32`. Swift rejects the comparison. Additionally, even with a correct cast, the condition is off by one: `inodeNumber` is the 0-based index (`Int(pathNode.inode) - 1`), so the threshold must be `Int(EXT4.FirstInode) - 1` (= 10), not `EXT4.FirstInode` (= 11). Using 11 would skip freeing the blocks and bitmap entry for inode 11, leaking one inode's allocation on every delete.
**Impact:** Compilation failure; also an off-by-one leak in inode freeing.
**Fix:** `guard inodeNumber >= Int(EXT4.FirstInode) - 1 else { return }`.

---

## 5. CRITICAL: Type mismatch `UInt64 < UInt32` in block count adjustment
**File:** EXT4+Formatter.swift:873
**Bug:** `while blocksCount < totalBlocks` compares `blocksCount: UInt64` against `totalBlocks: UInt32`. Swift rejects the comparison.
**Impact:** Compilation failure. The superblock's total block count can never be corrected when it falls short.
**Fix:** `if blocksCount < UInt64(totalBlocks) { blocksCount = UInt64(totalBlocks) }`. Changed to `if` since the body unconditionally satisfies the condition, making the `while` redundant.

---

## 6. HIGH: Runtime crash on empty range when all group descriptor blocks are used
**File:** EXT4+Formatter.swift:702–705
**Bug:** `for i in usedGroupDescriptorBlocks + 1...self.groupDescriptorBlocks` is unconditional. When `usedGroupDescriptorBlocks == self.groupDescriptorBlocks` (all descriptor blocks are in use), the range lower bound exceeds the upper bound and Swift traps at runtime: `Fatal error: Range requires lowerBound <= upperBound`.
**Impact:** Runtime crash when formatting any filesystem where the group descriptor blocks are exactly filled.
**Fix:** Guard with `if usedGroupDescriptorBlocks < self.groupDescriptorBlocks { ... }` before entering the loop.

---

## 7. HIGH: Dead condition causes incorrect block bitmap for the last block group
**File:** EXT4+Formatter.swift:810, 843
**Bug:** Inside `for group in blockGroupSize.blockGroups..<totalGroups.lo`, both branches check `if group == totalGroups.lo`. Because the loop iterates up to but *not including* `totalGroups.lo`, this condition is never true. The last group (index `totalGroups.lo - 1`) is never identified as the final partial group, so it always receives a full `blocksPerGroup` value for `blocksInGroup` and its block bitmap is written as if the disk is completely full through the end of the group. On a disk whose size is not an exact multiple of the block group size, all excess blocks in the last group are marked used rather than free.
**Impact:** Silent filesystem corruption: free space in the last block group is incorrectly reported as allocated, reducing available disk space and producing a malformed filesystem.
**Fix:** `if group == totalGroups.lo - 1`.

---

## 8. HIGH: Double-counted offset corrupts extent tree for large files
**File:** EXT4+Formatter.swift:1139–1142
**Bug:** `fillExtents(node:numExtents:numBlocks:start:offset:)` is called with `start: blocks.start + offset`. Inside `fillExtents`, the starting block for each extent leaf is computed as `start + extentBlock * EXT4.MaxBlocksPerExtent` where `extentBlock` already incorporates the `offset` parameter (`extentBlock = offset + i` for leaf index `i`). Adding `offset` to `blocks.start` therefore counts the offset twice, producing extent records that point to block numbers `offset * EXT4.MaxBlocksPerExtent` positions beyond the actual data blocks.
**Impact:** Silent data corruption: files whose extent tree requires more than one leaf block (large files with many extents) will have their data mapped to the wrong disk blocks, making their contents unreadable.
**Fix:** `start: blocks.start` (pass the raw start block; `offset` is already applied inside `fillExtents`).

---

## 9. HIGH: Out-of-bounds slice when reading xattr header magic
**File:** EXT4Reader+Export.swift:173, 186
**Bug:** `buffer[0...4].withUnsafeBytes { $0.load(as: UInt32.self) }` creates a 5-byte slice (`0...4` is a closed range covering indices 0, 1, 2, 3, 4) and then loads a 4-byte `UInt32` from it. If the caller passes a buffer of exactly 4 bytes, Swift's bounds check traps with an index-out-of-range error. This affects both `readInlineExtendedAttributes` and `readBlockExtendedAttributes`.
**Impact:** Runtime crash when reading xattrs from any file whose xattr header buffer is exactly 4 bytes in length.
**Fix:** `buffer[0..<4]` (half-open range, 4 elements).

---

## 10. MEDIUM: Hardcoded `logBlockSize = 2` is only correct for 4096-byte blocks
**File:** EXT4+Formatter.swift:889–890
**Bug:** `superblock.logBlockSize = 2` and `superblock.logClusterSize = 2` are written unconditionally. The EXT4 specification defines `logBlockSize` as the exponent `n` where block size = `1024 << n`. The value 2 is correct only for 4096-byte blocks; for 1024-byte blocks it should be 0, for 2048-byte blocks 1, and for 8192-byte blocks 3.
**Impact:** Any filesystem created with a non-4096-byte block size will have incorrect `logBlockSize` and `logClusterSize` fields in the superblock, rendering the filesystem unreadable by any EXT4 implementation.
**Fix:** `let logBlockSize = UInt32((self.blockSize / 1024).trailingZeroBitCount); superblock.logBlockSize = logBlockSize; superblock.logClusterSize = logBlockSize`.

---

## 11. LOW: Immutable `visited` set breaks cycle detection in `Hardlinks.resolve`
**File:** Formatter+Unpack.swift:185–191
**Bug:** `let visited: Set<FilePath> = [next]` declares `visited` as a constant initialised with only the first element of the chain. The loop advances `next` but never calls `visited.insert(next)`, so the set never grows beyond its initial single entry. Only a cycle that leads back directly to the very first node is detected; a cycle starting at any intermediate node (e.g., A→B→C→B) is silently missed, causing an infinite loop.
**Impact:** Low in practice because `Hardlinks.acyclic` is evaluated before `resolve` is called and would catch cycles first, causing the function to throw before `resolve` is ever invoked. However, if `resolve` were called independently, it would loop infinitely on any multi-node cycle.
**Fix:** Change to `var visited`, and add `visited.insert(next)` after advancing `next` inside the loop.
