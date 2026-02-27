# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: Extent offset double-counted when writing multi-level extent trees
**File:** EXT4+Formatter.swift:1138
**Bug:** `fillExtents` is called with `start: blocks.start + offset`, but internally it adds `offset` again via `extentBlock = offset + j * MaxBlocksPerExtent`, producing `blocks.start + 2*offset` instead of `blocks.start + offset`.
**Impact:** Files larger than ~128 MiB (requiring depth-1 extent trees) are written with incorrect physical block addresses. Every extent leaf beyond the first index node points to the wrong location on disk, silently corrupting file data.
**Fix:** Pass `start: blocks.start` so the single addition inside `fillExtents` yields the correct address.

## 2. CRITICAL: Extended attribute entry size calculated incorrectly (operator precedence)
**File:** EXT4+Xattrs.swift:46
**Bug:** `(name.count + 3) & ~3 + 16` parses as `(name.count + 3) & (~3 + 16)` because `+` binds tighter than `&` in Swift. This evaluates to `(name.count + 3) & 13`, which truncates most bits, producing a size far smaller than intended.
**Impact:** All xattr entry sizes are wrong. All xattr writes and capacity calculations use this value, leading to corrupted xattr data on disk and silent overflow of inline/block xattr storage.
**Fix:** Add explicit parentheses: `((name.count + 3) & ~3) + 16`.

## 3. CRITICAL: On-disk struct fields declared as `[UInt8]`/`[UInt32]` instead of tuples
**File:** EXT4+Types.swift:543, 545, 593
**Bug:** `dotName`, `dotDotName`, and `reserved` are declared as `[UInt8]` or `[UInt32]`. Swift `Array` is a heap-allocated reference type with pointer + length + capacity metadata.
**Impact:** `MemoryLayout<T>.size` returns the wrong size and `withUnsafeBytes(of:)` serializes pointer metadata instead of inline byte values. `DirectoryTreeRoot` and `XAttrHeader` produce corrupt on-disk structures.
**Fix:** Replace `[UInt8]` with `(UInt8, UInt8, UInt8, UInt8)` and `[UInt32]` with `(UInt32, UInt32, UInt32)`.

## 4. CRITICAL: Block xattr sort comparator is not a total order
**File:** EXT4+Xattrs.swift:180
**Bug:** The comparator `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)` returns `true` whenever *any* field is less, ignoring higher-priority fields. For example, if `a.index > b.index` but `a.name.count < b.name.count`, it incorrectly returns `true`.
**Impact:** Violates strict weak ordering, causing `sort` to produce a non-deterministic order. ext4 xattr entries in a block must be sorted by (index, name length, name) for the kernel to find them; incorrect ordering makes xattrs unreadable by Linux.
**Fix:** Cascade the comparison: compare `index` first, then `name.count`, then `name`.

## 5. CRITICAL: Timestamp extra bits silently lost during export
**File:** EXT4Reader+Export.swift:76-78, 159-161
**Bug:** `inode.ctimeExtra << 32` shifts a `UInt32` by its full bit width, which yields 0 in Swift. The expression `UInt64((inode.ctimeExtra << 32) | inode.ctime)` always reduces to `UInt64(inode.ctime)`.
**Impact:** All exported timestamps lose their high 32 bits (epoch extension and nanoseconds), collapsing every date to its low 32-bit seconds-since-epoch value. Nanosecond precision and dates beyond 2038 are silently discarded.
**Fix:** Cast before shifting: `UInt64(inode.mtimeExtra) << 32 | UInt64(inode.mtime)`.

## 6. CRITICAL: UID/GID truncated to 16 bits during export
**File:** EXT4Reader+Export.swift:74-75, 157-158
**Bug:** `uid_t(inode.uid)` and `gid_t(inode.gid)` only use the low 16-bit inode fields, discarding `uidHigh` and `gidHigh`.
**Impact:** Any UID or GID above 65535 is silently truncated in exported archives, assigning files to the wrong user or group.
**Fix:** Reconstruct the full 32-bit values: `uid_t(inode.uidHigh) << 16 | uid_t(inode.uid)`.

## 7. CRITICAL: Creation date uses inode change time instead of birth time
**File:** EXT4Reader+Export.swift:76, 159
**Bug:** The export code reads `ctime`/`ctimeExtra` (last inode metadata change time) and writes it as the archive entry's creation date instead of reading `crtime`/`crtimeExtra` (actual file birth time).
**Impact:** Every exported file gets a wrong creation timestamp — typically the time of the last chmod/chown/link operation rather than when the file was created.
**Fix:** Use `crtime`/`crtimeExtra` instead of `ctime`/`ctimeExtra`.

## 8. HIGH: `Date.fs()` crashes on pre-1970 dates
**File:** EXT4+Formatter.swift:1329
**Bug:** `UInt64(s)` traps at runtime when `s` is negative (any date before January 1, 1970).
**Impact:** Runtime crash when formatting any file with a pre-1970 timestamp. Container images containing such files cannot be written.
**Fix:** Add an `if s < 0` branch that uses `UInt64(bitPattern: Int64(s))` and masks to the 34-bit seconds field.

## 9. HIGH: `readInlineExtendedAttributes` reads 5 bytes for a 4-byte header
**File:** EXT4Reader+Export.swift:173, 186
**Bug:** `buffer[0...4]` is a closed range producing 5 elements (indices 0, 1, 2, 3, 4) for a `UInt32` that only needs 4 bytes.
**Impact:** If the buffer has exactly 4 bytes, `buffer[0...4]` causes an out-of-bounds crash. With larger buffers the load happens to read from the correct base address, masking the bug.
**Fix:** Use `buffer[0..<4]` (half-open range) and add a `buffer.count >= 4` guard.

