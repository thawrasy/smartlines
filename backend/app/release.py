"""The release the database is at (release manifest, schema file 1058; expert review stage C).

Reports name it as their source_version, and the metrics expose it with whether the applied schema files still match
the manifest's hash. Read at most once a minute. A production server does not start on a schema that differs from the
manifest of its last build or upgrade, or on a database without one (systems review of study 3.8, recommendation 17).
"""
from __future__ import annotations

import time
from typing import Optional

from . import db
from .config import is_test_server

_cache: Optional[tuple[float, Optional[dict]]] = None


async def current() -> Optional[dict]:
    """{version, commit_sha, schema_hash, files, applied_at, hash_matches} of the last build or upgrade, or None."""
    global _cache
    now = time.monotonic()
    if _cache is not None and now - _cache[0] < 60:
        return _cache[1]
    try:
        async with db.raw_connection() as conn:
            row = await conn.fetchrow("SELECT * FROM sys.current_release()")
        out = dict(row) if row else None
    except Exception:  # noqa: BLE001  (a database built before 1058 has no manifest)
        out = None
    _cache = (now, out)
    return out


async def source_version() -> str:
    r = await current()
    return f"masslak-db-{r['version']}" if r else "masslak-db-unknown"


def check(rel: Optional[dict]) -> None:
    """Raises on a production server when the schema is not the one its last build or upgrade recorded."""
    if is_test_server():
        return
    if rel is None:
        raise RuntimeError("the database has no release manifest, or it could not be read (sys.current_release): a "
                           "production database is built or upgraded with db/build.sh or db/upgrade.sh, which record it")
    if not rel["hash_matches"]:
        raise RuntimeError(f"the schema differs from the one release {rel['version']} recorded (schema hash "
                           f"{str(rel['schema_hash'])[:16]}): the record of applied schema files (sys.schema_file) changed "
                           "outside db/build.sh and db/upgrade.sh; upgrade the database, or restore it, before starting")


async def require_match_in_production() -> Optional[dict]:
    """The current release, after check() (the API and the worker call it when they start)."""
    rel = await current()
    check(rel)
    return rel
