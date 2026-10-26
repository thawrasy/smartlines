"""The business sign-in door (N16, 1150): a password an administrator sets for a new member of staff is temporary."""
import json


async def temporary_password(conn, user_id: int) -> dict:
    """Marks the password just set by an administrator as temporary (changed at the first sign-in, and stops working
    after auth.doors.temp_password_hours) and gives what the employee types at the door."""
    v = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'auth.doors'")
    d = json.loads(v) if isinstance(v, str) else dict(v or {})
    row = await conn.fetchrow(
        """UPDATE iam.app_user u SET password_must_change = true,
                  temp_password_expires_at = now() + make_interval(hours => $2)
            WHERE u.id = $1
        RETURNING u.username, (SELECT c.company_no FROM iam.company c WHERE c.id = u.home_company_id) AS company_no,
                  u.temp_password_expires_at""", user_id, int(d.get("temp_password_hours", 72)))
    return {"company_no": row["company_no"] or str(d.get("platform_no")), "username": row["username"],
            "temp_password_expires_at": row["temp_password_expires_at"].isoformat()}
