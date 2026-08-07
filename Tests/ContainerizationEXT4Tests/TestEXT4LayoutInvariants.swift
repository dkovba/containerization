//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
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
import SystemPackage
import Testing

@testable import ContainerizationEXT4

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A single formatter invocation to audit: `contentMiB` MiB of 1 MiB files written at
/// format time into an image requested at `requested` bytes.
struct FormatCase: Sendable, CustomStringConvertible {
    let label: String
    let contentMiB: Int
    /// Extra 4 KiB files written after the 1 MiB ones, for cases needing sub-MiB content.
    let contentBlocks: Int
    let requested: UInt64
    /// Explicit `JournalConfig.size`, for cases that exercise the journal sizing path.
    let journal: UInt64?
    /// Set for requests the formatter must refuse. A substring the thrown error has to
    /// contain; the case passes when `close()` throws it and fails when it succeeds.
    let mustRejectWith: String?

    var description: String {
        guard let journal else { return label }
        return "\(label) [journal \(journal) bytes]"
    }

    init(
        _ label: String, contentMiB: Int = 0, contentBlocks: Int = 0, requested: UInt64,
        journal: UInt64? = nil, mustRejectWith: String? = nil
    ) {
        self.label = label
        self.contentMiB = contentMiB
        self.contentBlocks = contentBlocks
        self.requested = requested
        self.journal = journal
        self.mustRejectWith = mustRejectWith
    }

    /// Empty images across every interesting block-group alignment.
    ///
    /// Requests below one block group (32KiB, 64MiB) are not listed: the formatter floors
    /// them up to a full 128 MiB group, which is a known pre-existing over-allocation
    /// tracked separately rather than something this matrix should re-report.
    ///
    /// Every size here except the boundary-tail cases (128MiB+4KiB, 128MiB+514blk,
    /// 128MiB+100B, 7.875GiB+4KiB — these test metadata-layout math specific to an empty
    /// image, which content would dilute rather than exercise) has a matching
    /// content-bearing case below at the same requested size.
    static let empty: [FormatCase] = [
        .init("128MiB (exactly 1 group)", requested: 128.mib()),
        .init("128MiB+4KiB (1-block tail)", requested: 128.mib() + 4.kib()),
        // A request that is not a whole number of blocks. The filesystem is floored to
        // 32,768 blocks and the leftover 100 bytes stay in the backing file past the end of
        // the filesystem, the same tail mke2fs leaves on an unaligned device. Rounding
        // s_blocks_count up instead would describe a block the file does not contain, which
        // e2fsck reports as "Either the superblock or the partition table is likely to be
        // corrupt!" while still exiting 0 under -fn -- so the size expectations below, not
        // e2fsck, are what hold this down.
        .init("128MiB+100B (non-block-aligned)", requested: 128.mib() + 100),
        .init("128MiB+514blk (packed footprint)", requested: 128.mib() + 514 * 4.kib()),
        .init("160MiB (issue #647)", requested: 160.mib()),
        .init("256MiB (exactly 2 groups)", requested: 256.mib()),
        .init("1GiB", requested: 1.gib()),
        .init("4GiB", requested: 4.gib()),
        .init("7.875GiB (63 groups)", requested: 63 * 128.mib()),
        .init("7.875GiB+4KiB (64 groups)", requested: 63 * 128.mib() + 4.kib()),
        .init("8GiB (64 groups)", requested: 8.gib()),
        .init("16GiB (128 groups)", requested: 16.gib()),
    ]

