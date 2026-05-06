// fix-bugs: 2026-04-24 21:48 — 0 critical, 0 high, 0 medium, 1 low (1 total)
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

import ContainerizationError
import Crypto
import Foundation

package func hashMountSource(source: String) throws -> String {
    // Resolve symlinks so different paths to the same directory get the same hash.
    let resolvedSource = URL(fileURLWithPath: source).resolvingSymlinksInPath().path
    guard let data = resolvedSource.data(using: .utf8) else {
        // Flagged #1: LOW: `hashMountSource()` error message reports unresolved path
        // The `guard let data` failure branch throws an error interpolating `source` (the raw, caller-supplied path) instead of `resolvedSource` (the symlink-resolved path that was actually passed to `.data(using:)`).
        throw ContainerizationError(.invalidArgument, message: "\(resolvedSource) could not be converted to Data")
    }
    return String(SHA256.hash(data: data).encoded.prefix(36))
}
