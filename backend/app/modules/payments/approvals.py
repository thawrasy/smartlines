"""The approval matrix of money decisions (owner's decision 5; review of release 1.47.0, R-23).

For each kind of decision (a credit from a bank statement line, a refund to the source) the platform sets how many
levels it needs, 0 to 5; for each level, who decides (the holders of a permission, or only the people named for it)
and from which amount the level applies. A request freezes the levels its amount needs when it is made. The database
enforces the rest (fin.tg_approval_decision): levels in order, one person decides one level at most and never their
own request, and the permission and the names are checked at the moment of deciding.
"""
from __future__ import annotations

import json
import uuid
from typing import Optional

import asyncpg

from ...errors import ApiError, not_found
from ..notify.outbox import emit

OBJECT_OF = {"BANK_CREDIT": "bank_statement_line", "REFUND": "payment_refund"}
MAX_LEVELS = 5


async def open_request(conn: asyncpg.Connection, action: str, object_id: int, amount: int, currency: str, summary: str,
                       requested_by: int) -> Optional[dict]:
    """Opens the request this decision needs, or None when the policy needs no approval for this amount."""
    levels = await conn.fetchval("SELECT fin.approval_levels($1, $2)", action, amount)
    if not levels:
        return None
    row = await conn.fetchrow(
        """INSERT INTO fin.approval_request (action, object_type, object_id, amount, currency, summary, required_levels, requested_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id, uid""",
        action, OBJECT_OF[action], object_id, amount, currency, summary[:300], levels, requested_by)
    return {"uid": str(row["uid"]), "levels": list(levels)}


async def policies(conn: asyncpg.Connection) -> list[dict]:
    rows = await conn.fetch("SELECT * FROM fin.approval_policy ORDER BY action")
    levels = await conn.fetch(
        """SELECT l.*, coalesce(array_agg(u.email ORDER BY u.email) FILTER (WHERE u.id IS NOT NULL), '{}') AS members
             FROM fin.approval_level l LEFT JOIN fin.approval_level_member m ON m.action = l.action AND m.level_no = l.level_no
             LEFT JOIN iam.app_user u ON u.id = m.user_id
            GROUP BY l.action, l.level_no ORDER BY l.action, l.level_no""")
    out = []
    for p in rows:
        out.append({"action": p["action"], "description": p["description"], "updated_at": p["updated_at"].isoformat(),
                    "levels": [{"level": lv["level_no"], "name": lv["name"], "permission": lv["permission_code"],
                                "min_amount": lv["min_amount"], "members": list(lv["members"])}
                               for lv in levels if lv["action"] == p["action"] and lv["level_no"] <= p["levels"]]})
    return out


async def set_policy(conn: asyncpg.Connection, user_id: int, action: str, levels: list[dict]) -> None:
    """Replaces the levels of one action. Every named member must hold the level's permission (else they could never
    decide), and a permission must be a platform one."""
    if action not in OBJECT_OF:
        raise not_found("approval policy")
    if len(levels) > MAX_LEVELS:
        raise ApiError(422, "TOO_MANY_LEVELS", f"at most {MAX_LEVELS} levels")
    named: dict[int, list[int]] = {}
    for i, lv in enumerate(levels, start=1):
        scope = await conn.fetchval("SELECT scope FROM iam.permission WHERE code = $1", lv["permission"])
        if scope not in ("PLATFORM", "BOTH"):
            raise ApiError(422, "UNKNOWN_PERMISSION", f"level {i}: {lv['permission']} is not a platform permission")
        ids = []
        for email in lv.get("members", []):
            uid = await conn.fetchval(
                """SELECT u.id FROM iam.app_user u WHERE lower(u.email) = lower($1) AND u.status = 'ACTIVE'
                      AND EXISTS (SELECT 1 FROM iam.user_role ur JOIN iam.role_permission rp ON rp.role_id = ur.role_id
                                   WHERE ur.user_id = u.id AND rp.permission_code = $2 AND (ur.valid_to IS NULL OR ur.valid_to > now()))""",
                email, lv["permission"])
            if uid is None:
                raise ApiError(422, "MEMBER_CANNOT_DECIDE", f"level {i}: {email} is not an active platform account holding {lv['permission']}",
                               level=i, email=email)
            ids.append(uid)
        named[i] = ids
    await conn.execute("UPDATE fin.approval_policy SET levels = $2, updated_by = $3, updated_at = now() WHERE action = $1",
                       action, len(levels), user_id)
    await conn.execute("DELETE FROM fin.approval_level_member WHERE action = $1", action)
    await conn.execute("DELETE FROM fin.approval_level WHERE action = $1 AND level_no > $2", action, len(levels))
    for i, lv in enumerate(levels, start=1):
        await conn.execute(
            """INSERT INTO fin.approval_level (action, level_no, name, permission_code, min_amount) VALUES ($1, $2, $3, $4, $5)
               ON CONFLICT (action, level_no) DO UPDATE SET name = EXCLUDED.name, permission_code = EXCLUDED.permission_code,
                                                            min_amount = EXCLUDED.min_amount""",
            action, i, lv["name"].strip(), lv["permission"], int(lv.get("min_amount") or 0))
        for uid in named[i]:
            await conn.execute("INSERT INTO fin.approval_level_member (action, level_no, user_id) VALUES ($1, $2, $3)", action, i, uid)
    # a change of who approves money is a security event: it reaches the security officers (outbox, audit T3)
    await emit(conn, "approval.policy_changed", "approval_policy", user_id,
               {"action": action, "levels": len(levels), "changed_by": user_id})


