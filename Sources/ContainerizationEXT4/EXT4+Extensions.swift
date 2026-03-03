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

import Foundation

extension EXT4.InodeFlag {
    public static func | (lhs: Self, rhs: Self) -> Self {
        Self(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }

    public static func | (lhs: Self, rhs: UInt32) -> UInt32 {
        lhs.rawValue | rhs
    }
}

extension EXT4.CompatFeature {
    public static func | (lhs: Self, rhs: Self) -> Self {
        EXT4.CompatFeature(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.IncompatFeature {
    public static func | (lhs: Self, rhs: Self) -> Self {
        EXT4.IncompatFeature(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.RoCompatFeature {
    public static func | (lhs: Self, rhs: Self) -> Self {
        EXT4.RoCompatFeature(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt32 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.FileModeFlag {
    public static func | (lhs: Self, rhs: Self) -> Self {
        Self(rawValue: lhs.rawValue | rhs.rawValue)
    }

    public static func | (lhs: Self, rhs: Self) -> UInt16 {
        lhs.rawValue | rhs.rawValue
    }
}

extension EXT4.XAttrEntry {
    init(using bytes: [UInt8]) throws {
        guard bytes.count == 16 else {
            throw EXT4.Error.invalidXattrEntry
        }
        nameLength = bytes[0]
        nameIndex = bytes[1]
        valueOffset = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        valueInum = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
        valueSize = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
        hash = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
    }
}

extension EXT4 {
    static func tupleToArray<T>(_ tuple: T) -> [UInt8] {
        let reflection = Mirror(reflecting: tuple)
        return reflection.children.compactMap { $0.value as? UInt8 }
    }
}
