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

import Foundation

/// A process reaper that returns exited processes along
/// with their exit status.
public struct Reaper {
    /// Process's pid and exit status.
    typealias Exit = (pid: Int32, status: Int32)

    /// Reap all pending processes and return the pid and exit status.
    public static func reap() -> [Int32: Int32] {
        var reaped = [Int32: Int32]()
        while true {
            guard let exit = wait() else {
                return reaped
            }
            reaped[exit.pid] = exit.status
        }
        // Flagged #1: LOW: `reap()` contains unreachable `return` statement after infinite loop
        // `reap()` contains a `while true` loop whose only exit path is `return reaped` inside the `guard else` branch. There is no `break` in the loop, so the `return reaped` statement placed after the closing brace of the loop is unreachable. Swift emits an "will never be executed" compiler warning for this dead code.
    }

    /// Returns the exit status of the last process that exited.
    /// nil is returned when no pending processes exist.
    private static func wait() -> Exit? {
        var rus = rusage()
        var ws = Int32()

        let pid = wait4(-1, &ws, WNOHANG, &rus)
        if pid <= 0 {
            return nil
        }
        return (pid: pid, status: Command.toExitStatus(ws))
    }
}
