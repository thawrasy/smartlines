"""The boarding photo (1086), its policy (1087) and its replacement by the platform (1087).

A photo of a person is taken when the profile is created: the person takes their own, and the head of a family takes a
member's (the database checks who may). It is stored encrypted like every file, scanned before anyone can see it, and
kept while the account exists; only an erasure request removes it. A photo on file is changed only by the platform: a
request carries the new photo and the evidence, and a second platform person applies it (WP4).

Whether a photo is required is decided by the rules of iam.photo_rule (WP1), read at booking and at boarding. A rule
that requires it turns a traveller away when no photo is on file; with no rule in force the photo is optional.
"""
import json
import uuid

from ... import crypto, db
from ...config import get_settings
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ..documents import scanner, storage

PHOTO_TYPES = ("image/jpeg", "image/png")
EVIDENCE_TYPES = ("application/pdf", "image/jpeg", "image/png")


async def store(conn, ctx: db.Context, pr: Principal, data: bytes, file_name: str, allowed: tuple, code: str) -> int:
    """Stores one file encrypted, scans it, and returns its file row. The type is read from the first bytes."""
    limit = get_settings().max_upload_bytes
    if not data:
        raise ApiError(422, "FILE_EMPTY", "the file is empty")
    if len(data) > limit:
        raise ApiError(422, "FILE_TOO_LARGE", "the file is larger than allowed", max_bytes=limit)
    try:
        mime = storage.detect(data)
    except storage.FileRejected:
        mime = None
    if mime not in allowed:
        raise ApiError(422, code, "the file is not of an accepted type")
    async with db.system_scope(conn, ctx):
        fc = await crypto.cipher(conn)
    try:
        stored = await storage.put(fc, data)
    except storage.FileRejected as e:
        raise ApiError(422, code, str(e))
    safe_name = "".join(ch for ch in file_name if ch.isalnum() or ch in "._- ")[:120] or "file"
    file_id = await conn.fetchval(
        """INSERT INTO ref.file_object (storage_key, file_name, mime_type, size_bytes, sha256, data_class, enc_key_id, uploaded_by)
           VALUES ($1, $2, $3, $4, $5, 'RESTRICTED', $6, $7) RETURNING id""",
        stored.storage_key, safe_name, stored.mime_type, stored.size, stored.sha256, stored.key_id, pr.user_id)
    if await scanner.scan_file(conn, ctx, file_id) in ("REJECTED", "QUARANTINED"):
        raise ApiError(422, "FILE_REJECTED", "the file did not pass the security scan")
    return file_id


async def _has_photo(conn, ctx: db.Context, party_id: int) -> bool:
    async with db.system_scope(conn, ctx):
        return bool(await conn.fetchval("SELECT 1 FROM iam.party_photo WHERE party_id = $1", party_id))


async def take(conn, ctx: db.Context, pr: Principal, data: bytes, file_name: str, target_party: int) -> dict:
    """Takes the first photo of target_party. The caller has checked that the principal may take it: their own party,
    or the party of a member of a family they head. A photo already on file is never replaced here (1086)."""
    if pr.portal != "PASSENGER":
        raise forbidden("only passenger accounts take boarding photos")
    if await _has_photo(conn, ctx, target_party):
        raise ApiError(409, "PHOTO_EXISTS", "a boarding photo is already on file; it changes only through the platform, with proof of identity")
    file_id = await store(conn, ctx, pr, data, file_name, PHOTO_TYPES, "PHOTO_TYPE")
    taken_as = await conn.fetchval("SELECT iam.set_party_photo($1, $2, $3)", target_party, file_id, pr.user_id)
    return {"party_id": target_party, "taken_by": taken_as}


async def status(conn, ctx: db.Context, pr: Principal) -> dict:
    """Whether the signed-in person has a boarding photo on file, and when it was taken. Never the picture itself."""
    row = await conn.fetchrow("SELECT taken_at, taken_by FROM iam.party_photo WHERE party_id = $1", pr.party_id)
    if row is None:
        return {"has_photo": False, "taken_at": None, "taken_by": None}
    return {"has_photo": True, "taken_at": row["taken_at"].isoformat(), "taken_by": row["taken_by"]}