async def requests(conn: asyncpg.Connection, user_id: int, permissions: set[str], status: str) -> list[dict]:
    rows = await conn.fetch(
        """SELECT r.*, u.email AS requester,
                  (SELECT count(*) FROM fin.approval_decision d WHERE d.request_id = r.id) AS done,
                  (SELECT coalesce(array_agg(d.user_id), '{}') FROM fin.approval_decision d WHERE d.request_id = r.id) AS decider_ids,
                  (SELECT coalesce(json_agg(json_build_object('level', d.level_no, 'by', du.email, 'decision', d.decision,
                                                              'note', d.note, 'at', d.decided_at) ORDER BY d.level_no), '[]')
                     FROM fin.approval_decision d JOIN iam.app_user du ON du.id = d.user_id WHERE d.request_id = r.id) AS decisions
             FROM fin.approval_request r JOIN iam.app_user u ON u.id = r.requested_by
            WHERE r.status = $1 ORDER BY r.created_at LIMIT 200""", status)
    levels = {(lv["action"], lv["level_no"]): lv for lv in await conn.fetch("SELECT * FROM fin.approval_level")}
    members = {}
    for m in await conn.fetch("SELECT action, level_no, user_id FROM fin.approval_level_member"):
        members.setdefault((m["action"], m["level_no"]), set()).add(m["user_id"])
    out = []
    for r in rows:
        decisions = r["decisions"] if isinstance(r["decisions"], list) else json.loads(r["decisions"])
        nxt = r["required_levels"][r["done"]] if r["status"] == "PENDING" and r["done"] < len(r["required_levels"]) else None
        lv = levels.get((r["action"], nxt)) if nxt else None
        named = members.get((r["action"], nxt), set())
        can = bool(lv) and r["requested_by"] != user_id and lv["permission_code"] in permissions \
            and (not named or user_id in named) and user_id not in r["decider_ids"]
        out.append({"uid": str(r["uid"]), "action": r["action"], "amount": r["amount"], "currency": r["currency"].strip(),
                    "summary": r["summary"], "status": r["status"], "requested_by": r["requester"],
                    "created_at": r["created_at"].isoformat(), "levels": list(r["required_levels"]),
                    "next_level": nxt, "next_level_name": lv["name"] if lv else None, "decisions": decisions, "can_decide": can})
    return out


async def decide(conn: asyncpg.Connection, user_id: int, uid: uuid.UUID, approve: bool, note: Optional[str]) -> asyncpg.Record:
    """Records one level's decision; the database checks who may decide. Returns the request after it."""
    rq = await conn.fetchrow("SELECT * FROM fin.approval_request WHERE uid = $1 FOR UPDATE", uid)
    if rq is None:
        raise not_found("approval request")
    if rq["status"] != "PENDING":
        raise ApiError(409, "APPROVAL_FINAL", f"this request is already {rq['status'].lower()}")
    if not approve and len((note or "").strip()) < 3:
        raise ApiError(422, "REASON_REQUIRED", "give the reason for rejecting")
    done = await conn.fetchval("SELECT count(*) FROM fin.approval_decision WHERE request_id = $1", rq["id"])
    await conn.execute("INSERT INTO fin.approval_decision (request_id, level_no, user_id, decision, note) VALUES ($1, $2, $3, $4, $5)",
                       rq["id"], rq["required_levels"][done], user_id, "APPROVE" if approve else "REJECT", note)
    return await conn.fetchrow("SELECT * FROM fin.approval_request WHERE id = $1", rq["id"])


async def cancel(conn: asyncpg.Connection, uid: uuid.UUID) -> asyncpg.Record:
    """Withdraws a pending request (a policy changed under it, or it was opened by mistake); its decision is undone."""
    rq = await conn.fetchrow("UPDATE fin.approval_request SET status = 'CANCELLED', decided_at = now() "
                             "WHERE uid = $1 AND status = 'PENDING' RETURNING *", uid)
    if rq is None:
        raise ApiError(409, "APPROVAL_FINAL", "only a pending request can be cancelled")
    return rq
