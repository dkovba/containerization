// fix-bugs: 2026-04-24 16:35 — 0 critical, 1 high, 0 medium, 0 low (1 total)
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

import AsyncHTTPClient
import Foundation
import NIOHTTP1

extension RegistryClient {
    /// `RegistryClient` errors.
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidStatus(url: String, HTTPResponseStatus, reason: String? = nil)

        /// Description of the errors.
        public var description: String {
            switch self {
            case .invalidStatus(let u, let response, let reason):
                return "HTTP request to \(u) failed with response: \(response.description). Reason: \(reason ?? "Unknown")"
            }
        }
    }

    /// The container registry typically returns actionable failure reasons in the response body
    /// of the failing HTTP Request. This type models the structure of the error message.
    /// Reference: https://distribution.github.io/distribution/spec/api/#errors
    internal struct ErrorResponse: Codable {
        let errors: [RemoteError]

        internal struct RemoteError: Codable {
            let code: String
            let message: String
            let detail: String?

            // Flagged #1: HIGH: `RemoteError` decode fails when `detail` is non-string JSON, silently discarding all registry error context
            // `detail` is declared as `String?`, so `JSONDecoder` throws a type-mismatch error when a registry returns a non-string value for that field (e.g. Docker Hub returns an array for `UNAUTHORIZED` responses: `"detail":[{"Type":"repository","Name":"ubuntu","Action":"pull"}]`). Because `fromResponseBody` wraps the entire decode in `try?`, a single non-string `detail` causes the whole `ErrorResponse` to be discarded and `fromResponseBody` returns `nil`. Every call site across `RegistryClient`, `RegistryClient+Fetch`, `RegistryClient+Push`, `RegistryClient+Referrers`, and `RegistryClient+Catalog` then receives `reason: nil`, and the thrown error surfaces as "Reason: Unknown" instead of the actual registry error message.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.code = try container.decode(String.self, forKey: .code)
                self.message = try container.decode(String.self, forKey: .message)
                self.detail = try? container.decode(String.self, forKey: .detail)
            }
        }

        internal static func fromResponseBody(_ body: HTTPClientResponse.Body) async -> ErrorResponse? {
            guard var buffer = try? await body.collect(upTo: Int(1.mib())) else {
                return nil
            }
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
                return nil
            }
            let data = Data(bytes)
            guard let jsonError = try? JSONDecoder().decode(ErrorResponse.self, from: data) else {
                return nil
            }
            return jsonError
        }

        public var jsonString: String {
            let data = try? JSONEncoder().encode(self)
            guard let data else {
                return "{}"
            }
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }
}
