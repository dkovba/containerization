#!/usr/bin/env bash
#
# Personal / temporary tooling — not part of the project's build or CI.
#
# Runs the EXT4 layout-invariant test matrix two ways — the Swift invariant
# test (host-side) and e2fsck -fn on the same images (external oracle, via
# scripts/ext4-fsck-audit.sh) — and prints one table: per FormatCase, did the
# test pass, did the check pass, and if not, what broke.
#
# Restricted to the cases added for this regression. Identical
# to ext4-report.sh apart from CZ_EXT4_CASES, which FormatCase.all honors, so both
# the Swift stage and the fsck audit see the same cases.
#
# Usage: scripts/ext4-report-new-cases.sh
# No parameters. Run from anywhere inside a containerization checkout that
# has Tests/ContainerizationEXT4Tests/TestEXT4LayoutInvariants.swift.
set -euo pipefail

# The cases added for this regression. The two 16 TiB journal cases carry
# mustRejectWith, so the formatter refusing them is the pass condition rather than a
# reported failure; they still trap on a baseline without the overflow guards, which is
# why every case runs in its own process.
export CZ_EXT4_CASES="124MiB in 128MiB+4KiB,125MiB+218blk in 128MiB+4KiB,125MiB+177blk in 128MiB+60KiB,128MiB+100B (non-block-aligned),16TiB journal in 128MiB,16TiB-4KiB journal in 128MiB"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHECKOUT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LAYOUT_TEST="$CHECKOUT/Tests/ContainerizationEXT4Tests/TestEXT4LayoutInvariants.swift"
if [[ ! -f "$LAYOUT_TEST" ]]; then
    echo "error: $LAYOUT_TEST not found" >&2
    echo "run this from inside a containerization checkout that has TestEXT4LayoutInvariants.swift" >&2
    exit 1
fi

CHECKOUT_NAME=$(basename "$CHECKOUT")
WORK_DIR="/tmp/ext4-report-new-cases.${CHECKOUT_NAME}"
mkdir -p "$WORK_DIR"
SWIFT_LOG="$WORK_DIR/swift-test.log"
FSCK_LOG="$WORK_DIR/fsck.log"

# One process per case: a case that traps the formatter kills the process it runs
# in, so batching them would stop at the first trap and the rest would never run.
# The logs are appended in CZ_EXT4_CASES order, which is the order the parser
# matches positionally.
echo "==> running the Swift layout-invariant test, one process per case" >&2
: >"$SWIFT_LOG"
SWIFT_EXIT=0
IFS=',' read -r -a CASE_LIST <<<"$CZ_EXT4_CASES"
for case_label in "${CASE_LIST[@]}"; do
    set +e
    (
        cd "$CHECKOUT"
        CZ_EXT4_CASES="$case_label" swift test --manifest-cache local --disable-sandbox --filter Ext4LayoutInvariantTests
    ) >>"$SWIFT_LOG" 2>&1
    rc=$?
    set -e
    # An `&&` chain here would abort the loop under `set -e` on the common rc=0 case.
    if [[ $rc -eq 1 ]]; then
        SWIFT_EXIT=1
    fi
done
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
        # Both sides of the cross-check are pure scratch and every measurement that
        # matters is already in $MKE2FS_LOG. Rebuilt from scratch next run either way.
        if [[ -n "${EXT4_KEEP_IMAGES:-}" ]]; then
            echo "   mke2fs images left in: $MK_DIR (EXT4_KEEP_IMAGES)" >&2
        else
            cp "$MK_DIR/ours/emit.log" "$WORK_DIR/mke2fs-emit.log" 2>/dev/null || true
            rm -rf "$MK_DIR"
        fi
    fi
fi

# Same per-case isolation for the emit/fsck stage, and for the same reason: the
# emit test dies on a trapping case, so a single batched run would never announce
# the cases after the first trap. CZ_EXT4_EMIT_APPEND keeps each run's CASE lines
# and CZ_EXT4_EMIT_INDEX_BASE keeps the indices unique and in order.
echo "==> running e2fsck via scripts/ext4-fsck-audit.sh, one process per case" >&2
# ext4-fsck-audit.sh deletes each image before formatting it, so pointing this
# at the same directory every run recreates every image fresh rather than
# accumulating stale ones from a prior run (e.g. after the formatter changes).
: >"$FSCK_LOG"
rm -rf "$WORK_DIR/images"; mkdir -p "$WORK_DIR/images"
: >"$WORK_DIR/images/emit.log"
idx=0
for case_label in "${CASE_LIST[@]}"; do
    CZ_EXT4_CASES="$case_label" CZ_EXT4_EMIT_APPEND=1 CZ_EXT4_EMIT_INDEX_BASE="$idx" \
        "$SCRIPT_DIR/ext4-fsck-audit.sh" "$WORK_DIR/images" >>"$FSCK_LOG" 2>&1 || true
    idx=$((idx + 1))
done
if ! grep -q '^CASE ' "$WORK_DIR/images/emit.log"; then
    echo "error: no case was announced by ext4-fsck-audit.sh — see $FSCK_LOG" >&2
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
echo "          re-run with EXT4_KEEP_IMAGES=1 to keep all of them" >&2
