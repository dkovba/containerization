#!/usr/bin/env bash
#
# Personal / temporary tooling — not part of the project's build or CI.
#
# Runs the EXT4 layout-invariant test matrix two ways — the Swift invariant
# test (host-side) and e2fsck -fn on the same images (external oracle, via
# scripts/ext4-fsck-audit.sh) — and prints one table: per FormatCase, did the
# test pass, did the check pass, and if not, what broke.
#
# Usage: scripts/ext4-report.sh
# No parameters. Run from anywhere inside a containerization checkout that
# has Tests/ContainerizationEXT4Tests/TestEXT4LayoutInvariants.swift.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECKOUT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LAYOUT_TEST="$CHECKOUT/Tests/ContainerizationEXT4Tests/TestEXT4LayoutInvariants.swift"
if [[ ! -f "$LAYOUT_TEST" ]]; then
    echo "error: $LAYOUT_TEST not found" >&2
    echo "run this from inside a containerization checkout that has TestEXT4LayoutInvariants.swift" >&2
    exit 1
fi

CHECKOUT_NAME=$(basename "$CHECKOUT")
WORK_DIR="/tmp/ext4-report.${CHECKOUT_NAME}"
mkdir -p "$WORK_DIR"
SWIFT_LOG="$WORK_DIR/swift-test.log"
FSCK_LOG="$WORK_DIR/fsck.log"

# SwiftPM serialises on .build per checkout, so any other `swift test` running in this
# same checkout makes a stage below sit completely silent until that one finishes --
# indistinguishable from a hang, and a wedged stray process can hold it indefinitely.
# Poll the stage's log and name the holder the moment SwiftPM reports it.
warn_if_lock_blocked() {
    local log=$1 pid=$2 warned=""
    while kill -0 "$pid" 2>/dev/null; do
        if [[ -z "$warned" ]] && grep -q "Another instance of SwiftPM" "$log" 2>/dev/null; then
            echo "   note: blocked by another SwiftPM instance ($(grep -m1 -o 'PID: [0-9]*' "$log")) holding $CHECKOUT/.build" >&2
            echo "         this resumes when that one exits; if it is wedged (0% CPU), kill it" >&2
            warned=1
        fi
        sleep 2
    done
}

# A scratch suite left behind by a killed run still compiles into every test bundle in
# this checkout, and can hang or fail a stage that has nothing to do with it. Name any
# that are present rather than letting them act at a distance.
STRAY=$(ls "$CHECKOUT"/Tests/ContainerizationEXT4Tests/ZZ*.swift 2>/dev/null | grep -v "ZZSweepEmit.swift" || true)
if [[ -n "$STRAY" ]]; then
    echo "==> note: scratch test suite(s) present in this checkout; they build into every run:" >&2
    printf '      %s\n' $STRAY >&2
fi

echo "==> running the Swift layout-invariant test" >&2
set +e
(
    cd "$CHECKOUT"
    swift test --manifest-cache local --disable-sandbox --filter Ext4LayoutInvariantTests
) >"$SWIFT_LOG" 2>&1 &
SWIFT_BG=$!
warn_if_lock_blocked "$SWIFT_LOG" "$SWIFT_BG"
wait "$SWIFT_BG"
SWIFT_EXIT=$?
set -e
# swift test exits nonzero when any case fails, which is expected and not an
# error in itself — but a log with zero "started" markers means the run never
# actually executed the matrix (crash, build failure, wrong filter), and that
# must not be treated as "everything passed".
if ! grep -q "started\." "$SWIFT_LOG"; then
    echo "error: $SWIFT_LOG has no test-case output — the Swift test did not run to completion" >&2
    tail -n 20 "$SWIFT_LOG" >&2
    exit 1
fi
if [[ $SWIFT_EXIT -ne 0 ]] && [[ $SWIFT_EXIT -ne 1 ]]; then
    echo "error: swift test exited $SWIFT_EXIT (not a plain test failure) — see $SWIFT_LOG" >&2
    tail -n 20 "$SWIFT_LOG" >&2
    exit 1
fi
# A case that traps kills the test process, so the run never prints its closing
# summary. That is reported per-case as CRASH rather than treated as a harness
# failure, so the cases that did complete are still shown.
if ! grep -q "Test run with" "$SWIFT_LOG"; then
    echo "==> the Swift run died before completing — the case it died on is reported as CRASH" >&2
fi

