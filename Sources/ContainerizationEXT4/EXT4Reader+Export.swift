// fix-bugs: 2026-04-25 01:00 — 0 critical, 3 high, 0 medium, 0 low (3 total)
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

import ContainerizationArchive
import Foundation
import SystemPackage

extension EXT4.EXT4Reader {
    public func export(archive: FilePath) throws {
        let config = ArchiveWriterConfiguration(
            format: .paxRestricted, filter: .none, options: [Options.xattrformat(.schily)])
        let writer = try ArchiveWriter(configuration: config)
        try writer.open(file: archive.url)
        var items = self.tree.root.pointee.children
        let hardlinkedInodes = Set(self.hardlinks.values)
        var hardlinkTargets: [EXT4.InodeNumber: FilePath] = [:]

        while items.count > 0 {
            let itemPtr = items.removeFirst()
            let item = itemPtr.pointee
            let inode = try self.getInode(number: item.inode)
            let entry = WriteEntry()
            let mode = inode.mode
            let size: UInt64 = (UInt64(inode.sizeHigh) << 32) | UInt64(inode.sizeLow)
            entry.permissions = mode_t(mode)
            guard let path = item.path else {
                continue
            }
            // Flagged #1: HIGH: `hardlinkTargets` overwritten with secondary hard-link path, corrupting tar entries
            // `hardlinkTargets[item.inode] = path` was executed for every tree item whose inode appeared in `hardlinkedInodes`, including secondary hard-link paths (paths that are themselves entries in `self.hardlinks`). When the BFS traversal visits a secondary path after the primary, the dictionary entry is overwritten with the secondary path. The hardlink-writing loop then sets `entry.hardlink` to a path that is itself a hard-link entry, producing circular or invalid tar hard-link records.
            if hardlinkedInodes.contains(item.inode) && self.hardlinks[path] == nil {
                hardlinkTargets[item.inode] = path
            }
            guard self.hardlinks[path] == nil else {
                continue
            }
            var attributes: [EXT4.ExtendedAttribute] = []
            let buffer: [UInt8] = EXT4.tupleToArray(inode.inlineXattrs)
            if !buffer.allZeros {
                try attributes.append(contentsOf: Self.readInlineExtendedAttributes(from: buffer))
            }
            if inode.xattrBlockLow != 0 {
                let block = inode.xattrBlockLow
                try self.seek(block: block)
                guard let buffer = try self.handle.read(upToCount: Int(self.blockSize)) else {
                    throw EXT4.Error.couldNotReadBlock(block)
                }
                try attributes.append(contentsOf: Self.readBlockExtendedAttributes(from: [UInt8](buffer)))
            }

            var xattrs: [String: Data] = [:]
            for attribute in attributes {
                guard attribute.fullName != "system.data" else {
                    continue
                }
                xattrs[attribute.fullName] = Data(attribute.value)
            }

            let pathStr = path.description
            entry.path = pathStr
            entry.size = Int64(size)
            entry.group = gid_t(inode.gidHigh) << 16 | gid_t(inode.gid)
            entry.owner = uid_t(inode.uidHigh) << 16 | uid_t(inode.uid)
            entry.creationDate = Date(fsTimestamp: UInt64(inode.crtimeExtra) << 32 | UInt64(inode.crtime))
            entry.modificationDate = Date(fsTimestamp: UInt64(inode.mtimeExtra) << 32 | UInt64(inode.mtime))
            entry.contentAccessDate = Date(fsTimestamp: UInt64(inode.atimeExtra) << 32 | UInt64(inode.atime))
            entry.xattrs = xattrs

            if mode.isDir() {
                entry.fileType = .directory
                for child in item.children {
                    items.append(child)
                }
                if pathStr == "" {
                    continue
                }
                try writer.writeEntry(entry: entry, data: nil)
            } else if mode.isReg() {
                entry.fileType = .regular
                var data = Data()
                var remaining: UInt64 = size
                if let block = item.blocks {
                    for dataBlock in block.start..<block.end {
                        try self.seek(block: dataBlock)
                        var count: UInt64
                        if remaining > self.blockSize {
                            count = self.blockSize
                        } else {
                            count = remaining
                        }
                        guard let dataBytes = try self.handle.read(upToCount: Int(count)) else {
                            throw EXT4.Error.couldNotReadBlock(dataBlock)
                        }
                        data.append(dataBytes)
                        remaining -= UInt64(dataBytes.count)
                    }
                }
                if let additionalBlocks = item.additionalBlocks {
                    for block in additionalBlocks {
                        for dataBlock in block.start..<block.end {
                            try self.seek(block: dataBlock)
                            var count: UInt64
                            if remaining > self.blockSize {
                                count = self.blockSize
                            } else {
                                count = remaining
                            }
                            guard let dataBytes = try self.handle.read(upToCount: Int(count)) else {
                                throw EXT4.Error.couldNotReadBlock(dataBlock)
                            }
                            data.append(dataBytes)
                            remaining -= UInt64(dataBytes.count)
                        }
                    }
                }
                try writer.writeEntry(entry: entry, data: data)
            } else if mode.isLink() {
                entry.fileType = .symbolicLink
                // Flagged #2: HIGH: Inline symlink with exactly 60-byte target exported with empty `symlinkTarget`
                // The condition `if size < 60` incorrectly excluded the boundary case. EXT4 stores symlink targets up to and including 60 bytes inline in the 60-byte `i_block` array (`EXT4_N_BLOCKS * 4 = 15 * 4 = 60`). For a symlink with a 60-byte target, `item.blocks` is `nil` (no data blocks allocated); the `else` branch's `if let block = item.blocks` silently falls through, leaving `entry.symlinkTarget` as an empty string.
                if size <= 60 {
                    let linkBytes = EXT4.tupleToArray(inode.block)
                    entry.symlinkTarget = String(bytes: linkBytes.prefix(Int(size)), encoding: .utf8) ?? ""
                } else {
                    if let block = item.blocks {
                        try self.seek(block: block.start)
                        guard let linkBytes = try self.handle.read(upToCount: Int(size)) else {
                            throw EXT4.Error.couldNotReadBlock(block.start)
                        }
                        entry.symlinkTarget = String(bytes: linkBytes, encoding: .utf8) ?? ""
                    }
                }
                try writer.writeEntry(entry: entry, data: nil)
            } else {  // do not process sockets, fifo, character and block devices
                continue
            }
        }
        for (path, number) in self.hardlinks {
            guard let targetPath = hardlinkTargets[number] else {
                continue
            }
            let inode = try self.getInode(number: number)
            let entry = WriteEntry()
            entry.path = path.description
            entry.hardlink = targetPath.description
            entry.permissions = mode_t(inode.mode)
            entry.group = gid_t(inode.gidHigh) << 16 | gid_t(inode.gid)
            entry.owner = uid_t(inode.uidHigh) << 16 | uid_t(inode.uid)
            entry.creationDate = Date(fsTimestamp: UInt64(inode.crtimeExtra) << 32 | UInt64(inode.crtime))
            entry.modificationDate = Date(fsTimestamp: UInt64(inode.mtimeExtra) << 32 | UInt64(inode.mtime))
            entry.contentAccessDate = Date(fsTimestamp: UInt64(inode.atimeExtra) << 32 | UInt64(inode.atime))
            try writer.writeEntry(entry: entry, data: nil)
        }
        try writer.finishEncoding()
    }

