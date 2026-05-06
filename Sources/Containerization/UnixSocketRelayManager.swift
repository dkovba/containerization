// fix-bugs: 2026-04-24 11:29 — 2 total
//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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
import Foundation
import Logging

package actor UnixSocketRelayManager {
    private let vm: any VirtualMachineInstance
    private var relays: [String: UnixSocketRelay]
    private let queue: DispatchQueue
    private let log: Logger?

    init(vm: any VirtualMachineInstance, log: Logger? = nil) {
        self.vm = vm
        self.relays = [:]
        self.queue = DispatchQueue(label: "com.apple.containerization.socket-relay")
        self.log = log
    }
}

extension UnixSocketRelayManager {
    func start(port: UInt32, socket: UnixSocketConfiguration) async throws {
        guard relays[socket.id] == nil else {
            throw ContainerizationError(
                .invalidState,
                message: "socket relay \(socket.id) already started"
            )
        }

        let relay = try UnixSocketRelay(
            port: port,
            socket: socket,
            vm: vm,
            queue: queue,
            log: log
        )

        do {
            relays[socket.id] = relay
            try await relay.start()
        } catch {
            relays.removeValue(forKey: socket.id)
            // Flagged #1 (1 of 2): HIGH: `UnixSocketRelayManager.stopAll()` abandons relays on first error and leaks state
            // `stopAll()` iterates relays with `try relay.stop()`. If any relay throws, the loop exits immediately, leaving remaining relays running. The `relays` dictionary is never cleared, so subsequent calls see stale entries.
            // Flagged #2: MEDIUM: `UnixSocketRelayManager.start()` does not stop a partially-started relay on failure
            // When `relay.start()` threw, the `catch` block removed the relay from the `relays` dictionary but never called `relay.stop()`. If `start()` had created any resources before throwing (e.g. bound a Unix-domain socket for a `.outOf` relay), those resources were never cleaned up because `stop()` is the only code path that releases them.
            try? relay.stop()
            throw error
        }
    }

    func stop(socket: UnixSocketConfiguration) async throws {
        guard let storedRelay = relays.removeValue(forKey: socket.id) else {
            throw ContainerizationError(
                .notFound,
                message: "failed to stop socket relay"
            )
        }
        try storedRelay.stop()
    }

    func stopAll() async throws {
        for (_, relay) in relays {
            // Flagged #1 (2 of 2)
            try? relay.stop()
        }
        relays.removeAll()
    }
}
