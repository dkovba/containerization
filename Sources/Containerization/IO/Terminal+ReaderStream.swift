// fix-bugs: 2026-04-24 11:29 — 2 total
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
import Foundation

extension Terminal: ReaderStream {
    public func stream() -> AsyncStream<Data> {
        // Flagged #1: HIGH: `Terminal.stream()` captures `self` in `readabilityHandler`, creating a retain cycle and handler leak on cancellation
        // The `readabilityHandler` closure captured `self` (the `Terminal`), creating a strong retain cycle: `Terminal` → `readabilityHandler` → `Terminal`. Additionally, there was no `onTermination` handler on the `AsyncStream` continuation, so if the stream consumer cancelled before EOF the `readabilityHandler` was never cleared.
        .init { [handle = self.handle] cont in
            // Flagged #2: MEDIUM: `Terminal.stream()` leaks `readabilityHandler` on cancellation
            // The `AsyncStream` returned by `stream()` never cleans up the `readabilityHandler`
            //   when the consuming Task is cancelled. The `readabilityHandler` closure continues to
            //   fire indefinitely, with `cont.yield()` calls silently dropped on the finished
            //   continuation, and the handler is never set to `nil`.
            cont.onTermination = { _ in handle.readabilityHandler = nil }
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    cont.finish()
                    return
                }
                cont.yield(data)
            }
        }
    }
}

extension Terminal: Writer {}
