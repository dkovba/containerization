#!/usr/bin/env bash
#
# Personal / temporary tooling — not part of the project's build or CI.
#
# Formats every case in the EXT4 layout-invariant test matrix (FormatCase.all
# in Tests/ContainerizationEXT4Tests/TestEXT4LayoutInvariants.swift) and runs
# `e2fsck -fn` on every resulting image inside a Linux container, via the
# `container` CLI. macOS has no e2fsck, so this is the external oracle for
# whatever TestEXT4LayoutInvariants.swift already checks host-side.
#
# Usage:
#   scripts/ext4-fsck-audit.sh [--emit-only] [--keep-images] [image-dir]
#
# Run from anywhere inside a containerization checkout that already has
# Tests/ContainerizationEXT4Tests/TestEXT4LayoutInvariants.swift (copy it in
# first if it's not there).
#
# A full matrix is ~7 GiB of images and every run rebuilds them from scratch, so
# they are deleted once e2fsck has had its say. Images that FAILED e2fsck are kept
# -- those are the ones worth opening. --keep-images (or EXT4_KEEP_IMAGES=1) keeps
# all of them, for when you want to poke at one that passed.
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "usage: $0 [--emit-only] [--keep-images] [image-dir]" >&2
    exit 1
fi

# --emit-only formats FormatCase.all and stops, skipping e2fsck. Used by
# ext4-report.sh's mke2fs cross-check, which needs the images but not the Linux
# container, so it works on a host without the `container` CLI. It never deletes
# anything: the caller still has to measure the images, and cleans up itself.
EMIT_ONLY=""
KEEP_IMAGES="${EXT4_KEEP_IMAGES:-}"
while [[ "${1:-}" == --* ]]; do
    case "$1" in
    --emit-only) EMIT_ONLY=1 ;;
    --keep-images) KEEP_IMAGES=1 ;;
    *)
        echo "error: unknown option $1" >&2
        exit 1
        ;;
    esac
    shift
done

if [[ -z "$EMIT_ONLY" ]] && ! command -v container >/dev/null 2>&1; then
    echo "error: the 'container' CLI is not on PATH (see apple/container)" >&2
    exit 1
fi

if [[ -z "$EMIT_ONLY" ]] && ! container system status >/dev/null 2>&1; then
    echo "error: the 'container' apiserver is not running — start it with 'container system start'" >&2
    exit 1
fi

CHECKOUT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LAYOUT_TEST="$CHECKOUT/Tests/ContainerizationEXT4Tests/TestEXT4LayoutInvariants.swift"
if [[ ! -f "$LAYOUT_TEST" ]]; then
    echo "error: $LAYOUT_TEST not found" >&2
    echo "run this from inside a containerization checkout that has TestEXT4LayoutInvariants.swift" >&2
    exit 1
fi

CHECKOUT_NAME=$(basename "$CHECKOUT")
IMAGE_DIR=${1:-$(mktemp -d "/tmp/ext4-fsck-audit.${CHECKOUT_NAME}.XXXXXX")}
mkdir -p "$IMAGE_DIR"
# Each invocation truncates emit.log, so a caller that runs this script once per case
# (to survive a case that traps the formatter) sets CZ_EXT4_EMIT_APPEND=1 to keep the
# earlier cases' lines, and CZ_EXT4_EMIT_INDEX_BASE so the indices stay unique.
if [[ -z "${CZ_EXT4_EMIT_APPEND:-}" ]]; then
    : >"$IMAGE_DIR/emit.log"
fi

# The emit suite lives in TestEXT4LayoutInvariants.swift, gated on
# EXT4_FSCK_AUDIT_DIR. It used to be written here as a scratch file under
# Tests/ and deleted on exit, which left the incremental build plan pointing at
# a missing input and broke the next `swift test` in the checkout.

