"""Finds the stored files no row points to and deletes them (reviews of October 2026, M-04).

A file is written to the store before its row in ref.file_object. A rolled-back transaction deletes its file again
(db.on_rollback); a process that died between the two leaves the file behind, encrypted but outside every lifecycle
and retention rule. This sweep lists the store (the volume or the object store), keeps every file a row points to and
every file younger than the grace period (an upload may still be on its way to its row), and deletes the rest:

    python -m app.tools.files_sweep                    # report only
    python -m app.tools.files_sweep --delete           # delete files no row points to, older than 24 hours
    python -m app.tools.files_sweep --delete --grace-hours 72

The worker runs it daily with --delete. It refuses to delete more than 5 % of the stored files (and at least 100):
that many unreferenced files means the store and the database do not belong together (another server's database,
a restore half done), which deleting would make worse; --force overrides it after checking. With bucket versioning on
(PRODUCTION_PROFILE.md), a deleted object stays recoverable as a noncurrent version.
"""
from __future__ import annotations

import argparse
import asyncio
import itertools
import json
import sys
import uuid
from datetime import datetime, timedelta, timezone

from .. import db
from ..modules.documents import storage

BATCH = 1000
MAX_SHARE, MAX_FLOOR = 0.05, 100


async def sweep(delete: bool = False, grace_hours: float = 24, force: bool = False, store=None) -> dict:
    store = store or storage.store()
    cutoff = datetime.now(timezone.utc) - timedelta(hours=grace_hours)
    listing = store.listing()
    stored = referenced = young = 0
    orphans: list[str] = []
    while True:             # a thousand files at a time: a large store is never held in memory
        chunk = await asyncio.to_thread(lambda: list(itertools.islice(listing, BATCH)))
        if not chunk:
            break
        ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
        async with db.transaction(ctx) as conn:
            known = {r["storage_key"] for r in await conn.fetch(
                "SELECT storage_key FROM ref.file_object WHERE storage_key = ANY($1::text[])", [k for k, _ in chunk])}
        stored, referenced = stored + len(chunk), referenced + len(known)
        for key, when in chunk:
            if key not in known:
                if when < cutoff:
                    orphans.append(key)
                else:
                    young += 1
    orphans.sort()
    out = {"stored": stored, "referenced": referenced, "unreferenced_older_than_grace": len(orphans),
           "unreferenced_within_grace": young, "grace_hours": grace_hours, "deleted": 0, "sample": orphans[:20]}
    limit = max(MAX_FLOOR, int(stored * MAX_SHARE))
    if delete and len(orphans) > limit and not force:
        out["refused"] = (f"{len(orphans)} unreferenced files is more than {limit}: check that this server's database "
                          "and file store belong together, then run again with --force")
        return out
    if delete:
        for key in orphans:
            await asyncio.to_thread(store.delete, key)
            out["deleted"] += 1
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m app.tools.files_sweep", description=__doc__.split("\n\n")[0])
    ap.add_argument("--delete", action="store_true", help="delete the unreferenced files (default: report only)")
    ap.add_argument("--grace-hours", type=float, default=24, help="keep unreferenced files younger than this (24)")
    ap.add_argument("--force", action="store_true", help="delete even beyond the 5 %% safety limit")
    args = ap.parse_args(argv)

    async def run() -> dict:
        await db.open_pools()
        try:
            return await sweep(args.delete, args.grace_hours, args.force)
        finally:
            await db.close_pools()
    out = asyncio.run(run())
    print(json.dumps(out, indent=2))
    return 1 if "refused" in out else 0


if __name__ == "__main__":
    sys.exit(main())
