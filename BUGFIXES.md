# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `Date.fs()` crashes on pre-1970 dates
**File:** EXT4+Formatter.swift:1329-1331
**Bug:** `UInt64(s)` traps at runtime when `s` is negative (any date before January 1, 1970). In addition, `truncatingRemainder(dividingBy: 1)` returns a negative fractional part for negative `s`, so `UInt64(negative)` also traps on the nanoseconds line.
**Impact:** Runtime crash when formatting any file whose timestamp predates the Unix epoch. Container images with such files cannot be formatted.
**Fix:** Use `Int64(s.rounded(.down))` (floor) for whole seconds, compute the fractional part as `s - Double(wholeSeconds)` (always ≥ 0), and mask seconds to 34 bits via `UInt64(bitPattern: wholeSeconds) & 0x3_FFFF_FFFF` to preserve two's-complement encoding.

---

## 2. CRITICAL: Timestamp nanoseconds always zero on export
**File:** EXT4Reader+Export.swift:76-78, 159-161
**Bug:** `UInt64((inode.ctimeExtra << 32) | inode.ctime)` performs the shift on `UInt32` values. In Swift, shifting a `UInt32` by its own bit width (32) is defined as zero, so `ctimeExtra << 32` is always `0`. The nanosecond component stored in `ctimeExtra` is silently discarded for every exported file.
**Impact:** All timestamps in exported archives lose sub-second precision. Round-tripping a filesystem through export and re-import corrupts every file timestamp.
**Fix:** Cast to `UInt64` before shifting: `(UInt64(inode.ctimeExtra) << 32) | UInt64(inode.ctime)`.

---

## 3. CRITICAL: `Date(fsTimestamp:)` misreads pre-1970 timestamps
**File:** EXT4Reader+Export.swift:206-207
**Bug:** `Int64(fsTimestamp & 0x3_ffff_ffff)` does not sign-extend the 34-bit seconds field. When bit 33 is set (any pre-epoch timestamp), the result is a large positive `Int64` instead of the correct negative value, decoding the timestamp as a date far in the future.
**Impact:** Any pre-1970 file timestamp is decoded as a date roughly 500 years in the future, silently corrupting metadata on read.
**Fix:** Sign-extend manually: `rawSeconds < (1 << 33) ? rawSeconds : rawSeconds - (1 << 34)`.

---

## 4. HIGH: Compile error — `uint32` is undefined
**File:** EXT4+Formatter.swift:955
**Bug:** `uint32(self.inodes.count)` references the identifier `uint32`, which does not exist in Swift. The correct type is `UInt64` (matching the type of `tableSize`).
**Impact:** The file does not compile.
**Fix:** Replace `uint32(self.inodes.count)` with `UInt64(self.inodes.count)`.

---

## 5. HIGH: Symlink targets contain trailing NUL bytes
**File:** EXT4Reader+Export.swift:132
**Bug:** `EXT4.tupleToArray(inode.block)` returns all 60 bytes of the inode block field. For symlinks shorter than 60 bytes, the unused bytes are zero. `String(bytes:encoding:)` does not stop at NUL, so the resulting symlink target string contains trailing NUL characters.
**Impact:** Exported symlinks with inline targets (< 60 bytes) point to corrupted paths containing NUL characters, causing them to be unresolvable on the target filesystem.
**Fix:** Limit the byte array to the actual symlink length: `.prefix(Int(size))`.

---

## 6. HIGH: Hard-link `linksCount` not decremented when count equals 2
**File:** EXT4+Formatter.swift:238
**Bug:** The condition `linkedInode.linksCount > 2` skips the decrement when `linksCount == 2` (one original reference plus one hard link). Removing the hard link leaves the count stuck at 2 instead of reducing it to 1.
**Impact:** Inodes for hard-linked files report an inflated link count after the hard link is removed, corrupting the filesystem's reference-counting metadata.
**Fix:** Change the condition to `linkedInode.linksCount > 1`.

---

## 7. HIGH: `freeBlocksCount` can underflow when `blocks > blocksPerGroup`
**File:** EXT4+Formatter.swift:774
**Bug:** `UInt32(self.blocksPerGroup - blocks)` wraps to a very large value when `blocks` exceeds `blocksPerGroup`. The immediately preceding `freeBlocks` variable was computed with proper bounds-checking for exactly this case, but was never used.
**Impact:** The group descriptor is written with a wildly incorrect free-block count, producing a corrupt filesystem that fails `fsck` and may be rejected by the kernel.
**Fix:** Use the already-computed `freeBlocks` value instead of recomputing without bounds-checking.

---

## 8. HIGH: Circular symlink detection only catches single-hop cycles
**File:** Formatter+Unpack.swift:185, 191
**Bug:** `visited` was declared `let`, so `visited.insert(next)` could never be called and the set was never updated. The cycle check only detects a self-referential link (A → A); any multi-hop cycle (A → B → C → A) loops infinitely.
**Impact:** A filesystem layer containing a multi-hop symlink cycle causes the unpacker to hang indefinitely.
**Fix:** Declare `visited` as `var` and insert `next` into the set after each step.

---

## 9. MEDIUM: `xattr` sort comparator violates strict weak ordering
**File:** EXT4+Xattrs.swift:180-183
**Bug:** The sort closure used `||` across all three comparison keys: `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)`. This can return `true` for both `compare(a, b)` and `compare(b, a)` simultaneously (e.g. when `a.index > b.index` but `a.name.count < b.name.count`), violating the strict-weak-ordering contract required by Swift's sort.
**Impact:** Undefined behaviour in Swift's sort: the resulting order is unpredictable and may corrupt the xattr block layout, making extended attributes unreadable.
**Fix:** Replace with a lexicographic comparator using sequential `if`/`else if` branches.

---

## 10. MEDIUM: Force-unwrap crash on non-ASCII xattr name in `hash`
**File:** EXT4+Xattrs.swift:60
**Bug:** `char.asciiValue!` force-unwraps an optional that is `nil` for any non-ASCII character. Extended attribute names may contain non-ASCII bytes.
**Impact:** Runtime crash when computing the hash of any xattr whose name contains a non-ASCII character, such as those written by third-party tools.
**Fix:** Use `guard let asciiVal = char.asciiValue else { continue }` and skip non-ASCII characters.

---

## 11. MEDIUM: Force-unwrap crash on invalid ASCII in xattr name during read
**File:** EXT4+Xattrs.swift:267
**Bug:** `String(bytes: rawName, encoding: .ascii)!` force-unwraps, crashing if the xattr name bytes in the filesystem image are not valid ASCII.
**Impact:** Runtime crash when reading any filesystem image whose xattr names contain non-ASCII bytes, including images produced by non-conforming writers.
**Fix:** Replace with `guard let name = String(bytes: rawName, encoding: .ascii) else { continue }` to skip undecodable entries.

---

## 12. LOW: `buffer[0...4]` is a 5-byte slice for a 4-byte `UInt32` header
**File:** EXT4Reader+Export.swift:173, 186
**Bug:** The closed range `0...4` contains five indices (0, 1, 2, 3, 4), but `UInt32` is only 4 bytes. The `load(as: UInt32.self)` reads the correct 4 bytes from the start of the slice, but the slice passed to `withUnsafeBytes` is one byte wider than necessary.
**Impact:** The extra byte does not affect the loaded value, but the unnecessarily wide slice is incorrect and fragile if the buffer is exactly 4 bytes long (index 4 would be out of bounds).
**Fix:** Use `buffer[0...3]`.