    /// Content-bearing images, one per non-boundary-tail size in `empty` above. The
    /// 160 MiB sweep additionally walks the payload across the first block-group
    /// boundary, which is where packed metadata starts straddling groups.
    ///
    /// `260MiB in 300MiB` pushes the write cursor past a block-group boundary while the
    /// requested size still sits below the next group multiple, which made the formatter
    /// inflate the image to the next whole group (300 MiB became 384 MiB). The requested
    /// size already holds that content, so it must be honored exactly.
    ///
    /// Content size, not requested size, is what reaches the boundary: at 126 MiB and
    /// below the cursor stays inside the first group, so none of the 160 MiB cases trigger
    /// the round-up. 300 MiB has no paired empty case; content-bearing images are the only
    /// ones that can reach this condition.
    static let withContent: [FormatCase] = [
        .init("10MiB in 160MiB", contentMiB: 10, requested: 160.mib()),
        .init("50MiB in 128MiB", contentMiB: 50, requested: 128.mib()),
        .init("120MiB in 160MiB", contentMiB: 120, requested: 160.mib()),
        .init("124MiB in 160MiB", contentMiB: 124, requested: 160.mib()),
        .init("126MiB in 160MiB", contentMiB: 126, requested: 160.mib()),
        .init("130MiB in 256MiB", contentMiB: 130, requested: 256.mib()),
        .init("200MiB in 1GiB", contentMiB: 200, requested: 1.gib()),
        .init("260MiB in 300MiB", contentMiB: 260, requested: 300.mib()),
        .init("260MiB in 4GiB", contentMiB: 260, requested: 4.gib()),
        .init("500MiB in 7.875GiB", contentMiB: 500, requested: 63 * 128.mib()),
        .init("300MiB in 8GiB", contentMiB: 300, requested: 8.gib()),
        .init("1000MiB in 16GiB", contentMiB: 1000, requested: 16.gib()),
        // A nearly-full leading group plus a small partial tail leaves no room for the
        // packed metadata region the extra group would need, so the tail is dropped and the
        // filesystem ends on the group boundary -- 4 KiB short of the request. Materializing
        // the group instead put its inode table past the end of the filesystem
        // ("Inode table for group N is not in group"); rounding the image up to the next
        // whole group instead would cost 128 MiB to hold 4 KiB.
        .init("124MiB in 128MiB+4KiB", contentMiB: 124, requested: 128.mib() + 4.kib()),
        .init("125MiB+218blk in 128MiB+4KiB", contentMiB: 125, contentBlocks: 218, requested: 128.mib() + 4.kib()),
        // Surfaced by scripts/ext4-sweep.sh over the 96,000-case grid. e2fsck accepts this
        // image; it is here as a guard on a 15-block tail with a nearly-full leading group,
        // the shape that broke in the first revision of this commit.
        .init("125MiB+177blk in 128MiB+60KiB", contentMiB: 125, contentBlocks: 177, requested: 128.mib() + 60.kib()),
        // A journal larger than the image has to be refused, so the throw is the pass
        // condition. Both once trapped instead of erroring -- the first in
        // calculateJournalSize's `UInt32(blocks)`, the second one call later in
        // setupJournalInode's `startBlock + blockCount`.
        .init(
            "16TiB journal in 128MiB", requested: 128.mib(), journal: 16 * 1024 * 1.gib(),
            mustRejectWith: "journal size"),
        .init(
            "16TiB-4KiB journal in 128MiB", requested: 128.mib(), journal: UInt64(UInt32.max) * 4.kib(),
            mustRejectWith: "journal size"),
    ]

    /// When `CZ_EXT4_CASES` holds a comma-separated list of labels, only those cases run.
    /// Both the Swift invariant test and the fsck audit read this list, so
    /// ext4-report-parse.py's log-consistency check still holds for a filtered run.
    static let all: [FormatCase] = {
        let full = empty + withContent
        guard let filter = ProcessInfo.processInfo.environment["CZ_EXT4_CASES"], !filter.isEmpty else {
            return full
        }
        let wanted = Set(filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return full.filter { wanted.contains($0.label) }
    }()
}

/// Formats an image for `testCase` at a fresh temporary path and hands it to `body`.
private func withFormattedImage<T>(_ testCase: FormatCase, _ body: (FilePath) throws -> T) throws -> T {
    let fsPath = FilePath(
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false))
    defer { try? FileManager.default.removeItem(at: fsPath.url) }

