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

import Foundation
import Logging

actor TimeSyncer {
    private var task: Task<Void, Never>?
    private var context: Vminitd?
    private var paused: Bool
    private let logger: Logger?

    init(logger: Logger?) {
        self.paused = false
        self.logger = logger
    }

    func start(context: Vminitd, interval: Duration = .seconds(30)) {
        guard self.task == nil else {
            return
        }

        self.context = context
        // Flagged #1 (1 of 2): HIGH: `TimeSyncer.close()` double-closes the context via actor re-entrancy and leaves stale references on throw
        // Two related defects in `TimeSyncer.close()`: (1) `close()` did not clear `self.task` or `self.context` before the first suspension point (`await task.value`). While the first `close()` call was suspended there, a second concurrent caller could enter `close()`, pass the `guard let task else { return }` check (because `self.task` was still set), and proceed to call `try await self.context?.close()` concurrently with the first call. Both callers could then race to close the same underlying vminitd gRPC context while the other was still using it. (2) `self.task = nil` and `self.context = nil` were also placed after `try await context?.close()`; if `close()` threw, those assignments were never reached, leaving stale references that any subsequent call inspecting `self.context` would operate on.
        // Flagged #2 (1 of 2): HIGH: `TimeSyncer` captures `self` inside an unstructured `Task`, causing an actor-isolation data race on `self.logger`
        // `TimeSyncer.start()` created an unstructured `Task` whose closure referenced `self.logger`. `TimeSyncer` is an `actor`; unstructured tasks do not run on the actor's executor, so accessing `self.logger` inside the task is a cross-actor access without `await`. Under Swift 6 strict concurrency this is a compile-time error; under Swift 5 mode it is a silent data race.
        let logger = self.logger
        self.task = Task {
            while true {
                do {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }

                    guard !paused else {
                        continue
                    }

                    var timeval = timeval()
                    guard gettimeofday(&timeval, nil) == 0 else {
                        throw POSIXError.fromErrno()
                    }

                    try await context.setTime(
                        sec: Int64(timeval.tv_sec),
                        usec: Int32(timeval.tv_usec)
                    )
                // Flagged #3: MEDIUM: TimeSyncer does not distinguish CancellationError from real sync failures — periodic loop and resume()
                // The same defect appears in two methods. (1) The periodic sync loop had a single `catch` block that logged every error as a failed time-sync. When the actor's task was cancelled, `CancellationError` was caught here, logged as an error, and the loop continued — re-throwing cancellation on every subsequent `setTime` call until the task was eventually torn down. (2) `resume()` called `context.setTime(sec:usec:)` inside a `do/catch` whose only handler was a generic error logger. If the calling task was cancelled while awaiting `setTime`, the `CancellationError` was caught, logged as "failed to sync time with guest agent", and swallowed — neither re-thrown nor distinguished from a real RPC failure.
                } catch is CancellationError {
                    return
                } catch {
                    // Flagged #2 (2 of 2)
                    logger?.error("failed to sync time with guest agent: \(error)")
                }
            }
        }
    }

    func pause() async {
        self.paused = true
    }

    func resume() async {
        self.paused = false
    }

    func close() async throws {
        guard let task else {
            // Already closed, nop.
            return
        }
        // Flagged #1 (2 of 2)
        self.task = nil
        let context = self.context
        self.context = nil

        task.cancel()
        await task.value
        try await context?.close()
    }
}
