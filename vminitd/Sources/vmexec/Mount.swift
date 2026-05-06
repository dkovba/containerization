// fix-bugs: 2026-04-24 10:45 — 0 bugs
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

import ContainerizationOCI
import ContainerizationOS
import FoundationEssentials

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

struct ContainerMount {
    private let mounts: [ContainerizationOCI.Mount]
    private let rootfs: String

    init(rootfs: String, mounts: [ContainerizationOCI.Mount]) {
        self.rootfs = rootfs
        self.mounts = mounts
    }

    func mountToRootfs() throws {
        for m in self.mounts {
            let osMount = m.toOSMount()
            try osMount.mount(root: self.rootfs)
        }
    }

    func configureConsole() throws {
        let ptmx = rootfs + "/dev/ptmx"
        // Flagged #1: MEDIUM: `configureConsole()` throws spuriously when `/dev/ptmx` does not exist
        // `guard remove(ptmx) == 0` treats ENOENT as a fatal error. If the rootfs does not already contain a `/dev/ptmx` node, `remove()` returns -1 with `errno == ENOENT`, causing `configureConsole()` to throw before the symlink is ever created.
        guard remove(ptmx) == 0 || errno == ENOENT else {
            throw App.Errno(stage: "remove(ptmx)")
        }
        guard symlink("pts/ptmx", ptmx) == 0 else {
            throw App.Errno(stage: "symlink(pts/ptmx)")
        }
    }
}

extension ContainerizationOCI.Mount {
    func toOSMount() -> ContainerizationOS.Mount {
        ContainerizationOS.Mount(
            type: self.type,
            source: self.source,
            target: self.destination,
            options: self.options
        )
    }
}
