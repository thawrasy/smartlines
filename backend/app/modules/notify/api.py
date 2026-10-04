"""In-app notifications for the signed-in user: /api/notifications. The interface renders each from its template
code and values in the reader's language."""
import json
from typing import Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_user
from ...util import row_dict

router = APIRouter(prefix="/api/notifications", tags=["notifications"])


@router.get("")
async def mine(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT id, template_code, payload, status, created_at, read_at FROM crm.notification
                WHERE user_id = $1 AND channel = 'IN_APP' ORDER BY created_at DESC LIMIT 50""", pr.user_id)
        unread = await conn.fetchval(
            "SELECT count(*) FROM crm.notification WHERE user_id = $1 AND channel = 'IN_APP' AND read_at IS NULL", pr.user_id)
    items = []
    for r in recs:
        d = row_dict(r)
        d["payload"] = json.loads(d["payload"]) if isinstance(d["payload"], str) else d["payload"]
        for private in ("booker_user_id", "uploaded_by", "contact_mobile", "agency_id"):
            d["payload"].pop(private, None)
        items.append(d)
    return {"notifications": items, "unread": unread}


class ReadIn(BaseModel):
    ids: Optional[list[int]] = Field(default=None, max_length=100)     # none = mark all as read


@router.post("/read")
async def mark_read(body: ReadIn, request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        n = await conn.execute(
            """UPDATE crm.notification SET read_at = now(), status = 'READ'
                WHERE user_id = $1 AND channel = 'IN_APP' AND read_at IS NULL AND ($2::bigint[] IS NULL OR id = ANY($2))""",
            pr.user_id, body.ids)
    return {"ok": True, "updated": int(n.split()[-1])}
