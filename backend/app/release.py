"""The release the database is at (release manifest, schema file 1058; expert review stage C).

Reports name it as their source_version, and the metrics expose it with whether the applied schema files still match
the manifest's hash. Read at most once a minute.
"""
from __future__ import annotations

import time
from typing import Optional

from . import db

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
