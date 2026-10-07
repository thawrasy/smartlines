"""Re-encrypts Restricted columns from retired keys to the active key (review 3.12).

Rotation: register the new key reference as ACTIVE in sec.key_registry, add its material to MASSLAK_FIELD_KEYS, move
the old reference to DECRYPT_ONLY, then run

    python -m app.tools.rekey            # report what would change
    python -m app.tools.rekey --apply    # re-encrypt, in batches, each batch in its own transaction

Plaintext only lives in this process's memory for the length of one row; nothing is logged but counts. When no row
still uses a DECRYPT_ONLY key, that key can be RETIRED and removed from MASSLAK_FIELD_KEYS.
"""
from __future__ import annotations

import asyncio
import logging
import sys
import uuid
from dataclasses import dataclass

from .. import crypto, db

log = logging.getLogger("masslak.rekey")
BATCH = 500


@dataclass(frozen=True)
class Column:
    table: str
    enc: str
    aad: str                         # the associated data the value was sealed with
    where: str = "true"              # extra filter, when one table holds values sealed for different purposes
    key_ref: str = crypto.RESTRICTED_REF
    also: tuple = ()                 # other (column, associated data) pairs of the row that share its enc_key_id


COLUMNS = [
    Column("sales.passenger", "id_no_enc", "sales.passenger.id_no", also=(("mobile_enc", "sales.passenger.mobile"),)),
    Column("sales.passenger", "mobile_enc", "sales.passenger.mobile", "id_no_enc IS NULL"),
    Column("iam.family_member", "id_no_enc", "iam.family_member.id_no", also=(("mobile_enc", "iam.family_member.mobile"),)),
    Column("iam.family_member", "mobile_enc", "iam.family_member.mobile", "id_no_enc IS NULL"),
    Column("brd.manifest_person", "doc_no_enc", "brd.manifest_person.doc_no"),
    Column("iam.bank_account", "iban_enc", "iam.bank_account.iban"),
    Column("iam.mfa_factor", "secret_enc", "iam.mfa_factor.secret", "factor_type = 'TOTP'"),
    Column("iam.mfa_factor", "secret_enc", "iam.mfa_factor.recovery", "factor_type = 'RECOVERY_CODES'"),
    Column("sys.webhook_endpoint", "secret_enc", "sys.webhook_endpoint.secret", key_ref="kms://masslak/webhook/v1"),
]


def _ctx() -> db.Context:
    return db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")


async def pending(conn, col: Column) -> int:
    return await conn.fetchval(
        f"""SELECT count(*) FROM {col.table} t JOIN sec.key_registry k ON k.id = t.enc_key_id
             WHERE t.{col.enc} IS NOT NULL AND k.status <> 'ACTIVE' AND {col.where}""")


async def rekey_column(col: Column, apply: bool) -> tuple[int, int]:
    """Returns (rows found under a retired key, rows re-encrypted)."""
    async with db.transaction(_ctx()) as conn:
        found = await pending(conn, col)
    if not apply or not found:
        return found, 0
    done, last_id = 0, 0
    while True:
        async with db.transaction(_ctx()) as conn:
            fc = await crypto.cipher(conn)
            extra = "".join(f", t.{c} AS also_{i}" for i, (c, _) in enumerate(col.also))
            rows = await conn.fetch(
                f"""SELECT t.id, t.{col.enc} AS blob, t.enc_key_id{extra} FROM {col.table} t JOIN sec.key_registry k ON k.id = t.enc_key_id
                     WHERE t.{col.enc} IS NOT NULL AND k.status <> 'ACTIVE' AND {col.where} AND t.id > $1
                     ORDER BY t.id LIMIT {BATCH} FOR UPDATE OF t""", last_id)
            if not rows:
                return found, done
            for r in rows:
                sealed = fc.encrypt(fc.decrypt(bytes(r["blob"]), r["enc_key_id"], col.aad), col.aad, key_ref=col.key_ref)
                sets, args = [f"{col.enc} = $2", "enc_key_id = $3"], [r["id"], sealed.ciphertext, sealed.key_id]
                for i, (c, aad) in enumerate(col.also):     # siblings move to the same key in the same update
                    if r[f"also_{i}"] is not None:
                        args.append(fc.encrypt(fc.decrypt(bytes(r[f"also_{i}"]), r["enc_key_id"], aad), aad, key_ref=col.key_ref).ciphertext)
                        sets.append(f"{c} = ${len(args)}")
                await conn.execute(f"UPDATE {col.table} SET {', '.join(sets)} WHERE id = $1", *args)
                done += 1
            last_id = rows[-1]["id"]


async def main(apply: bool) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    await db.open_pools()
    crypto.reset_cipher()
    left = 0
    try:
        for col in COLUMNS:
            found, done = await rekey_column(col, apply)
            left += found - done
            log.info("%s.%s (%s): %d under a retired key, %d re-encrypted", col.table, col.enc, col.aad, found, done)
    finally:
        await db.close_pools()
    return 0 if apply or left == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main("--apply" in sys.argv)))
