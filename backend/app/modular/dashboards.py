"""Module dashboards: headline tiles, status breakdowns, a 30-day trend and the latest records.

Every widget names a resource from the specs; the dashboard of a portal keeps only the widgets whose resource that portal
may read, and every query runs inside the caller's transaction, so row-level security scopes the numbers to the company,
agency or passenger looking at them. Identifiers come from the specs only; values are bound parameters.
"""
from dataclasses import dataclass, field
from typing import Optional

import asyncpg

from . import engine
from .specs import RESOURCES
from .. import markets
from ..deps import Principal
from ..errors import ApiError


@dataclass(frozen=True)
class Tile:
    id: str                         # i18n key dash.<id>
    res: str
    agg: str = "count"              # count | sum
    col: Optional[str] = None       # summed column
    where: dict = field(default_factory=dict)   # column -> allowed values (None means IS NULL)
    since: Optional[tuple] = None   # (timestamp column, days)
    tone: str = ""                  # "", "good", "warn", "bad"


@dataclass(frozen=True)
class Dash:
    tiles: tuple
    breakdowns: tuple = ()          # (resource, column)
    trend: Optional[tuple] = None   # (resource, timestamp column)
    recent: Optional[str] = None


def T(id, res, *args, **kw):
    return Tile(id, res, *args, **kw)


