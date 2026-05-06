// fix-bugs: 2026-04-24 10:35 — 0 critical, 1 high, 0 medium, 0 low (1 total)
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

import FoundationEssentials
import LCShim

#if canImport(Musl)
import Musl
private let _close = Musl.close
#elseif canImport(Glibc)
import Glibc
private let _close = Glibc.close
#endif

class Console {
    let master: Int32
    let slavePath: String

    init() throws {
        let masterFD = open("/dev/ptmx", O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard masterFD != -1 else {
            throw App.Errno(stage: "open_ptmx")
        }

        // Flagged #1 (1 of 2): MEDIUM: `init()` leaks master PTY file descriptor on failure
        // `masterFD` is opened via `open("/dev/ptmx", ...)` but is never closed if `unlockpt` or `ptsname` subsequently fails. Both guard-else branches throw without closing `masterFD`, leaking the file descriptor.
        guard unlockpt(masterFD) == 0 else {
            _ = _close(masterFD)
            throw App.Errno(stage: "unlockpt")
        }

        // Flagged #1 (2 of 2)
        guard let slavePath = ptsname(masterFD) else {
            _ = _close(masterFD)
            throw App.Errno(stage: "ptsname")
        }

        self.master = masterFD
        self.slavePath = String(cString: slavePath)
    }

    func configureStdIO() throws {
        let path = self.slavePath
        let slaveFD = open(path, O_RDWR)
        guard slaveFD != -1 else {
            throw App.Errno(stage: "open_pts")
        }
        defer { _ = _close(slaveFD) }

        for fd: Int32 in 0...2 {
            guard dup3(slaveFD, fd, 0) != -1 else {
                throw App.Errno(stage: "dup3")
            }
        }
    }

    func close() throws {
        guard _close(self.master) == 0 else {
            throw App.Errno(stage: "close")
        }
    }
}
