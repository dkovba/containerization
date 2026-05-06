// fix-bugs: 2026-04-25 02:29 — 0 critical, 0 high, 1 medium, 0 low (1 total)
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

extension FileManager {
    /// Returns a unique temporary directory to use.
    // Flagged #1 (1 of 2): MEDIUM: `uniqueTemporaryDirectory(create:)` silently returns non-existent directory on creation failure
    // `try?` discards any error thrown by `createDirectory(at:withIntermediateDirectories:attributes:)`. When `create: true` and directory creation fails, the function returns a URL pointing to a directory that was never created, with no indication of failure to the caller.
    public func uniqueTemporaryDirectory(create: Bool = true) throws -> URL {
        let tempDirectoryURL = temporaryDirectory
        let uniqueDirectoryURL = tempDirectoryURL.appendingPathComponent(UUID().uuidString)
        if create {
            // Flagged #1 (2 of 2)
            try createDirectory(at: uniqueDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        return uniqueDirectoryURL
    }
}
