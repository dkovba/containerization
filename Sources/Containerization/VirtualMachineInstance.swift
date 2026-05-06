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

import ContainerizationError
import Foundation

/// The runtime state of the virtual machine instance.
public enum VirtualMachineInstanceState: Sendable, Equatable {
    case starting
    case running
    // Flagged #1: HIGH: Paused containers cannot be stopped — missing `.paused` state handling at every layer
    // Paused-container stop is broken at two layers. (1) `LinuxContainer.stop()` attempts to extract a `startedState` and falls back to `createdState`; a paused container is in neither state, so `stop()` throws an `invalidState` error. (2) At the VM-instance layer, `VirtualMachineInstanceState` had no `.paused` case — the Virtualization framework's `.paused` state fell through to the `default` branch and was mapped to `.unknown` — and the guard in `VZVirtualMachineInstance.stop()` only allowed `.running`, so calling `stop()` on a paused VM also threw `.invalidState`. Both layers must be fixed together for a paused container to be stoppable.
    case paused
    case stopped
    case stopping
    case unknown
}

/// A live instance of a virtual machine.
public protocol VirtualMachineInstance: Sendable {
    associatedtype Agent: VirtualMachineAgent

    // The state of the virtual machine.
    var state: VirtualMachineInstanceState { get }

    var mounts: [String: [AttachedFilesystem]] { get }
    /// Dial the Agent. It's up the VirtualMachineInstance to determine
    /// what port the agent is listening on.
    func dialAgent() async throws -> Agent
    /// Dial a vsock port in the guest.
    func dial(_ port: UInt32) async throws -> FileHandle
    /// Listen on a host vsock port.
    func listen(_ port: UInt32) throws -> VsockListener
    /// Start the virtual machine.
    func start() async throws
    /// Stop the virtual machine.
    func stop() async throws
    /// Pause the virtual machine.
    func pause() async throws
    /// Resume the virtual machine.
    func resume() async throws
}

extension VirtualMachineInstance {
    public func pause() async throws {
        throw ContainerizationError(.unsupported, message: "pause")
    }
    public func resume() async throws {
        throw ContainerizationError(.unsupported, message: "resume")
    }
}