async def read_for_ticket(conn, ctx: db.Context, trip_id: int, ticket_uid: uuid.UUID) -> tuple[int, bytes, str]:
    """The photo of the passenger on a ticket of this trip: (party id, bytes, type). A passenger without a linked profile,
    or without a photo, has none (PHOTO_NONE)."""
    async with db.system_scope(conn, ctx):
        row = await conn.fetchrow(
            """SELECT p.party_id, f.storage_key, f.enc_key_id, f.sha256, f.mime_type, f.scan_status
                 FROM sales.ticket k
                 JOIN sales.passenger p ON p.id = k.passenger_id
                 LEFT JOIN iam.party_photo pp ON pp.party_id = p.party_id
                 LEFT JOIN ref.file_object f ON f.id = pp.file_id
                WHERE k.uid = $1 AND k.trip_id = $2 AND k.status IN ('ISSUED', 'BOARDED')""", ticket_uid, trip_id)
        if row is None:
            raise not_found("ticket")
        if row["party_id"] is None or row["storage_key"] is None:
            raise ApiError(404, "PHOTO_NONE", "no photo is on file for this passenger")
        if row["scan_status"] != "CLEAN":
            raise ApiError(409, "FILE_NOT_CLEAN", "the photo is not available until it passes the security scan")
        fc = await crypto.cipher(conn)
        data = await storage.get(fc, row["storage_key"], row["enc_key_id"], bytes(row["sha256"]))
    return row["party_id"], data, row["mime_type"]


# ---- WP1: the policy -------------------------------------------------------------------------------------------

async def requirement(conn, trip_id: int, nationality: str, category: str | None, transit: bool = False) -> str:
    """REQUIRED, OPTIONAL or NOT_APPLICABLE for this traveller on this trip, from the rules in force."""
    scope = await conn.fetchrow("SELECT market, trip_scope FROM ops.trip_photo_scope($1)", trip_id)
    return await conn.fetchval("SELECT iam.photo_requirement($1, $2, iam.traveller_class($3, $4), $5)",
                               scope["market"], scope["trip_scope"], nationality, transit, category)


async def missing(conn, ctx: db.Context, trip_id: int, nationality: str, category: str | None, party_id: int | None) -> bool:
    """True when a photo is required for this traveller on this trip and none is on file. A traveller without a linked
    profile has no photo on file, so a required photo cannot be shown for them."""
    if await requirement(conn, trip_id, nationality, category) != "REQUIRED":
        return False
    if party_id is None:
        return True
    return not await _has_photo(conn, ctx, party_id)


async def propose_rule(conn, pr: Principal, body) -> str:
    uid = await conn.fetchval(
        "SELECT iam.propose_photo_rule($1, $2, $3, $4, $5, $6, $7)", body.market, body.trip_scope, body.traveller_class,
        body.passenger_category, body.requirement, body.effective_from, body.legal_basis)
    return str(uid)


async def rule_row(conn, uid: uuid.UUID):
    row = await conn.fetchrow("SELECT id, status, proposed_by_user_id, approved_by_user_id FROM iam.photo_rule WHERE uid = $1", uid)
    if row is None:
        raise not_found("photo rule")
    return row


async def approve_rule(conn, pr: Principal, uid: uuid.UUID) -> int:
    r = await rule_row(conn, uid)
    if r["status"] != "PROPOSED":
        raise ApiError(409, "NOT_PROPOSED", "the rule is not waiting for approval")
    if r["proposed_by_user_id"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "a second platform person approves the rule")
    await conn.execute("SELECT iam.approve_photo_rule($1)", uid)
    return r["id"]


async def retire_rule(conn, pr: Principal, uid: uuid.UUID) -> int:
    r = await rule_row(conn, uid)
    if r["status"] == "RETIRED":
        raise ApiError(409, "NOT_RETIRABLE", "the rule is already retired")
    if r["status"] == "APPROVED" and r["approved_by_user_id"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "a second platform person retires an approved rule")
    await conn.execute("SELECT iam.retire_photo_rule($1)", uid)
    return r["id"]


async def list_rules(conn) -> list[dict]:
    rows = await conn.fetch(
        """SELECT uid, market, trip_scope, traveller_class, passenger_category, requirement, effective_from, effective_to,
                  legal_basis, status, proposed_at, approved_at, retired_at
             FROM iam.photo_rule ORDER BY proposed_at DESC LIMIT 200""")
    return [dict(r) | {"uid": str(r["uid"])} for r in rows]


# ---- WP4: the platform changes a photo on file -----------------------------------------------------------------

