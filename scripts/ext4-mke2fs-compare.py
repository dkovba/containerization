#!/usr/bin/env python3
#
# Personal / temporary tooling — not part of the project's build or CI.
#
# Builds every FormatCase.all size a second time with e2fsprogs' mke2fs and
# compares the two implementations on both dimensions that matter:
#
#   logical  = s_blocks_count * s_block_size, the capacity the filesystem
#              advertises. This is what a guest sees and what `minDiskSize`
#              is asking for.
#   physical = st_blocks * 512, the bytes the image actually occupies on this
#              host. Sparse regions cost nothing, so this is the real price.
#
# For content-bearing cases the payload is subtracted from our physical figure
# so both sides are compared on metadata cost alone — the mke2fs reference
# images are always empty. mke2fs is invoked without a journal because the
# formatter creates none by default.
#
# Invoked by scripts/ext4-report.sh; MKE2FS and DUMPE2FS come from its probe.
#
# Usage: ext4-mke2fs-compare.py <emit.log> <our-image-dir> <ref-image-dir>

import fcntl
import os
import re
import subprocess
import sys

MKE2FS = os.environ.get("MKE2FS", "mke2fs")
DUMPE2FS = os.environ.get("DUMPE2FS", "dumpe2fs")
MIB = 1024 * 1024


def parse_cases(emit_log):
    """CASE/emitted line pairs -> [(requested_bytes, content_bytes, image_name)]."""
    cases, pending = [], None
    for line in open(emit_log, errors="replace"):
        # contentBlocks is the 4 KiB-file half of the payload. Leaving it out of the
        # subtraction below charged those bytes to our metadata: a 218-block case was
        # reported as 892,928 bytes of overhead it does not have.
        m = re.search(
            r"CASE index=(\d+) requestedBytes=(\d+) contentMiB=(\d+)(?: contentBlocks=(\d+))?",
            line,
        )
        if m:
            content = int(m.group(3)) * MIB + int(m.group(4) or 0) * 4096
            pending = (int(m.group(2)), content)
            continue
        m = re.match(r"emitted (\S+\.img)", line.strip())
        if m and pending:
            cases.append((pending[0], pending[1], m.group(1)))
            pending = None
    return cases


def physical_bytes(path):
    """st_blocks * 512, after forcing the image out to disk.

    APFS delays allocation, so st_blocks on a just-written sparse image reports only
    what writeback has got to so far -- an empty 128 MiB image measured 81,920 bytes
    seconds after the emit and 2,277,376 once flushed. Without F_FULLFSYNC this
    comparison reports whichever point in the flush it happened to catch, which is how
    a case can pass one run and fail the next with no code change in between.
    """
    fd = os.open(path, os.O_RDONLY)
    try:
        # F_FULLFSYNC (macOS): fsync() alone only queues the write with the drive.
        fcntl.fcntl(fd, 51)
    except OSError:
        pass  # Linux, or a filesystem that does not implement it: plain stat is fine.
    finally:
        os.close(fd)
    return os.stat(path).st_blocks * 512


def superblock(path):
    """Superblock fields by lowercased name, read via dumpe2fs so the same parser
    serves both implementations' images."""
    out = subprocess.run(
        [DUMPE2FS, "-h", path], capture_output=True, text=True
    ).stdout
    fields = {}
    for line in out.split("\n"):
        if ":" in line:
            k, v = line.split(":", 1)
            fields[k.strip().lower()] = v.strip()
    return fields


def logical_bytes(path):
    """s_blocks_count * s_block_size -- the capacity the filesystem advertises."""
    f = superblock(path)
    try:
        return int(f["block count"]) * int(f["block size"])
    except (KeyError, ValueError):
        return 0


def block_size(path):
    try:
        return int(superblock(path)["block size"])
    except (KeyError, ValueError):
        return 0


def journal_mib(path):
    """Journal size of an existing image, in MiB, from "Total journal size"."""
    raw = superblock(path).get("total journal size", "")
    m = re.match(r"(\d+)([kKmMgG])", raw)
    if not m:
        return 0
    n = int(m.group(1))
    unit = m.group(2).lower()
    return n // 1024 if unit == "k" else n * 1024 if unit == "g" else n


def build_reference(requested, path, journalMiB=None):
    """An empty ext4 of the requested size, built with or without a journal.

    Each of our images is compared only against a reference built the same way:
    a journal materialises a large contiguous region on both sides, so mixing the
    settings would compare two different things.
    """
    if os.path.exists(path):
        os.unlink(path)
    with open(path, "wb") as f:
        f.truncate(requested)
    args = [MKE2FS, "-q", "-t", "ext4"]
    if journalMiB:
        args += ["-J", f"size={journalMiB}"]
    else:
        args += ["-O", "^has_journal"]
    args += ["-b", "4096", "-F", path]
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode == 0:
        return True, ""
    # mke2fs prefixes its diagnostics with the image path, which is a temp dir
    # here and only clutters the report.
    reason = r.stderr.strip().split("\n")[0]
    _, _, tail = reason.partition(".img: ")
    return False, (tail or reason)


def main():
    if len(sys.argv) != 5:
        print(
            "usage: ext4-mke2fs-compare.py <emit.log> <our-image-dir> <ref-image-dir> <out.log>",
            file=sys.stderr,
        )
        return 2
    emit_log, our_dir, ref_dir, out_log = sys.argv[1:5]
    os.makedirs(ref_dir, exist_ok=True)

    cases = parse_cases(emit_log)
    if not cases:
        print(f"error: no cases parsed from {emit_log}", file=sys.stderr)
        return 1

    # One line per case, field=value only, so the report never parses prose.
    with open(out_log, "w") as out:
        for requested, content, name in cases:
            our_path = os.path.join(our_dir, name)
            if not os.path.exists(our_path):
                out.write(f"MKE2FS image={name} status=missing\n")
                continue

            ref_path = os.path.join(ref_dir, name)
            built, err = build_reference(requested, ref_path)
            our_logical, our_physical = logical_bytes(our_path), physical_bytes(our_path)
            # Metadata cost only: the reference images hold no content.
            our_overhead = max(our_physical - content, 0)

            if not built:
                out.write(
                    f"MKE2FS image={name} status=refused ourLogical={our_logical} "
                    f"ourPhysical={our_overhead} reason={err.replace(' ', '_')}\n"
                )
                continue

            # Journalled pair: our journalled image against a journalled reference.
            jrn_ref = ref_path.replace(".img", "-journal.img")
            our_jrn = os.path.join(our_dir, name.replace(".img", "-ourjournal.img"))
            jrn_built, _ = build_reference(
                requested, jrn_ref, journalMiB=journal_mib(our_jrn) if os.path.exists(our_jrn) else None
            )
            ours_jrn = max(physical_bytes(our_jrn) - content, 0) if os.path.exists(our_jrn) else 0
            ref_jrn = physical_bytes(jrn_ref) if jrn_built else 0

            out.write(
                f"MKE2FS image={name} status=ok requested={requested} "
                f"ourLogical={our_logical} ourPhysical={our_overhead} "
                f"refLogical={logical_bytes(ref_path)} refPhysical={physical_bytes(ref_path)} "
                f"ourJournalPhysical={ours_jrn} refJournalPhysical={ref_jrn} "
                f"refBlockSize={block_size(ref_path)}\n"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
