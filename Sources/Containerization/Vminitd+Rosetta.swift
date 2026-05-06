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

import ContainerizationOS

extension Vminitd {
    /// Enable Rosetta's x86_64 emulation.
    public func enableRosetta() async throws {
        let path = "/run/rosetta"
        // Flagged #1: HIGH: `Vminitd.enableRosetta()` mounts to `/run/rosetta` without creating the directory first
        // `enableRosetta()` called `self.mount(...)` with destination `/run/rosetta` without first ensuring the directory existed in the guest. A virtiofs mount to a non-existent path fails immediately in the guest kernel.
        try await self.mkdir(path: path, all: true, perms: 0o755)
        try await self.mount(
            .init(
                type: "virtiofs",
                source: "rosetta",
                destination: path
            )
        )
        try await self.setupEmulator(
            binaryPath: "\(path)/rosetta",
            configuration: Binfmt.Entry.amd64()
        )
    }
}
