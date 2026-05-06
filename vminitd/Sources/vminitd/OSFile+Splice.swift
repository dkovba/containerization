// fix-bugs: 2026-04-24 12:21 — 1 critical, 1 high, 0 medium, 0 low (2 total)
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
import LCShim

extension OSFile {
    struct SpliceFile: Sendable {
        fileprivate var file: OSFile
        fileprivate var offset: Int
        fileprivate let pipe = Pipe()

        var fileDescriptor: Int32 {
            file.fileDescriptor
        }

        var reader: Int32 {
            pipe.fileHandleForReading.fileDescriptor
        }

        var writer: Int32 {
            pipe.fileHandleForWriting.fileDescriptor
        }

        init(fd: Int32) {
            self.file = OSFile(fd: fd)
            self.offset = 0
        }

        init(handle: FileHandle) {
            self.file = OSFile(handle: handle)
            self.offset = 0
        }

        init(from: OSFile, withOffset: Int = 0) {
            self.file = from
            self.offset = withOffset
        }

        func close() throws {
            try self.file.close()
        }
    }

    static func splice(from: inout SpliceFile, to: inout SpliceFile, count: Int = 1 << 16) throws -> (read: Int, wrote: Int, action: IOAction) {
        let fromOffset = from.offset
        let toOffset = to.offset
        // Flagged #2 (1 of 3): HIGH: EOF detected during stage-1 read discards bytes already buffered in the pipe
        // When `splice()` returned 0 (EOF) inside the stage-1 inner loop, the code executed `return (0, 0, .eof)` immediately. If any earlier iteration of that same inner loop had already read bytes from the source into `to.pipe` (incrementing `from.offset`), those bytes were sitting in the pipe but had never been written to `to.fileDescriptor`. The immediate return abandoned them, causing data loss, and also reported incorrect byte counts of `(0, 0)` instead of reflecting the bytes transferred so far in this call.
        var sawEOF = false

        while true {
            while (from.offset - to.offset) < count {
                let toRead = count - (from.offset - to.offset)
                let bytesRead = LCShim.splice(from.fileDescriptor, nil, to.writer, nil, toRead, UInt32(bitPattern: LCShim.SPLICE_F_MOVE | LCShim.SPLICE_F_NONBLOCK))
                if bytesRead == -1 {
                    // Flagged #1 (1 of 2): CRITICAL: `EIO` from `splice(2)` silently swallowed, causing infinite retry loop
                    // Both `splice()` error checks used `if errno != EAGAIN && errno != EIO`, treating `EIO` identically to `EAGAIN` (break and retry). Per `splice(2)`, `EIO` means "attempted splice to or from a tty" — a permanent, non-retriable condition. Suppressing it causes the outer `while true` loop to spin forever whenever either file descriptor is a tty.
                    if errno != EAGAIN {
                        throw POSIXError(.init(rawValue: errno)!)
                    }
                    break
                }
                // Flagged #2 (2 of 3)
                if bytesRead == 0 {
                    sawEOF = true
                    break
                }
                from.offset += bytesRead
                if bytesRead < toRead {
                    break
                }
            }
            // Flagged #2 (3 of 3)
            if from.offset == to.offset {
                return (from.offset - fromOffset, to.offset - toOffset, sawEOF ? .eof : .success)
            }
            while to.offset < from.offset {
                let toWrite = from.offset - to.offset
                let bytesWrote = LCShim.splice(to.reader, nil, to.fileDescriptor, nil, toWrite, UInt32(bitPattern: LCShim.SPLICE_F_MOVE | LCShim.SPLICE_F_NONBLOCK))
                if bytesWrote == -1 {
                    // Flagged #1 (2 of 2)
                    if errno != EAGAIN {
                        throw POSIXError(.init(rawValue: errno)!)
                    }
                    break
                }
                to.offset += bytesWrote
                if bytesWrote == 0 {
                    return (from.offset - fromOffset, to.offset - toOffset, .brokenPipe)
                }
                if bytesWrote < toWrite {
                    break
                }
            }
        }
    }
}
