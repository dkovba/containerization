#!/usr/bin/env python3
"""
Personal / temporary tooling — not part of the project's build or CI.

Parses the text output of:
  swift test --filter Ext4LayoutInvariantTests   (TestEXT4LayoutInvariants.swift)
  scripts/ext4-fsck-audit.sh                      (e2fsck -fn over the same FormatCase matrix,
                                                     including its emit.log with machine-readable
                                                     `CASE index=.. requestedBytes=.. contentMiB=..`
                                                     lines)

Prints one block per FormatCase, matched across both logs by index (the order
FormatCase.all enumerates them in — both tools iterate the same array). Every
field is either the literal word "PASS" or a value captured verbatim from a
tool: the requested/content parameters from the emit.log CASE line, the
Swift-Testing auto-captured operand (the "expr → value" lines under a failed
#expect), or e2fsck's own stdout. No authored sentences enter the table.

Usage: ext4-report-parse.py <swift-test-log> <emit-log> <fsck-log>
"""
import os
import re
import sys


# --- emit.log: machine-readable case parameters + the exact filename used ---

CASE_RE = re.compile(
    r"^CASE index=(\d+) requestedBytes=(\d+) contentMiB=(\d+)"
    r"(?: contentBlocks=(\d+))?(?: journal=(\S+))?(?: mustReject=(\S+))?"
)
THREW_RE = re.compile(r"^THREW index=(\d+) error=(.+)$")
EMITTED_RE = re.compile(r"^emitted (\S+\.img)$")
EMITTED_JOURNAL_RE = re.compile(r"^emittedJournal (\S+\.img)$")


def parse_emit_log(path):
    """index -> {requestedBytes, contentMiB, image}"""
    cases = {}
    pending = None
    with open(path) as f:
        for line in f:
            m = CASE_RE.match(line)
            if m:
                idx, req, content, blocks, journal, must_reject = m.groups()
                pending = int(idx)
                cases[pending] = {
                    "requestedBytes": int(req),
                    "contentMiB": int(content),
                    "contentBlocks": int(blocks or 0),
                    "journal": None if journal in (None, "-") else int(journal),
                    "mustReject": must_reject == "yes",
                    "image": None,
                    "journalImage": None,
                }
                continue
            m = THREW_RE.match(line)
            if m:
                threw_idx = int(m.group(1))
                if threw_idx in cases:
                    cases[threw_idx]["threw"] = m.group(2).strip()
                pending = None
                continue
            m = EMITTED_JOURNAL_RE.match(line)
            if m and cases:
                cases[max(cases)]["journalImage"] = m.group(1)
                continue
            m = EMITTED_RE.match(line)
            if m and pending is not None:
                cases[pending]["image"] = m.group(1)
                pending = None
    return cases


# --- swift test log: match failures to cases by requested-bytes + contentMiB ---
# The test log never sees FormatCase.requested directly, but every failure line
# quotes the FormatCase.label, and FormatCase.all's labels are unique — so we
# recover the index by asking the emit log which index produced which image,
# and cross-referencing labels is unnecessary: we instead re-run the same
# FormatCase.all ordering assumption and match on position. Swift Testing
# emits "started" markers in FormatCase.all order for each @Test function
# independently, so the Nth "started" line for a given function is case N.

STARTED_RE = re.compile(r"Test case passing \d+ arguments? testCase → .+ to (\w+)\(_:\) started\.")
FAILED_RE = re.compile(r"Test (\w+)\(_:\) recorded an issue with \d+ arguments?.* (Expectation failed: .+)")
OPERAND_RE = re.compile(r"^\s*↳\s{0,3}(\S.*?)\s+→\s+(.+)$")
BLOCK_END_RE = re.compile(r"[✘◇]")


