"""Data keys under envelope encryption (third-party audit R-10).

    python -m app.tools.keys new --ref kms://masslak/field/restricted/v2 [--purpose FIELD_ENCRYPTION] [--class RESTRICTED]
                                 [--kms-key-id masslak-field]
        generates a 32-byte data key, wraps it with the configured key service (MASSLAK_KMS_PROVIDER) and prints the
        statements the database owner runs to register it as the active key; the clear key is never printed or stored.
        Then re-encrypt the rows under the old key: python -m app.tools.rekey --apply
    python -m app.tools.keys check
        opens every wrapped key in sec.key_registry with the key service and reports the ones it cannot open.
    python -m app.tools.keys bootstrap [--kms-key-id masslak-field]
        as the database owner (MASSLAK_OWNER_URL, or the PG* environment): every data key the API opens (field
        encryption, webhook secrets, blind index) that is not wrapped yet is wrapped by the key service and stored
        wrapped. A key given in MASSLAK_FIELD_KEYS or MASSLAK_BIDX_KEY is adopted as it is, so what it sealed stays
        readable; a key nothing was sealed under is new. A key that sealed rows but is given nowhere stops it. Run by
        deploy/migrate.sh on a production server, where the API and the worker then hold no clear key in their
        environment (reviews of October 2026, package 2, H-06); once it has run, remove the raw keys from deploy/.env.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
import uuid

import asyncpg

from .. import crypto, db, kms

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


DATA_KEY_PURPOSES = ("FIELD_ENCRYPTION", "WEBHOOK_SECRET", "BLIND_INDEX")


async def _sealed_under(conn: asyncpg.Connection, key_id: int) -> bool:
    """Whether any row refers to this registry key: every column that seals or signs under a key has a foreign key to
    sec.key_registry, so the catalog lists them all."""
    refs = await conn.fetch("""
        SELECT c.conrelid::regclass::text AS tbl, a.attname AS col, r.attname AS target
          FROM pg_constraint c
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
          JOIN pg_attribute r ON r.attrelid = c.confrelid AND r.attnum = c.confkey[1]
         WHERE c.contype = 'f' AND c.confrelid = 'sec.key_registry'::regclass AND c.conparentid = 0""")
    ref = await conn.fetchval("SELECT key_ref FROM sec.key_registry WHERE id = $1", key_id)
    for r in refs:
        value = key_id if r["target"] == "id" else ref
        if await conn.fetchval(f'SELECT EXISTS (SELECT 1 FROM {r["tbl"]} WHERE "{r["col"]}" = $1)', value):
            return True
    return False


async def bootstrap(conn: asyncpg.Connection, wrapper: kms.KeyWrapper, kms_key_id: str) -> list[str]:
    """Wraps every data key the API opens that is not wrapped yet; returns one line per key."""
    rows = await conn.fetch("""SELECT id, key_ref, purpose FROM sec.key_registry
                                WHERE purpose = ANY($1::text[]) AND status IN ('ACTIVE', 'DECRYPT_ONLY')
                                  AND company_id IS NULL AND wrapped_dek IS NULL ORDER BY id""", list(DATA_KEY_PURPOSES))
    configured = crypto._configured_field_keys()
    raw_bidx = os.environ.get("MASSLAK_BIDX_KEY", "").strip()
    bidx = crypto._decode_key(raw_bidx, "MASSLAK_BIDX_KEY") if raw_bidx else None
    sealed_any = None
    done = []
    for r in rows:
        key = bidx if r["purpose"] == "BLIND_INDEX" else configured.get(r["key_ref"])
        how = "adopted from the environment"
        if key is None:
            if r["purpose"] == "BLIND_INDEX":
                # blind indexes sit next to sealed values: any sealed row means indexes were made under a key
                if sealed_any is None:
                    sealed_any = any([await _sealed_under(conn, x["id"]) for x in rows if x["purpose"] != "BLIND_INDEX"])
                in_use = sealed_any
            else:
                in_use = await _sealed_under(conn, r["id"])
            if in_use:
                raise kms.KmsError(f"rows are sealed under {r['key_ref']} but its key is not given "
                                   f"({'MASSLAK_BIDX_KEY' if r['purpose'] == 'BLIND_INDEX' else 'MASSLAK_FIELD_KEYS'}): "
                                   "give it once so it can be wrapped")
            key, how = os.urandom(32), "new"
        wrapped = wrapper.wrap(key, r["key_ref"], kms_key_id)
        if wrapper.unwrap(wrapped, r["key_ref"], kms_key_id) != key:      # prove the service opens what it wrapped
            raise kms.KmsError(f"the key service did not return the same key for {r['key_ref']}")
        await conn.execute("UPDATE sec.key_registry SET wrapped_dek = $2, kms_key_id = $3 WHERE id = $1 AND wrapped_dek IS NULL",
                           r["id"], wrapped, kms_key_id)
        done.append(f"{r['key_ref']}: wrapped by {wrapper.name} ({how})")
    return done


async def bootstrap_main(kms_key_id: str) -> int:
    wrapper = kms.provider()
    if wrapper is None:
        print("the key service is required: set MASSLAK_KMS_PROVIDER=vault, MASSLAK_VAULT_ADDR and MASSLAK_VAULT_TOKEN",
              file=sys.stderr)
        return 2
    url = os.environ.get("MASSLAK_OWNER_URL")
    conn = await (asyncpg.connect(url) if url else asyncpg.connect(database=os.environ.get("POSTGRES_DB", "masslak")))
    try:
        async with conn.transaction():
            lines = await bootstrap(conn, wrapper, kms_key_id)
    except kms.KmsError as exc:
        print(f"keys bootstrap stopped: {exc}", file=sys.stderr)
        return 1
    finally:
        await conn.close()
    for line in lines:
        print(line)
    print(f"{len(lines)} data key(s) wrapped" if lines else "every data key is already wrapped by the key service")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(prog="python -m app.tools.keys")
    sub = ap.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("new")
    n.add_argument("--ref", required=True)
    n.add_argument("--purpose", default="FIELD_ENCRYPTION", choices=sorted(ALGORITHMS))
    n.add_argument("--class", dest="data_class", default="RESTRICTED", choices=["RESTRICTED", "CONFIDENTIAL", "INTERNAL"])
    n.add_argument("--kms-key-id", default=None)
    sub.add_parser("check")
    b = sub.add_parser("bootstrap")
    b.add_argument("--kms-key-id", default=os.environ.get("MASSLAK_VAULT_TRANSIT_KEY", "masslak-field"))
    args = ap.parse_args(argv)
    if args.cmd == "new":
        return new_key(args)
    return asyncio.run(bootstrap_main(args.kms_key_id) if args.cmd == "bootstrap" else check())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
