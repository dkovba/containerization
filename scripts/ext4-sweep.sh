#!/usr/bin/env bash
#
# Personal / temporary tooling — not part of the project's build or CI.
#
# Sweeps two dimensions — requested image size and content size — over the region
# where the packed-metadata layout goes wrong, formats an image per combination,
# runs `e2fsck -fn` on it, and prints only the combinations that fail.
#
# Output is the ext4-report-parse.py block format, reduced to the checks a single
# image can answer on its own: "Logical size" (the three size invariants from
# requestedSizeIsHonored) and "e2fsck". No mke2fs cross-check, no sparseness check,
# no Swift test run.

#
# The five knobs, all overridable from the environment:
#
#   STEP          4 KiB   one filesystem block: the smallest step that changes the
#                         layout at all, and the granularity the bug lives at
#   SIZE_MIN      128 MiB + 1 block     first size with a partial tail past a group
#   SIZE_MAX      128 MiB + 200 blocks  tails of 1..200 blocks — a tail only has to
#                         be smaller than the 514-block packed footprint to matter,
#                         and small tails are where it bites hardest
#   CONTENT_MIN   124 MiB   content that leaves ~475 free blocks in the leading group
#   CONTENT_MAX   124 MiB + 479 blocks   walks the metadata end across the group
#                         boundary, covering freeSlack from ~475 down to 0
#
# That is 200 x 480 = 96,000 images. Measured at ~0.2 s per case (format ~124 MiB,
# fsck it, delete it), so about 5.5 h. TIME_BUDGET_SECONDS stops the sweep early and
# reports how many cases were left uncovered, so the run cannot overshoot 8 h
# whatever the machine does. Widening either range multiplies the total — the grid
# is the product of the two, not the sum.
#
# The image is deleted after every case, pass or fail, so peak disk use is one
# image. A case that traps the formatter kills the Swift process; the sweep records
# it as CRASH, restarts past it, and keeps going, so one trap does not end the run.
#
# stdout carries only the failing cases and the summary. stderr carries progress, and
# also whatever the toolchain writes there (macOS 26 emits a wall of "objc[...] Class ...
# implemented in both" warnings per process); redirect it to a file and grep for '^sweep:'.
#
# Usage:
#   scripts/ext4-sweep.sh
#   TIME_BUDGET_SECONDS=600 scripts/ext4-sweep.sh                     # 10-min sample
#   CONTENT_MIN=$((250*1024*1024)) CONTENT_MAX=$((250*1024*1024 + 479*4096)) \
#     SIZE_MIN=$((256*1024*1024 + 4096)) SIZE_MAX=$((256*1024*1024 + 200*4096)) \
#     scripts/ext4-sweep.sh                                           # 2nd boundary
set -euo pipefail

STEP=${STEP:-4096}
SIZE_MIN=${SIZE_MIN:-$((128 * 1024 * 1024 + 4096))}
SIZE_MAX=${SIZE_MAX:-$((128 * 1024 * 1024 + 200 * 4096))}
CONTENT_MIN=${CONTENT_MIN:-$((124 * 1024 * 1024))}
CONTENT_MAX=${CONTENT_MAX:-$((124 * 1024 * 1024 + 479 * 4096))}
TIME_BUDGET_SECONDS=${TIME_BUDGET_SECONDS:-28800}

E2FSCK=$(command -v e2fsck || true)
if [[ -z "$E2FSCK" ]] && command -v brew >/dev/null 2>&1; then
    CANDIDATE="$(brew --prefix e2fsprogs 2>/dev/null || true)/sbin/e2fsck"
    if [[ -x "$CANDIDATE" ]]; then
        E2FSCK="$CANDIDATE"
    fi
fi
if [[ -z "$E2FSCK" ]]; then
    echo "error: e2fsck not found — install it with 'brew install e2fsprogs'" >&2
    exit 1
fi

SIZE_COUNT=$(((SIZE_MAX - SIZE_MIN) / STEP + 1))
CONTENT_COUNT=$(((CONTENT_MAX - CONTENT_MIN) / STEP + 1))
TOTAL=$((SIZE_COUNT * CONTENT_COUNT))

CHECKOUT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
WORK=$(mktemp -d /tmp/ext4-sweep.XXXXXX)
EMIT_TEST="$CHECKOUT/Tests/ContainerizationEXT4Tests/ZZSweepEmit.swift"
cleanup() {
    rm -f "$EMIT_TEST"
    rm -rf "$WORK"
}
# A bare EXIT trap does not fire when the shell is killed, and this sweep is designed to
# run for hours -- so an interrupted run could leave ZZSweepEmit.swift behind. A leftover
# scratch suite compiles into every subsequent `swift test` in this checkout, and if it is
# later deleted by hand the incremental build plan points at a missing input and breaks
# the next run outright. Catch the signals a long run actually gets.
trap cleanup EXIT INT TERM HUP

