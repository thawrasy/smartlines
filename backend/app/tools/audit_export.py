"""Copies the audit logs out of the production database for a write-once archive (third-party audit R-09).

Each run exports the rows added since the previous run, table by table, as gzip-compressed JSON lines, and writes a
manifest that lists every file with its SHA-256 and the SHA-256 of the previous manifest. The manifests form a chain:
deleting, reordering or editing any exported file or manifest breaks `verify`. The directory is then synchronised to
storage with object lock (S3 Object Lock in compliance mode, or equivalent), which nobody, the platform included, can
alter before the retention ends; see docs/operations/RUNBOOKS.md.

    python -m app.tools.audit_export export <dir>     # read as the audit role (MASSLAK_AUDIT_DATABASE_URL)
    python -m app.tools.audit_export verify <dir>     # check the whole chain and every file
"""
from __future__ import annotations

import asyncio
import datetime as dt
import gzip
import hashlib
import json
import sys
from pathlib import Path

from .. import db

TABLES = {"audit.activity_log": "id", "audit.row_change": "id", "audit.data_access_log": "id", "audit.auth_event": "id",
          "audit.ddl_event": "id", "audit.log_seal": "id"}
BATCH = 50_000


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _manifests(out: Path) -> list[Path]:
    return sorted((out / "manifests").glob("*.json"))


def _last_ids(out: Path) -> dict[str, int]:
    last: dict[str, int] = {}
    for m in _manifests(out):
        for f in json.loads(m.read_text())["files"]:
            last[f["table"]] = max(last.get(f["table"], 0), f["last_id"])
    return last


async def export(out: Path) -> Path | None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "manifests").mkdir(exist_ok=True)
    previous = _manifests(out)
    seq = len(previous) + 1
    prev_sha = _sha(previous[-1]) if previous else None
    last = _last_ids(out)
    files = []
    await db.open_pools()
    try:
        async with db.audit_reader() as conn:
            for table, key in TABLES.items():
                rows = await conn.fetch(f"SELECT to_jsonb(t) AS r, t.{key} AS k FROM {table} t WHERE t.{key} > $1 ORDER BY t.{key} LIMIT {BATCH}",  # nosec B608
                                        last.get(table, 0))
                if not rows:
                    continue
                name = f"{seq:06d}-{table.replace('.', '_')}-{rows[0]['k']}-{rows[-1]['k']}.jsonl.gz"
                path = out / name
                with gzip.open(path, "wt", encoding="utf-8") as fh:
                    for r in rows:
                        fh.write((r["r"] if isinstance(r["r"], str) else json.dumps(r["r"], default=str)) + "\n")
                files.append({"file": name, "table": table, "first_id": rows[0]["k"], "last_id": rows[-1]["k"], "rows": len(rows),
                              "sha256": _sha(path)})
    finally:
        await db.close_pools()
    if not files:
        return None
    manifest = out / "manifests" / f"{seq:06d}.json"
    manifest.write_text(json.dumps({"sequence": seq, "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                                    "previous_manifest_sha256": prev_sha, "files": files}, indent=1))
    return manifest


def verify(out: Path) -> list[str]:
    problems, prev_sha, last = [], None, {}
    for i, m in enumerate(_manifests(out), start=1):
        data = json.loads(m.read_text())
        if data["sequence"] != i:
            problems.append(f"{m.name}: sequence {data['sequence']}, expected {i} (a manifest is missing)")
        if data["previous_manifest_sha256"] != prev_sha:
            problems.append(f"{m.name}: does not chain to the previous manifest")
        for f in data["files"]:
            p = out / f["file"]
            if not p.exists():
                problems.append(f"{f['file']}: missing")
            elif _sha(p) != f["sha256"]:
                problems.append(f"{f['file']}: content changed")
            if f["first_id"] <= last.get(f["table"], 0):
                problems.append(f"{f['file']}: overlaps an earlier export")
            last[f["table"]] = f["last_id"]
        prev_sha = _sha(m)
    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in ("export", "verify"):
        print(__doc__)
        return 2
    out = Path(argv[1])
    if argv[0] == "export":
        m = asyncio.run(export(out))
        print(f"exported: {m}" if m else "nothing new to export")
        return 0
    problems = verify(out)
    for p in problems:
        print(p)
    print(f"{len(_manifests(out))} manifests checked, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