# ---------------------------------------------------------------------------
# mke2fs cross-check: build the same FormatCase.all sizes with e2fsprogs and
# compare what each implementation advertises to a guest against what it
# actually costs on the host.
#
#   declared  = s_blocks_count * s_block_size -- the capacity the filesystem
#               reports, i.e. what a guest sees
#   occupied  = st_blocks * 512 -- bytes the image really consumes on this host
#
# For content-bearing cases the payload bytes are subtracted from our occupied
# figure, so both sides are compared on metadata cost alone (the mke2fs
# reference images are empty). mke2fs runs without a journal because the
# formatter creates none by default.
#
# Runs before the e2fsck stage so it still works on a host without the
# `container` CLI. Skipped, not failed, when e2fsprogs is absent.
MKE2FS=""
DUMPE2FS=""
for d in "" /opt/homebrew/opt/e2fsprogs/sbin /usr/sbin /sbin; do
    if [[ -z "$MKE2FS" ]] && [[ -x "${d:+$d/}mke2fs" || -n "$(command -v mke2fs 2>/dev/null)" ]]; then
        MKE2FS=$([[ -n "$d" && -x "$d/mke2fs" ]] && echo "$d/mke2fs" || command -v mke2fs 2>/dev/null || true)
        DUMPE2FS=$([[ -n "$d" && -x "$d/dumpe2fs" ]] && echo "$d/dumpe2fs" || command -v dumpe2fs 2>/dev/null || true)
    fi
done

if [[ -z "$MKE2FS" || -z "$DUMPE2FS" ]]; then
    echo "==> skipping the mke2fs cross-check (e2fsprogs not found)" >&2
else
    echo "==> cross-checking against mke2fs ($("$MKE2FS" -V 2>&1 | head -1 | awk '{print $2}'))" >&2
    MK_DIR="$WORK_DIR/mke2fs"
    rm -rf "$MK_DIR"; mkdir -p "$MK_DIR"
    MK_LOG="$WORK_DIR/mke2fs.log"

    # Our images, emitted from FormatCase.all by the same scratch test the fsck
    # audit uses. Regenerated here so this stage does not depend on that one.
    "$SCRIPT_DIR/ext4-fsck-audit.sh" --emit-only "$MK_DIR/ours" >"$MK_LOG" 2>&1 || true
    # A concurrent SwiftPM in the same checkout can leave this log without CASE lines
    # (it serialises on .build and the emit output lands late). That is a skip, not a
    # reason to abort the whole report before the e2fsck stage has run.
    if [[ ! -f "$MK_DIR/ours/emit.log" ]] || ! grep -q '^CASE ' "$MK_DIR/ours/emit.log"; then
        echo "   note: no cases were emitted (see $MK_LOG); skipping the mke2fs cross-check" >&2
    else
        MKE2FS_LOG="$WORK_DIR/mke2fs-compare.log"
        if ! MKE2FS="$MKE2FS" DUMPE2FS="$DUMPE2FS" python3 "$SCRIPT_DIR/ext4-mke2fs-compare.py" \
            "$MK_DIR/ours/emit.log" "$MK_DIR/ours" "$MK_DIR/ref" "$MKE2FS_LOG"; then
            echo "   note: the mke2fs cross-check failed (see $MK_LOG); skipping it" >&2
            MKE2FS_LOG=""
        fi
        # Both sides of the cross-check are pure scratch -- ~8 GiB for a full matrix,
        # and every measurement that matters is already in $MKE2FS_LOG. Rebuilt from
        # scratch next run either way.
        if [[ -n "${EXT4_KEEP_IMAGES:-}" ]]; then
            echo "   mke2fs images left in: $MK_DIR (EXT4_KEEP_IMAGES)" >&2
        else
            cp "$MK_DIR/ours/emit.log" "$WORK_DIR/mke2fs-emit.log" 2>/dev/null || true
            rm -rf "$MK_DIR"
        fi
    fi
fi

echo "==> running e2fsck via scripts/ext4-fsck-audit.sh" >&2
# ext4-fsck-audit.sh deletes each image before formatting it, so pointing this
# at the same directory every run recreates every image fresh rather than
# accumulating stale ones from a prior run (e.g. after the formatter changes).
if ! "$SCRIPT_DIR/ext4-fsck-audit.sh" "$WORK_DIR/images" >"$FSCK_LOG" 2>&1; then
    echo "error: ext4-fsck-audit.sh failed — see $FSCK_LOG" >&2
    tail -n 20 "$FSCK_LOG" >&2
    exit 1
fi

EMIT_LOG="$WORK_DIR/images/emit.log"
if [[ ! -f "$EMIT_LOG" ]]; then
    echo "error: $EMIT_LOG was not produced by ext4-fsck-audit.sh — see $FSCK_LOG" >&2
    exit 1
fi

echo "==> parsing results" >&2
echo >&2
python3 "$SCRIPT_DIR/ext4-report-parse.py" "$SWIFT_LOG" "$EMIT_LOG" "$FSCK_LOG" "${MKE2FS_LOG:-}"

echo >&2
echo "raw logs: $SWIFT_LOG, $EMIT_LOG, $FSCK_LOG" >&2
echo "images:   removed; only images that failed e2fsck are kept, in $WORK_DIR/images" >&2
echo "          re-run with EXT4_KEEP_IMAGES=1 to keep all of them (~15 GiB for a full matrix)" >&2