    let formatter = try EXT4.Formatter(
        fsPath, minDiskSize: testCase.requested,
        journal: testCase.journal.map { EXT4.JournalConfig(size: $0) })
    if testCase.contentMiB > 0 {
        let chunk = Data(repeating: 0xab, count: Int(1.mib()))
        for i in 0..<testCase.contentMiB {
            let stream = InputStream(data: chunk)
            stream.open()
            try formatter.create(path: FilePath("/f\(i)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream)
            stream.close()
        }
    }
    if testCase.contentBlocks > 0 {
        let smallChunk = Data(repeating: 0xcd, count: Int(4.kib()))
        for i in 0..<testCase.contentBlocks {
            let stream = InputStream(data: smallChunk)
            stream.open()
            try formatter.create(path: FilePath("/s\(i)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: stream)
            stream.close()
        }
    }
    try formatter.close()
    return try body(fsPath)
}

/// Everything the on-disk layout audit needs to report.
struct LayoutAudit {
    var imageSize: UInt64 = 0
    var physicalBytes: UInt64 = 0
    var blocksCount: UInt64 = 0
    var groups: UInt32 = 0
    /// Blocks one group's inode table occupies; with the two bitmaps this is what a
    /// trailing group costs, and so how far past the request an image may legitimately go.
    var inodeTableBlocks: UInt64 = 0
    /// Metadata blocks that a group descriptor points at but which the containing
    /// group's block bitmap reports as free. Any entry here is filesystem corruption.
    var metadataMarkedFree: [String] = []
    /// The same block claimed by two different group descriptors.
    var overlappingMetadata: [String] = []
    /// Metadata pointers at or beyond `s_blocks_count`.
    var outOfBounds: [String] = []
    /// Groups whose free-bit count disagrees with `bg_free_blocks_count`.
    var freeCountMismatch: [String] = []
    /// Trailing groups where blocks past the end of the filesystem are not marked used.
    var unmarkedPadding: [String] = []
    /// Set when `sum(bg_free_blocks_count) != s_free_blocks_count`.
    var superblockFreeMismatch: String?

    var problems: [String] {
        metadataMarkedFree + overlappingMetadata + outOfBounds + freeCountMismatch + unmarkedPadding
            + (superblockFreeMismatch.map { [$0] } ?? [])
    }
}

/// Reads back a formatted image and checks the block-allocation invariants that must
/// hold for any ext4 filesystem, whatever the requested size or block-group alignment.
private func auditLayout(at fsPath: FilePath) throws -> LayoutAudit {
    var audit = LayoutAudit()

    let handle = try FileHandle(forReadingFrom: fsPath.url)
    defer { try? handle.close() }
    audit.imageSize = try handle.seekToEnd()

    // APFS delays allocation, so st_blocks on a just-formatted sparse image reports only
    // what writeback has reached -- an empty 128 MiB image measures 81,920 bytes moments
    // after close() and 2,277,376 once flushed. Force it out before measuring, or the
    // sparseness check below is scored against an arbitrary point in the flush.
    #if canImport(Darwin)
    _ = fcntl(handle.fileDescriptor, F_FULLFSYNC)
    #endif

    var st = stat()
    guard stat(fsPath.description, &st) == 0 else { throw EXT4.Error.notFound(fsPath.description) }
    audit.physicalBytes = UInt64(st.st_blocks) * 512

    let reader = try EXT4.EXT4Reader(blockDevice: fsPath)
    let sb = reader.superBlock
    let blockSize = UInt64(sb.blockSize)
    let blocksPerGroup = sb.blocksPerGroup
    let inodeTableBlocks = sb.inodesPerGroup * UInt32(sb.inodeSize) / sb.blockSize
    audit.inodeTableBlocks = UInt64(inodeTableBlocks)
    audit.blocksCount = UInt64(sb.blocksCountLow) | (UInt64(sb.blocksCountHigh) << 32)
    audit.groups = UInt32((audit.blocksCount + UInt64(blocksPerGroup) - 1) / UInt64(blocksPerGroup))

    // Map every metadata block to the group whose descriptor claims it.
    var owner: [UInt64: (group: UInt32, kind: String)] = [:]
    var descriptors: [EXT4.GroupDescriptor] = []
    for group in 0..<audit.groups {
        let gd = try reader.getGroupDescriptor(group)
        descriptors.append(gd)

        var claims: [(UInt64, String)] = [
            (UInt64(gd.blockBitmapLow), "blockBitmap"),
            (UInt64(gd.inodeBitmapLow), "inodeBitmap"),
        ]
        for i in 0..<UInt64(inodeTableBlocks) {
            claims.append((UInt64(gd.inodeTableLow) + i, "inodeTable+\(i)"))
        }
        for (block, kind) in claims {
            if block >= audit.blocksCount {
                audit.outOfBounds.append("group \(group) \(kind) -> block \(block) >= s_blocks_count \(audit.blocksCount)")
            }
            if let prior = owner[block] {
                audit.overlappingMetadata.append(
                    "block \(block): group \(group) \(kind) overlaps group \(prior.group) \(prior.kind)")
            }
            owner[block] = (group, kind)
        }
    }

    // Cache each group's block bitmap.
    var bitmaps: [UInt32: [UInt8]] = [:]
    let bitmapBytes = Int(blocksPerGroup) / 8
    for group in 0..<audit.groups {
        try handle.seek(toOffset: UInt64(descriptors[Int(group)].blockBitmapLow) * blockSize)
        guard let data = try handle.read(upToCount: bitmapBytes), data.count == bitmapBytes else {
            continue
        }
        bitmaps[group] = [UInt8](data)
    }

    // A metadata block must be marked used in the bitmap of the group that physically
    // contains it — which, with flex_bg, is not necessarily the group that owns it.
    for (block, claim) in owner {
        let containing = UInt32(block / UInt64(blocksPerGroup))
        guard containing < audit.groups, let bitmap = bitmaps[containing] else { continue }
        let bit = UInt32(block % UInt64(blocksPerGroup))
        if (bitmap[Int(bit / 8)] >> (bit % 8)) & 1 == 0 {
            audit.metadataMarkedFree.append(
                "block \(block) holds group \(claim.group) \(claim.kind) but is FREE in group \(containing) bitmap")
        }
    }

    // Per-group free counts, and padding past the end of the filesystem.
    var summedFree: UInt64 = 0
    for group in 0..<audit.groups {
        guard let bitmap = bitmaps[group] else { continue }
        let groupStart = UInt64(group) * UInt64(blocksPerGroup)
        let realBlocks = UInt32(min(UInt64(blocksPerGroup), audit.blocksCount - groupStart))

        var used: UInt32 = 0
        let fullBytes = Int(realBlocks / 8)
        for i in 0..<fullBytes { used += UInt32(bitmap[i].nonzeroBitCount) }
        let remainderBits = Int(realBlocks % 8)
        if remainderBits > 0 {
            let mask = UInt8((1 << remainderBits) - 1)
            used += UInt32((bitmap[fullBytes] & mask).nonzeroBitCount)
        }
        let freeBits = realBlocks - used
        summedFree += UInt64(freeBits)

        if freeBits != descriptors[Int(group)].freeBlocksCountLow {
            audit.freeCountMismatch.append(
                "group \(group): \(freeBits) free bits but bg_free_blocks_count = \(descriptors[Int(group)].freeBlocksCountLow)")
        }

        // Blocks past the end of the filesystem do not exist and must read as used.
        if realBlocks < blocksPerGroup {
            var unmarked = 0
            if remainderBits > 0 {
                let mask = ~UInt8((1 << remainderBits) - 1)
                unmarked += (mask & ~bitmap[fullBytes]).nonzeroBitCount
            }
            for i in Int((UInt32(realBlocks) + 7) / 8)..<bitmapBytes {
                unmarked += (~bitmap[i]).nonzeroBitCount
            }
            if unmarked > 0 {
                audit.unmarkedPadding.append(
                    "group \(group): \(unmarked) blocks past end of filesystem not marked used")
            }
        }
    }

    let superblockFree = UInt64(sb.freeBlocksCountLow) | (UInt64(sb.freeBlocksCountHigh) << 32)
    if summedFree != superblockFree {
        audit.superblockFreeMismatch =
            "sum(bg_free_blocks_count) = \(summedFree) but s_free_blocks_count = \(superblockFree)"
    }

    return audit
}

/// Block-allocation invariants for the ext4 formatter across every reasonable image
/// size, with and without content written at format time.
@Suite(.serialized)
struct Ext4LayoutInvariantTests {
    /// Runs a `mustRejectWith` case and reports whether the formatter refused it as required.
    /// Returns false for cases that are expected to format, so the caller carries on.
    private func rejectionHandled(_ testCase: FormatCase) -> Bool {
        guard let expected = testCase.mustRejectWith else { return false }
        var message: String?
        do {
            _ = try withFormattedImage(testCase) { _ in }
        } catch {
            message = "\(error)"
        }
        guard let message else {
            Issue.record("\(testCase): formatted successfully but must be rejected with an error containing \"\(expected)\"")
            return true
        }
        #expect(
            message.contains(expected),
            "\(testCase): expected an error containing \"\(expected)\" but got \"\(message)\"")
        return true
    }

    /// Nothing the formatter emits may advertise live metadata as free space, whatever
    /// the requested size or how much content is baked in.
    @Test(arguments: FormatCase.all)
    func layoutInvariantsHold(_ testCase: FormatCase) throws {
        if rejectionHandled(testCase) { return }
        let audit = try withFormattedImage(testCase) { try auditLayout(at: $0) }

        func report(_ what: String, _ found: [String]) -> Comment {
            Comment(
                rawValue: """
                    \(testCase.label): \(found.count) \(what) (\(audit.groups) groups, \(audit.blocksCount) blocks)
                    \(found.prefix(5).joined(separator: "\n"))
                    """)
        }

        // Comparing counts rather than `isEmpty` keeps the failure message readable:
        // these arrays can hold tens of thousands of entries.
        #expect(audit.metadataMarkedFree.count == 0, report("metadata blocks advertised as free", audit.metadataMarkedFree))
        #expect(audit.overlappingMetadata.count == 0, report("overlapping metadata blocks", audit.overlappingMetadata))
        #expect(audit.outOfBounds.count == 0, report("out-of-bounds metadata pointers", audit.outOfBounds))
        #expect(audit.freeCountMismatch.count == 0, report("groups with a wrong free count", audit.freeCountMismatch))
        #expect(audit.unmarkedPadding.count == 0, report("groups with unmarked padding", audit.unmarkedPadding))
        #expect(audit.superblockFreeMismatch == nil, "\(testCase.label): \(audit.superblockFreeMismatch ?? "")")
    }

    /// The filesystem must occupy a whole number of blocks and must match the requested
    /// size wherever the formatter is expected to honor it. Two departures are expected
    /// rather than failures, and both are bounded below: bytes past the last whole block
    /// stay in the file but outside the filesystem, and a trailing partial group with no
    /// room for its own metadata is dropped instead of being materialized or rounded up.
    @Test(arguments: FormatCase.all)
    func requestedSizeIsHonored(_ testCase: FormatCase) throws {
        if rejectionHandled(testCase) { return }
        let audit = try withFormattedImage(testCase) { try auditLayout(at: $0) }

        // Only whole blocks belong to the filesystem, so a request that is not a whole
        // number of blocks keeps its remainder as a tail in the backing file, past
        // s_blocks_count. The file must hold every block the superblock describes, and may
        // carry at most that sub-block remainder beyond them.
        let fsBytes = audit.blocksCount * 4.kib()
        let tailBytes = Int64(audit.imageSize) - Int64(fsBytes)
        #expect(
            tailBytes >= 0 && tailBytes < Int64(4.kib()),
            "\(testCase.label): image is \(audit.imageSize) bytes but s_blocks_count implies \(fsBytes)")

        // The formatter never emits less than one full block group, and never a partial
        // block, so a sub-group request is floored up to 32,768 blocks x 4 KiB and a request
        // that is not a whole number of blocks is floored down to one. Encode both rules
        // instead of exempting those cases, so exact size stays pinned for every other size.
        let oneBlockGroup: UInt64 = 32768 * 4.kib()
        let expectedSize = max(testCase.requested / 4.kib() * 4.kib(), oneBlockGroup)
        // A trailing group the request does not fully cover still needs its own bitmaps and
        // inode table, so the image may exceed the request by that much. It may never exceed
        // it by a whole block group -- that is the round-up this check exists to catch
        // (300MiB advertised as 384MiB, or 128MiB+4KiB as 256MiB).
        let perGroupMetadata = (2 + audit.inodeTableBlocks) * 4.kib()
        let allowance = min(perGroupMetadata * UInt64(audit.groups), oneBlockGroup - 4.kib())
        #expect(
            fsBytes <= expectedSize + allowance,
            "\(testCase.label): requested \(testCase.requested) (floor \(oneBlockGroup), allowance \(allowance)) but got \(fsBytes)")

        // That same metadata is what a trailing partial group cannot always pay for. When
        // the tail past the last whole group is smaller than one group's metadata footprint
        // there is nowhere to describe it, and dropping it is the expected outcome -- the
        // alternative is inflating the image by a whole group to hold a few blocks. So the
        // filesystem may fall short of the request, but only back to a whole-group boundary
        // and only by less than that footprint; anything more is a real under-allocation.
        let groupAlignedFloor = expectedSize / oneBlockGroup * oneBlockGroup
        let shortfall = expectedSize > fsBytes ? expectedSize - fsBytes : 0
        #expect(
            shortfall == 0 || (fsBytes == groupAlignedFloor && shortfall < perGroupMetadata),
            """
            \(testCase.label): filesystem is \(fsBytes) bytes, \(shortfall) short of the requested \(testCase.requested); \
            a dropped tail may reach back only to \(groupAlignedFloor) and only when it is under \(perGroupMetadata) bytes
            """)
    }

