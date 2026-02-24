# ContainerizationEXT4 Bug Fixes

Ordered by severity (critical → low).

---

## 1. CRITICAL: `Date.fs()` crashes on pre-1970 dates
**File:** EXT4+Formatter.swift:1329-1331
**Bug:** `UInt64(s)` traps at runtime when `s` is negative (any date before January 1, 1970). Similarly, `truncatingRemainder(dividingBy: 1)` returns a negative fractional part, and `UInt64(negative)` also traps.
**Impact:** Runtime crash when formatting any file with a pre-1970 timestamp. Container images with such files cannot be formatted.
**Fix:** Use `UInt64(bitPattern: Int64(s))` for seconds and `abs(...)` for the fractional part.

## 2. CRITICAL: `sizeEntry` operator precedence produces wrong xattr entry sizes
**File:** EXT4+Xattrs.swift:46
**Bug:** `(name.count + 3) & ~3 + 16` evaluates as `(name.count + 3) & (~3 + 16)` = `(name.count + 3) & 13` due to `+` having higher precedence than `&`. This produces values 0–13 instead of the correct rounded-up-name-length + 16.
**Impact:** All extended attribute entries are written with corrupt size metadata. Any file with xattrs (capabilities, SELinux labels, ACLs) is silently corrupted. The resulting filesystem will fail `e2fsck` or produce incorrect xattr data when read back.
**Fix:** Add parentheses: `((name.count + 3) & ~3) + 16`.

## 3. CRITICAL: `writeBlockAttributes` sort comparison is logically incorrect
**File:** EXT4+Xattrs.swift:179-184
**Bug:** The sort closure uses `||` chaining: `($0.index < $1.index) || ($0.name.count < $1.name.count) || ($0.name < $1.name)`. If `$0.index > $1.index` but `$0.name.count < $1.name.count`, it returns `true` — violating the strict weak ordering required by `sort`. This can produce incorrectly ordered attributes and potentially cause the sort to exhibit undefined behavior.
**Impact:** Block-level xattrs may be written in wrong order. The ext4 spec requires attributes sorted by (index, name_length, name). Incorrect ordering can cause xattr lookup failures or `e2fsck` errors.
**Fix:** Use cascading comparison: check `index` first, then `name.count`, then `name`.

## 4. CRITICAL: Timestamp reconstruction loses extra bits due to UInt32 shift overflow
**File:** EXT4Reader+Export.swift:76-78, 159-161
**Bug:** `UInt64((inode.ctimeExtra << 32) | inode.ctime)` — both `ctimeExtra` and `ctime` are `UInt32`. Shifting a `UInt32` left by 32 bits overflows to 0, so the extra bits (nanoseconds and epoch extension) are silently lost.
**Impact:** All exported timestamps lose their nanosecond precision and epoch-extension data. Files appear to have incorrect timestamps in exported archives.
**Fix:** Convert to `UInt64` before shifting: `(UInt64(inode.ctimeExtra) << 32) | UInt64(inode.ctime)`.

## 5. HIGH: `copyMemory` precondition violation on partial reads
**File:** EXT4Reader+IO.swift:228-245
**Bug:** `dest` is created with `count: chunk` before reading data. If `FileHandle.read` returns fewer bytes than `chunk`, `dest.copyMemory(from: sourceBytes)` is called where `sourceBytes.count < dest.count`. The `copyMemory(from:)` method requires `from.count == self.count` — violating this is undefined behavior.
**Impact:** Potential crash or memory corruption during file reads when the underlying file handle returns a short read.
**Fix:** Move `dest` creation inside `data.withUnsafeBytes` and size it to `sourceBytes.count`.

## 6. HIGH: UID/GID truncation — high 16 bits ignored during export
**File:** EXT4Reader+Export.swift:74-75, 157-158
**Bug:** `gid_t(inode.gid)` and `uid_t(inode.uid)` only read the low 16 bits. The ext4 inode stores 32-bit UID/GID split across `uid`/`uidHigh` and `gid`/`gidHigh` fields.
**Impact:** Any file owned by a UID or GID > 65535 is exported with the wrong owner. The high bits are silently discarded.
**Fix:** Reconstruct full 32-bit values: `UInt32(inode.uidHigh) << 16 | UInt32(inode.uid)`.

