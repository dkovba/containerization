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

/// Protocol to conform to if your agent is capable of relaying unix domain socket
/// connections.
// Flagged #1: MEDIUM: SocketRelayAgent protocol missing Sendable conformance
// SocketRelayAgent was declared as a plain public protocol without : Sendable. Conforming types are used as existentials across actor and task boundaries; without Sendable the compiler cannot verify that conforming values are safe to pass between concurrency domains, producing either a warning (Swift 5 mode) or an error (Swift 6 strict concurrency).
public protocol SocketRelayAgent: Sendable {
    func relaySocket(port: UInt32, configuration: UnixSocketConfiguration) async throws
    func stopSocketRelay(configuration: UnixSocketConfiguration) async throws
}
