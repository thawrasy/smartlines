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


async def _parcel(conn, kind: str, payload: dict) -> list[Delivery]:
    """The sender's account hears of each step. On arrival the recipient's mobile is texted the pickup code too: the code
    is drawn again here from the parcel and the moment it arrived, so it never sits in the outbox."""
    values = dict(payload)
    if kind == "parcel.arrived":
        from ..parcels.journey import pickup_code
        values["pickup_code"] = pickup_code(payload["tracking_no"], payload["arrived_at"])
    out: list[Delivery] = []
    uid = await conn.fetchval("SELECT id FROM iam.app_user WHERE party_id = $1 AND status = 'ACTIVE' ORDER BY id LIMIT 1",
                              payload.get("shipper_party_id"))
    if uid is not None:
        d = await _user(conn, uid, kind, ["IN_APP", "EMAIL"], values)
        if d:
            out.append(d)
    if kind == "parcel.arrived" and payload.get("recipient_mobile"):
        out.append(Delivery(kind, ["SMS"], await default_locale(conn), mobile=payload["recipient_mobile"], values=values))
    return out


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
    if kind == "booking.trip_changed":   # the carrier changed the trip: new time, vehicle or trip (N42, 1148)
        template = f"booking.trip_changed.{str(payload.get('change', '')).lower()}"
        if payload.get("agency_id") or payload.get("counter") or not payload.get("booker_user_id"):
            if not payload.get("contact_mobile"):
                return []              # listed for the carrier to call (ops.trip_change_contact)
            return [Delivery(template, ["SMS"], await default_locale(conn), mobile=payload["contact_mobile"],
                             values=payload, booking_id=event["aggregate_id"])]
        d = await _user(conn, payload["booker_user_id"], template, ["IN_APP", "EMAIL"], payload, event["aggregate_id"])
        return [d] if d else []
    if kind in ("withdrawal.paid", "withdrawal.rejected"):
        return await _owners(conn, event["company_id"], kind, payload)
    if kind.startswith("payment_activation."):   # the gateway's roll-out, step by step (1145): the carrier's owners hear of it
        return await _owners(conn, event["company_id"], kind, payload)
    if kind == "agency_cash.received":    # the carrier recorded the agency's cash (N13, 1145): the agency's owners hear of it
        return await _owners(conn, event["company_id"], kind, payload)
    if kind == "trip.cancel_penalty":   # the regulators' penalty for a cancelled trip (1106)
        return await _owners(conn, event["company_id"], kind, payload)
    if kind in ("tracking.signal_lost", "tracking.alert_escalated"):       # the platform found a silent trip (1100)
        return await _owners(conn, event["company_id"], kind, payload)
    if kind == "screen.unseen":         # a station screen stopped reading its board (1129): its administration, else the platform
        if event["company_id"] is not None:
            return await _owners(conn, event["company_id"], kind, payload)
        return await _platform_staff(conn, "boarding.manage", kind, ["IN_APP", "EMAIL"], payload)
    if kind in ("parcel.arrived", "parcel.delivered", "parcel.exception"):   # a parcel's journey (1182): its sender, and
        return await _parcel(conn, kind, payload)                            # the recipient's mobile when it arrives
    if kind == "fuel.filled":           # a vehicle filled at a fuel station (1180): the owners of the company holding the account
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
    if kind in ("security.traffic_alert", "security.shield_changed"):   # the platform shield (1142): its security staff
        channels = ["IN_APP", "EMAIL", "SMS"] if payload.get("severity") == "CRITICAL" or payload.get("level") == "LOCKDOWN" \
            else ["IN_APP", "EMAIL"]
        return await _platform_staff(conn, "security.console", kind, channels, payload)
    if kind == "account.signed_in_elsewhere" and payload.get("user_id"):   # one session per portal (1142)
        d = await _user(conn, payload["user_id"], kind, ["IN_APP", "EMAIL"], payload)
        return [d] if d else []
    if kind in ("document.approved", "document.rejected"):
        d = await _user(conn, payload["uploaded_by"], kind, ["IN_APP", "EMAIL"], payload)
        return [d] if d else []
    if kind in ("voucher.used", "voucher.returned") and payload.get("user_id"):   # partner vouchers (1107)
        d = await _user(conn, payload["user_id"], kind, ["IN_APP"], payload)
        return [d] if d else []
    if kind == "points.earned" and payload.get("booker_user_id"):       # loyalty points after a trip (1103)
        d = await _user(conn, payload["booker_user_id"], kind, ["IN_APP"], payload)
        return [d] if d else []
    if kind in ("case.replied", "claim.paid") and payload.get("user_id"):
        d = await _user(conn, payload["user_id"], kind, ["IN_APP", "EMAIL"], payload)
        return [d] if d else []
    if kind in ("family.link_requested", "family.link_approved") and payload.get("booker_user_id"):
        d = await _user(conn, payload["booker_user_id"], kind, ["IN_APP", "EMAIL"], payload)
        return [d] if d else []
    return []
