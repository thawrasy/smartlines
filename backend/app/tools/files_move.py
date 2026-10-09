"""Moves the encrypted files of a volume into the S3-compatible object store (code review of October 2026, 3.2).

Files are copied as they are stored: encrypted by the platform (AES-256-GCM, the storage key as associated data), and
encrypted again by the object store on arrival (server-side encryption, asked for and checked on every write). The
object store is the one of the MASSLAK_FILES_S3_* settings, whatever MASSLAK_FILES_BACKEND says, so the copy can run
before the platform switches to it.

    python -m app.tools.files_move copy   [--from /data/files]   # every file not yet in the object store
    python -m app.tools.files_move verify [--from /data/files]   # every file the database refers to is there, and
                                                                 # the same, byte for byte, as on the volume

The steps are in docs/operations/RUNBOOKS.md, section 24: copy, switch MASSLAK_FILES_BACKEND to s3, copy again (the
files uploaded meanwhile), verify, and keep the volume until verify reports nothing missing.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor

from .. import db
from ..config import get_settings
from ..modules.documents import storage

THREADS = 8


def copy(source: storage.LocalStore, target) -> dict:
    """Copies the files the target does not have yet. A file already there is left alone (keys are never reused)."""
    def one(key: str) -> str:
        if target.exists(key):
            return "present"
        target.write(key, source.read(key))
        return "copied"
    with ThreadPoolExecutor(THREADS) as pool:
        results = list(pool.map(one, source.keys()))
    return {"copied": results.count("copied"), "already_there": results.count("present")}


def compare(keys: list[str], target, source: storage.LocalStore | None) -> dict:
    """Every key is in the target; with a source, its bytes there are those of the volume."""
    def one(key: str) -> str:
        try:
            data = target.read(key)
        except storage.FileRejected:
            return "missing"
        if source is not None and source.exists(key) and source.read(key) != data:
            return "different"
        return "ok"
    with ThreadPoolExecutor(THREADS) as pool:
        results = dict(zip(keys, pool.map(one, keys)))
    bad = {k: v for k, v in results.items() if v != "ok"}
    return {"referenced": len(keys), "ok": len(keys) - len(bad),
            "missing": sorted(k for k, v in bad.items() if v == "missing")[:50],
            "different": sorted(k for k, v in bad.items() if v == "different")[:50]}


async def referenced_keys() -> list[str]:
    async with db.transaction(db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")) as conn:
        return [r["storage_key"] for r in await conn.fetch("SELECT storage_key FROM ref.file_object ORDER BY id")]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m app.tools.files_move", description=__doc__.split("\n\n")[0])
    ap.add_argument("action", choices=["copy", "verify"])
    ap.add_argument("--from", dest="source", default=None, help="the volume (default MASSLAK_FILES_DIR)")
    args = ap.parse_args(argv)
    target = storage.s3_from_settings()
    source = storage.LocalStore(args.source or get_settings().files_dir)
    if args.action == "copy":
        out = copy(source, target)
        ok = True
    else:
        async def run():
            await db.open_pools()
            try:
                return await referenced_keys()
            finally:
                await db.close_pools()
        out = compare(asyncio.run(run()), target, source if source.root.is_dir() else None)
        ok = not out["missing"] and not out["different"]
    print(json.dumps({"action": args.action, "bucket": target.bucket, **out}, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