DASHBOARDS = {
    "approved_lines": Dash(
        (T("lines_active", "line", where={"status": ["ACTIVE"]}, tone="good"),
         T("permits_active", "line-permit", where={"status": ["ACTIVE"]}),
         T("versions_pending", "line-version", where={"status": ["PENDING_APPROVAL"]}, tone="warn"),
         T("adherence_7d", "route-adherence", since=("ts", 7), tone="bad")),
        (("line", "status"), ("line-permit", "status")), ("route-adherence", "ts"), "line-version"),
    "shuttle_rides": Dash(
        (T("rides_today", "shuttle-ride", since=("created_at", 1)),
         T("rides_open", "shuttle-ride", where={"status": ["OPEN"]}),
         T("rides_charged_30d", "shuttle-ride", "sum", "charged_amount", since=("created_at", 30), tone="good"),
         T("rides_outstanding", "shuttle-ride", "sum", "outstanding_amount", tone="warn")),
        (("shuttle-ride", "status"),), ("shuttle-ride", "created_at"), "shuttle-ride"),
    "shuttle_subscriptions": Dash(
        (T("subs_active", "subscription", where={"status": ["ACTIVE"]}, tone="good"),
         T("subs_revenue_30d", "subscription", "sum", "price_paid", since=("created_at", 30)),
         T("passes_active", "shuttle-pass", where={"status": ["ACTIVE"]}),
         T("plans_active", "subscription-plan", where={"status": ["ACTIVE"]})),
        (("subscription", "status"), ("nfc-card", "status")), ("subscription", "created_at"), "subscription"),
    "cargo": Dash(
        (T("shipments_moving", "shipment", where={"status": ["PICKED_UP", "IN_NETWORK", "OUT_FOR_DELIVERY"]}),
         T("shipments_delivered_30d", "shipment", where={"status": ["DELIVERED"]}, since=("updated_at", 30), tone="good"),
         T("shipments_exception", "shipment", where={"status": ["EXCEPTION"]}, tone="bad"),
         T("cod_pending", "cod", "sum", "amount", where={"status": ["PENDING", "COLLECTED"]}, tone="warn"),
         T("cargo_claims_open", "cargo-claim", where={"status": ["OPEN", "UNDER_REVIEW"]})),
        (("shipment", "status"), ("pickup-request", "status")), ("shipment", "created_at"), "shipment"),
    "international": Dash(
        (T("entry_rules_active", "entry-rule", where={"status": ["ACTIVE"]}, tone="good"),
         T("travel_docs_pending", "ticket-document", where={"status": ["PENDING"]}, tone="warn"),
         T("travel_docs_verified", "ticket-document", where={"status": ["VERIFIED"]}),
         T("travel_docs_rejected", "ticket-document", where={"status": ["REJECTED"]}, tone="bad")),
        (("ticket-document", "status"), ("entry-rule", "status")), ("entry-rule", "created_at"), "ticket-document"),
    "border_manifest": Dash(
        (T("manifests_submitted", "manifest", where={"status": ["SUBMITTED"]}, tone="warn"),
         T("manifests_acknowledged", "manifest", where={"status": ["ACKNOWLEDGED"]}, tone="good"),
         T("manifests_rejected", "manifest", where={"status": ["REJECTED"]}, tone="bad"),
         T("discrepancies_open", "manifest-discrepancy", where={"resolved_at": [None]})),
        (("manifest", "status"), ("border-point", "status")), ("manifest", "created_at"), "manifest"),
    "gov_adapters": Dash(
        (T("adapters_active", "gov-adapter", where={"status": ["ACTIVE"]}, tone="good"),
         T("verifications_waiting", "verification-job", where={"status": ["QUEUED", "SENT"]}),
         T("verifications_matched_30d", "verification-job", where={"status": ["MATCHED"]}, since=("requested_at", 30)),
         T("verifications_mismatch", "verification-job", where={"status": ["MISMATCH", "NOT_FOUND", "FAILED"]}, tone="bad")),
        (("verification-job", "status"), ("gov-adapter", "status")), ("verification-job", "requested_at"), "verification-job"),
    "tracking_stations": Dash(
        (T("tracking_on", "tracking-state", where={"status": ["ON"]}, tone="good"),
         T("delays_7d", "trip-delay", since=("reported_at", 7), tone="warn"),
         T("vehicles_out_of_service", "vehicle-service-status", where={"status": ["OUT_OF_SERVICE", "IMPOUNDED"]}, tone="bad"),
         T("insurance_claims_open", "insurance-claim", where={"status": ["NOTIFIED", "UNDER_REVIEW"]})),
        (("vehicle-service-status", "status"), ("insurance-claim", "status")), ("trip-delay", "reported_at"), "driver-notice"),
    "freight": Dash(
        (T("freight_open", "freight-request", where={"status": ["OPEN"]}),
         T("bids_7d", "freight-bid", since=("created_at", 7)),
         T("freight_running", "freight-contract", where={"status": ["SIGNED", "IN_PROGRESS"]}, tone="good"),
         T("freight_value", "freight-contract", "sum", "price", where={"status": ["SIGNED", "IN_PROGRESS", "COMPLETED"]}),
         T("freight_claims_open", "freight-claim", where={"status": ["OPEN", "UNDER_REVIEW"]}, tone="bad")),
        (("freight-request", "status"), ("freight-contract", "status")), ("freight-request", "created_at"), "freight-request"),
    "intermediary_platforms": Dash(
        (T("channels_active", "channel", where={"status": ["ACTIVE"]}, tone="good"),
         T("channel_agreements_active", "channel-agreement", where={"status": ["ACTIVE"]}),
         T("channel_net_due", "channel-statement", "sum", "net_due", where={"status": ["ISSUED", "DISPUTED"]}, tone="warn"),
         T("channel_memos_open", "channel-memo", where={"status": ["ISSUED", "DISPUTED"]})),
        (("channel-statement", "status"), ("channel-memo", "status")), ("channel-memo", "created_at"), "channel-statement"),
    "rail": Dash(
        (T("fare_classes_active", "fare-class", where={"status": ["ACTIVE"]}),
         T("coach_layouts_active", "coach-layout", where={"status": ["ACTIVE"]}),
         T("journeys_booked", "journey", where={"status": ["BOOKED", "IN_PROGRESS"]}, tone="good"),
         T("journeys_disrupted", "journey", where={"status": ["DISRUPTED"]}, tone="bad")),
        (("journey", "status"),), ("journey", "created_at"), "journey"),
    "taxi": Dash(
        (T("taxi_on_shift", "taxi-shift", where={"status": ["ON"]}, tone="good"),
         T("taxi_searching", "ride-request", where={"status": ["SEARCHING"]}, tone="warn"),
         T("taxi_rides_7d", "taxi-ride", where={"status": ["COMPLETED"]}, since=("ended_at", 7)),
         T("taxi_fares_30d", "taxi-ride", "sum", "fare", where={"status": ["COMPLETED"]}, since=("ended_at", 30)),
         T("taxi_offices_active", "taxi-office", where={"status": ["ACTIVE"]})),
        (("ride-request", "status"), ("taxi-ride", "status")), ("ride-request", "created_at"), "taxi-ride"),
    "car_rental": Dash(
        (T("cars_available", "rental-car", where={"status": ["AVAILABLE"]}, tone="good"),
         T("cars_rented", "rental-car", where={"status": ["RENTED"]}),
         T("rental_bookings_upcoming", "rental-booking", where={"status": ["PENDING", "CONFIRMED"]}, tone="warn"),
         T("deposits_held", "deposit-hold", "sum", "amount", where={"status": ["HELD", "PARTIALLY_CAPTURED"]})),
        (("rental-car", "status"), ("rental-booking", "status")), ("rental-booking", "created_at"), "rental-booking"),
    "transit_passengers": Dash(
        (T("corridors_active", "corridor", where={"status": ["ACTIVE"]}, tone="good"),
         T("crossings_7d", "crossing-event", since=("occurred_at", 7)),
         T("transit_open", "transit-reconciliation", where={"status": ["OPEN"]}, tone="warn"),
         T("transit_discrepancy", "transit-reconciliation", where={"status": ["DISCREPANCY"]}, tone="bad")),
        (("transit-reconciliation", "status"),), ("crossing-event", "occurred_at"), "crossing-event"),
    "contract_transport": Dash(
        (T("contracts_active", "service-contract", where={"status": ["ACTIVE"]}, tone="good"),
         T("riders_active", "contract-rider", where={"status": ["ACTIVE"]}),
         T("attendance_today", "attendance", since=("occurred_at", 1)),
         T("contract_unpaid", "contract-invoice", "sum", "amount", where={"status": ["ISSUED"]}, tone="warn")),
        (("service-contract", "status"), ("contract-invoice", "status")), ("attendance", "occurred_at"), "attendance"),
    "carrier_billing": Dash(
        (T("billing_subs_active", "company-subscription", where={"status": ["ACTIVE"]}, tone="good"),
         T("billing_due", "carrier-invoice", "sum", "total", where={"status": ["DUE", "OVERDUE"]}, tone="warn"),
         T("billing_overdue", "carrier-invoice", where={"status": ["OVERDUE"]}, tone="bad"),
         T("usage_30d", "usage-event", since=("ts", 30))),
        (("carrier-invoice", "status"), ("company-subscription", "status")), ("usage-event", "ts"), "carrier-invoice"),
    "service_partners": Dash(
        (T("partners_active", "partner", where={"status": ["ACTIVE"]}, tone="good"),
         T("fuel_sessions_30d", "fuel-session", since=("opened_at", 30)),
         T("fuel_anomalies_open", "fuel-anomaly", where={"status": ["OPEN"]}, tone="bad"),
         T("partner_sales_30d", "partner-sale", "sum", "amount", where={"status": ["COMPLETED"]}, since=("created_at", 30))),
        (("partner-order", "status"), ("fuel-anomaly", "status")), ("partner-sale", "created_at"), "partner-order"),
    "loyalty_partners": Dash(
        (T("loyalty_partners_active", "loyalty-partner", where={"status": ["ACTIVE"]}, tone="good"),
         T("rewards_active", "reward", where={"status": ["ACTIVE"]}),
         T("vouchers_issued", "voucher", where={"status": ["ISSUED"]}),
         T("redemptions_value", "partner-redemption", "sum", "value")),
        (("voucher", "status"), ("points-transfer", "status")), ("voucher", "created_at"), "partner-redemption"),
    "campaigns": Dash(
        (T("campaigns_live", "campaign", where={"status": ["LIVE"]}, tone="good"),
         T("campaign_budget", "campaign", "sum", "budget_total", where={"status": ["APPROVED", "LIVE", "PAUSED"]}),
         T("campaign_spent", "campaign", "sum", "budget_spent", tone="warn"),
         T("sponsors_active", "sponsor", where={"status": ["ACTIVE"]})),
        (("campaign", "status"),), ("campaign", "created_at"), "campaign"),
    "accounting_ops": Dash(
        (T("invoices_open", "sales-invoice", "sum", "total", where={"status": ["ISSUED", "PARTIALLY_PAID"]}, tone="warn"),
         T("receipts_30d", "cash-receipt", "sum", "amount", since=("receipt_date", 30), tone="good"),
         T("payments_30d", "cash-payment", "sum", "amount", since=("payment_date", 30)),
         T("cash_sessions_open", "cash-session", where={"status": ["OPEN"]})),
        (("sales-invoice", "status"), ("cash-session", "status")), ("cash-receipt", "receipt_date"), "sales-invoice"),
    "contact_center": Dash(
        (T("calls_today", "call", since=("started_at", 1)),
         T("calls_queued", "call", where={"state": ["QUEUED"]}, tone="warn"),
         T("agents_available", "call-agent", where={"status": ["AVAILABLE"]}, tone="good"),
         T("callbacks_pending", "callback", where={"status": ["PENDING"]})),
        (("call", "state"), ("call-agent", "status")), ("call", "started_at"), "call"),
}