async def request_change(conn, ctx: db.Context, pr: Principal, party_uid: uuid.UUID, reason: str, evidence_kind: str,
                         evidence: bytes, evidence_name: str, photo: bytes, photo_name: str) -> tuple[str, int]:
    async with db.system_scope(conn, ctx):
        party_id = await conn.fetchval("SELECT id FROM iam.party WHERE uid = $1", party_uid)
    if party_id is None:
        raise not_found("person")
    if not await conn.fetchval("SELECT iam.evidence_accepted($1, $2)", party_id, evidence_kind):
        raise ApiError(422, "EVIDENCE_KIND_NOT_ACCEPTED", "this document is not accepted as evidence for this person now",
                       evidence_kind=evidence_kind)
    missing = await conn.fetchval(
        "SELECT field_code FROM iam.data_requirement WHERE requirement = 'REQUIRED' AND NOT iam.data_requirement_met($1, field_code) "
        "ORDER BY field_code LIMIT 1", party_id)
    if missing:
        raise ApiError(422, "DATA_REQUIRED", "an item the platform requires is missing from the person's record", field=missing)
    photo_file = await store(conn, ctx, pr, photo, photo_name, PHOTO_TYPES, "PHOTO_TYPE")
    evidence_file = await store(conn, ctx, pr, evidence, evidence_name, EVIDENCE_TYPES, "EVIDENCE_TYPE")
    uid = await conn.fetchval("SELECT iam.request_photo_change($1, $2, $3, $4, $5)",
                              party_id, reason, evidence_kind, evidence_file, photo_file)
    return str(uid), party_id


async def change_row(conn, uid: uuid.UUID):
    row = await conn.fetchrow(
        """SELECT r.id, r.status, r.requested_by_user_id, r.approval_stages, p.id AS party_id
             FROM iam.photo_change_request r JOIN iam.party p ON p.id = r.party_id WHERE r.uid = $1""", uid)
    if row is None:
        raise not_found("photo change request")
    return row


async def approve_change(conn, pr: Principal, uid: uuid.UUID) -> dict:
    """Records this person's stage of the change; the photo is replaced at the last stage (1091)."""
    r = await change_row(conn, uid)
    if r["status"] != "PENDING":
        raise ApiError(409, "NOT_PENDING", "the request is not waiting for a decision")
    if r["requested_by_user_id"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "the one who asks for the change does not approve it")
    if await _already(conn, "CHANGE_REQUEST", r["id"], pr.user_id):
        raise ApiError(409, "ALREADY_APPROVED", "this person has already approved the change")
    status = await conn.fetchval("SELECT iam.approve_photo_change($1)", uid)
    return {"status": status, "party_id": r["party_id"], **(await _approvals(conn, "CHANGE_REQUEST", r["id"], r["approval_stages"]))}


async def reject_change(conn, pr: Principal, uid: uuid.UUID) -> int:
    r = await change_row(conn, uid)
    if r["status"] != "PENDING":
        raise ApiError(409, "NOT_PENDING", "the request is not waiting for a decision")
    await conn.execute("SELECT iam.reject_photo_change($1)", uid)
    return r["party_id"]


async def list_changes(conn) -> list[dict]:
    rows = await conn.fetch(
        """SELECT r.uid, p.uid AS party_uid, u.uid AS requested_by, r.evidence_kind, r.status, r.reason, r.created_at, r.decided_at
             FROM iam.photo_change_request r
             JOIN iam.party p ON p.id = r.party_id
             JOIN iam.app_user u ON u.id = r.requested_by_user_id
            ORDER BY r.created_at DESC LIMIT 200""")
    return [dict(r) | {"uid": str(r["uid"]), "party_uid": str(r["party_uid"]), "requested_by": str(r["requested_by"])} for r in rows]


async def read_evidence(conn, ctx: db.Context, uid: uuid.UUID) -> tuple[bytes, str, int]:
    async with db.system_scope(conn, ctx):
        row = await conn.fetchrow(
            """SELECT r.party_id, f.storage_key, f.enc_key_id, f.sha256, f.mime_type, f.scan_status
                 FROM iam.photo_change_request r JOIN ref.file_object f ON f.id = r.evidence_file_id
                WHERE r.uid = $1""", uid)
        if row is None:
            raise not_found("evidence")
        if row["scan_status"] != "CLEAN":
            raise ApiError(409, "FILE_NOT_CLEAN", "the evidence is not available until it passes the security scan")
        fc = await crypto.cipher(conn)
        data = await storage.get(fc, row["storage_key"], row["enc_key_id"], bytes(row["sha256"]))
    return data, row["mime_type"], row["party_id"]


# ---- 1088-1091: the documents accepted, the age rule and the required data are settings; a change to them, and a change
#      of a photo on file, pass through the approval stages set in the platform's settings (the one who asks is not one)

def _jsonb(value):
    return json.loads(value) if isinstance(value, str) else value


async def _already(conn, subject_type: str, subject_id: int, person: int) -> bool:
    return bool(await conn.fetchval(
        "SELECT 1 FROM iam.photo_approval WHERE subject_type = $1 AND subject_id = $2 AND approver_user_id = $3",
        subject_type, subject_id, person))


async def _approvals(conn, subject_type: str, subject_id: int, stages) -> dict:
    """How many stages have been recorded, and the stages the change passes (in order, the last is the final approval)."""
    done = await conn.fetchval("SELECT count(*) FROM iam.photo_approval WHERE subject_type = $1 AND subject_id = $2",
                               subject_type, subject_id)
    return {"approvals": done, "stages": _jsonb(stages)}


