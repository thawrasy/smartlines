"""Data keys under envelope encryption (third-party audit R-10).

    python -m app.tools.keys new --ref kms://masslak/field/restricted/v2 [--purpose FIELD_ENCRYPTION] [--class RESTRICTED]
                                 [--kms-key-id masslak-field]
        generates a 32-byte data key, wraps it with the configured key service (MASSLAK_KMS_PROVIDER) and prints the
        statements the database owner runs to register it as the active key; the clear key is never printed or stored.
        Then re-encrypt the rows under the old key: python -m app.tools.rekey --apply
    python -m app.tools.keys check
        opens every wrapped key in sec.key_registry with the key service and reports the ones it cannot open.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
import uuid

from .. import db, kms

ALGORITHMS = {"FIELD_ENCRYPTION": "AES-256-GCM", "WEBHOOK_SECRET": "AES-256-GCM", "BLIND_INDEX": "HMAC-SHA256"}


def _sql_text(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def register_statements(ref: str, purpose: str, data_class: str, kms_key_id: str | None, wrapped: bytes) -> str:
    """The owner's statements: the current key of the purpose and class becomes decrypt-only, the new one active."""
    return "\n".join([
        "BEGIN;",
        f"UPDATE sec.key_registry SET status = 'DECRYPT_ONLY', rotated_at = now() WHERE purpose = {_sql_text(purpose)} "
        f"AND data_class = {_sql_text(data_class)} AND company_id IS NULL AND status = 'ACTIVE';",
        "INSERT INTO sec.key_registry (key_ref, purpose, data_class, algorithm, status, key_version, kms_key_id, wrapped_dek)",
        f"VALUES ({_sql_text(ref)}, {_sql_text(purpose)}, {_sql_text(data_class)}, {_sql_text(ALGORITHMS[purpose])}, 'ACTIVE',",
        f"        coalesce((SELECT max(key_version) FROM sec.key_registry WHERE purpose = {_sql_text(purpose)}), 0) + 1,",
        f"        {_sql_text(kms_key_id) if kms_key_id else 'NULL'}, decode('{wrapped.hex()}', 'hex'));",
        "COMMIT;",
    ])


def new_key(args) -> int:
    wrapper = kms.provider()
    if wrapper is None:
        print("set MASSLAK_KMS_PROVIDER (vault or local) first", file=sys.stderr)
        return 2
    dek = os.urandom(32)
    wrapped = wrapper.wrap(dek, args.ref, args.kms_key_id)
    if wrapper.unwrap(wrapped, args.ref, args.kms_key_id) != dek:          # prove the service opens what it wrapped
        print("the key service did not return the same key", file=sys.stderr)
        return 1
    del dek
    print(f"-- data key {args.ref} wrapped by {wrapper.name}; run as the database owner:")
    print(register_statements(args.ref, args.purpose, args.data_class, args.kms_key_id, wrapped))
    return 0


async def check() -> int:
    wrapper = kms.provider()
    await db.open_pools()
    try:
        async with db.transaction(db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")) as conn:
            rows = await conn.fetch("""SELECT key_ref, status, kms_key_id, wrapped_dek FROM sec.key_registry
                                        WHERE wrapped_dek IS NOT NULL AND status <> 'RETIRED' ORDER BY id""")
    finally:
        await db.close_pools()
    bad = 0
    for r in rows:
        try:
            if wrapper is None:
                raise kms.KmsError("no key service configured")
            ok = len(wrapper.unwrap(bytes(r["wrapped_dek"]), r["key_ref"], r["kms_key_id"])) == 32
        except Exception as exc:  # report every key, then fail
            ok = False
            print(f"{r['key_ref']} ({r['status']}): cannot open: {exc}")
        bad += not ok
        if ok:
            print(f"{r['key_ref']} ({r['status']}): opens")
    print(f"{len(rows)} wrapped keys, {bad} cannot be opened")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="python -m app.tools.keys")
    sub = ap.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("new")
    n.add_argument("--ref", required=True)
    n.add_argument("--purpose", default="FIELD_ENCRYPTION", choices=sorted(ALGORITHMS))
    n.add_argument("--class", dest="data_class", default="RESTRICTED", choices=["RESTRICTED", "CONFIDENTIAL", "INTERNAL"])
    n.add_argument("--kms-key-id", default=None)
    sub.add_parser("check")
    args = ap.parse_args(argv)
    return new_key(args) if args.cmd == "new" else asyncio.run(check())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
