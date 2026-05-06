// fix-bugs: 2026-04-24 11:29 — 1 total
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

import ContainerizationExtras
import Foundation

internal func createTemporaryDirectory(baseName: String) -> URL? {
    let url = FileManager.default.uniqueTemporaryDirectory().appendingPathComponent(
        "\(baseName).XXXXXX")

    var path = url.absoluteURL.path
    return path.withUTF8 { utf8Bytes in
        var mutablePath = Array(utf8Bytes) + [0]
        return mutablePath.withUnsafeMutableBufferPointer { buffer -> URL? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            // Flagged #1: HIGH: `createTemporaryDirectory()` returns a non-existent URL when `mkdtemp` fails
            // The return value of `mkdtemp(baseAddress)` was discarded. When `mkdtemp` fails it returns `nil` and leaves the buffer unchanged (still containing the template suffix `XXXXXX`). The code then constructs and returns a `URL` from the unmodified buffer, pointing to a path that was never created on disk.
            guard mkdtemp(baseAddress) != nil else { return nil }
            let resultPath = String(decoding: buffer[..<(buffer.count - 1)], as: UTF8.self)
            return URL(fileURLWithPath: resultPath, isDirectory: true)
        }
    }
}
