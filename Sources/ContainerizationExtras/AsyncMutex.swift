// fix-bugs: 2026-04-25 02:10 — 1 critical, 0 high, 0 medium, 0 low (1 total)
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

/// `AsyncMutex` provides a mutex that protects a piece of data, with the main benefit being that it
/// is safe to call async methods while holding the lock. This is primarily used in spots
/// where an actor makes sense, but we may need to ensure we don't fall victim to actor
/// reentrancy issues.
public actor AsyncMutex<T: Sendable> {
    private final class Box: @unchecked Sendable {
        var value: T
        init(_ value: T) {
            self.value = value
        }
    }

    private var busy = false
    private var queue: ArraySlice<CheckedContinuation<(), Never>> = []
    private let box: Box

    public init(_ initialValue: T) {
        self.box = Box(initialValue)
    }

    /// withLock provides a scoped locking API to run a function while holding the lock.
    /// The protected value is passed to the closure for safe access.
    public func withLock<R: Sendable>(_ body: @Sendable @escaping (inout T) async throws -> R) async rethrows -> R {
        // Flagged #1 (1 of 2): CRITICAL: `withLock` allows new callers to steal the lock ahead of queued waiters, causing starvation
        // In the `defer` block, `self.busy = false` was set unconditionally before resuming the next queued waiter via `next.resume(returning: ())`. Because the actor becomes free to process new tasks the moment the `defer` block completes, a new `withLock` caller could be scheduled before the just-resumed continuation runs. That new caller would see `busy == false`, acquire the lock, and push the previously-resumed waiter to the back of the queue. Under sustained contention this can repeat indefinitely, starving the earliest-queued waiter even though it was already dequeued and resumed.
        if self.busy {
            await withCheckedContinuation { cc in
                self.queue.append(cc)
            }
        }

        self.busy = true

        defer {
            if let next = self.queue.popFirst() {
                next.resume(returning: ())
            } else {
                // Flagged #1 (2 of 2)
                self.busy = false
                self.queue = []
            }
        }

        return try await body(&self.box.value)
    }
}