## 7. HIGH: `XAttrHeader.reserved` uses `[UInt32]` (heap-allocated Array) instead of fixed-size tuple
**File:** EXT4+Types.swift:593
**Bug:** `reserved: [UInt32]` is a Swift Array whose in-memory representation is a pointer to heap storage, not inline data. If this struct were used with `withUnsafeBytes` or `loadLittleEndian`, the pointer would be serialized instead of the actual values — producing corrupt data.
**Impact:** Latent corruption bug. The struct is currently not used for direct serialization, but any future use with unsafe byte operations would silently produce garbage.
**Fix:** Change to `(UInt32, UInt32, UInt32)` tuple matching the ext4 on-disk `h_reserved[3]` field.

## 8. HIGH: `DirectoryTreeRoot.dotName`/`dotDotName` use `[UInt8]` (heap-allocated Array)
**File:** EXT4+Types.swift:543, 545
**Bug:** Same category as #7. The Array's in-memory representation is a pointer, not inline data. The on-disk format has 4-byte fixed fields.
**Impact:** Same latent corruption risk as #7.
**Fix:** Change to `(UInt8, UInt8, UInt8, UInt8)` tuples.

## 9. HIGH: `FilePath.init?(_ data: Data)` buffer overread via `String(cString:)`
**File:** FilePath+Extensions.swift:56-70
**Bug:** Uses `bindMemory(to: CChar.self)` then `String(cString:)` which reads until a null terminator. If the `Data` has no null terminator, this reads past the buffer end — undefined behavior.
**Impact:** Potential crash or information leak when constructing a `FilePath` from Data without a null terminator.
**Fix:** Replace with `String(bytes: data, encoding: .utf8)` which respects the Data's bounds.

## 10. HIGH: `Hardlinks.resolve` never updates its `visited` set
**File:** Formatter+Unpack.swift:185-192
**Bug:** `let visited: Set<FilePath> = [next]` is declared immutable. The `while` loop checks `visited.contains(item)` but never inserts new items. Only direct self-loops (A → A) are detected; longer cycles (A → B → A) are missed.
**Impact:** If `acyclic` check passes but `resolve` encounters a cycle (theoretically impossible given the current call order, but a defense-in-depth failure), it would infinite-loop.
**Fix:** Change to `var visited` and add `visited.insert(next)`.

## 11. MEDIUM: `ExtentLeaf` and `ExtentIndex` loaded with `.load` instead of `.loadLittleEndian`
**File:** EXT4+Reader.swift:214, 223
**Bug:** Depth-0 extent leaves use `$0.load(as: ExtentLeaf.self)` while depth-1 uses `$0.loadLittleEndian`. On little-endian platforms (all Apple hardware) these are equivalent, but the depth-0 path is incorrect for big-endian architectures.
**Impact:** No impact on Apple platforms. Would produce corrupt extent data on big-endian hardware.
**Fix:** Use `$0.loadLittleEndian(as:)` consistently for both depths.

## 12. MEDIUM: `seek(block:)` only available inside `#if os(macOS)`
**File:** EXT4Reader+Export.swift:194-196 (removed), EXT4+Reader.swift (added)
**Bug:** `seek(block:)` was defined only in `EXT4Reader+Export.swift` inside `#if os(macOS)`, but called unconditionally from `EXT4+Reader.swift`'s `getDirTree` method.
**Impact:** Compilation failure on non-macOS platforms (e.g., Linux).
**Fix:** Move `seek(block:)` into `EXT4+Reader.swift` where it's always available.

## 13. MEDIUM: `Ptr.initialize(to:)` deinitializes `capacity` elements but only 1 was initialized
**File:** EXT4+Ptr.swift:46, 81
**Bug:** `self.underlying.deinitialize(count: self.capacity)` when reinitializing, but only a single element was ever initialized via `initialize(to:)`. Deinitializing uninitialized memory is undefined behavior if `capacity > 1`.
**Impact:** No impact in practice (all callers use `capacity: 1`), but incorrect in the general case and would cause UB if the API were used with higher capacities.
**Fix:** Change to `deinitialize(count: 1)`.

## 14. MEDIUM: `readInlineExtendedAttributes` / `readBlockExtendedAttributes` slice 5 bytes for UInt32
**File:** EXT4Reader+Export.swift:173, 186
**Bug:** `buffer[0...4]` is a closed range selecting 5 bytes (indices 0,1,2,3,4). A `UInt32` is 4 bytes. The 5-byte slice wastes memory and is semantically misleading.
**Impact:** Functionally correct because `$0.load(as: UInt32.self)` only reads the first 4 bytes, but the slice contains one extra byte unnecessarily.
**Fix:** Change to `buffer[0..<4]`.

