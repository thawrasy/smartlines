"""Document use cases: a company uploads, the platform reviews, both read the file (staff reads are logged)."""
import uuid
from datetime import date
from typing import Optional

import asyncpg

from ... import crypto, db
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ...util import rows
from ..notify.outbox import emit
from . import scanner, storage

DOC_TYPES = ("CR", "TAX_CERT", "TRANSPORT_LICENSE", "INSURANCE_POLICY", "VEHICLE_REG", "AGENCY_LICENSE", "OTHER")

LIST_SQL = """
    SELECT d.uid, d.doc_type, d.owner_type, d.issuer, d.issue_date, d.expiry_date, d.review_note, d.created_at,
           d.reviewed_at, f.file_name, f.mime_type, f.size_bytes, f.scan_status, p.legal_name AS company_name, v.plate_no,
           CASE WHEN d.status = 'APPROVED' AND d.expiry_date < current_date THEN 'EXPIRED' ELSE d.status END AS status,
           d.expiry_date - current_date AS days_left
      FROM iam.document d JOIN ref.file_object f ON f.id = d.file_id JOIN iam.party p ON p.id = d.company_id
      LEFT JOIN fleet.vehicle v ON d.owner_type = 'VEHICLE' AND v.id = d.owner_id"""


def company_of(pr: Principal) -> int:
    if pr.portal not in ("OPERATOR", "AGENCY") or not pr.company_id:
        raise forbidden("carrier or agency portal only")
    return pr.company_id


def _rejected(e: storage.FileRejected) -> ApiError:
    code, _, msg = str(e).partition(": ")
    return ApiError(422, code, msg)


# Licences, insurance and identity papers: reading them takes the same permission as filing them, on either side.
# A counter clerk or a driver of the company sees none, and on the platform only reviewers (company.approve) do
# (review of 1.47.0, R-25).
COMPANY_DOCUMENT_PERMISSIONS = {"company.staff", "vehicle.manage", "company.billing"}


def _require_document_access(pr: Principal) -> None:
    if pr.portal == "PLATFORM":
        if "company.approve" not in pr.permissions:
            raise forbidden("missing permission: company.approve")
    elif not pr.permissions.intersection(COMPANY_DOCUMENT_PERMISSIONS):
        raise forbidden("missing permission to manage documents")


async def upload(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, doc_type: str, data: bytes, file_name: str,
                 issuer: Optional[str], issue_date: Optional[date], expiry_date: Optional[date],
                 vehicle_uid: Optional[uuid.UUID]) -> tuple[int, str]:
    company = company_of(pr)
    _require_document_access(pr)
    if doc_type not in DOC_TYPES:
        raise ApiError(422, "DOC_TYPE", "unknown document type")
    if expiry_date and expiry_date <= date.today():
        raise ApiError(422, "DOCUMENT_EXPIRED", "the document has already expired")
    owner_type, owner_id = "COMPANY", company
    if vehicle_uid:
        owner_id = await conn.fetchval("SELECT id FROM fleet.vehicle WHERE uid = $1 AND company_id = $2", vehicle_uid, company)
        if owner_id is None:
            raise not_found("vehicle")
        owner_type = "VEHICLE"
    async with db.system_scope(conn, ctx):
        fc = await crypto.cipher(conn)
    try:
        stored = await storage.put(fc, data)
    except storage.FileRejected as e:
        raise _rejected(e)
    safe_name = "".join(ch for ch in file_name if ch.isalnum() or ch in "._- ")[:120] or "document"
    file_id = await conn.fetchval(
        """INSERT INTO ref.file_object (storage_key, file_name, mime_type, size_bytes, sha256, data_class, enc_key_id,
             uploaded_by, company_id) VALUES ($1, $2, $3, $4, $5, 'CONFIDENTIAL', $6, $7, $8) RETURNING id""",
        stored.storage_key, safe_name, stored.mime_type, stored.size, stored.sha256, stored.key_id, pr.user_id, company)
    # quarantine: the file is scanned before anyone can download or approve it (audit T3-15)
    if await scanner.scan_file(conn, ctx, file_id) in ("REJECTED", "QUARANTINED"):
        raise ApiError(422, "FILE_REJECTED", "the file did not pass the security scan")
    row = await conn.fetchrow(
        """INSERT INTO iam.document (owner_type, owner_id, doc_type, issuer, issue_date, expiry_date, file_id, company_id, uploaded_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING id, uid""",
        owner_type, owner_id, doc_type, issuer, issue_date, expiry_date, file_id, company, pr.user_id)
    return row["id"], str(row["uid"])


