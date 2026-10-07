"""Encrypts phone numbers still stored in clear (third-party audit R-04, schema file 1046).

Passengers' and family members' phone numbers are sealed with the field key; the clear column is emptied in the same
update. Persons' contact fields left on iam.party are reported, since the migration already moved every one that belongs
to an account. When nothing is left in clear, the tool prints the statements that make the sealing constraints cover old
rows too; the application role does not own the tables, so the database owner runs them (psql as the migration role).

    python -m app.tools.seal_contacts            # report what is still in clear
    python -m app.tools.seal_contacts --apply    # seal, in batches; then print the statements the owner runs
"""
from __future__ import annotations

import asyncio
import logging
import sys
import uuid

from .. import crypto, db

log = logging.getLogger("masslak.seal_contacts")
BATCH = 500
TABLES = [("sales.passenger", "sales.passenger.mobile", "passenger_mobile_sealed"),
          ("iam.family_member", "iam.family_member.mobile", "family_member_mobile_sealed")]


def _ctx() -> db.Context:
    return db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")


async def seal_table(table: str, aad: str, apply: bool) -> tuple[int, int]:
    """Returns (rows in clear, rows sealed)."""
    async with db.transaction(_ctx()) as conn:
        found = await conn.fetchval(f"SELECT count(*) FROM {table} WHERE mobile IS NOT NULL")
    if not apply or not found:
        return found, 0
    done = 0
    while True:
        async with db.transaction(_ctx()) as conn:
            fc = await crypto.cipher(conn)
            rows = await conn.fetch(f"""SELECT id, mobile, id_no_enc, enc_key_id FROM {table} WHERE mobile IS NOT NULL
                                         ORDER BY id LIMIT {BATCH} FOR UPDATE""")
            if not rows:
                return found, done
            for r in rows:
                sealed = fc.encrypt(r["mobile"], aad)
                if r["id_no_enc"] is not None and r["enc_key_id"] != sealed.key_id:
                    # the row's document is under an older key: rotate it first (python -m app.tools.rekey --apply)
                    log.warning("%s id=%s: document under a retired key, skipped until rekey", table, r["id"])
                    continue
                await conn.execute(f"""UPDATE {table} SET mobile_enc = $2, mobile_last4 = $3, enc_key_id = $4, mobile = NULL
                                        WHERE id = $1""", r["id"], sealed.ciphertext, crypto.last4(r["mobile"]), sealed.key_id)
                done += 1
            if len(rows) < BATCH:
                return found, done


def validate_statements(constraints: list[tuple[str, str]]) -> str:
    return "\n".join(f"ALTER TABLE {table} VALIDATE CONSTRAINT {con};" for table, con in constraints)


async def main(apply: bool) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    await db.open_pools()
    crypto.reset_cipher()
    left = 0
    try:
        for table, aad, _ in TABLES:
            found, done = await seal_table(table, aad, apply)
            left += found - done
            log.info("%s: %d phone numbers in clear, %d sealed", table, found, done)
        async with db.transaction(_ctx()) as conn:
            persons = await conn.fetchval("""SELECT count(*) FROM iam.party WHERE party_type = 'PERSON'
                                               AND (mobile IS NOT NULL OR email IS NOT NULL OR address IS NOT NULL)""")
        log.info("iam.party: %d persons still carry contact fields (move them to the person's account, then rerun)", persons)
        left += persons
        if apply and left == 0:
            print("Nothing left in clear. As the database owner, run:")
            print(validate_statements([(t, c) for t, _, c in TABLES] + [("iam.party", "party_person_contact_sealed")]))
    finally:
        await db.close_pools()
    return 0 if left == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main("--apply" in sys.argv)))