    /// Formatting must not materialize the sparse image. Metadata scales with the group
    /// count, so the bound is generous, but it has to stay far below the image size.
    @Test(arguments: FormatCase.empty)
    func emptyImagesStaySparse(_ testCase: FormatCase) throws {
        let audit = try withFormattedImage(testCase) { try auditLayout(at: $0) }
        // Round up: a partial MiB of overage must still fail rather than truncate away.
        let allocatedMiB = (audit.physicalBytes + 1.mib() - 1) / 1.mib()
        let ceilingMiB: UInt64 = 32
        #expect(allocatedMiB <= ceilingMiB)
    }

/// Locates e2fsprogs' `debugfs`, which is needed to add files to an ext4 image on a host
/// with no ext4 driver. Absent on a stock macOS box, so the test below is skipped there.
private enum Debugfs {
    static let path: String? = {
        let candidates = ["/opt/homebrew/opt/e2fsprogs/sbin/debugfs", "/usr/sbin/debugfs", "/sbin/debugfs", "/usr/bin/debugfs"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()
}

/// Reproduces inode exhaustion: an image formatted empty, then filled the way a guest fills
/// it, runs out of inodes while nearly all blocks are still free.
///
/// `inodesPerGroup` is chosen from the files present at format time, so formatting empty
/// freezes `s_inodes_count` at the smallest value the search allows, and nothing can raise it
/// afterwards. 8,000 files of one byte each need ~32 MiB of a 256 MiB image, so blocks are
/// never the limiting factor at either size.
@Test(.enabled(if: Debugfs.path != nil), arguments: [256 * 1024 * 1024, 1024 * 1024 * 1024] as [UInt64])
func fillingAnEmptyImageDoesNotExhaustInodesWhileBlocksRemain(_ requested: UInt64) throws {
    let debugfs = try #require(Debugfs.path)
    let fileCount = 8_000
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let image = FilePath(dir.appendingPathComponent("fs.img"))
    let formatter = try EXT4.Formatter(image, minDiskSize: requested)
    try formatter.close()

    let payload = dir.appendingPathComponent("payload")
    try Data("x".utf8).write(to: payload)
    let script = dir.appendingPathComponent("cmds")
    try Data((0..<fileCount).map { "write \(payload.path) f\($0)" }.joined(separator: "\n").utf8)
        .write(to: script)

    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: debugfs)
    proc.arguments = ["-w", "-f", script.path, image.description]
    proc.standardOutput = pipe
    proc.standardError = pipe
    try proc.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    proc.waitUntilExit()

    let lines = output.split(separator: "\n").map(String.init)
    let created = lines.filter { $0.hasPrefix("Allocated inode") }.count
    let failure = lines.first { $0.contains("write:") } ?? "none"

    #expect(
        created == fileCount,
        Comment(rawValue: "\(requested / 1024 / 1024)MiB image, \(fileCount) files:\n\(failure)"))
}

}