## 15. MEDIUM: `tupleToArray` uses `Mirror` reflection
**File:** EXT4+Extensions.swift:95-98
**Bug:** Uses runtime reflection (`Mirror(reflecting:)` + `compactMap { $0.value as? UInt8 }`) to convert tuples to byte arrays. This is slow and fragile — it depends on `Mirror` preserving element order and on all children being castable to `UInt8`.
**Impact:** Performance penalty on every call. Functionally correct but unnecessarily complex.
**Fix:** Replace with `withUnsafeBytes(of: tuple) { Array($0) }`.

## 16. MEDIUM: `XAttrEntry.init(using:)` uses unbounded range `bytes[12...]`
**File:** EXT4+Extensions.swift:89
**Bug:** `bytes[12...]` uses an open-ended range. The guard ensures exactly 16 bytes, so this works, but if the guard were ever changed, the slice could silently extend beyond 4 bytes.
**Impact:** No current bug, but fragile — a maintenance hazard.
**Fix:** Change to explicit `bytes[12...15]`.

## 17. MEDIUM: `hash` computation force-unwraps `char.asciiValue!`
**File:** EXT4+Xattrs.swift:60
**Bug:** Iterates over `name` as `Character` values and force-unwraps `char.asciiValue!`. If `name` contains any non-ASCII character, this crashes at runtime.
**Impact:** Runtime crash on non-ASCII xattr names.
**Fix:** Iterate over `name.utf8` which yields `UInt8` values directly.

## 18. MEDIUM: `FileXattrsState.read` force-unwraps ASCII string conversion
**File:** EXT4+Xattrs.swift:267
**Bug:** `String(bytes: rawName, encoding: .ascii)!` — force unwrap crashes if name bytes aren't valid ASCII.
**Impact:** Runtime crash on malformed xattr name data in a filesystem being read.
**Fix:** Use `guard let` with `continue` to skip malformed entries.

## 19. MEDIUM: Short symlink target includes trailing zero bytes
**File:** EXT4Reader+Export.swift:133
**Bug:** For fast symlinks (size < 60), `EXT4.tupleToArray(inode.block)` converts all 60 bytes. The actual target is only `size` bytes; remaining bytes are zeros that appear as null characters in the string.
**Impact:** Symlink targets in exported archives may contain trailing null characters, causing path resolution failures.
**Fix:** Use `linkBytes.prefix(Int(size))`.

## 20. LOW: `FileXattrsState.read` off-by-one in bounds checks
**File:** EXT4+Xattrs.swift:260, 265, 278, 280, 282
**Bug:** `i + 16 < buffer.count` and `endIndex < buffer.count` use strict `<` but these are exclusive upper bounds for half-open range operations. When the value equals `buffer.count`, the slice is valid but the guard rejects it.
**Impact:** The last valid xattr entry in a buffer is skipped if it ends exactly at the buffer boundary.
**Fix:** Change to `<=`.

## 21. LOW: `uint32` instead of `UInt32` in `commitInodeTable`
**File:** EXT4+Formatter.swift:955
**Bug:** `uint32(self.inodes.count)` uses the C-imported `uint32` type alias instead of Swift's `UInt32`. Functionally equivalent but inconsistent with the rest of the codebase.
**Impact:** No functional impact. Style inconsistency.
**Fix:** Change to `UInt64(UInt32(self.inodes.count) * EXT4.InodeSize)` for type safety.

## 22. LOW: `breathWiseChildTree` typo in variable name
**File:** EXT4+Formatter.swift:598
**Bug:** Variable named `breathWiseChildTree` instead of `breadthWiseChildTree` (breadth-first traversal).
**Impact:** No functional impact. Misleading identifier.
**Fix:** Rename to `breadthWiseChildTree`.

## 23. LOW: Typo "entrees" in documentation
**File:** EXT4.swift:213
**Bug:** "directory entrees" should be "directory entries".
**Impact:** No functional impact. Documentation error.
**Fix:** Change to "entries".

## 24. LOW: Typo "a inode" in documentation
**File:** EXT4.swift:116
**Bug:** "represents a inode" should be "represents an inode".
**Impact:** No functional impact. Grammar error.
**Fix:** Change to "an inode".

## 25. LOW: Typo "less than not a multiple" in comment
**File:** EXT4+Xattrs.swift:21
**Bug:** "less than not a multiple of 4" is garbled. Should be "not a multiple of 4".
**Impact:** No functional impact. Comment error.
**Fix:** Remove "less than".
