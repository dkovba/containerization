// fix-bugs: 2026-04-24 12:11 — 0 bugs
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

struct OSFile: Sendable {
    enum IOAction: Equatable {
        case eof
        case again
        case success
        case brokenPipe
        case error(_ errno: Int32)
    }

    private let fd: Int32

    var closed: Bool {
        Foundation.fcntl(fd, F_GETFD) == -1 && errno == EBADF
    }

    var fileDescriptor: Int32 { fd }

    init(fd: Int32) {
        self.fd = fd
    }

    init(handle: FileHandle) {
        self.fd = handle.fileDescriptor
    }

    func close() throws {
        guard Foundation.close(self.fd) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
    }

    func read(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (read: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesRead: Int = 0
        while true {
            let n = Foundation.read(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesRead),
                buffer.count - bytesRead
            )
            if n == -1 {
                // Flagged #1 (1 of 2): HIGH: `read()` and `write()` treat `EIO` as a retriable condition
                // Both `read()` and `write()` use the condition `errno == EAGAIN || errno == EIO` to map errors to the `.again` action. `EIO` is not a transient, retriable condition — on Linux it is returned permanently when, for example, the slave end of a PTY has been closed. Treating it as `.again` causes the caller to retry indefinitely, spinning forever.
                if errno == EAGAIN {
                    return (bytesRead, .again)
                }
                return (bytesRead, .error(errno))
            }

            if n == 0 {
                return (bytesRead, .eof)
            }

            bytesRead += n
            if bytesRead < buffer.count {
                continue
            }
            return (bytesRead, .success)
        }
    }

    func write(_ buffer: UnsafeMutableBufferPointer<UInt8>) -> (wrote: Int, action: IOAction) {
        if buffer.count == 0 {
            return (0, .success)
        }

        var bytesWrote: Int = 0
        while true {
            let n = Foundation.write(
                self.fd,
                buffer.baseAddress!.advanced(by: bytesWrote),
                buffer.count - bytesWrote
            )
            if n == -1 {
                // Flagged #1 (2 of 2)
                if errno == EAGAIN {
                }
                // Flagged #2 (1 of 2): MEDIUM: `write()` detects broken pipe via `n == 0` instead of `errno == EPIPE`
                // The code returns `.brokenPipe` when `write()` returns `0`. On POSIX, `write()` signals a broken pipe by returning `-1` with `errno == EPIPE`, not by returning `0`.
                if errno == EPIPE {
                    return (bytesWrote, .brokenPipe)
                }
                return (bytesWrote, .error(errno))
            }

            // Flagged #2 (2 of 2)
            if n == 0 {
                continue
            }

            bytesWrote += n
            if bytesWrote < buffer.count {
                continue
            }
            return (bytesWrote, .success)
        }
    }

    static func pipe() -> (read: Self, write: Self) {
        let pipe = Pipe()
        return (Self(handle: pipe.fileHandleForReading), Self(handle: pipe.fileHandleForWriting))
    }

    static func open(path: String) throws -> Self {
        try open(path: path, mode: O_RDONLY | O_CLOEXEC)
    }

    static func open(path: String, mode: Int32) throws -> Self {
        let fd = Foundation.open(path, mode)
        if fd < 0 {
            throw POSIXError(.init(rawValue: errno)!)
        }
        return Self(fd: fd)
    }
}
