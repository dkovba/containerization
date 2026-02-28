# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `Date.fs()` crashes on pre-1970 dates
**File:** EXT4+Formatter.swift:1329-1331
**Bug:** `UInt64(s)` traps at runtime when `s` is negative (any date between 1902 and 1970). The existing guard only clamps values below `-0x8000_0000` (roughly year 1902), so negative values in the range `-0x8000_0000 < s < 0` reach `UInt64(s)`, which is undefined behavior for a negative `Double` and crashes. The nanosecond calculation `UInt64(truncatingRemainder(dividingBy: 1) * 1_000_000_000)` also traps because the fractional part is negative.
**Impact:** Runtime crash when formatting any file whose timestamp falls between 1902 and 1970. Container images containing such files cannot be formatted at all.
**Fix:** Add `guard s >= 0 else { return 0 }` before the `UInt64` conversions, clamping pre-epoch timestamps to zero.

---

## 2. CRITICAL: Last block group bitmap never written for non-aligned disk sizes
**File:** EXT4+Formatter.swift:808, 841
**Bug:** The loop `for group in blockGroupSize.blockGroups..<totalGroups.lo` checks `group == totalGroups.lo` for the last-group special case. Since the loop's upper bound is exclusive at `totalGroups.lo`, the last iteration has `group == totalGroups.lo - 1`, so the condition `group == totalGroups.lo` is never true. The partial-block-group bitmap is never written; the generic full bitmap is written instead, marking free blocks as allocated.
**Impact:** When the disk size is not aligned to a block group boundary, the last block group's bitmap is wrong. Free blocks are marked as used, wasting disk space and potentially causing `e2fsck` failures on the formatted filesystem.
**Fix:** Change the condition to `group == totalGroups.lo - 1`.

---

## 3. HIGH: Hardlink cycle detection in `resolve()` is broken
**File:** Formatter+Unpack.swift:185-191
**Bug:** The `visited` set is declared with `let`, making it immutable. The loop checks `visited.contains(item)` but never calls `visited.insert(next)`, so `visited` only ever contains the initial target. A cycle longer than one hop (e.g. A→B→C→A) causes an infinite loop because B and C are never added to the set.
**Impact:** Unpacking a container image with a cyclic hardlink chain of length > 1 hangs forever instead of throwing `circularLinks`.
**Fix:** Change `let visited` to `var visited` and add `visited.insert(next)` after advancing.

---

## 4. HIGH: Extended attribute sort violates strict weak ordering
**File:** EXT4+Xattrs.swift:179-184
**Bug:** The block attribute sort comparator uses `||` across three conditions: `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)`. This returns `true` when any single condition is met, regardless of the others. For example, if `a.index > b.index` but `a.name.count < b.name.count`, the comparator returns `true` for `a < b`, violating the strict weak ordering requirement. This is undefined behavior for `sort` and can produce incorrect orderings or, on some standard library implementations, crash.
**Impact:** Block-level extended attributes may be written in an incorrect order, producing a filesystem that Linux kernel ext4 or `e2fsck` may reject or misparse.
**Fix:** Rewrite as a proper lexicographic comparison: compare `index` first, then `name.count`, then `name`.

---

## 5. HIGH: Xattr header read uses wrong byte range `0...4` (5 bytes)
**File:** EXT4Reader+Export.swift:173, 189
**Bug:** `buffer[0...4]` produces a 5-element slice (indices 0, 1, 2, 3, 4) for a 4-byte `UInt32` header. While `load(as: UInt32.self)` only reads the first 4 bytes so the comparison still succeeds, the slice reads one byte beyond the header. On a buffer shorter than 5 bytes this would be an out-of-bounds crash.
**Impact:** Incorrect range expression. In practice the buffers are always large enough (96 bytes inline, blockSize for block), so this does not crash in normal operation, but the code is semantically wrong and fragile.
**Fix:** Change `buffer[0...4]` to `buffer[0..<4]` and add a `guard buffer.count >= 4` bounds check.

---

## 6. MEDIUM: Hardlink unlink threshold prevents last link from being decremented
**File:** EXT4+Formatter.swift:238
**Bug:** When unlinking a hardlink, the code checks `linkedInode.linksCount > 2` before decrementing. For a regular file with exactly 2 links (the original plus one hardlink), removing the hardlink should decrement the count from 2 to 1. The `> 2` check prevents this, leaving the link count at 2 when it should be 1.
**Impact:** After removing a hardlink, the target inode's `linksCount` is one too high. `e2fsck` will report a link count mismatch.
**Fix:** Change `> 2` to `> 1`.

---

## 7. MEDIUM: Reserved inode guard is off by one
**File:** EXT4+Formatter.swift:244
**Bug:** `guard inodeNumber > FirstInode` uses `>` with `FirstInode` (which is 11), but `inodeNumber` is 0-based (inode number minus 1). Inode 11 (the first user inode, `lost+found`) has `inodeNumber == 10`. The guard `10 > 11` is false, so inode 11 is never freed on unlink — its blocks and metadata are leaked.
**Impact:** Unlinking `lost+found` or the first user-created file/directory fails to reclaim its blocks and inode. Repeated create/unlink cycles leak disk space.
**Fix:** Change to `guard inodeNumber >= Int(FirstInode) - 1`.

---

## 8. LOW: Symlink target contains trailing null bytes on export
**File:** EXT4Reader+Export.swift:132-133
**Bug:** For fast symlinks (target < 60 bytes stored in the inode `block` field), `tupleToArray(inode.block)` returns all 60 bytes. The resulting string contains trailing `\0` bytes beyond the actual target length.
**Impact:** Exported tar archives contain symlink targets padded with null bytes. Most tools ignore trailing nulls, but strict parsers or byte-level comparisons would see a different target than intended.
**Fix:** Trim the byte array to the actual size with `linkBytes.prefix(Int(size))`.
