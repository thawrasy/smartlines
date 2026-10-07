"""Creates the first platform administrator on a fresh production database.

    MASSLAK_OWNER_URL=postgresql://... python3 backend/scripts/create_admin.py admin@example.gov "Full Name"

The password is read from MASSLAK_ADMIN_PASSWORD or prompted for; it must meet the password policy. The account must
enrol a second factor at its first sign-in, in every mode.
Further staff accounts are created from the administration portal.
"""
import asyncio
import getpass
import os
import sys
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.security import hash_password, password_problem  # noqa: E402


async def main(email: str, name: str, password: str):
    conn = await asyncpg.connect(os.environ["MASSLAK_OWNER_URL"])
    try:
        async with conn.transaction():
            await conn.execute("SELECT sys.set_context(NULL, NULL, 'SYSTEM')")
            if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = $1", email):
                print(f"{email} already exists")
                return
            pid = await conn.fetchval(
                "INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id", name)
            uid = await conn.fetchval(
                """INSERT INTO iam.app_user (party_id, account_kind, email, password_hash, password_changed_at, status, mfa_required)
                   VALUES ($1, 'PLATFORM', $2, $3, now(), 'ACTIVE', true) RETURNING id""", pid, email, hash_password(password))
            for role in ("PLATFORM_ADMIN", "PLATFORM_SECURITY"):
                await conn.execute(
                    "INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = $2 AND company_id IS NULL",
                    uid, role)
        print(f"created platform administrator {email}")
    finally:
        await conn.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    pw = os.environ.get("MASSLAK_ADMIN_PASSWORD") or getpass.getpass("Password: ")
    problem = password_problem(pw)
    if problem:
        sys.exit(f"password rejected: {problem}")
    asyncio.run(main(sys.argv[1], sys.argv[2], pw))
