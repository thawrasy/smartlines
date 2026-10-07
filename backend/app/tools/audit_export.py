"""Copies the audit logs out of the production database for a write-once archive (third-party audit R-09).

Each run exports the rows added since the previous run, table by table, as gzip-compressed JSON lines, and writes a
manifest that lists every file with its SHA-256 and the SHA-256 of the previous manifest. The manifests form a chain:
deleting, reordering or editing any exported file or manifest breaks `verify`. The directory is then synchronised to
storage with object lock (S3 Object Lock in compliance mode, or equivalent), which nobody, the platform included, can
alter before the retention ends; see docs/operations/RUNBOOKS.md.

Each manifest is also signed (Ed25519, audit T3-13) with the exporter's private key, MASSLAK_AUDIT_SIGNING_KEY (a PEM
file held only by the export job; production keeps it in the key service). Anyone holding the public key checks the
signatures without being able to forge one, so an archive copied to a separate account cannot be rewritten by an
administrator of the production account. `head` prints the signed tip of the chain; the evidence custodian records it
outside the platform, and `verify --min-sequence N` then detects a chain cut short.

    python -m app.tools.audit_export keygen <private.pem> <public.pem>   # once, by the security officer
    python -m app.tools.audit_export export <dir>     # read as the audit role (MASSLAK_AUDIT_DATABASE_URL)
    python -m app.tools.audit_export verify <dir> [--public-key public.pem] [--min-sequence N]
    python -m app.tools.audit_export head <dir>       # the tip to record outside the platform
"""
from __future__ import annotations

import asyncio
import datetime as dt
import gzip
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

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


def keygen(private_path: Path, public_path: Path) -> None:
    key = Ed25519PrivateKey.generate()
    private_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
    os.chmod(private_path, 0o600)
    public_path.write_bytes(key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))


def _signing_key() -> Optional[Ed25519PrivateKey]:
    path = os.environ.get("MASSLAK_AUDIT_SIGNING_KEY")
    if not path:
        return None
    key = serialization.load_pem_private_key(Path(path).read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        raise SystemExit("MASSLAK_AUDIT_SIGNING_KEY must be an Ed25519 private key")
    return key


def _public_key(path: Optional[Path]) -> Optional[Ed25519PublicKey]:
    path = path or (Path(os.environ["MASSLAK_AUDIT_VERIFY_KEY"]) if os.environ.get("MASSLAK_AUDIT_VERIFY_KEY") else None)
    if path is None:
        return None
    key = serialization.load_pem_public_key(path.read_bytes())
    if not isinstance(key, Ed25519PublicKey):
        raise SystemExit("the verify key must be an Ed25519 public key")
    return key


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
    key = _signing_key()
    if key is not None:
        manifest.with_suffix(".sig").write_bytes(key.sign(manifest.read_bytes()))
    return manifest


def head(out: Path) -> dict:
    ms = _manifests(out)
    if not ms:
        return {"sequence": 0, "manifest_sha256": None}
    return {"sequence": len(ms), "manifest": ms[-1].name, "manifest_sha256": _sha(ms[-1]),
            "signed": ms[-1].with_suffix(".sig").exists()}


def verify(out: Path, public_key: Optional[Ed25519PublicKey] = None, min_sequence: int = 0) -> list[str]:
    problems, prev_sha, last = [], None, {}
    ms = _manifests(out)
    if len(ms) < min_sequence:
        problems.append(f"the chain ends at {len(ms)} but {min_sequence} manifests were recorded (manifests removed from the end)")
    for i, m in enumerate(ms, start=1):
        if public_key is not None:
            sig = m.with_suffix(".sig")
            try:
                public_key.verify(sig.read_bytes(), m.read_bytes())
            except FileNotFoundError:
                problems.append(f"{m.name}: not signed")
            except InvalidSignature:
                problems.append(f"{m.name}: signature does not match (manifest altered or signed by another key)")
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
    if len(argv) < 2 or argv[0] not in ("export", "verify", "head", "keygen"):
        print(__doc__)
        return 2
    if argv[0] == "keygen":
        if len(argv) != 3:
            print(__doc__)
            return 2
        keygen(Path(argv[1]), Path(argv[2]))
        print(f"private key: {argv[1]} (keep in the key service), public key: {argv[2]} (give to verifiers)")
        return 0
    out = Path(argv[1])
    if argv[0] == "export":
        m = asyncio.run(export(out))
        print(f"exported: {m}" if m else "nothing new to export")
        return 0
    if argv[0] == "head":
        print(json.dumps(head(out)))
        return 0
    opts = dict(zip(argv[2::2], argv[3::2]))
    problems = verify(out, _public_key(Path(opts["--public-key"]) if "--public-key" in opts else None),
                      int(opts.get("--min-sequence", 0)))
    for p in problems:
        print(p)
    print(f"{len(_manifests(out))} manifests checked, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
