// fix-bugs: 2026-04-24 11:29 — 3 total
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

#if os(macOS)
import Foundation
import Logging
import Virtualization
import ContainerizationError

extension VZVirtualMachine {
    nonisolated func connect(queue: DispatchQueue, port: UInt32) async throws -> VZVirtioSocketConnection {
        try await withCheckedThrowingContinuation { cont in
            queue.sync {
                // Flagged #1 (1 of 3): CRITICAL: `VZVirtualMachine` vsock helper methods crash with a fatal index-out-of-bounds when `socketDevices` is empty
                // `connect(queue:port:)`, `listen(queue:port:listener:)`, and `removeListener(queue:port:)` all accessed `self.socketDevices[0]` — a hard-subscript that Swift evaluates unconditionally before the `guard let … as?` cast. If `socketDevices` is empty the subscript traps with a fatal "index out of range" error, crashing the process.
                guard let vsock = self.socketDevices.first as? VZVirtioSocketDevice else {
                    let error = ContainerizationError(.invalidArgument, message: "no vsock device")
                    cont.resume(throwing: error)
                    return
                }
                vsock.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        // `conn` isn't used concurrently.
                        nonisolated(unsafe) let conn = conn
                        cont.resume(returning: conn)
                    case .failure(let error):
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func listen(queue: DispatchQueue, port: UInt32, listener: VZVirtioSocketListener) throws {
        try queue.sync {
            // Flagged #1 (2 of 3)
            guard let vsock = self.socketDevices.first as? VZVirtioSocketDevice else {
                throw ContainerizationError(.invalidArgument, message: "no vsock device")
            }
            vsock.setSocketListener(listener, forPort: port)
        }
    }

    func removeListener(queue: DispatchQueue, port: UInt32) throws {
        try queue.sync {
            // Flagged #1 (3 of 3)
            guard let vsock = self.socketDevices.first as? VZVirtioSocketDevice else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "no vsock device to remove"
                )
            }
            vsock.removeSocketListener(forPort: port)
        }
    }

    func start(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.start { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func stop(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.stop { error in
                    if let error {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func pause(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.pause { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }

    func resume(queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.sync {
                self.resume { result in
                    if case .failure(let error) = result {
                        cont.resume(throwing: error)
                        return
                    }
                    cont.resume()
                }
            }
        }
    }
}

extension VZVirtualMachine {
    func waitForAgent(queue: DispatchQueue) async throws -> FileHandle {
        let agentConnectionRetryCount: Int = 200
        let agentConnectionSleepDuration: Duration = .milliseconds(20)

        for _ in 0...agentConnectionRetryCount {
            do {
                return try await self.connect(queue: queue, port: Vminitd.port).dupHandle()
            // Flagged #2: MEDIUM: `VZVirtualMachine.waitForAgent()` retry loop swallows `CancellationError`, delaying task cancellation by up to 4 seconds
            // Two observations about the same retry loop: (1) `for _ in 0...agentConnectionRetryCount` uses a closed range, producing 201 iterations (0 through 200 inclusive) instead of the intended 200; the one extra retry is negligible in practice (~20 ms). (2) A single generic `catch` block treats `CancellationError` identically to a transient connection failure — it sleeps 20 ms and retries. Because `Task.sleep` itself checks for cancellation and rethrows it, the loop eventually exits, but only after an unnecessary 20 ms delay per iteration — up to 4 seconds total across 200 retries.
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await Task.sleep(for: agentConnectionSleepDuration)
                continue
            }
        }
        throw ContainerizationError(.timeout, message: "failed to get a connection to agent socket")
    }
}

extension VZVirtioSocketConnection {
    func dupHandle() throws -> FileHandle {
        // Flagged #3: MEDIUM: `VZVirtioSocketConnection.dupHandle()` leaks the connection if `dup()` fails
        // `self.close()` was called after `dup()`, so if `dup()` returned `-1` and threw `POSIXError`, `self.close()` was never reached and the `VZVirtioSocketConnection` was leaked.
        defer { self.close() }
        let fd = dup(self.fileDescriptor)
        if fd == -1 {
            throw POSIXError.fromErrno()
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

#endif
