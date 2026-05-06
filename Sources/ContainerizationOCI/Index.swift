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

//  Source: https://github.com/opencontainers/image-spec/blob/main/specs-go/v1/index.go

import Foundation

/// Index references manifests for various platforms.
/// This structure provides `application/vnd.oci.image.index.v1+json` mediatype when marshalled to JSON.
public struct Index: Codable, Sendable {
    /// schemaVersion is the image manifest schema that this image follows
    public let schemaVersion: Int

    // Flagged #1 (1 of 3): MEDIUM: `Index.mediaType` always encoded even when absent, breaking OCI round-trips
    // `mediaType` was declared as non-optional `String`. The custom decoder used `decodeIfPresent` and fell back to `""` when the field was absent in the JSON. Because no custom `encode(to:)` was provided, the synthesized encoder always emitted `"mediaType": ""` — even for an index decoded from JSON that contained no `mediaType` field. This violates the OCI Image Index Specification, which marks `mediaType` as `omitempty`, and corrupts round-trip JSON encoding.
    public let mediaType: String?

    /// manifests references platform specific manifests.
    public var manifests: [Descriptor]

    /// annotations contains arbitrary metadata for the image index.
    public var annotations: [String: String]?

    /// `subject` references another manifest this index is an artifact of.
    public let subject: Descriptor?

    /// `artifactType` specifies the IANA media type of the artifact this index represents.
    public let artifactType: String?

    // Flagged #1 (2 of 3)
    public init(
        schemaVersion: Int = 2, mediaType: String? = MediaTypes.index, manifests: [Descriptor],
        annotations: [String: String]? = nil, subject: Descriptor? = nil, artifactType: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mediaType = mediaType
        self.manifests = manifests
        self.annotations = annotations
        self.subject = subject
        self.artifactType = artifactType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // Flagged #1 (3 of 3)
        self.mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        self.manifests = try container.decode([Descriptor].self, forKey: .manifests)
        self.annotations = try container.decodeIfPresent([String: String].self, forKey: .annotations)
        self.subject = try container.decodeIfPresent(Descriptor.self, forKey: .subject)
        self.artifactType = try container.decodeIfPresent(String.self, forKey: .artifactType)
    }
}
