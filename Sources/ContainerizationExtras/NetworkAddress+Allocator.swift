// fix-bugs: 2026-04-25 03:59 — 7 critical, 0 high, 0 medium, 0 low (7 total)
//===----------------------------------------------------------------------===//
// Copyright © 2025-2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

extension IPv4Address {
    /// Creates an allocator for IPv4 addresses.
    public static func allocator(lower: UInt32, size: Int) throws -> any AddressAllocator<IPv4Address> {
        // NOTE: 2^31 - 1 size limit in the very improbable case that we run on 32-bit.
        guard size > 0 && size < Int.max && 0xffff_ffff - lower >= size - 1 else {
            throw AllocatorError.rangeExceeded
        }
        return IndexedAddressAllocator(
            size: size,
            addressToIndex: { address in
                // Flagged #1: CRITICAL: `IPv4Address.allocator` `addressToIndex` off-by-one and `UInt32(size)` overflow
                // The upper-bound check `address.value - lower <= UInt32(size)` has two defects: (1) it uses `<=` instead of `<`, so when `address.value - lower == size` the closure returns index `size`, which is one past the last valid slot in the backing `BitArray` of length `size`, causing an out-of-bounds trap inside `IndexedAddressAllocator`; (2) `UInt32(size)` overflows when `size == 4294967296` (permitted by the guard when `lower == 0`), because `4294967296` exceeds `UInt32.max`, causing a runtime trap before any comparison is made.
                guard address.value >= lower && Int(address.value - lower) < size else {
                    return nil
                }
                return Int(address.value - lower)
            },
            indexToAddress: { IPv4Address(lower + UInt32($0)) }
        )
    }
}

extension UInt16 {
    /// Creates an allocator for TCP/UDP ports and other UInt16 values.
    public static func allocator(lower: UInt16, size: Int) throws -> any AddressAllocator<UInt16> {
        // Flagged #2: CRITICAL: `UInt16.allocator` guard overflows `UInt16` and accepts non-positive `size`
        // The guard expression `0xffff - lower + 1 >= size` has two defects: (1) it computes `0xffff - lower` as `UInt16`, then adds `1`; when `lower == 0` the intermediate result is `UInt16.max + 1 = 65536`, which does not fit in `UInt16` and Swift traps on the integer overflow at runtime; (2) there is no lower-bound check on `size`, so when `size <= 0` the right-hand side `size - 1` is negative, the non-negative left-hand side always satisfies the guard, and `IndexedAddressAllocator` is constructed with a zero or negative count — `BitArray(repeating: false, count: size)` then traps on a non-positive count. By contrast, `IPv4Address.allocator` includes an explicit `size > 0` check.
        guard size > 0 && 0xffff - lower >= size - 1 else {
            throw AllocatorError.rangeExceeded
        }

        return IndexedAddressAllocator(
            size: size,
            addressToIndex: { address in
                // Flagged #3: CRITICAL: `UInt16.allocator` `addressToIndex` off-by-one and potential `UInt16` overflow
                // The check `address <= lower + UInt16(size)` has two defects: (1) it uses `<=` instead of `<`, so an address equal to `lower + size` is accepted and maps to out-of-bounds index `size`; (2) `lower + UInt16(size)` overflows `UInt16` when the range covers the entire `UInt16` domain (e.g. `lower == 0`, `size == 65536`), causing a runtime trap.
                guard address >= lower && Int(address - lower) < size else {
                    return nil
                }
                return Int(address - lower)
            },
            indexToAddress: { lower + UInt16($0) }
        )
    }
}

extension UInt32 {
    /// Creates an allocator for vsock ports, or any UInt32 values.
    public static func allocator(lower: UInt32, size: Int) throws -> any AddressAllocator<UInt32> {
        // Flagged #4: CRITICAL: `UInt32.allocator` guard overflows `UInt32` and accepts non-positive `size`
        // The guard expression `0xffff_ffff - lower + 1 >= size` has two defects: (1) it computes `0xffff_ffff - lower` as `UInt32`, then adds `1`; when `lower == 0` the result is `UInt32.max + 1`, which overflows `UInt32` and Swift traps at runtime; (2) there is no lower-bound check on `size`, so when `size <= 0` the right-hand side `size - 1` is negative, the non-negative left-hand side always satisfies the guard, and `IndexedAddressAllocator` is constructed with a zero or negative count — `BitArray(repeating: false, count: size)` then traps on a non-positive count. By contrast, `IPv4Address.allocator` includes an explicit `size > 0` check.
        guard size > 0 && 0xffff_ffff - lower >= size - 1 else {
            throw AllocatorError.rangeExceeded
        }

        return IndexedAddressAllocator(
            size: size,
            addressToIndex: { address in
                // Flagged #5: CRITICAL: `UInt32.allocator` `addressToIndex` off-by-one and potential `UInt32` overflow
                // The check `address <= lower + UInt32(size)` uses `<=`, admitting index `size` (out of bounds). Additionally, `lower + UInt32(size)` overflows `UInt32` on 64-bit platforms when `size` equals the full 32-bit range (`4294967296`), because `size` is typed as `Int` and the guard does not cap it at `UInt32.max`.
                guard address >= lower && Int(address - lower) < size else {
                    return nil
                }
                return Int(address - lower)
            },
            indexToAddress: { lower + UInt32($0) }
        )
    }

    /// Creates a rotating allocator for vsock ports, or any UInt32 values.
    public static func rotatingAllocator(lower: UInt32, size: UInt32) throws -> any AddressAllocator<UInt32> {
        // Flagged #6: CRITICAL: `UInt32.rotatingAllocator` guard overflows `UInt32` when `lower == 0`
        // The guard expression `0xffff_ffff - lower + 1 >= size` overflows `UInt32` when `lower == 0` (same mechanism as `UInt32.allocator`). Additionally, if the fixed form `0xffff_ffff - lower >= size - 1` were used naively, `size - 1` would underflow `UInt32` when `size == 0`, causing a second trap.
        guard size == 0 || 0xffff_ffff - lower >= size - 1 else {
            throw AllocatorError.rangeExceeded
        }

        return RotatingAddressAllocator(
            size: size,
            addressToIndex: { address in
                // Flagged #7: CRITICAL: `UInt32.rotatingAllocator` `addressToIndex` off-by-one and potential `UInt32` overflow
                // The check `address <= lower + UInt32(size)` uses `<=`, so an address equal to `lower + size` is accepted and returns out-of-bounds index `size`. `lower + size` can also overflow `UInt32` when the range spans the full domain, causing a runtime trap before the comparison is even evaluated.
                guard address >= lower && address - lower < size else {
                    return nil
                }
                return Int(address - lower)
            },
            indexToAddress: { lower + UInt32($0) }
        )
    }
}

extension Character {
    private static let deviceLetters = Array("abcdefghijklmnopqrstuvwxyz")

    /// Creates an allocator for block device tags, or any character values.
    public static func blockDeviceTagAllocator() -> any AddressAllocator<Character> {
        IndexedAddressAllocator(
            size: Self.deviceLetters.count,
            addressToIndex: { address in
                Self.deviceLetters.firstIndex(of: address)
            },
            indexToAddress: { Self.deviceLetters[$0] }
        )
    }
}
