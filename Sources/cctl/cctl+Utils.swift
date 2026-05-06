// fix-bugs: 2026-04-24 11:29 — 2 total
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

import Containerization
import ContainerizationError
import ContainerizationOCI
import Foundation

extension Application {
    static func fetchImage(reference: String, store: ImageStore) async throws -> Containerization.Image {
        // Flagged #1: MEDIUM: fetchImage does not normalize the reference before store lookups
        // The raw `reference` string is passed directly to `store.get` and `store.pull` without parsing and normalizing. A reference like `ubuntu` is stored normalized (e.g. `docker.io/library/ubuntu:latest`) but looked up unnormalized, producing a not-found error and triggering an unnecessary pull.
        let ref = try Reference.parse(reference)
        ref.normalize()
        let normalizedReference = ref.description
        do {
            return try await store.get(reference: normalizedReference)
        } catch let error as ContainerizationError {
            if error.code == .notFound {
                return try await store.pull(reference: normalizedReference)
            }
            throw error
        }
    }

    static func parseKeyValuePairs(from items: [String]) -> [String: String] {
        var parsedLabels: [String: String] = [:]
        for item in items {
            // Flagged #2 (1 of 2): MEDIUM: `parseKeyValuePairs` silently drops `key=` label entries with empty values
            // `item.split(separator: "=", maxSplits: 1)` with default `omittingEmptySubsequences: true` drops trailing empty substrings, so `"key="` produces `["key"]` (count 1), which fails the `guard parts.count == 2` check and is silently ignored.
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let key = String(parts[0])
            // Flagged #2 (2 of 2)
            guard !key.isEmpty else {
                continue
            }
            let val = String(parts[1])
            parsedLabels[key] = val
        }
        return parsedLabels
    }
}

extension ContainerizationOCI.Platform {
    static var arm64: ContainerizationOCI.Platform {
        .init(arch: "arm64", os: "linux", variant: "v8")
    }
}