echo "==> formatting FormatCase.all into $IMAGE_DIR" >&2
# --manifest-cache local keeps manifest compilation inside this checkout's
# .build/ instead of the shared ~/Library/Caches/org.swift.swiftpm cache,
# which is a single per-user DB other concurrent `swift` invocations (in any
# repo) can transiently lock and fail with "Invalid manifest". --disable-sandbox
# avoids "sandbox_apply: Operation not permitted" when this script itself runs
# under an outer sandbox (e.g. an agent harness), where SwiftPM's own
# manifest-compile sandbox can't nest. The retry loop is a backstop in case
# something else transient still happens.
#
# Run in the background so the wait can be narrated: SwiftPM serialises on .build per
# checkout, so a concurrent `swift test` in this same checkout makes this stage sit
# silent for as long as the other one runs, and a wedged one holds it indefinitely.
for attempt in 1 2 3; do
    (
        cd "$CHECKOUT"
        EXT4_FSCK_AUDIT_DIR="$IMAGE_DIR" swift test --manifest-cache local --disable-sandbox --filter ZZFsckAuditEmit \
            >>"$IMAGE_DIR/emit.log" 2>&1
    ) &
    EMIT_BG=$!
    WARNED=""
    while kill -0 "$EMIT_BG" 2>/dev/null; do
        if [[ -z "$WARNED" ]] && grep -q "Another instance of SwiftPM" "$IMAGE_DIR/emit.log" 2>/dev/null; then
            echo "==> blocked by another SwiftPM instance ($(grep -m1 -o 'PID: [0-9]*' "$IMAGE_DIR/emit.log")) holding $CHECKOUT/.build" >&2
            echo "    this resumes when that one exits; if it is wedged (0% CPU), kill it" >&2
            WARNED=1
        fi
        sleep 2
    done
    wait "$EMIT_BG" || true
    grep -E 'emitted|error:' "$IMAGE_DIR/emit.log" || true
    if ls "$IMAGE_DIR"/*.img >/dev/null 2>&1; then
        break
    fi
    if [[ $attempt -lt 3 ]]; then
        echo "==> emit failed (likely a transient SwiftPM manifest error), retrying ($((attempt + 1))/3)" >&2
    fi
done

if ! ls "$IMAGE_DIR"/*.img >/dev/null 2>&1; then
    echo "error: no images were emitted into $IMAGE_DIR — check the build output above" >&2
    exit 1
fi

if [[ -n "$EMIT_ONLY" ]]; then
    echo "==> emitted $(ls "$IMAGE_DIR"/*.img | wc -l | tr -d ' ') images into $IMAGE_DIR (--emit-only)" >&2
    exit 0
fi

cat >"$IMAGE_DIR/run-fsck.sh" <<'SH'
#!/bin/sh
# Runs e2fsck -fn over every emitted image and prints a per-image verdict.
set -u
apk add --no-cache e2fsprogs >/dev/null 2>&1
pass=0
fail=0
for f in /imgs/*.img; do
    name=$(basename "$f")
    out=$(e2fsck -fn "$f" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1))
        printf 'PASS rc=0  %s\n' "$name"
        # e2fsck can complain loudly and still exit 0 -- a superblock block count larger
        # than the device is answered "Abort? no" under -n and never reaches the exit
        # status. Print anything past the boilerplate so it does not vanish behind a PASS.
        extra=$(echo "$out" | grep -vE '^e2fsck [0-9]|^Pass [0-9]|^$|^/imgs/.*: [0-9]+/[0-9]+ files')
        if [ -n "$extra" ]; then
            echo "$extra" | sed 's/^/         ! /' | head -40
        fi
    else
        fail=$((fail + 1))
        printf 'FAIL rc=%s  %s\n' "$rc" "$name"
        echo "$out" | grep -vE '^e2fsck [0-9]|^Pass [0-9]|^$' | sed 's/^/         | /' | head -40
    fi
done
printf '\n==== e2fsck summary: %s passed, %s failed (of %s images) ====\n' "$pass" "$fail" "$((pass + fail))"
SH

echo "==> running e2fsck -fn inside a Linux container" >&2
# Captured as well as printed: the verdicts decide which images survive below, and
# the caller still needs the full output on stdout for ext4-report-parse.py.
VERDICTS="$IMAGE_DIR/fsck-verdicts.txt"
container run --rm -v "$IMAGE_DIR:/imgs" docker.io/library/alpine:latest sh /imgs/run-fsck.sh | tee "$VERDICTS"

echo >&2
if [[ -n "$KEEP_IMAGES" ]]; then
    echo "images left in: $IMAGE_DIR (--keep-images)" >&2
    echo "delete with: rm -rf '$IMAGE_DIR'" >&2
else
    # Field 3 of a "FAIL rc=8  name.img" line, which run-fsck.sh prints per image.
    FAILED=$(awk '/^FAIL rc=/ {print $3}' "$VERDICTS")
    REMOVED=0
    KEPT=0
    for img in "$IMAGE_DIR"/*.img; do
        [[ -e "$img" ]] || continue
        if printf '%s\n' "$FAILED" | grep -qxF "$(basename "$img")"; then
            KEPT=$((KEPT + 1))
            continue
        fi
        rm -f "$img"
        REMOVED=$((REMOVED + 1))
    done
    echo "removed $REMOVED image(s) that passed e2fsck; kept $KEPT that failed, in $IMAGE_DIR" >&2
    echo "keep everything next time with --keep-images (or EXT4_KEEP_IMAGES=1)" >&2
fi
