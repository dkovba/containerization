// fix-bugs: 2026-04-24 18:36 — 0 critical, 1 high, 0 medium, 0 low (1 total)
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

import ContainerizationError
import Crypto
import Foundation

public final class LocalContent: Content {
    public let path: URL
    private let file: FileHandle

    public init(path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw ContainerizationError(.notFound, message: "content at path \(path.absolutePath())")
        }

        self.file = try FileHandle(forReadingFrom: path)
        self.path = path
    }

    public func digest() throws -> SHA256.Digest {
        let bufferSize = 64 * 1024  // 64 KB
        var hasher = SHA256()

        try self.file.seek(toOffset: 0)
        // Flagged #1: HIGH: `digest()` silently produces incorrect hash on I/O errors
        // `file.readData(ofLength: bufferSize)` is the legacy non-throwing Foundation API. On an I/O error it raises an uncatchable NSException (crashing the process) or silently returns a short/empty `Data`, causing the SHA-256 hasher to finalize over incomplete data and return a wrong digest with no error signal to the caller. Every other read in this class uses the modern throwing variants (`read(upToCount:)`, `readToEnd()`), so errors there are correctly propagated as Swift errors.
        while case let data = try file.read(upToCount: bufferSize), !data.isEmpty {
            hasher.update(data: data)
        }

        let digest = hasher.finalize()

        try self.file.seek(toOffset: 0)
        return digest
    }

    public func data(offset: UInt64 = 0, length size: Int = 0) throws -> Data? {
        try file.seek(toOffset: offset)
        if size == 0 {
            return try file.readToEnd()
        }
        return try file.read(upToCount: size)
    }

    public func data() throws -> Data {
        try Data(contentsOf: self.path)
    }

    public func size() throws -> UInt64 {
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: self.path.absolutePath())
        if let size = fileAttrs[FileAttributeKey.size] as? UInt64 {
            return size
        }
        throw ContainerizationError(.internalError, message: "could not determine file size for \(path.absolutePath())")
    }

    public func decode<T>() throws -> T where T: Decodable {
        let json = JSONDecoder()
        let data = try Data(contentsOf: self.path)
        return try json.decode(T.self, from: data)
    }

    deinit {
        try? self.file.close()
    }
}
