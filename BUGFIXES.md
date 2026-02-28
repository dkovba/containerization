# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `uint32` undefined — project does not compile
**File:** EXT4+Formatter.swift:954
**Bug:** `uint32(self.inodes.count)` references an undefined symbol. `uint32` is not a Swift type; the correct name is `UInt32`. The module cannot be compiled at all.
**Impact:** Build failure — no functionality is available.
**Fix:** Replace `uint32` with `UInt32`.

---

## 2. CRITICAL: `seek(block:)` missing on non-Apple platforms
**File:** EXT4+Reader.swift:122 (fix); EXT4Reader+Export.swift (original location)
**Bug:** `seek(block:)` on `EXT4Reader` was only defined inside `#if os(macOS)` in `EXT4Reader+Export.swift`, but is called from platform-independent code in `EXT4+Reader.swift` (`getDirTree`, `getExtents`). On Linux the module does not compile.
**Impact:** Build failure on Linux — the primary deployment target for container workloads.
**Fix:** Move `seek(block:)` into `EXT4+Reader.swift` so it is always compiled.

---

## 3. CRITICAL: Type mismatch — `UInt32` compared with `UInt64` does not compile
**File:** EXT4+Formatter.swift:870–874
**Bug:** `totalBlocks` is declared as `UInt32`, but `blocksCount` is `UInt64` (product of two `UInt64` values). Swift does not allow mixed-type comparisons without explicit casts, so `while blocksCount < totalBlocks` and `if totalBlocks > blocksCount` are compile errors.
**Impact:** Build failure.
**Fix:** Add explicit `UInt64(totalBlocks)` casts in both comparisons.

---

## 4. HIGH: xattr magic header read overflows buffer by one byte
**File:** EXT4Reader+Export.swift:173, 186
**Bug:** `buffer[0...4]` is a closed range selecting 5 bytes (indices 0–4), but `$0.load(as: UInt32.self)` requires exactly 4 bytes. The load reads one byte beyond the intended range. On buffers that are exactly 4 bytes this is also an out-of-bounds access.
**Impact:** Silent data corruption — the magic number check may pass or fail incorrectly, causing valid xattr blocks to be rejected or invalid ones to be accepted.
**Fix:** Replace `buffer[0...4]` with `buffer[0..<4]` in both `readInlineExtendedAttributes` and `readBlockExtendedAttributes`.

---

## 5. HIGH: Wrong `freeBlocksCount` written to group descriptor
**File:** EXT4+Formatter.swift:774–782
**Bug:** After carefully computing `freeBlocks` (handling the edge case where `blocks > blocksPerGroup` and the case where the disk is smaller than one block group), the code discards it and instead passes `freeBlocksCount = UInt32(self.blocksPerGroup - blocks)` to the group descriptor. When `blocks > blocksPerGroup` this subtraction wraps around, producing a wildly wrong free-block count. Even in the normal case the size-adjusted value computed in `freeBlocks` is not used.
**Impact:** Incorrect free-block counts in the superblock and group descriptors. Filesystem checkers (e2fsck) will report errors; mounted filesystems may behave incorrectly.
**Fix:** Remove the `freeBlocksCount` local variable and pass `freeBlocks.lo` directly to the group descriptor.

---

## 6. HIGH: Off-by-one in `unlink` — first user inode's blocks never freed
**File:** EXT4+Formatter.swift:244
**Bug:** `inodeNumber` is the zero-based index (`pathNode.inode - 1`), while `FirstInode` (`EXT4.FirstInode = 11`) is a one-based inode number. The guard `inodeNumber > FirstInode` therefore requires `pathNode.inode > 12`, skipping inode 12 — the very first user-created inode (e.g. the first file after `/lost+found`). Blocks for that inode are never marked free on deletion.
**Impact:** Deleting the first user file (or whiteout-unlinking it during layer unpacking) leaks its data blocks, corrupting the free-block bitmap and inflating the resulting image.
**Fix:** Compare `Int(pathNode.inode) > Int(EXT4.FirstInode)` so that inode 12 and above are correctly freed.

---

## 7. HIGH: Extent block count uses wrong ceiling division, over-allocating extent index nodes
**File:** EXT4+Formatter.swift:1103
**Bug:** `numExtents / extentsPerBlock + 1` always adds 1, even when `numExtents` is an exact multiple of `extentsPerBlock`. For example, with `extentsPerBlock = 340` and `numExtents = 340`, the result is 2 instead of the correct 1. The extra extent index block is allocated and written, consuming disk space and shifting all subsequent block addresses.
**Impact:** Incorrect extent tree layout for files whose extent count is an exact multiple of the per-block capacity; the filesystem may be unreadable by a kernel driver.
**Fix:** Use proper ceiling division: `(numExtents + extentsPerBlock - 1) / extentsPerBlock`.

---

## 8. HIGH: `fillExtents` double-counts `offset`, writing wrong physical block addresses
**File:** EXT4+Formatter.swift:1134–1137
**Bug:** Inside the depth-1 (multi-index) extent path, `fillExtents` is called with `start: blocks.start + offset`. Inside `fillExtents`, the physical start of each leaf is computed as `extentStart = start + extentBlock`, where `extentBlock = offset + i * MaxBlocksPerExtent`. The `offset` term therefore appears twice: once in `start` and once in `extentBlock`, so every leaf extent points `offset` blocks past its correct location.
**Impact:** All data blocks in multi-index extent trees (files requiring more than 4 extents) are mapped to wrong physical addresses. Reading such files returns garbage; writing corrupts unrelated blocks.
**Fix:** Pass `start: blocks.start` so that `offset` is only counted once inside `fillExtents`.

---

## 9. MEDIUM: `finishDirEntryBlock` writes past the end of the block when `left < 8`
**File:** EXT4+Formatter.swift:1231–1248
**Bug:** When `0 < left < MemoryLayout<DirectoryEntry>.size` (8 bytes), the function skips the `left <= 0` guard and writes a full 8-byte `DirectoryEntry` header into fewer remaining bytes of the block, overflowing into the next block. This can happen when `blockSize mod (minimum record length)` is non-zero (e.g., 4096 mod 12 = 4, so after 341 minimum-length entries exactly 4 bytes remain).
**Impact:** Silent filesystem corruption: one byte of the next block is overwritten with directory entry data.
**Fix:** Add a guard that zero-pads the remaining bytes and returns when `left < directoryEntrySize`, preventing the out-of-bounds write.

---

## 10. LOW: Dead condition — empty block group bitmap branch never executes
**File:** EXT4+Formatter.swift:807, 840
**Bug:** The loop iterates `for group in blockGroupSize.blockGroups..<totalGroups.lo`, so `group` is always strictly less than `totalGroups.lo`. The condition `if group == totalGroups.lo` inside the loop body can therefore never be true. The code intended to handle the last partial block group is completely dead, and all empty groups are treated identically with a full `blocksPerGroup` block count.
**Impact:** For filesystems whose total size is not an exact multiple of the block-group size (before the size-alignment expansion), the last empty group descriptor may report an incorrect free-block count.
**Fix:** Change the condition to `group == totalGroups.lo - 1` so the last group in the range is handled correctly.
