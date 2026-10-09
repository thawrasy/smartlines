"""Checks that the files the database refers to are in the file store, whole and unchanged (review of release 1.47.0,
R-44: a restore proves the database and the stored files belong to the same moment).

Every row of ref.file_object is read back from the configured store (the volume or the object store), decrypted with
its key and compared with the size and SHA-256 recorded when it was uploaded. Run it after every restore drill, and
after restoring the object store to the time the database was restored to (bucket versioning; RUNBOOKS.md, section 2):

    python -m app.tools.files_check                     # every file
    python -m app.tools.files_check --since 2026-10-01  # files uploaded since a day (a quick check after a restore)
    python -m app.tools.files_check --sample 500        # a random sample

It prints a JSON report and exits 1 when a file is missing, cannot be decrypted or differs from its record.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid
from datetime import date

from .. import crypto, db
from ..modules.documents import storage

CONCURRENCY = 8


async def check(since: date | None = None, sample: int | None = None) -> dict:
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        fc = await crypto.cipher(conn)
        rows = await conn.fetch(
            """SELECT storage_key, enc_key_id, sha256, size_bytes, created_at FROM ref.file_object
                WHERE ($1::date IS NULL OR created_at >= $1::date)
                ORDER BY CASE WHEN $2 THEN random() END, id LIMIT $3""", since, sample is not None, sample or 2 ** 62)
    missing, broken, different = [], [], []
    gate = asyncio.Semaphore(CONCURRENCY)

    async def one(r) -> None:
        async with gate:
            try:
                data = await storage.get(fc, r["storage_key"], r["enc_key_id"], bytes(r["sha256"]))
            except storage.FileRejected as exc:
                (different if "FILE_TAMPERED" in str(exc) else missing).append(r["storage_key"])
                return
            except Exception:                                          # noqa: BLE001 - a key or ciphertext problem
                broken.append(r["storage_key"])
                return
            if len(data) != r["size_bytes"]:
                different.append(r["storage_key"])
    await asyncio.gather(*(one(r) for r in rows))
    newest = max((r["created_at"] for r in rows), default=None)
    return {"checked": len(rows), "ok": len(rows) - len(missing) - len(broken) - len(different),
            "missing": sorted(missing)[:50], "undecryptable": sorted(broken)[:50], "different": sorted(different)[:50],
            "newest_file": newest.isoformat() if newest else None}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m app.tools.files_check", description=__doc__.split("\n\n")[0])
    ap.add_argument("--since", type=date.fromisoformat, default=None, help="only files uploaded since this day")
    ap.add_argument("--sample", type=int, default=None, help="a random sample of this many files")
    args = ap.parse_args(argv)

    async def run() -> dict:
        await db.open_pools()
        try:
            return await check(args.since, args.sample)
        finally:
            await db.close_pools()
    out = asyncio.run(run())
    print(json.dumps(out, indent=2))
    return 0 if out["ok"] == out["checked"] else 1


if __name__ == "__main__":
    sys.exit(main())
