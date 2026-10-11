"""The boarding photo (migration 1086).

A photo of the person is taken when the profile is created: the passenger takes their own, and the head of the family
takes a member's (the caller decides whose party it is; family.head_family and member_by_uid check the head). It is
stored encrypted like every file (ref.file_object, RESTRICTED), scanned before anyone can see it, and kept while the
account exists: closing the account keeps it, and only an erasure request removes it (gov.erase_party_photo).

Only the driver of the trip and the carrier's office for it read the photo, at boarding, and every read is audited by
the caller. The photo is never listed, never in a notification and never in an export.
"""
import uuid

from ... import crypto, db
from ...config import get_settings
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ..documents import scanner, storage

PHOTO_TYPES = ("image/jpeg", "image/png")


def _check_photo(data: bytes) -> str:
    if not data:
        raise ApiError(422, "FILE_EMPTY", "the photo is empty")
    if len(data) > get_settings().max_upload_bytes:
        raise ApiError(422, "FILE_TOO_LARGE", "the photo is larger than allowed", max_bytes=get_settings().max_upload_bytes)
    try:
        mime = storage.detect(data)
    except storage.FileRejected:
        mime = None
    if mime not in PHOTO_TYPES:
        raise ApiError(422, "PHOTO_TYPE", "the photo must be a JPEG or PNG image")
    return mime


async def take(conn, ctx: db.Context, pr: Principal, data: bytes, file_name: str, target_party: int) -> dict:
    """Stores the first photo of target_party. The caller has checked that the principal may take it: their own party,
    or the party of a member of a family they head. A photo already on file is never replaced here."""
    if pr.portal != "PASSENGER":
        raise forbidden("only passenger accounts take boarding photos")
    _check_photo(data)
    async with db.system_scope(conn, ctx):
        if await conn.fetchval("SELECT 1 FROM iam.party_photo WHERE party_id = $1", target_party):
            raise ApiError(409, "PHOTO_EXISTS", "a boarding photo is already on file; it changes only through the platform, with proof of identity")
        fc = await crypto.cipher(conn)
    try:
        stored = await storage.put(fc, data)
    except storage.FileRejected as e:
        raise ApiError(422, "PHOTO_TYPE", str(e))
    safe_name = "".join(ch for ch in file_name if ch.isalnum() or ch in "._- ")[:120] or "photo"
    file_id = await conn.fetchval(
        """INSERT INTO ref.file_object (storage_key, file_name, mime_type, size_bytes, sha256, data_class, enc_key_id, uploaded_by)
           VALUES ($1, $2, $3, $4, $5, 'RESTRICTED', $6, $7) RETURNING id""",
        stored.storage_key, safe_name, stored.mime_type, stored.size, stored.sha256, stored.key_id, pr.user_id)
    if await scanner.scan_file(conn, ctx, file_id) in ("REJECTED", "QUARANTINED"):
        raise ApiError(422, "FILE_REJECTED", "the photo did not pass the security scan")
    # the database checks who may take it and removes the earlier file (migration 1086)
    taken_as = await conn.fetchval("SELECT iam.set_party_photo($1, $2, $3)", target_party, file_id, pr.user_id)
    return {"party_id": target_party, "taken_by": taken_as}


async def status(conn, ctx: db.Context, pr: Principal) -> dict:
    """Whether the signed-in person has a boarding photo on file, and when it was taken. Never the picture itself."""
    row = await conn.fetchrow("SELECT taken_at, taken_by FROM iam.party_photo WHERE party_id = $1", pr.party_id)
    if row is None:
        return {"has_photo": False, "taken_at": None, "taken_by": None}
    return {"has_photo": True, "taken_at": row["taken_at"].isoformat(), "taken_by": row["taken_by"]}


async def read_for_ticket(conn, ctx: db.Context, trip_id: int, ticket_uid: uuid.UUID) -> tuple[int, bytes, str]:
    """The photo of the passenger on a ticket of this trip: (party id, bytes, type). Only for a valid ticket; a
    passenger without a linked profile, or without a photo, has none (PHOTO_NONE)."""
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