/// Formats every FormatCase to disk instead of asserting anything, for
/// scripts/ext4-fsck-audit.sh to run e2fsck over. Disabled unless
/// EXT4_FSCK_AUDIT_DIR names an output directory, so a normal `swift test` skips it.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["EXT4_FSCK_AUDIT_DIR"] != nil))
struct ZZFsckAuditEmit {
    // Renders a byte count as a sum of terms derived purely from the value
    // itself, so the filename is real data — never copied from
    // FormatCase.label's hand-written text. Tries both a GiB/MiB/KiB/B binary
    // decomposition and a "N×128MiB" decomposition (128 MiB being the
    // formatter's actual default block-group size: 4096-byte blocks, 32,768
    // blocks per group), keeping whichever has fewer terms — e.g.
    // 63 * 128 MiB reads as "63x128MiB" rather than "7GiB+896MiB".
    static func sizeTag(_ bytes: UInt64) -> String {
        func decompose(_ bytes: UInt64, units: [(UInt64, String)]) -> [String] {
            var remaining = bytes
            var parts: [String] = []
            for (unit, suffix) in units {
                if remaining >= unit {
                    let n = remaining / unit
                    remaining -= n * unit
                    parts.append("\(n)\(suffix)")
                }
            }
            if remaining > 0 || parts.isEmpty {
                parts.append("\(remaining)B")
            }
            return parts
        }

        let binary = decompose(bytes, units: [(UInt64(1 << 30), "GiB"), (UInt64(1 << 20), "MiB"), (UInt64(1 << 10), "KiB")])

        let blockGroupBytes = UInt64(128 << 20)
        let groupCount = bytes / blockGroupBytes
        let remainder = bytes % blockGroupBytes
        var groups: [String] = groupCount > 0 ? ["\(groupCount)x128MiB"] : []
        if remainder > 0 {
            groups += decompose(remainder, units: [(UInt64(1 << 20), "MiB"), (UInt64(1 << 10), "KiB")])
        }

        guard !groups.isEmpty else { return binary.joined(separator: "+") }
        let best = groups.count < binary.count ? groups : binary
        return best.joined(separator: "+")
    }