async def company_documents(conn: asyncpg.Connection, pr: Principal) -> list[dict]:
    _require_document_access(pr)
    return rows(await conn.fetch(LIST_SQL + " WHERE d.company_id = $1 ORDER BY d.created_at DESC", company_of(pr)))


async def review_queue(conn: asyncpg.Connection, pr: Principal, status: Optional[str]) -> list[dict]:
    _require_document_access(pr)
    return rows(await conn.fetch(LIST_SQL + """ WHERE ($1::text IS NULL OR d.status = $1)
                                               ORDER BY d.created_at LIMIT 200""", status))


async def read_file(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, doc_uid: uuid.UUID, purpose: str) -> tuple[bytes, str, str]:
    _require_document_access(pr)
    d = await conn.fetchrow(
        """SELECT d.id, d.company_id, f.storage_key, f.enc_key_id, f.sha256, f.mime_type, f.file_name, f.scan_status
             FROM iam.document d JOIN ref.file_object f ON f.id = d.file_id WHERE d.uid = $1""", doc_uid)
    if d is None or (pr.portal != "PLATFORM" and d["company_id"] != pr.company_id):
        raise not_found("document")
    if d["scan_status"] != "CLEAN":
        raise ApiError(409, "FILE_NOT_CLEAN", "the file is not available until it passes the security scan", scan_status=d["scan_status"])
    async with db.system_scope(conn, ctx):
        fc = await crypto.cipher(conn)
        if pr.portal == "PLATFORM":
            await conn.execute(
                """INSERT INTO audit.data_access_log (user_id, company_id, ip, object_type, object_id, fields, purpose, request_id)
                   VALUES ($1, $2, $3::inet, 'document', $4, ARRAY['file'], $5, $6)""",
                pr.user_id, d["company_id"], ctx.ip, d["id"], purpose, ctx.request_id)
    try:
        return await storage.get(fc, d["storage_key"], d["enc_key_id"], bytes(d["sha256"])), d["mime_type"], d["file_name"]
    except storage.FileRejected as e:
        raise ApiError(500, "FILE_TAMPERED", str(e))


async def decide(conn: asyncpg.Connection, pr: Principal, doc_uid: uuid.UUID, approve: bool, note: Optional[str]) -> int:
    if pr.portal != "PLATFORM" or "company.approve" not in pr.permissions:
        raise forbidden("missing permission: company.approve")
    d = await conn.fetchrow("SELECT id, status, uploaded_by, doc_type, company_id FROM iam.document WHERE uid = $1 FOR UPDATE", doc_uid)
    if d is None:
        raise not_found("document")
    if d["status"] != "PENDING":
        raise ApiError(409, "INVALID_TRANSITION", "only pending documents can be reviewed")
    if not approve and not (note and len(note.strip()) >= 3):
        raise ApiError(422, "REASON_REQUIRED", "give the reason for rejecting the document")
    await conn.execute(
        "UPDATE iam.document SET status = $2, review_note = $3, reviewed_by = $4, reviewed_at = now() WHERE id = $1",
        d["id"], "APPROVED" if approve else "REJECTED", note, pr.user_id)
    if d["uploaded_by"]:
        await emit(conn, "document.approved" if approve else "document.rejected", "document", d["id"],
                   {"doc_type": d["doc_type"], "note": note, "uploaded_by": d["uploaded_by"]}, company_id=d["company_id"])
    return d["id"]
