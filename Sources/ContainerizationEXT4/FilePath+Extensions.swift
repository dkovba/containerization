// fix-bugs: 2026-04-25 01:24 — 0 critical, 1 high, 0 medium, 0 low (1 total)
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
import SystemPackage

extension FilePath {
    public static let Separator: String = "/"

    public var bytes: [UInt8] {
        self.withCString { cstr in
            var ptr = cstr
            var rawBytes: [UInt8] = []
            // Flagged #1: HIGH: `bytes` property loops forever on null-pointer check instead of null-byte check
            // The `while` loop condition `UInt(bitPattern: ptr) != 0` tests whether the pointer *address* is non-zero (a nil-pointer guard), not whether the byte *at* that address is the C-string null terminator. Because `withCString` always provides a non-nil pointer, this condition never terminates the loop; the loop exits only via the inner `if ptr.pointee == 0x00 { break }`, which is the correct check but is buried as a secondary guard. The intended loop invariant — "keep going while the current byte is not the null terminator" — is never expressed in the loop condition.
            while ptr.pointee != 0 {
                rawBytes.append(UInt8(bitPattern: ptr.pointee))
                ptr = ptr.successor()
            }
            return rawBytes
        }
    }

    public var base: String {
        self.lastComponent?.string ?? "/"
    }

    public var dir: FilePath {
        self.removingLastComponent()
    }

    public var url: URL {
        URL(fileURLWithPath: self.string)
    }

    public var items: [String] {
        self.components.map { $0.string }
    }

    public init(_ url: URL) {
        self.init(url.path(percentEncoded: false))
    }

    public func join(_ path: FilePath) -> FilePath {
        self.pushing(path)
    }

    public func join(_ path: String) -> FilePath {
        self.join(FilePath(path))
    }

    public func split() -> (dir: FilePath, base: String) {
        (self.dir, self.base)
    }

    public func clean() -> FilePath {
        self.lexicallyNormalized()
    }

    public static func rel(_ basepath: String, _ targpath: String) -> FilePath {
        let base = FilePath(basepath)
        let targ = FilePath(targpath)

        if base == targ {
            return "."
        }

        let baseComponents = base.items
        let targComponents = targ.items

        var commonPrefix = 0
        while commonPrefix < min(baseComponents.count, targComponents.count)
            && baseComponents[commonPrefix] == targComponents[commonPrefix]
        {
            commonPrefix += 1
        }

        let upCount = baseComponents.count - commonPrefix
        let relComponents = Array(repeating: "..", count: upCount) + targComponents[commonPrefix...]

        return FilePath(relComponents.joined(separator: Self.Separator))
    }
}

extension FileHandle {
    public convenience init?(forWritingTo path: FilePath) {
        self.init(forWritingAtPath: path.description)
    }

    public convenience init?(forReadingAtPath path: FilePath) {
        self.init(forReadingAtPath: path.description)
    }

    public convenience init?(forReadingFrom path: FilePath) {
        self.init(forReadingAtPath: path.description)
    }
}
