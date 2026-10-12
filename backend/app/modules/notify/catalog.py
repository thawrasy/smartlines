"""Which event notifies whom, through which channels, with which template.

Each event resolves to deliveries. A delivery to a user carries their language and address; an agency sale also
texts the traveller's mobile, who has no account. The payload already carries what the message needs, so the worker
never reads business tables beyond the recipients.
"""
from dataclasses import dataclass, field
from typing import Optional

import asyncpg


@dataclass
class Delivery:
    template: str
    channels: list[str]
    locale: str
    user_id: Optional[int] = None
    party_id: Optional[int] = None
    email: Optional[str] = None
    mobile: Optional[str] = None
    values: dict = field(default_factory=dict)
    booking_id: Optional[int] = None


async def _user(conn, user_id: int, template: str, channels: list[str], values: dict, booking_id=None) -> Optional[Delivery]:
    u = await conn.fetchrow("SELECT id, party_id, email, mobile, preferred_locale FROM iam.app_user WHERE id = $1 AND status = 'ACTIVE'",
                            user_id)
    if u is None:
        return None
    return Delivery(template, channels, u["preferred_locale"], u["id"], u["party_id"], u["email"], u["mobile"], values, booking_id)


async def _owners(conn, company_id: int, template: str, values: dict) -> list[Delivery]:
    ids = await conn.fetch("SELECT user_id FROM iam.company_member WHERE company_id = $1 AND is_owner AND status = 'ACTIVE'", company_id)
    out = [await _user(conn, r["user_id"], template, ["IN_APP", "EMAIL"], values) for r in ids]
    return [d for d in out if d]


async def _platform_staff(conn, permission: str, template: str, channels: list[str], values: dict) -> list[Delivery]:
    """Platform users whose current roles hold the permission (the security staff for alarms)."""
    ids = await conn.fetch(
        """SELECT DISTINCT ur.user_id FROM iam.user_role ur JOIN iam.role_permission rp ON rp.role_id = ur.role_id
            WHERE rp.permission_code = $1 AND (ur.valid_to IS NULL OR ur.valid_to > now())""", permission)
    out = [await _user(conn, r["user_id"], template, channels, values) for r in ids]
    return [d for d in out if d]


async def default_locale(conn) -> str:
    return await conn.fetchval("SELECT coalesce((SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), 'en')")


async def deliveries(conn: asyncpg.Connection, event: asyncpg.Record, payload: dict) -> list[Delivery]:
    kind = event["event_type"]
    if kind in ("booking.confirmed", "booking.cancelled", "booking.reserved", "booking.cancelled_by_carrier"):
        template = kind
        if payload.get("agency_id") or payload.get("counter"):      # the traveller has no account: a text, if a mobile was left
            if not payload.get("contact_mobile"):
                return []
            return [Delivery(template, ["SMS"], await default_locale(conn), mobile=payload["contact_mobile"],
                             values=payload, booking_id=event["aggregate_id"])]
        d = await _user(conn, payload["booker_user_id"], template, ["IN_APP", "EMAIL"], payload, event["aggregate_id"])
        return [d] if d else []
    if kind in ("withdrawal.paid", "withdrawal.rejected"):
        return await _owners(conn, event["company_id"], kind, payload)
    if kind in ("tracking.signal_lost", "tracking.alert_escalated"):       # the platform found a silent trip (1100)
        return await _owners(conn, event["company_id"], kind, payload)
    if kind == "sos.raised":            # an emergency on a trip (1101): the carrier's owners and the platform's security staff
        owners = await _owners(conn, event["company_id"], kind, payload)
        for d in owners:
            d.channels = ["IN_APP", "EMAIL", "SMS"]
        return owners + await _platform_staff(conn, "security.console", kind, ["IN_APP", "EMAIL", "SMS"], payload)
    if kind == "incident.reported":     # a driver's report (1101); the platform hears of severe ones and injuries
        out = await _owners(conn, event["company_id"], kind, payload)
        if payload.get("platform"):
            out += await _platform_staff(conn, "security.console", kind, ["IN_APP", "EMAIL"], payload)
        return out
    if kind in ("document.approved", "document.rejected"):
        d = await _user(conn, payload["uploaded_by"], kind, ["IN_APP", "EMAIL"], payload)
        return [d] if d else []
    if kind in ("case.replied", "claim.paid") and payload.get("user_id"):
        d = await _user(conn, payload["user_id"], kind, ["IN_APP", "EMAIL"], payload)
        return [d] if d else []
    if kind in ("family.link_requested", "family.link_approved") and payload.get("booker_user_id"):
        d = await _user(conn, payload["booker_user_id"], kind, ["IN_APP", "EMAIL"], payload)
        return [d] if d else []
    return []