TREND_DAYS = 30


def _visible(key: str, pr: Principal) -> Optional[engine.Resource]:
    res = RESOURCES.get(key)
    if res is None or pr.portal not in res.portals:
        return None
    try:
        engine.check_access(res, pr)
    except ApiError:
        return None
    return res


def _where(meta: engine.TableMeta, tile: Tile, params: list) -> str:
    parts = ["true"]
    for col, values in tile.where.items():
        _ = meta.cols[col]          # unknown columns fail loudly
        if values == [None]:
            parts.append(f"t.{col} IS NULL")
            continue
        params.append([str(v) for v in values])
        parts.append(f"t.{col}::text = ANY(${len(params)}::text[])")
    if tile.since:
        col, days = tile.since
        params.append(days)
        parts.append(f"t.{col} >= now() - make_interval(days => ${len(params)})")
        _ = meta.cols[col]
    return " AND ".join(parts)


async def build(conn: asyncpg.Connection, module: str, pr: Principal) -> dict:
    dash = DASHBOARDS.get(module)
    if dash is None:
        return {"tiles": [], "breakdowns": [], "trend": None, "recent": None}
    tiles = []
    for tile in dash.tiles:
        res = _visible(tile.res, pr)
        if not res:
            continue
        meta = await engine.table_meta(conn, res.table)
        params: list = []
        where = _where(meta, tile, params)
        if tile.agg == "sum":
            value = await conn.fetchval(f"SELECT coalesce(sum(t.{tile.col}), 0)::bigint FROM {res.table} t WHERE {where}", *params)
            money = engine.is_money(meta.cols[tile.col])
        else:
            value = await conn.fetchval(f"SELECT count(*) FROM {res.table} t WHERE {where}", *params)
            money = False
        tiles.append({"id": tile.id, "res": res.key, "value": int(value), "money": money, "tone": tile.tone,
                      "filter": {k: v for k, v in tile.where.items() if len(v) == 1 and v[0] is not None}})
    breakdowns = []
    for key, col in dash.breakdowns:
        res = _visible(key, pr)
        if not res:
            continue
        meta = await engine.table_meta(conn, res.table)
        rows = await conn.fetch(f"SELECT t.{col}::text AS v, count(*) AS n FROM {res.table} t GROUP BY 1 ORDER BY 2 DESC")
        order = meta.cols[col].choices or []
        items = sorted(({"value": r["v"], "count": r["n"]} for r in rows if r["v"] is not None),
                       key=lambda i: order.index(i["value"]) if i["value"] in order else len(order))
        breakdowns.append({"res": res.key, "column": col, "items": items})
    trend = None
    if dash.trend and (res := _visible(dash.trend[0], pr)):
        col = dash.trend[1]
        meta = await engine.table_meta(conn, res.table)
        _ = meta.cols[col]
        tz = (await markets.of_party(conn, pr.company_id)).time_zone          # days of the viewer's market (1061)
        rows = await conn.fetch(
            f"SELECT d::date AS day, (SELECT count(*) FROM {res.table} t "
            f"  WHERE (t.{col} AT TIME ZONE $2::text)::date = d::date) AS n "
            f"FROM generate_series((now() AT TIME ZONE $2::text)::date - ($1::int - 1), "
            f"(now() AT TIME ZONE $2::text)::date, interval '1 day') d ORDER BY 1", TREND_DAYS, tz) \
            if meta.cols[col].pg_type.startswith("timestamp") else await conn.fetch(
            f"SELECT d::date AS day, (SELECT count(*) FROM {res.table} t WHERE t.{col} = d::date) AS n "
            f"FROM generate_series(current_date - ($1::int - 1), current_date, interval '1 day') d ORDER BY 1", TREND_DAYS)
        trend = {"res": res.key, "column": col, "points": [{"day": r["day"].isoformat(), "count": r["n"]} for r in rows]}
    recent = None
    if dash.recent and (res := _visible(dash.recent, pr)):
        spec = await engine.describe(conn, res, pr)
        rows = await engine.list_rows(conn, res, pr, None, {}, 5, 0)
        recent = {"res": res.key, "columns": spec["list"][:5], "rows": rows["rows"], "total": rows["total"]}
    return {"tiles": tiles, "breakdowns": breakdowns, "trend": trend, "recent": recent}


def check() -> list:
    """Spec problems (unknown resources or modules), used by the tests."""
    problems = []
    for module, dash in DASHBOARDS.items():
        keys = [t.res for t in dash.tiles] + [b[0] for b in dash.breakdowns] + ([dash.trend[0]] if dash.trend else []) + \
               ([dash.recent] if dash.recent else [])
        for k in keys:
            if k not in RESOURCES:
                problems.append(f"{module}: unknown resource {k}")
            elif RESOURCES[k].module != module:
                problems.append(f"{module}: {k} belongs to {RESOURCES[k].module}")
    return problems
