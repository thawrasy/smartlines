"""The object store's versions, recorded with each backup and put back with a restore (reviews of October 2026, H-04).

With the files in an S3-compatible object store, the nightly backup holds the database but not the files. Restoring
the database to a backup must bring the files back to the same moment, or rows point to files changed or deleted
since. The bucket therefore keeps every version (versioning) and locks them against deletion (Object Lock, with a
default retention at least as long as backups are kept), and each backup records the version every file had:

    python -m app.tools.files_versions check             # the bucket keeps versions and locks them; exit 1 if not
    python -m app.tools.files_versions manifest          # the current version of every file, as JSON lines (backup.sh)
    python -m app.tools.files_versions restore FILE      # after restoring the database: put those versions back
    python -m app.tools.files_versions restore FILE --dry-run

restore reads a manifest (a file, or - for standard input) and makes each listed version the current one again,
whether the file was changed or deleted since: the store copies the kept version onto its key. Files written after
the backup are left alone; no row of the restored database points to them, and the daily sweep (files_sweep) removes
them. python -m app.tools.files_check then proves that every file the database refers to is there, whole.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import IO, Iterator

from ..modules.documents import storage

KIND = "masslak-files-manifest"


def problems(protection: dict, keep_days: int) -> list[str]:
    """What the bucket lacks for a restore to reach any backup still kept."""
    out = []
    if protection.get("versioning") != "Enabled":
        out.append("the file bucket does not keep old versions: enable versioning on it")
    if not protection.get("object_lock"):
        out.append("the file bucket has no Object Lock: create it with Object Lock enabled (it cannot be added later)")
    elif protection.get("retention_days", 0) < keep_days:
        out.append(f"the file bucket's default retention is {protection.get('retention_days', 0)} days: set at least "
                   f"{keep_days} (MASSLAK_BACKUP_KEEP_DAYS), so every file of a kept backup stays")
    return out


def keep_days() -> int:
    try:
        return int(os.environ.get("MASSLAK_BACKUP_KEEP_DAYS", "14"))
    except ValueError:
        return 14


def manifest(store: storage.S3Store, out: IO[str]) -> int:
    """Writes the header and one line per file with its current version; returns the number of files."""
    out.write(json.dumps({"kind": KIND, "bucket": store.bucket, "prefix": store.prefix,
                          "taken_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}) + "\n")
    n = 0
    for v in store.versions():
        if v["latest"] and not v["deleted"]:
            out.write(json.dumps({"key": v["key"], "version": v["version_id"], "etag": v["etag"],
                                  "modified": v["modified"]}) + "\n")
            n += 1
    return n


def read_manifest(lines: Iterator[str]) -> tuple[dict, list[dict]]:
    header, entries = None, []
    for line in lines:
        if not line.strip():
            continue
        row = json.loads(line)
        if header is None:
            if row.get("kind") != KIND:
                raise ValueError("not a file manifest of a Masslak backup")
            header = row
        else:
            entries.append(row)
    if header is None:
        raise ValueError("the manifest is empty")
    return header, entries


def restore(store: storage.S3Store, entries: list[dict], dry_run: bool = False) -> dict:
    """Makes every listed version current again; reports what it did."""
    current: dict[str, tuple[str, str] | None] = {}               # key -> (version, content tag) of the current one
    for v in store.versions():
        if v["latest"]:
            current[v["key"]] = None if v["deleted"] else (v["version_id"], v["etag"])
    listed = {e["key"] for e in entries}
    out = {"listed": len(entries), "unchanged": 0, "restored": 0, "newer_files_left": sum(1 for k in current if k not in listed
                                                                                          and current[k] is not None),
           "dry_run": dry_run, "sample": []}
    for e in entries:
        now = current.get(e["key"])
        # the same version, or the same bytes (a version put back earlier is a copy with a new version id)
        if now is not None and (now[0] == e["version"] or (e.get("etag") and now[1] == e["etag"])):
            out["unchanged"] += 1
            continue
        if not dry_run:
            store.restore_version(e["key"], e["version"])
        out["restored"] += 1
        if len(out["sample"]) < 20:
            out["sample"].append(e["key"])
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m app.tools.files_versions", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("check", help="the bucket keeps versions and locks them")
    sub.add_parser("manifest", help="the current version of every file, as JSON lines")
    r = sub.add_parser("restore", help="put back the versions a manifest names")
    r.add_argument("file", help="the manifest, or - for standard input")
    r.add_argument("--dry-run", action="store_true", help="report what would be restored, change nothing")
    args = ap.parse_args(argv)
    store = storage.s3_from_settings()
    if args.command == "check":
        found = problems(store.protection(), keep_days())
        for p in found:
            print(p, file=sys.stderr)
        if not found:
            print("the file bucket keeps every version and locks them for at least the backups' retention")
        return 1 if found else 0
    if args.command == "manifest":
        n = manifest(store, sys.stdout)
        print(f"{n} files recorded", file=sys.stderr)
        return 0
    with (sys.stdin if args.file == "-" else open(args.file, encoding="utf-8")) as f:
        header, entries = read_manifest(f)
    if header.get("bucket") != store.bucket or header.get("prefix") != store.prefix:
        print(f"the manifest is of bucket {header.get('bucket')!r} prefix {header.get('prefix')!r}, not this server's "
              f"{store.bucket!r} {store.prefix!r}", file=sys.stderr)
        return 1
    print(json.dumps(restore(store, entries, args.dry_run) | {"taken_at": header.get("taken_at")}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