    @Test func emit() throws {
        guard let outDir = ProcessInfo.processInfo.environment["EXT4_FSCK_AUDIT_DIR"] else {
            Issue.record("EXT4_FSCK_AUDIT_DIR not set")
            return
        }
        for (i, c) in FormatCase.all.enumerated() {
            let blockTag = c.contentBlocks > 0 ? "+\(c.contentBlocks)blk" : ""
            let contentTag = (c.contentMiB > 0 || c.contentBlocks > 0) ? "_\(c.contentMiB)MiB\(blockTag)-content" : ""
            // Without the journal in the name, a journal case collides with the plain case at
            // the same requested size: it deletes that case's images, then fails to format,
            // leaving the earlier case with no image and a superblock-less journalled one.
            let journalTag = c.journal.map { "_journal\(Self.sizeTag($0))" } ?? ""
            let name = "\(Self.sizeTag(c.requested))\(contentTag)\(journalTag).img"
            let path = FilePath("\(outDir)/\(name)")

            // Announced before formatting, so a case that *traps* the formatter still appears
            // here with no matching "emitted" or "THREW" line — which is the only thing
            // ext4-report-parse.py treats as a crash.
            let base = Int(ProcessInfo.processInfo.environment["CZ_EXT4_EMIT_INDEX_BASE"] ?? "0") ?? 0
            print(
                "CASE index=\(base + i) requestedBytes=\(c.requested) contentMiB=\(c.contentMiB)"
                    + " contentBlocks=\(c.contentBlocks) journal=\(c.journal.map(String.init) ?? "-")"
                    + " mustReject=\(c.mustRejectWith == nil ? "-" : "yes")")
            fflush(stdout)
            try? FileManager.default.removeItem(atPath: path.description)

            // Each case is emitted twice: unjournalled and journalled. The mke2fs
            // cross-check pairs each against a reference built the same way -- the two
            // sides must always share the journal setting, since a journal materialises
            // a large contiguous region on both sides and dilutes the difference.
            let journalPath = FilePath("\(outDir)/\(Self.sizeTag(c.requested))\(contentTag)\(journalTag)-ourjournal.img")
            try? FileManager.default.removeItem(atPath: journalPath.description)
            do {
            let fj = try EXT4.Formatter(
                journalPath, minDiskSize: c.requested,
                journal: c.journal.map { EXT4.JournalConfig(size: $0) } ?? .default)
            if c.contentMiB > 0 {
                let chunk = Data(repeating: 0xab, count: Int(1.mib()))
                for j in 0..<c.contentMiB {
                    let s = InputStream(data: chunk)
                    s.open()
                    try fj.create(path: FilePath("/f\(j)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: s)
                    s.close()
                }
            }
            if c.contentBlocks > 0 {
                let smallChunk = Data(repeating: 0xcd, count: Int(4.kib()))
                for j in 0..<c.contentBlocks {
                    let s = InputStream(data: smallChunk)
                    s.open()
                    try fj.create(path: FilePath("/s\(j)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: s)
                    s.close()
                }
            }
            try fj.close()

            let f = try EXT4.Formatter(
                path, minDiskSize: c.requested,
                journal: c.journal.map { EXT4.JournalConfig(size: $0) })
            if c.contentMiB > 0 {
                let chunk = Data(repeating: 0xab, count: Int(1.mib()))
                for j in 0..<c.contentMiB {
                    let s = InputStream(data: chunk)
                    s.open()
                    try f.create(path: FilePath("/f\(j)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: s)
                    s.close()
                }
            }
            if c.contentBlocks > 0 {
                let smallChunk = Data(repeating: 0xcd, count: Int(4.kib()))
                for j in 0..<c.contentBlocks {
                    let s = InputStream(data: smallChunk)
                    s.open()
                    try f.create(path: FilePath("/s\(j)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: s)
                    s.close()
                }
            }
            try f.close()
            print("emitted \(name)")
            // Announced separately so the report can attach an e2fsck verdict to the
            // journalled image as well; the fsck stage globs *.img and checks both.
            print("emittedJournal \(journalPath.lastComponent?.string ?? "")")
            } catch {
                // A formatter that rejects the request is not a crash: report the error and
                // keep going, so one bad case does not truncate the run.
                //
                // Both images are created before close() decides to throw, so a rejected case
                // otherwise leaves a 128 MiB file with no superblock behind. The fsck stage
                // globs *.img, so those survive as "Bad magic number in super-block" failures
                // attached to no case -- two of them, invisible in the report table because a
                // THREW case announces no image to attach a verdict to.
                try? FileManager.default.removeItem(atPath: path.description)
                try? FileManager.default.removeItem(atPath: journalPath.description)
                print("THREW index=\(base + i) error=\(error)")
                fflush(stdout)
            }
        }
    }
}
