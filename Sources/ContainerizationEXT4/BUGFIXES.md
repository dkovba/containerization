# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `Date.fs()` crashes on pre-1970 dates
**File:** EXT4+Formatter.swift:1321-1322
**Bug:** The guard `if s < -0x8000_0000` only catches dates before ~1901. For dates between 1901 and 1970, `s` is negative and falls through to `UInt64(s)` on line 1329, which traps at runtime because `UInt64` cannot represent negative values.
**Impact:** Runtime crash when formatting any file whose timestamp falls between 1901-12-13 and 1970-01-01. Container images containing such files cannot be formatted.
**Fix:** Clamp all negative timestamps to 0 (`if s < 0 { return 0 }`).

---

## 2. HIGH: Hardlink cycle detection in `resolve()` is non-functional
**File:** Formatter+Unpack.swift:184-191
**Bug:** The `visited` set is declared with `let` and is never updated inside the `while` loop. The `visited.insert(next)` call is missing entirely. As a result, the set only ever contains the initial target, and chains longer than two links are never detected as cycles.
**Impact:** Circular hardlink chains in container image layers cause an infinite loop during `unpack()`, hanging the formatter indefinitely.
**Fix:** Change `let visited` to `var visited` and add `visited.insert(next)` after advancing `next`.

---

## 3. HIGH: XAttr header read uses wrong byte count
**File:** EXT4Reader+Export.swift:173, 185
**Bug:** `buffer[0...4]` is a closed range that reads 5 bytes (indices 0, 1, 2, 3, 4), but a `UInt32` is only 4 bytes. The extra byte is included in the `withUnsafeBytes` load.
**Impact:** The loaded `UInt32` value may be incorrect due to reading one byte beyond the intended range. On little-endian systems the low 4 bytes happen to be correct, so the magic check passes by luck, but the read is technically undefined behavior (accessing memory beyond the slice's intended bounds within the buffer).
**Fix:** Change `buffer[0...4]` to `buffer[0..<4]` in both `readInlineExtendedAttributes` and `readBlockExtendedAttributes`.

---

## 4. MEDIUM: Block xattr sort comparator produces wrong ordering
**File:** EXT4+Xattrs.swift:178-187
**Bug:** The original comparator `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)` uses short-circuit `||`, which does not implement a proper lexicographic comparison. For example, if `a.index > b.index` but `a.name.count < b.name.count`, the comparator returns `true` even though `a` should sort after `b` by the primary key.
**Impact:** Block-level extended attributes may be written in an incorrect order, producing a filesystem that does not match the expected xattr layout. This can cause tools like `e2fsck` to flag the filesystem or cause xattr lookup mismatches.
**Fix:** Rewrite as a proper multi-field lexicographic comparator that checks fields in priority order, only falling through to the next field when the current field is equal.

---

## 5. MEDIUM: Extent leaf and index loaded without endian conversion
**File:** EXT4+Reader.swift:213-214, 222-223
**Bug:** `ExtentLeaf` and `ExtentIndex` structs are loaded with `.load(as:)` instead of `.loadLittleEndian(as:)`. All other on-disk structures in the reader (superblock, group descriptors, inodes, extent headers) use `loadLittleEndian`. EXT4 is a little-endian filesystem format.
**Impact:** On big-endian platforms, extent block addresses and lengths are byte-swapped, causing reads from wrong disk locations. On little-endian platforms (all current Apple hardware) the behavior is identical, so this is latent.
**Fix:** Change `.load(as: ExtentLeaf.self)` and `.load(as: ExtentIndex.self)` to `.loadLittleEndian(as:)`.

---

## 6. LOW: `XAttrEntry` hash field parsed with unbounded range
**File:** EXT4+Extensions.swift:89
**Bug:** `bytes[12...]` creates an `ArraySlice` from index 12 to the end of the array. The `XAttrEntry` initializer is always called with a 16-byte array (guarded at line 75), so the slice is always `bytes[12...15]` in practice. However, the open-ended range is inconsistent with the other fields (`bytes[2...3]`, `bytes[4...7]`, `bytes[8...11]`) which all use explicit upper bounds.
**Impact:** If the guard were ever relaxed or the function called with a larger buffer, the `withUnsafeBytes` load would read from a larger-than-expected backing store. With the current 16-byte guard, behavior is identical.
**Fix:** Change `bytes[12...]` to `bytes[12...15]` for consistency and defensive correctness.

---

## 7. LOW: Xattr name bounds check skips last valid entry
**File:** EXT4+Xattrs.swift:266
**Bug:** `guard endIndex < buffer.count` rejects an entry whose name ends exactly at the buffer boundary (`endIndex == buffer.count`). The subsequent slice `buffer[i..<endIndex]` is valid when `endIndex == buffer.count`.
**Impact:** The last extended attribute in a fully-packed buffer is silently skipped during reading.
**Fix:** Change `<` to `<=` so that `endIndex == buffer.count` is accepted.