cat >"$EMIT_TEST" <<'SWIFT'
import Foundation
import SystemPackage
import Testing

@testable import ContainerizationEXT4

@Suite(.serialized)
struct ZZSweepEmit {
    /// Mirrors format_bytes in ext4-report-parse.py.
    static func sizeTag(_ bytes: UInt64) -> String {
        func decompose(_ value: UInt64, _ units: [(String, UInt64)]) -> ([String], UInt64) {
            var remaining = value
            var parts: [String] = []
            for (suffix, size) in units where remaining >= size {
                let count = remaining / size
                remaining -= count * size
                parts.append("\(count)\(suffix)")
            }
            return (parts, remaining)
        }
        var (binaryParts, binaryRem) = decompose(bytes, [("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)])
        if binaryRem > 0 || binaryParts.isEmpty {
            binaryParts.append("\(binaryRem)B")
        }
        let blockGroupBytes: UInt64 = 128 << 20
        let groupCount = bytes / blockGroupBytes
        let remainder = bytes % blockGroupBytes
        var groupsParts: [String] = groupCount > 0 ? ["\(groupCount)x128MiB"] : []
        if remainder > 0 {
            var (remParts, remRem) = decompose(remainder, [("MiB", 1 << 20), ("KiB", 1 << 10)])
            if remRem > 0 { remParts.append("\(remRem)B") }
            groupsParts += remParts
        }
        if !groupsParts.isEmpty && groupsParts.count < binaryParts.count {
            return groupsParts.joined(separator: "+")
        }
        return binaryParts.joined(separator: "+")
    }

    static func contentTag(_ bytes: UInt64) -> String {
        let wholeMiB = bytes / 1.mib()
        let extraBlocks = (bytes % 1.mib()) / 4.kib()
        return "\(wholeMiB)MiB" + (extraBlocks > 0 ? "+\(extraBlocks)*4KiB" : "")
    }

    /// Runs `e2fsck -fn`, returning (exit status, output filtered the same way
    /// ext4-fsck-audit.sh and ext4-report-parse.py filter it).
    static func fsck(_ tool: String, _ path: FilePath) -> (Int32, [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["-fn", path.string]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, ["could not run \(tool): \(error)"])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // Same reason: one pipe per case adds up if the handles only close on deinit.
        try? pipe.fileHandleForReading.close()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                if line.isEmpty { return false }
                if line.hasPrefix("Pass ") { return false }
                let head = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
                if head.contains("e2fsck") { return false }
                return true
            }
        return (p.terminationStatus, lines)
    }

    @Test func sweep() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SWEEP_DIR"], let tool = env["SWEEP_E2FSCK"],
            let step = UInt64(env["SWEEP_STEP"] ?? ""),
            let sizeMin = UInt64(env["SWEEP_SIZE_MIN"] ?? ""),
            let contentMin = UInt64(env["SWEEP_CONTENT_MIN"] ?? ""),
            let sizeCount = UInt64(env["SWEEP_SIZE_COUNT"] ?? ""),
            let contentCount = UInt64(env["SWEEP_CONTENT_COUNT"] ?? ""),
            let startIndex = UInt64(env["SWEEP_START_INDEX"] ?? ""),
            let budget = Double(env["SWEEP_BUDGET"] ?? "")
        else {
            Issue.record("sweep parameters not set")
            return
        }

        let mib = Data(repeating: 0xab, count: Int(1.mib()))
        let block = Data(repeating: 0xcd, count: Int(4.kib()))
        let path = FilePath("\(dir)/sweep.img")
        let progress = URL(fileURLWithPath: "\(dir)/progress")
        let stateURL = URL(fileURLWithPath: "\(dir)/state")
        let oneBlockGroup: UInt64 = 32768 * 4.kib()
        let total = sizeCount * contentCount

        // Carried across restarts so the totals survive a crash.
        var done: UInt64 = 0
        var failed: UInt64 = 0
        var suppressed: UInt64 = 0
        if let s = try? String(contentsOf: stateURL, encoding: .utf8) {
            let f = s.split(separator: " ").compactMap { UInt64($0) }
            if f.count == 3 { (done, failed, suppressed) = (f[0], f[1], f[2]) }
        }

        let started = Date()
        var index = startIndex
        while index < total {
            if Date().timeIntervalSince(started) > budget { break }

            let requested = sizeMin + (index / contentCount) * step
            let contentBytes = contentMin + (index % contentCount) * step
            let wholeMiB = Int(contentBytes / 1.mib())
            let extraBlocks = Int((contentBytes % 1.mib()) / 4.kib())

            // Written before formatting, so if the formatter traps the shell knows
            // which case died and can restart past it.
            try? "\(index)\t\(Self.sizeTag(requested))\t\(Self.contentTag(contentBytes))\n"
                .write(to: progress, atomically: true, encoding: .utf8)

            var sizeFailures: [String] = []
            var rc: Int32 = 0
            var detail: [String] = []
            do {
                let f = try EXT4.Formatter(path, minDiskSize: requested)
                for i in 0..<wholeMiB {
                    let s = InputStream(data: mib)
                    s.open()
                    try f.create(path: FilePath("/f\(i)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: s)
                    s.close()
                }
                for j in 0..<extraBlocks {
                    let s = InputStream(data: block)
                    s.open()
                    try f.create(path: FilePath("/s\(j)"), mode: EXT4.Inode.Mode(.S_IFREG, 0o644), buf: s)
                    s.close()
                }
                try f.close()

                let sb = try EXT4.EXT4Reader(blockDevice: path).superBlock
                let blocksCount = UInt64(sb.blocksCountLow) | (UInt64(sb.blocksCountHigh) << 32)
                let inodeTableBlocks = UInt64(sb.inodesPerGroup * UInt32(sb.inodeSize) / sb.blockSize)
                let groups = (blocksCount + UInt64(sb.blocksPerGroup) - 1) / UInt64(sb.blocksPerGroup)
                // Closed explicitly: leaving it to deinit leaks a descriptor per case, and
                // after a few thousand cases Process.run() fails with EBADF because the
                // table is full.
                let handle = try FileHandle(forReadingFrom: path.url)
                let imageSize = try handle.seekToEnd()
                try? handle.close()

                // The three size invariants from requestedSizeIsHonored.
                let fsBytes = blocksCount * 4.kib()
                let tailBytes = Int64(imageSize) - Int64(fsBytes)
                if tailBytes < 0 || tailBytes >= Int64(4.kib()) {
                    sizeFailures.append("audit.imageSize = \(imageSize); audit.blocksCount * 4.kib() = \(fsBytes)")
                }
                let expectedSize = max(requested / 4.kib() * 4.kib(), oneBlockGroup)
                let perGroupMetadata = (2 + inodeTableBlocks) * 4.kib()
                let allowance = min(perGroupMetadata * groups, oneBlockGroup - 4.kib())
                if fsBytes > expectedSize + allowance {
                    sizeFailures.append("fsBytes = \(fsBytes); expectedSize = \(expectedSize); allowance = \(allowance)")
                }
                // A trailing partial group smaller than one group's metadata footprint has
                // nowhere to describe itself, so the formatter drops it: the filesystem may
                // fall short of the request back to the group boundary, and no further.
                let groupAlignedFloor = expectedSize / oneBlockGroup * oneBlockGroup
                let shortfall = expectedSize > fsBytes ? expectedSize - fsBytes : 0
                if shortfall != 0 && !(fsBytes == groupAlignedFloor && shortfall < perGroupMetadata) {
                    sizeFailures.append(
                        "fsBytes = \(fsBytes); testCase.requested = \(requested); shortfall = \(shortfall); "
                            + "groupAlignedFloor = \(groupAlignedFloor); perGroupMetadata = \(perGroupMetadata)")
                }

                (rc, detail) = Self.fsck(tool, path)
            } catch {
                sizeFailures.append("threw: \(error)")
                rc = -2
                detail = ["formatter threw before producing an image"]
            }
            // Deleted on every path — pass, fail, or throw — so only one image at a
            // time exists on disk.
            try? FileManager.default.removeItem(atPath: path.description)

            done += 1
            // The size verdict is counted but not printed on its own, so the sweep stays an
            // e2fsck-driven scan and one systematic size regression cannot bury the grid in
            // 96,000 identical blocks. The summary line reports how many there were; run the
            // report scripts on a specific size to see the numbers.
            if rc == 0 && !sizeFailures.isEmpty {
                suppressed += 1
            }
            if rc != 0 {
                failed += 1
                var out: [String] = []
                out.append("Requested size: \(Self.sizeTag(requested))")
                out.append("Content: \(Self.contentTag(contentBytes))")
                if sizeFailures.isEmpty {
                    out.append("Logical size: PASS")
                } else {
                    out.append("Logical size: FAIL")
                    out += sizeFailures
                }
                if rc == 0 {
                    out.append("e2fsck: PASS")
                } else {
                    out.append("e2fsck: FAIL rc=\(rc)")
                    out += detail
                }
                out.append(String(repeating: "-", count: 40))
                print(out.joined(separator: "\n"))
                fflush(stdout)
            }
            try? "\(done) \(failed) \(suppressed)\n".write(to: stateURL, atomically: true, encoding: .utf8)

            if done % 200 == 0 {
                let elapsed = Date().timeIntervalSince(started)
                let rate = elapsed / Double(done - startIndex == 0 ? 1 : done)
                let msg = "sweep: \(done)/\(total) done, \(failed) failing e2fsck, "
                    + "\(suppressed) size-only (not printed), "
                    + "~\(Int(Double(total - done) * rate / 60))m left\n"
                FileHandle.standardError.write(msg.data(using: .utf8) ?? Data())
            }
            index += 1
        }

        // Tells the shell how far this segment got, and whether the grid is finished.
        try? "\(index)\t-\t-\n".write(to: progress, atomically: true, encoding: .utf8)
        if index >= total {
            try? "done".write(to: URL(fileURLWithPath: "\(dir)/finished"), atomically: true, encoding: .utf8)
        }
    }
}
SWIFT

cd "$CHECKOUT"
echo "==> grid: $SIZE_COUNT sizes x $CONTENT_COUNT contents = $TOTAL cases, step $STEP" >&2
echo "==> size $SIZE_MIN..$SIZE_MAX, content $CONTENT_MIN..$CONTENT_MAX" >&2
echo "==> budget ${TIME_BUDGET_SECONDS}s; only failing cases are printed" >&2

SWEEP_BEGAN=$SECONDS
START_INDEX=0
CRASHES=0
while [[ ! -f "$WORK/finished" ]]; do
    REMAINING=$((TIME_BUDGET_SECONDS - (SECONDS - SWEEP_BEGAN)))
    # Plain `[[ ... ]] && break` would abort the whole script under `set -e`
    # whenever the test is false, skipping the summary.
    if [[ $REMAINING -le 0 || $START_INDEX -ge $TOTAL ]]; then
        break
    fi

    set +e
    SWEEP_DIR="$WORK" SWEEP_E2FSCK="$E2FSCK" SWEEP_STEP="$STEP" \
        SWEEP_SIZE_MIN="$SIZE_MIN" SWEEP_CONTENT_MIN="$CONTENT_MIN" \
        SWEEP_SIZE_COUNT="$SIZE_COUNT" SWEEP_CONTENT_COUNT="$CONTENT_COUNT" \
        SWEEP_START_INDEX="$START_INDEX" SWEEP_BUDGET="$REMAINING" \
        swift test --disable-sandbox --manifest-cache local --filter ZZSweepEmit |
        grep -vE '^objc\[|^\[[A-Za-z0-9]|^Building|^Build complete|^warning:|^◇|^✔|^✘|^↳|^Test run|^Note: Some test targets|^error: Process'
    set -e

    if [[ -f "$WORK/finished" ]]; then
        break
    fi

    # The progress file names the case in flight when the process died.
    if [[ -f "$WORK/progress" ]]; then
        IFS=$'\t' read -r DIED_INDEX DIED_SIZE DIED_CONTENT <"$WORK/progress"
    else
        DIED_INDEX=$START_INDEX; DIED_SIZE="-"; DIED_CONTENT="-"
        echo "==> the run died before announcing a case (build or startup); skipping case $START_INDEX" >&2
    fi

    if [[ "$DIED_SIZE" != "-" ]]; then
        CRASHES=$((CRASHES + 1))
        printf 'Requested size: %s\nContent: %s\nCRASH:\n%s\n' \
            "$DIED_SIZE" "$DIED_CONTENT" "$(printf '%040d' 0 | tr '0' '-')"
    fi
    # Restart past the case that died, so one trap does not end the sweep.
    START_INDEX=$((DIED_INDEX + 1))
done

# Plain command substitution + awk: `read ... < <(...)` is a bashism that fails if the
# script is invoked with a different shell, and it also returns non-zero on a file with
# no trailing newline, which `set -e` then turns into a silent exit.
STATE=$(cat "$WORK/state" 2>/dev/null || echo "0 0 0")
DONE=$(printf '%s\n' "$STATE" | awk '{print $1+0; exit}')
FAILED=$(printf '%s\n' "$STATE" | awk '{print $2+0; exit}')
SUPPRESSED=$(printf '%s\n' "$STATE" | awk '{print $3+0; exit}')
ELAPSED=$((SECONDS - SWEEP_BEGAN))
printf '\nswept %s/%s cases in %sm%ss, %s failing e2fsck, %s crashed\n' \
    "$DONE" "$TOTAL" "$((ELAPSED / 60))" "$((ELAPSED % 60))" "$FAILED" "$CRASHES"
printf '%s case(s) failed only the size check and were not printed\n' "$SUPPRESSED"
if [[ $CRASHES -gt 0 ]]; then
    # The counters live in a file the sweep rewrites per case; a process killed
    # mid-case can lose its last few writes, so after a crash these totals are a
    # lower bound. The printed blocks above are the authoritative list.
    printf 'note: %s crash restart(s) — the swept/failing totals are a lower bound\n' "$CRASHES"
fi
if [[ ! -f "$WORK/finished" ]]; then
    printf 'stopped early: %s cases uncovered\n' "$((TOTAL - DONE))"
fi
