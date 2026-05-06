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

import Foundation

#if os(macOS)
import Virtualization
#endif

/// A stream of vsock connections.
public final class VsockListener: NSObject, Sendable, AsyncSequence {
    public typealias Element = FileHandle

    /// The port the connections are for.
    public let port: UInt32

    private let connections: AsyncStream<FileHandle>
    private let cont: AsyncStream<FileHandle>.Continuation
    private let stopListening: @Sendable (_ port: UInt32) throws -> Void

    package init(port: UInt32, stopListen: @Sendable @escaping (_ port: UInt32) throws -> Void) {
        self.port = port
        let (stream, continuation) = AsyncStream.makeStream(of: FileHandle.self)
        self.connections = stream
        self.cont = continuation
        self.stopListening = stopListen
    }

    // Flagged #2: HIGH: `VsockListener.finish()` signals end-of-stream before stopping the listener, risking a yield-after-finish race
    // `finish()` called `self.cont.finish()` first and then `self.stopListening(self.port)`. In the window between the two calls a new vsock connection could be accepted via the delegate callback, calling `cont.yield()` on an already-finished continuation.
    public func finish() throws {
        defer { self.cont.finish() }
        try self.stopListening(self.port)
    }

    public func makeAsyncIterator() -> AsyncStream<FileHandle>.AsyncIterator {
        connections.makeAsyncIterator()
    }
}

#if os(macOS)

extension VsockListener: VZVirtioSocketListenerDelegate {
    public func listener(
        _: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
        from _: VZVirtioSocketDevice
    ) -> Bool {
        let fd = dup(conn.fileDescriptor)
        guard fd != -1 else {
            return false
        }
        conn.close()

        // Flagged #1: CRITICAL: VsockListener leaks every accepted file descriptor
        // FileHandle(fileDescriptor: fd, closeOnDealloc: false) was used for the duplicated vsock connection fd. With closeOnDealloc: false, the FileHandle does not close the fd on deallocation; nothing else in the code closed it either.
        let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let result = cont.yield(fh)
        if case .terminated = result {
            try? fh.close()
            return false
        }

        return true
    }
}

#endif
