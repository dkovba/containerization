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

extension Vminitd: SocketRelayAgent {
    /// Sets up a relay between a host socket to a newly created guest socket, or vice versa.
    public func relaySocket(port: UInt32, configuration: UnixSocketConfiguration) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_ProxyVsockRequest.with {
            $0.id = configuration.id
            $0.vsockPort = port

            switch configuration.direction {
            case .into:
                $0.guestPath = configuration.destination.path
                $0.action = .into
                // Flagged #1: LOW: `Vminitd+SocketRelay` sets `guestSocketPermissions` on `.outOf` relays
                // `guestSocketPermissions` was assigned before the `direction` switch, so it was included in the request for both `.into` and `.outOf` relays. For `.outOf` relays the host connects to an existing guest-side socket; setting permissions on it is meaningless and may confuse the guest agent.
                if let perms = configuration.permissions {
                    $0.guestSocketPermissions = UInt32(perms.rawValue)
                }
            case .outOf:
                $0.guestPath = configuration.source.path
                $0.action = .outOf
            }
        }
        _ = try await client.proxyVsock(request)
    }

    /// Stops the specified socket relay.
    public func stopSocketRelay(configuration: UnixSocketConfiguration) async throws {
        let request = Com_Apple_Containerization_Sandbox_V3_StopVsockProxyRequest.with {
            $0.id = configuration.id
        }
        _ = try await client.stopVsockProxy(request)
    }
}
