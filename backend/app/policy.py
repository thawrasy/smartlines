"""Policy decision point for reading restricted data (review 3.11).

Every read of a document number, an IBAN or an authority's view of a manifest passes a purpose and a reason to
sec.authorize(). The decision is written to sec.policy_decision in its own short transaction, so a refusal stays on
record even though the request that asked is rolled back.
"""
from __future__ import annotations

from typing import Optional

from . import db
from .errors import ApiError


async def authorize(ctx: db.Context, resource: str, action: str, purpose: str, reason: Optional[str],
                    permission: Optional[str] = None) -> None:
    async with db.transaction(ctx) as conn:
        allowed = await conn.fetchval("SELECT sec.authorize($1, $2, $3, $4, $5)", resource, action, purpose, reason, permission)
    if not allowed:
        raise ApiError(403, "ACCESS_DENIED", f"{action} on {resource} needs the purpose {purpose} and a reason")
