"""Public verification of documents issued by the platform (16.25).

Anyone (a station, an inspector, an authority) can check a printed booking or a ticket QR; the
answer comes from the server, so an edited printout is detected immediately. No personal data is shown.
"""
import uuid

from fastapi import APIRouter, Query, Request

from .. import db
from ..deps import base_context
from ..security import verify_document_token, verify_ticket_qr

router = APIRouter(prefix="/api/verify", tags=["verify"])


@router.get("")
async def verify(request: Request, token: str = Query(..., min_length=10, max_length=300)):
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    doc = verify_document_token(token)
    ticket_uid = None if doc else verify_ticket_qr(token)
    if not doc and not ticket_uid:
        return {"valid": False, "reason": "SIGNATURE_INVALID"}
    async with db.transaction(ctx) as conn:
        if doc:
            kind, ref = doc
            r = await conn.fetchrow(
                """SELECT b.booking_ref, b.status, b.total_amount, b.currency, t.trip_no, t.departure_at,
                          (SELECT count(*) FROM sales.ticket k WHERE k.booking_id = b.id) AS tickets
                     FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id WHERE b.booking_ref = $1""", ref)
            if r is None:
                return {"valid": False, "reason": "NOT_FOUND"}
            return {"valid": True, "kind": "booking", "booking_ref": r["booking_ref"], "status": r["status"],
                    "trip_no": r["trip_no"], "departure_at": r["departure_at"].isoformat(), "tickets": r["tickets"],
                    "total_amount": r["total_amount"], "currency": r["currency"]}
        r = await conn.fetchrow(
            """SELECT k.ticket_no, k.status, k.seat_no, t.trip_no, t.departure_at FROM sales.ticket k
                 JOIN ops.trip t ON t.id = k.trip_id WHERE k.uid = $1""", uuid.UUID(ticket_uid))
        if r is None:
            return {"valid": False, "reason": "NOT_FOUND"}
        return {"valid": True, "kind": "ticket", "ticket_no": r["ticket_no"], "status": r["status"],
                "seat_no": r["seat_no"], "trip_no": r["trip_no"], "departure_at": r["departure_at"].isoformat()}