    @available(*, deprecated, renamed: "readInlineExtendedAttributes(from:)")
    public static func readInlineExtenedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        try readInlineExtendedAttributes(from: buffer)
    }

    public static func readInlineExtendedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        let header = buffer[0..<4].withUnsafeBytes { $0.loadLittleEndian(as: UInt32.self) }
        if header != EXT4.XAttrHeaderMagic {
            throw EXT4.FileXattrsState.Error.missingXAttrHeader
        }
        return try EXT4.FileXattrsState.read(buffer: buffer, start: 4, offset: 4)
    }

    @available(*, deprecated, renamed: "readBlockExtendedAttributes(from:)")
    public static func readBlockExtenedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        try readBlockExtendedAttributes(from: buffer)
    }

    public static func readBlockExtendedAttributes(from buffer: [UInt8]) throws -> [EXT4.ExtendedAttribute] {
        let header = buffer[0..<4].withUnsafeBytes { $0.loadLittleEndian(as: UInt32.self) }
        if header != EXT4.XAttrHeaderMagic {
            throw EXT4.FileXattrsState.Error.missingXAttrHeader
        }

        return try EXT4.FileXattrsState.read(buffer: [UInt8](buffer), start: 32, offset: 0)
    }

    func seek(block: UInt32) throws {
        try self.handle.seek(toOffset: UInt64(block) * blockSize)
    }
}

extension Date {
    init(fsTimestamp: UInt64) {
        // Flagged #3: HIGH: `Date(fsTimestamp: 0)` returns year 0001 instead of Unix epoch
        // An early-return guard `if fsTimestamp == 0 { self = Date.distantPast; return }` mapped a zero EXT4 timestamp to `Date.distantPast` (approximately year 0001). A zero timestamp means `ctime = 0` and `ctimeExtra = 0`, which is the Unix epoch (1970-01-01 00:00:00 UTC). Zero timestamps are extremely common in reproducible container builds where tools zero all file modification times. The general computation path already produces the correct result: `Int64(base) = 0`, `epoch = 0`, `nanoseconds = 0.0`, yielding `Date(timeIntervalSince1970: 0.0)`.
        // 32 bits - base: seconds since January 1, 1970, signed (negative for pre-1970 dates)
        // 2 bits - epoch: overflow counter (0-3), how many times the 32-bit seconds field has wrapped
        // 30 bits - nanoseconds (0-999,999,999)
        let base = Int32(truncatingIfNeeded: fsTimestamp)
        let epoch = Int64(fsTimestamp & 0x3_0000_0000)
        let seconds = Int64(base) + epoch
        let nanoseconds = Double(fsTimestamp >> 34) / 1_000_000_000

        self = Date(timeIntervalSince1970: Double(seconds) + nanoseconds)
    }
}