def parse_swift_log(path):
    """func -> [ {exprFailed, operands: {expr: value}}, ... ] in FormatCase.all order (None = pass)"""
    with open(path) as f:
        lines = [line.rstrip("\n") for line in f]

    counters = {}  # func -> next case index
    results = {}  # func -> {index: [failure, ...]}

    i = 0
    while i < len(lines):
        line = lines[i]

        m = STARTED_RE.search(line)
        if m:
            func = m.group(1)
            idx = counters.get(func, 0)
            counters[func] = idx + 1
            results.setdefault(func, {}).setdefault(idx, [])
            i += 1
            continue

        m = FAILED_RE.search(line)
        if m:
            func, expr_failed = m.groups()
            idx = counters.get(func, 1) - 1
            operands = {}
            j = i + 1
            while j < len(lines) and not BLOCK_END_RE.search(lines[j]):
                om = OPERAND_RE.match(lines[j])
                if om:
                    operands[om.group(1)] = om.group(2)
                j += 1
            results.setdefault(func, {}).setdefault(idx, []).append({"exprFailed": expr_failed, "operands": operands})
            i = j
            continue

        i += 1

    return results


# --- fsck log: match by exact image filename (real data, from emit.log) ---

FSCK_LINE_RE = re.compile(r"(PASS|FAIL)\s+rc=(\S+)\s+(\S+\.img)\s*$")
DETAIL_LINE_RE = re.compile(r"^\s*[|!]\s?(.*)$")


def parse_fsck_log(path):
    """image filename -> (status, rc, [detail lines])"""
    with open(path) as f:
        lines = [line.rstrip("\n") for line in f]

    results = {}
    i = 0
    while i < len(lines):
        m = FSCK_LINE_RE.search(lines[i])
        if m:
            status, rc, image = m.groups()
            detail_lines = []
            j = i + 1
            while j < len(lines):
                dm = DETAIL_LINE_RE.match(lines[j])
                if not dm:
                    break
                text = dm.group(1).strip()
                if text and "e2fsck" not in text.split(":")[0]:
                    detail_lines.append(text)
                j += 1
            results[image] = (status, rc, detail_lines)
            i = j
            continue
        i += 1

    return results


