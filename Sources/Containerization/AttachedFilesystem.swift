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

import ContainerizationExtras
import ContainerizationOCI

/// A filesystem that was attached and able to be mounted inside the runtime environment.
public struct AttachedFilesystem: Sendable {
    /// The type of the filesystem.
    public var type: String
    /// The path to the filesystem within a sandbox.
    public var source: String
    /// Destination when mounting the filesystem inside a sandbox.
    public var destination: String
    /// The options to use when mounting the filesystem.
    public var options: [String]

    public init(mount: Mount, allocator: any AddressAllocator<Character>) throws {
        // Flagged #1: MEDIUM: `AttachedFilesystem` and `VZVirtualMachineInstance` kernel command-line builder dispatch on mount type string instead of typed `runtimeOptions`
        // Two sites perform a `switch` on the raw mount type string literal (`"virtiofs"`, `"ext4"`) instead of the `runtimeOptions` enum. In `AttachedFilesystem`, a mismatch between the string and the actual runtime option silently falls through to the wrong case. In `VZVirtualMachineInstance`'s `Kernel.commandLine`, a mount whose `runtimeOptions` is `.virtioblk` but whose type string differs from `"ext4"` hits the `fatalError` default branch. Both sites contain the same class of error.
        switch mount.runtimeOptions {
        case .virtiofs:
            let name = try hashMountSource(source: mount.source)
            self.source = name
        case .virtioblk:
            let char = try allocator.allocate()
            self.source = "/dev/vd\(char)"
        case .any:
            self.source = mount.source
        }
        self.type = mount.type
        self.options = mount.options
        self.destination = mount.destination
    }

    public init(type: String, source: String, destination: String, options: [String]) {
        self.type = type
        self.source = source
        self.destination = destination
        self.options = options
    }
}