## 10. HIGH: `getDirEntries` breaks on deleted directory entries
**File:** EXT4+Reader.swift:179
**Bug:** Deleted directory entries have `inode == 0` but a valid `recordLength`. The code treated `inode == 0` as end-of-block and stopped parsing.
**Impact:** All entries after the first deleted one in a directory block are silently dropped. Directories containing any deleted files appear to have fewer entries than they actually do.
**Fix:** Break only on `recordLength == 0` (true end sentinel). Skip entries where `inode == 0` by advancing past them using `recordLength`.

## 11. HIGH: `Ptr.initialize(to:)` deinitializes wrong count
**File:** EXT4+Ptr.swift:46
**Bug:** `deinitialize(count: self.capacity)` deinitializes `capacity` elements, but only 1 element was ever initialized via `initialize(to:)`.
**Impact:** Invokes destructors on uninitialized memory — undefined behavior. The types used with `Ptr` (`FileTreeNode`, `Inode`) contain reference-counted fields, so this could corrupt reference counts or crash.
**Fix:** Change to `deinitialize(count: 1)`.

## 12. HIGH: `unlink` guard compares wrong variable
**File:** EXT4+Formatter.swift:244
**Bug:** `inodeNumber` is a 0-based array index, but `FirstInode` is 11 (a 1-based inode number). The guard `inodeNumber > FirstInode` compares values in mismatched units.
**Impact:** Could allow deletion of reserved inodes (root, lost+found) or prevent deletion of valid inodes near the boundary.
**Fix:** Compare `pathNode.inode` (the actual 1-based inode number) against `FirstInode`.

## 13. HIGH: `FilePath.init?(_ data: Data)` reads past buffer
**File:** FilePath+Extensions.swift:62-63
**Bug:** `String(cString:)` scans forward until it finds a null byte. If the `Data` does not contain a null terminator, the read continues past the buffer boundary.
**Impact:** Undefined behavior — can crash or return garbage data from adjacent memory.
**Fix:** Find the effective length (stopping at the first null byte or `data.count`), then use `String(bytes:encoding:)` on the bounded slice.

## 14. MEDIUM: Symlink target includes trailing null bytes during export
**File:** EXT4Reader+Export.swift:132
**Bug:** `EXT4.tupleToArray(inode.block)` returns all 60 bytes of the block field regardless of the actual symlink target length.
**Impact:** Exported fast symlinks (target < 60 bytes stored inline) contain trailing null bytes, which may cause path resolution failures on the importing system.
**Fix:** Use `.prefix(Int(size))` to take only the actual target bytes.

## 15. MEDIUM: Xattr `read` loop guard off-by-one
**File:** EXT4+Xattrs.swift:257
**Bug:** `while i + 16 < buffer.count` uses strict less-than, skipping the last xattr entry when it fits exactly in the remaining space (`i + 16 == buffer.count`).
**Impact:** The final xattr entry is silently dropped when the buffer is exactly filled.
**Fix:** Change to `i + 16 <= buffer.count`.

## 16. MEDIUM: Xattr `read` name length bounds check off-by-one
**File:** EXT4+Xattrs.swift:263
**Bug:** `guard endIndex < buffer.count` rejects a name that ends exactly at the buffer boundary, even though that is a valid position.
**Impact:** A valid xattr whose name ends at the buffer boundary is skipped.
**Fix:** Change to `endIndex <= buffer.count`.

## 17. MEDIUM: Xattr `read` force-unwraps ASCII string conversion
**File:** EXT4+Xattrs.swift:267
**Bug:** `String(bytes: rawName, encoding: .ascii)!` force-unwraps the result.
**Impact:** A corrupted xattr entry with non-ASCII name bytes causes an unrecoverable crash instead of graceful error handling.
**Fix:** Use `guard let name = String(bytes:encoding:)` and break out of the loop.

## 18. MEDIUM: Xattr `read` missing value bounds check
**File:** EXT4+Xattrs.swift:269
**Bug:** The value slice `buffer[valueStart..<valueEnd]` is created without verifying that `valueEnd <= buffer.count`.
**Impact:** A corrupted or truncated xattr block causes an out-of-bounds crash.
**Fix:** Add `guard valueEnd <= buffer.count`.

## 19. MEDIUM: Hardlink `resolve` uses immutable visited set
**File:** Formatter+Unpack.swift:185
**Bug:** `let visited: Set<FilePath>` is never mutated — `visited.insert(next)` is never called inside the loop. Only the initial target is tracked.
**Impact:** A hardlink chain like `A → B → C → B` causes an infinite loop because `B` is never added to `visited`. The `acyclic` check that runs before `resolve` masks this in practice, but the safety net in `resolve` itself is non-functional.
**Fix:** Change to `var visited` and add `visited.insert(next)` inside the loop.

## 20. LOW: Extent data loaded with `.load` instead of `.loadLittleEndian`
**File:** EXT4+Reader.swift:214, 223
**Bug:** Depth-0 extent leaves and depth-1 extent indices use `.load(as:)` while all other on-disk structures use `.loadLittleEndian(as:)`.
**Impact:** On little-endian platforms (all current Apple hardware) these are identical and produce correct results. On a hypothetical big-endian platform, extent block addresses would be byte-swapped, causing reads from wrong disk locations.
**Fix:** Use `.loadLittleEndian(as:)` consistently.