async def settings_view(conn) -> dict:
    """What the platform sets: the accepted documents, the age rule of the identity card (None: no rule), the approval
    stages in force for a new change, and the data items that are required or optional."""
    kinds = [dict(r) for r in await conn.fetch("SELECT code, label, active, age_rule FROM iam.photo_evidence_kind ORDER BY id")]
    min_age = await conn.fetchval("SELECT (value #>> '{}')::integer FROM sys.setting WHERE key = 'photo.identity_card_min_age'")
    items = [dict(r) for r in await conn.fetch("SELECT field_code, label, requirement FROM iam.data_requirement ORDER BY field_code")]
    return {"kinds": kinds, "identity_card_min_age": min_age,
            "approval_stages": _jsonb(await conn.fetchval("SELECT iam.photo_approval_stages()")), "data_requirements": items}


async def policy_change_row(conn, uid: uuid.UUID):
    row = await conn.fetchrow("SELECT id, status, requested_by_user_id, approval_stages FROM iam.photo_policy_change WHERE uid = $1", uid)
    if row is None:
        raise not_found("photo policy change")
    return row


async def request_evidence_change(conn, pr: Principal, code: str, active: bool, reason: str) -> tuple[str, int]:
    if not await conn.fetchval("SELECT 1 FROM iam.photo_evidence_kind WHERE code = $1", code):
        raise not_found("evidence kind")
    uid = await conn.fetchval("SELECT iam.request_photo_policy_change('EVIDENCE_KIND', $1, $2, NULL, NULL, NULL, $3)", code, active, reason)
    return str(uid), (await policy_change_row(conn, uid))["id"]


async def request_identity_age(conn, pr: Principal, min_age: int | None, reason: str) -> tuple[str, int]:
    uid = await conn.fetchval("SELECT iam.request_photo_policy_change('IDENTITY_MIN_AGE', NULL, NULL, $1, NULL, NULL, $2)", min_age, reason)
    return str(uid), (await policy_change_row(conn, uid))["id"]


async def request_data_requirement(conn, pr: Principal, field: str, requirement: str, reason: str) -> tuple[str, int]:
    if not await conn.fetchval("SELECT 1 FROM iam.data_requirement WHERE field_code = $1", field):
        raise not_found("data item")
    uid = await conn.fetchval("SELECT iam.request_photo_policy_change('FIELD_REQUIREMENT', NULL, NULL, NULL, $1, $2, $3)",
                              field, requirement, reason)
    return str(uid), (await policy_change_row(conn, uid))["id"]


async def approve_policy_change(conn, pr: Principal, uid: uuid.UUID) -> dict:
    row = await policy_change_row(conn, uid)
    if row["status"] != "PENDING":
        raise ApiError(409, "NOT_PENDING", "the change is not waiting for approval")
    if row["requested_by_user_id"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "the one who asks for the change does not approve it")
    if await _already(conn, "POLICY_CHANGE", row["id"], pr.user_id):
        raise ApiError(409, "ALREADY_APPROVED", "this person has already approved the change")
    status = await conn.fetchval("SELECT iam.approve_photo_policy_change($1)", uid)
    return {"status": status, "change_id": row["id"], **(await _approvals(conn, "POLICY_CHANGE", row["id"], row["approval_stages"]))}


async def reject_policy_change(conn, pr: Principal, uid: uuid.UUID) -> int:
    row = await policy_change_row(conn, uid)
    if row["status"] != "PENDING":
        raise ApiError(409, "NOT_PENDING", "the change is not waiting for a decision")
    await conn.execute("SELECT iam.reject_photo_policy_change($1)", uid)
    return row["id"]


async def list_policy_changes(conn) -> list[dict]:
    rows = await conn.fetch(
        """SELECT c.id, c.uid, c.change_type, c.evidence_code, c.new_active, c.new_min_age, c.field_code, c.new_requirement,
                  c.reason, c.status, c.requested_at, c.decided_at, c.approval_stages, u.uid AS requested_by,
                  (SELECT count(*) FROM iam.photo_approval a WHERE a.subject_type = 'POLICY_CHANGE' AND a.subject_id = c.id) AS approvals
             FROM iam.photo_policy_change c JOIN iam.app_user u ON u.id = c.requested_by_user_id
            ORDER BY c.requested_at DESC LIMIT 200""")
    out = []
    for r in rows:
        item = {k: v for k, v in dict(r).items() if k not in ("id", "uid", "requested_by", "approval_stages")}
        out.append(item | {"uid": str(r["uid"]), "requested_by": str(r["requested_by"]), "stages": _jsonb(r["approval_stages"])})
    return out