def format_bytes(n):
    """Mirrors ZZFsckAuditEmit.sizeTag in ext4-fsck-audit.sh: tries a binary
    GiB/MiB/KiB/B decomposition and a "Nx128MiB" decomposition, keeping
    whichever has fewer terms, so this matches the emitted filename."""

    def decompose(value, units):
        parts = []
        for suffix, size in units:
            if value >= size:
                count = value // size
                value -= count * size
                parts.append(f"{count}{suffix}")
        return parts, value

    binary_parts, binary_rem = decompose(n, [("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)])
    if binary_rem > 0 or not binary_parts:
        binary_parts = binary_parts + [f"{binary_rem}B"]

    block_group_bytes = 128 << 20
    group_count, remainder = divmod(n, block_group_bytes)
    groups_parts = [f"{group_count}x128MiB"] if group_count > 0 else []
    if remainder > 0:
        rem_parts, rem_rem = decompose(remainder, [("MiB", 1 << 20), ("KiB", 1 << 10)])
        if rem_rem > 0:
            rem_parts = rem_parts + [f"{rem_rem}B"]
        groups_parts += rem_parts

    if groups_parts and len(groups_parts) < len(binary_parts):
        return "+".join(groups_parts)
    return "+".join(binary_parts)


def size_field(idx, swift_by_func, func):
    """PASS, or the real captured byte counts from one size test.

    `requestedSizeIsHonored` runs over FormatCase.all, `emptyImagesStaySparse`
    only over FormatCase.empty. Because `all` is `empty + withContent`, the
    empty cases share the same indices in both, and a content case simply has no
    entry for the sparse test.
    """
    failures = swift_by_func.get(func, {}).get(idx)
    if failures is None:
        return None
    if not failures:
        return "PASS"
    lines = ["FAIL"]
    for f in failures:
        ops = f["operands"]
        pairs = [f"{k} = {v}" for k, v in ops.items()]
        lines.append("; ".join(pairs) if pairs else f["exprFailed"])
    return "\n".join(lines)


def fsck_field(idx, swift_by_func, fsck_results, image):
    """The 'e2fsck' block: Pass, e2fsck's own multi-line output on failure, or
    (if e2fsck passed but layoutInvariantsHold still caught something, which
    should not happen but would indicate the check itself needs work) the
    Swift-side captured counts."""
    fsck = fsck_results.get(image)
    if fsck is not None:
        status, rc, detail_lines = fsck
        if status == "PASS":
            layout_failures = swift_by_func.get("layoutInvariantsHold", {}).get(idx, [])
            if not layout_failures and not detail_lines:
                return "PASS"
            # e2fsck exits 0 on complaints it answers "Abort? no" to under -n, so a rc=0
            # image can still have carried a diagnostic. Print whatever it said.
            lines = ["PASS (rc=0)" if detail_lines else "PASS"]
            lines.extend(detail_lines)
            if layout_failures:
                # e2fsck passed but our own invariant check disagrees — surface both,
                # verbatim, so the discrepancy isn't hidden.
                lines.append("layoutInvariantsHold:")
                for f in layout_failures:
                    for k, v in f["operands"].items():
                        lines.append(f"  {k} = {v}")
            return "\n".join(lines)
        lines = [f"FAIL rc={rc}"]
        lines.extend(detail_lines)
        return "\n".join(lines)

    layout_failures = swift_by_func.get("layoutInvariantsHold", {}).get(idx, [])
    if not layout_failures:
        return "PASS" if image is None else "not run (no e2fsck result for this image)"
    lines = ["FAIL"]
    for f in layout_failures:
        for k, v in f["operands"].items():
            lines.append(f"{k} = {v}")
    return "\n".join(lines)


# --- mke2fs cross-check log: one "MKE2FS image=... field=value" line per case ---


def parse_mke2fs_log(path):
    """image filename -> {field: value}"""
    results = {}
    if not path or not os.path.exists(path):
        return results
    for line in open(path, errors="replace"):
        if not line.startswith("MKE2FS "):
            continue
        fields = {}
        for token in line.split()[1:]:
            if "=" in token:
                k, v = token.split("=", 1)
                fields[k] = v
        if "image" in fields:
            results[fields["image"]] = fields
    return results


def mke2fs_fields(image, mke2fs_results):
    """The two comparison lines: what each implementation advertises, and what
    each actually costs. Absent when the cross-check did not run."""
    f = mke2fs_results.get(image)
    if f is None:
        return None, None, None
    if f.get("status") == "missing":
        return "SKIP (our image missing)", "SKIP (our image missing)", None
    if f.get("status") == "refused":
        reason = f.get("reason", "").replace("_", " ")
        return f"SKIP (mke2fs refused: {reason})", f"SKIP (mke2fs refused: {reason})", None

    ours_l, ref_l = int(f["ourLogical"]), int(f["refLogical"])
    ours_p, ref_p = int(f["ourPhysical"]), int(f["refPhysical"])

    # Same shape as the Size field: the failed comparison, then its operands in
    # bytes. format_bytes is deliberately not used -- it decomposes into exact
    # terms ("29MiB+48KiB"), which suits a requested size but not a measurement.
    def verdict(name, ours, ref, grain=1, allowance=0):
        # Compare at `grain` resolution so a difference smaller than one grain is
        # not reported. `allowance` additionally permits a bounded overshoot: a trailing
        # group needs its own bitmaps and inode table, which mke2fs's reference image (built
        # empty, tail dropped) does not carry.
        if (ours // grain) <= ((ref + allowance) // grain):
            return "PASS"
        over = ours - ref
        return (
            f"FAIL\n{name} <= mke2fs + allowance = false; {name} = {ours:,}; "
            f"mke2fs = {ref:,}; over by = {over:,}; allowance = {allowance:,}"
        )

    # mke2fs rounds its block count down to a multiple of 8 blocks so the block
    # bitmap ends on a byte boundary, while this formatter honours the request
    # exactly; measured drops are 1-2 blocks (7 is the maximum possible). Comparing
    # at that granularity ignores the rounding without hiding real differences --
    # the round-up this check exists to catch is thousands of blocks
    # (300MiB advertised as 384MiB).
    grain = 8 * int(f.get("refBlockSize", 0) or 1)
    # Never a whole block group over mke2fs. mke2fs drops a tail it cannot fill, so its
    # reference is group-aligned and this bound stays sharp: metadata-sized overshoot
    # passes, a group-sized round-up does not.
    group_bytes = 32768 * int(f.get("refBlockSize", 0) or 4096)
    logical_allowance = group_bytes - int(f.get("refBlockSize", 0) or 4096)
    # Journalled pair, both sides journalled. Only the physical dimension is
    # comparable there: the journal is additive on top of minDiskSize on our side
    # but internal to mke2fs's block count, so logical stays on the unjournalled pair.
    ours_jrn = int(f.get("ourJournalPhysical", 0) or 0)
    ref_jrn = int(f.get("refJournalPhysical", 0) or 0)
    return (
        verdict("logical", ours_l, ref_l, grain, logical_allowance),
        verdict("physical", ours_p, ref_p),
        verdict("physical", ours_jrn, ref_jrn)
        if (ours_jrn and ref_jrn)
        else None,
    )


def main():
    if len(sys.argv) not in (4, 5):
        print(
            "usage: ext4-report-parse.py <swift-test-log> <emit-log> <fsck-log> [mke2fs-log]",
            file=sys.stderr,
        )
        sys.exit(2)

    swift_log, emit_log, fsck_log = sys.argv[1:4]
    mke2fs_log = sys.argv[4] if len(sys.argv) == 5 else None
    cases = parse_emit_log(emit_log)
    swift_by_func = parse_swift_log(swift_log)
    fsck_results = parse_fsck_log(fsck_log)
    mke2fs_results = parse_mke2fs_log(mke2fs_log)

    if not cases:
        print("error: no CASE lines found in the emit log — did ext4-fsck-audit.sh's emit step run?", file=sys.stderr)
        sys.exit(1)

    # A case with zero recorded "started" markers for layoutInvariantsHold means
    # the swift-test log doesn't actually cover this run's FormatCase.all — e.g.
    # a stale or truncated log from a prior invocation. Reporting PASS in that
    # situation would be indistinguishable from a real pass, so refuse instead.
    # A case announced in the emit log with no "emitted" line is one the formatter
    # trapped on: the emit process died mid-format. The Swift run dies on the same
    # case, so its log is short by however many cases follow — both truncations are
    # expected here and must not be read as a stale log.
    # A case with neither an image nor a reported error is one the formatter trapped on:
    # the process died mid-format. A reported error is a clean rejection, not a crash.
    crashed = {idx for idx, c in cases.items() if c["image"] is None and not c.get("threw")}
    observed = len(swift_by_func.get("layoutInvariantsHold", {}))
    if crashed:
        print(
            f"note: {len(crashed)} case(s) trapped the formatter and are reported as CRASH; "
            "the run stops there, so any later case is absent from both logs",
            file=sys.stderr,
        )
    elif observed != len(cases):
        print(
            f"error: swift-test log has {observed} layoutInvariantsHold case(s) but emit.log has {len(cases)} — "
            "logs are mismatched or stale, refusing to report",
            file=sys.stderr,
        )
        sys.exit(1)

    total = len(cases)
    clean = 0

    for idx in sorted(cases):
        c = cases[idx]
        requested = format_bytes(c["requestedBytes"])
        blocks = c.get("contentBlocks", 0)
        block_suffix = f"+{blocks}*4KiB" if blocks else ""
        content = f"{c['contentMiB']}MiB{block_suffix}" if (c["contentMiB"] > 0 or blocks) else "none"

        if idx in crashed:
            logical_result = physical_result = fsck_result = "CRASH"
        else:
            logical_result = size_field(idx, swift_by_func, "requestedSizeIsHonored")
            physical_result = size_field(idx, swift_by_func, "emptyImagesStaySparse")
            fsck_result = fsck_field(idx, swift_by_func, fsck_results, c["image"])
        fsck_journal_result = (
            fsck_field(idx, swift_by_func, fsck_results, c["journalImage"])
            if c.get("journalImage") and idx not in crashed
            else None
        )

        mke_logical, mke_physical, mke_physical_jrn = mke2fs_fields(c["image"], mke2fs_results)

        # Every check that actually ran must pass. None means the check did not
        # run for this case (sparse test is empty-images-only; the mke2fs
        # cross-check is absent without e2fsprogs), and a SKIP means mke2fs
        # itself declined the size -- neither counts against the case.
        verdicts = [
            logical_result,
            physical_result,
            fsck_result,
            fsck_journal_result,
            mke_logical,
            mke_physical,
            mke_physical_jrn,
        ]
        rejected_as_required = bool(c.get("mustReject")) and bool(c.get("threw"))
        if rejected_as_required:
            clean += 1
        elif idx not in crashed and not c.get("threw") and all(v is None or v == "PASS" or v.startswith("SKIP") for v in verdicts):
            clean += 1

        print(f"Requested size: {requested}")
        print(f"Content: {content}")
        # Printed only when the case sets one: it is the parameter under test for the
        # journal cases, and without it two of them are indistinguishable.
        if c.get("journal"):
            print(f'Journal: {c["journal"]} bytes ({format_bytes(c["journal"])})')
        if idx in crashed:
            # No image and no reported error: the process died mid-format. Every per-image
            # check is moot, so one line replaces the four verdicts.
            print("CRASH: formatter trapped; no image produced")
            print("-" * 40)
            continue
        if c.get("threw"):
            # The formatter rejected the request. That is a verdict in itself, not a crash,
            # and not a missing result — so report the error it raised, verbatim. A case
            # carrying mustReject is asking to be rejected, so the throw is its pass.
            label = "THREW (EXPECTED)" if c.get("mustReject") else "THREW"
            print(f'{label}: {c["threw"]}')
            print("-" * 40)
            continue
        if c.get("mustReject"):
            # Formatted successfully when the case requires a rejection.
            print("FAIL: must be rejected, but the formatter produced an image")
            print("-" * 40)
            continue
        print(f"Logical size: {logical_result or 'not run'}")
        print(f"Physical size: {physical_result or 'not run (empty images only)'}")
        print(f"e2fsck: {fsck_result}")
        if fsck_journal_result is not None:
            print(f"e2fsck (journalled): {fsck_journal_result}")
        if mke_logical is not None:
            print(f"Logical size vs mke2fs (no journal): {mke_logical}")
            print(f"Physical size vs mke2fs (no journal): {mke_physical}")
            if mke_physical_jrn is not None:
                print(f"Physical size vs mke2fs (journalled): {mke_physical_jrn}")
        print("-" * 40)

    print()
    print(f"{clean}/{total} cases fully clean (every check that ran passed)")

    # Every verdict in the fsck log is attached to a case by image filename, so an image
    # the emit never announced is scored by nobody. That is how a run can print
    # "29/29 cases fully clean" while fsck.log ends in "54 passed, 2 failed": a case
    # that throws announces no image, but any half-written file it left behind is still
    # globbed and still fails. Never let those go unreported.
    attributed = {c["image"] for c in cases.values() if c["image"]}
    attributed |= {c["journalImage"] for c in cases.values() if c.get("journalImage")}
    orphans = sorted((img, r) for img, r in fsck_results.items() if img not in attributed)
    if orphans:
        failed = sum(1 for _, (status, _, _) in orphans if status != "PASS")
        print()
        print(f"{len(orphans)} image(s) in the fsck log belong to no case and are not scored above" + (f" -- {failed} FAILED:" if failed else ":"))
        for img, (status, rc, detail) in orphans:
            print(f"  {status} rc={rc}  {img}")
            for line in detail[:3]:
                print(f"    | {line}")


if __name__ == "__main__":
    main()
