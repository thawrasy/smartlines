"""Report datasets: the only tables, joins and columns a report can read.

A report (from the catalog or built by a user) names a dataset and column keys; it never carries SQL. Every query
runs inside the caller's transaction, so row-level security applies, and company portals add an explicit filter on
their own company because some tables (published trips, active stations) are readable by everyone.

Column types drive filters, totals and export formats: money is stored in minor units and exported in pounds.
Columns marked personal never reach a reader who holds the regulator role only.
"""
from dataclasses import dataclass, field
from typing import Optional

TEXT, INT, MONEY, DATE, TIME, BOOL, NUM, PCT = "text", "int", "money", "date", "datetime", "bool", "num", "pct"


@dataclass(frozen=True)
class Col:
    key: str
    sql: str
    type: str = TEXT
    group: bool = True          # may be grouped by
    filter: bool = True
    agg: bool = False           # may be summed / averaged (numbers and money)
    personal: bool = False
    values: str = ""            # translation group for coded values (statuses, cities...)


@dataclass(frozen=True)
class Dataset:
    key: str
    category: str
    from_sql: str
    columns: tuple
    portals: frozenset                  # PLATFORM, OPERATOR, AGENCY
    date_col: str                       # column key the period parameter filters on
    company_sql: Optional[str] = None   # company filter for OPERATOR / AGENCY portals
    agency_sql: Optional[str] = None
    permission: Optional[str] = None    # extra platform permission (security datasets)
    default_sort: tuple = field(default=())
    reader: str = "app"                 # "audit": read through the audit connection (append-only logs)

    def col(self, key: str) -> Col:
        for c in self.columns:
            if c.key == key:
                return c
        raise KeyError(key)

    @property
    def keys(self) -> list[str]:
        return [c.key for c in self.columns]


PARTY_NAME = "(SELECT legal_name FROM iam.party WHERE id = {})"
CITY_OF_STATION = "(SELECT c.code FROM net.station s JOIN ref.city c ON c.id = s.city_id WHERE s.id = {})"
ALL = frozenset({"PLATFORM", "OPERATOR", "AGENCY"})
STAFF = frozenset({"PLATFORM", "OPERATOR"})
PLATFORM = frozenset({"PLATFORM"})

# Trip end points from the first and last stop (every trip has stops; not every trip has a carrier route)
TRIP_ENDS = """
  LEFT JOIN LATERAL (SELECT c.code AS city, s.name AS station FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                       LEFT JOIN ref.city c ON c.id = s.city_id WHERE ts.trip_id = t.id ORDER BY ts.seq LIMIT 1) o ON true
  LEFT JOIN LATERAL (SELECT c.code AS city, s.name AS station FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                       LEFT JOIN ref.city c ON c.id = s.city_id WHERE ts.trip_id = t.id ORDER BY ts.seq DESC LIMIT 1) d ON true"""

DATASETS: dict[str, Dataset] = {}


def _add(ds: Dataset) -> None:
    DATASETS[ds.key] = ds


# ------------------------------------------------------------------ sales
_add(Dataset(
    "bookings", "sales",
    f"sales.booking b JOIN ops.trip t ON t.id = b.trip_id {TRIP_ENDS}",
    (
        Col("booking_ref", "b.booking_ref", group=False),
        Col("created_at", "b.created_at", TIME, group=False),
        Col("created_date", "(b.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("created_month", "to_char(b.created_at AT TIME ZONE __TZ__, 'YYYY-MM')"),
        Col("status", "b.status", values="booking_status"),
        Col("carrier", PARTY_NAME.format("b.company_id")),
        Col("trip_no", "t.trip_no"),
        Col("departure_date", "(t.departure_at AT TIME ZONE __TZ__)::date", DATE),
        Col("origin_city", "o.city", values="cities"),
        Col("dest_city", "d.city", values="cities"),
        Col("channel", "CASE WHEN b.agency_id IS NOT NULL THEN 'AGENCY' WHEN b.channel_id IS NOT NULL THEN 'CHANNEL' ELSE 'DIRECT' END",
            values="channel"),
        Col("agency", PARTY_NAME.format("b.agency_id")),
        Col("pay_method", "b.pay_method", values="pay_method"),
        Col("passengers", "(SELECT count(*) FROM sales.ticket k WHERE k.booking_id = b.id)", INT, group=False, agg=True),
        Col("fares", "coalesce((b.price_breakdown ->> 'fares_total')::bigint, b.total_amount)", MONEY, group=False, agg=True),
        Col("platform_fee", "coalesce((b.price_breakdown ->> 'platform_fee')::bigint, 0)", MONEY, group=False, agg=True),
        Col("total_amount", "b.total_amount", MONEY, group=False, agg=True),
        Col("cancelled_at", "b.cancelled_at", TIME, group=False),
        Col("cancel_reason", "b.cancel_reason"),
        Col("contact_mobile", "b.contact_mobile", group=False, personal=True),
    ),
    ALL, "created_date", company_sql="b.company_id", agency_sql="b.agency_id", default_sort=("created_at", "desc")))

_add(Dataset(
    "tickets", "sales",
    """sales.ticket k JOIN sales.booking b ON b.id = k.booking_id JOIN ops.trip t ON t.id = k.trip_id
        JOIN sales.passenger p ON p.id = k.passenger_id
        LEFT JOIN LATERAL (SELECT s.name FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                           WHERE ts.trip_id = k.trip_id AND ts.seq = k.from_seq) fs ON true
        LEFT JOIN LATERAL (SELECT s.name FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                           WHERE ts.trip_id = k.trip_id AND ts.seq = k.to_seq) tsx ON true""",
    (
        Col("ticket_no", "k.ticket_no", group=False),
        Col("booking_ref", "b.booking_ref", group=False),
        Col("created_date", "(k.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("status", "k.status", values="ticket_status"),
        Col("carrier", PARTY_NAME.format("t.company_id")),
        Col("trip_no", "t.trip_no"),
        Col("departure_date", "(t.departure_at AT TIME ZONE __TZ__)::date", DATE),
        Col("from_station", "fs.name"),
        Col("to_station", "tsx.name"),
        Col("fare_brand", "k.fare_brand_code"),
        Col("seat_no", "k.seat_no", INT, group=False),
        Col("passenger", "coalesce(nullif(concat_ws(' ', p.first_name, p.last_name), ''), p.full_name)", group=False, personal=True),
        Col("nationality", "p.nationality", values="countries"),
        Col("travel_category", "k.travel_category", values="travel_category"),
        Col("total_amount", "k.total_amount", MONEY, group=False, agg=True),
        Col("boarded_at", "k.boarded_at", TIME, group=False),
    ),
    ALL, "created_date", company_sql="t.company_id", agency_sql="b.agency_id", default_sort=("created_date", "desc")))

# ------------------------------------------------------------------ operations
_add(Dataset(
    "trips", "operations",
    f"""ops.trip t {TRIP_ENDS}
        LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id
        LEFT JOIN LATERAL (SELECT count(*) FILTER (WHERE k.status IN ('ISSUED','BOARDED')) AS sold,
                                  count(*) FILTER (WHERE k.status = 'BOARDED') AS boarded,
                                  coalesce(sum(k.total_amount) FILTER (WHERE k.status IN ('ISSUED','BOARDED')), 0) AS revenue
                             FROM sales.ticket k WHERE k.trip_id = t.id) s ON true
        LEFT JOIN LATERAL (SELECT round(extract(epoch FROM (ts.actual_dep - ts.sched_dep)) / 60) AS delay
                             FROM ops.trip_stop ts WHERE ts.trip_id = t.id ORDER BY ts.seq LIMIT 1) dl ON true""",
    (
        Col("trip_no", "t.trip_no", group=False),
        Col("departure_date", "(t.departure_at AT TIME ZONE __TZ__)::date", DATE),
        Col("departure_at", "t.departure_at", TIME, group=False),
        Col("status", "t.status", values="trip_status"),
        Col("carrier", PARTY_NAME.format("t.company_id")),
        Col("origin_city", "o.city", values="cities"),
        Col("dest_city", "d.city", values="cities"),
        Col("trip_type", "t.trip_type", values="trip_type"),
        Col("vehicle", "v.plate_no"),
        Col("seats_total", "t.seats_total", INT, group=False, agg=True),
        Col("seats_sold", "s.sold", INT, group=False, agg=True),
        Col("boarded", "s.boarded", INT, group=False, agg=True),
        Col("load_factor", "CASE WHEN t.seats_total > 0 THEN round(100.0 * s.sold / t.seats_total, 1) END", PCT, group=False,
            filter=True),
        Col("revenue", "s.revenue", MONEY, group=False, agg=True),
        Col("departure_delay_min", "dl.delay", INT, group=False, agg=True),
    ),
    STAFF, "departure_date", company_sql="t.company_id", default_sort=("departure_at", "desc")))

_add(Dataset(
    "incidents", "operations",
    "ops.incident i LEFT JOIN fleet.vehicle v ON v.id = i.vehicle_id LEFT JOIN ops.trip t ON t.id = i.trip_id",
    (
        Col("occurred_at", "i.occurred_at", TIME, group=False),
        Col("occurred_date", "(i.occurred_at AT TIME ZONE __TZ__)::date", DATE),
        Col("type", "i.type", values="incident_type"),
        Col("severity", "i.severity", values="severity"),
        Col("injuries", "i.injuries", BOOL),
        Col("status", "i.status", values="incident_status"),
        Col("carrier", PARTY_NAME.format("i.company_id")),
        Col("vehicle", "v.plate_no"),
        Col("trip_no", "t.trip_no"),
        Col("police_report_no", "i.police_report_no", group=False),
    ),
    STAFF, "occurred_date", company_sql="i.company_id", default_sort=("occurred_at", "desc")))

# ------------------------------------------------------------------ finance
_add(Dataset(
    "wallet_movements", "finance",
    "fin.ledger_entry e JOIN fin.ledger_txn x ON x.id = e.txn_id JOIN fin.wallet w ON w.id = e.wallet_id",
    (
        Col("created_at", "e.created_at", TIME, group=False),
        Col("created_date", "(e.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("created_month", "to_char(e.created_at AT TIME ZONE __TZ__, 'YYYY-MM')"),
        Col("txn_type", "x.txn_type", values="txn_type"),
        Col("direction", "e.direction", values="direction"),
        Col("wallet_type", "w.wallet_type", values="wallet_type"),
        Col("wallet_owner", f"coalesce({PARTY_NAME.format('w.company_id')}, {PARTY_NAME.format('w.owner_party_id')}, w.label)",
            personal=True),
        Col("credit", "CASE WHEN e.direction = 'CR' THEN e.amount ELSE 0 END", MONEY, group=False, agg=True),
        Col("debit", "CASE WHEN e.direction = 'DR' THEN e.amount ELSE 0 END", MONEY, group=False, agg=True),
        Col("balance_after", "e.balance_after", MONEY, group=False),
        Col("reference", "x.memo", group=False),
    ),
    ALL, "created_date", company_sql="w.company_id", agency_sql="w.company_id", default_sort=("created_at", "desc")))

_add(Dataset(
    "payments", "finance",
    "fin.payment y LEFT JOIN fin.payment_provider pv ON pv.id = y.provider_id",
    (
        Col("created_at", "y.created_at", TIME, group=False),
        Col("created_date", "(y.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("purpose", "y.purpose", values="payment_purpose"),
        Col("provider", "pv.code"),
        Col("method", "y.method", values="pay_method"),
        Col("status", "y.status", values="payment_status"),
        Col("amount", "y.amount", MONEY, group=False, agg=True),
        Col("fee", "y.fee", MONEY, group=False, agg=True),
        Col("provider_ref", "y.provider_ref", group=False),
        Col("card_last4", "y.card_last4", group=False, personal=True),
        Col("settled_at", "y.settled_at", TIME, group=False),
    ),
    PLATFORM, "created_date", default_sort=("created_at", "desc")))

_add(Dataset(
    "settlements", "finance",
    "fin.settlement_batch sb",
    (
        Col("company", PARTY_NAME.format("sb.company_id")),
        Col("period_from", "lower(sb.period)", DATE),
        Col("period_to", "upper(sb.period) - 1", DATE),
        Col("status", "sb.status", values="settlement_status"),
        Col("gross", "sb.gross", MONEY, group=False, agg=True),
        Col("commission", "sb.commission", MONEY, group=False, agg=True),
        Col("tax", "sb.tax", MONEY, group=False, agg=True),
        Col("refunds", "sb.refunds", MONEY, group=False, agg=True),
        Col("net", "sb.net", MONEY, group=False, agg=True),
        Col("created_date", "(sb.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("approved_at", "sb.approved_at", TIME, group=False),
    ),
    STAFF, "created_date", company_sql="sb.company_id", default_sort=("created_date", "desc")))

_add(Dataset(
    "withdrawals", "finance",
    "fin.withdrawal_request wr",
    (
        Col("created_at", "wr.created_at", TIME, group=False),
        Col("created_date", "(wr.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("company", PARTY_NAME.format("wr.company_id")),
        Col("status", "wr.status", values="withdrawal_status"),
        Col("amount", "wr.amount", MONEY, group=False, agg=True),
        Col("needs_second", "wr.needs_second", BOOL),
        Col("decided_at", "wr.decided_at", TIME, group=False),
        Col("paid_at", "wr.paid_at", TIME, group=False),
        Col("bank_ref", "wr.bank_ref", group=False),
    ),
    ALL, "created_date", company_sql="wr.company_id", agency_sql="wr.company_id", default_sort=("created_at", "desc")))

_add(Dataset(
    "cash_aging", "finance",
    "fin.cash_aging() a",
    (
        Col("carrier", PARTY_NAME.format("a.company_id")),
        Col("owed", "a.owed", MONEY, group=False, agg=True),
        Col("credit_limit", "a.credit_limit", MONEY, group=False),
        Col("days_0_7", "a.days_0_7", MONEY, group=False, agg=True),
        Col("days_8_30", "a.days_8_30", MONEY, group=False, agg=True),
        Col("days_31_60", "a.days_31_60", MONEY, group=False, agg=True),
        Col("days_61_90", "a.days_61_90", MONEY, group=False, agg=True),
        Col("days_over_90", "a.days_over_90", MONEY, group=False, agg=True),
        Col("overdue", "a.overdue", MONEY, group=False, agg=True),
        Col("oldest_unpaid_date", "(a.oldest_unpaid_at AT TIME ZONE __TZ__)::date", DATE),
        Col("oldest_unpaid_days", "(now()::date - a.oldest_unpaid_at::date)", INT, group=False, agg=True),
    ),
    STAFF, "oldest_unpaid_date", company_sql="a.company_id", default_sort=("overdue", "desc")))

_add(Dataset(
    "invoices", "finance",
    "acct.sales_invoice si",
    (
        Col("invoice_no", "si.invoice_no", group=False),
        Col("issue_date", "si.issue_date", DATE),
        Col("issue_month", "to_char(si.issue_date, 'YYYY-MM')"),
        Col("due_date", "si.due_date", DATE),
        Col("company", PARTY_NAME.format("si.company_id")),
        Col("customer", PARTY_NAME.format("si.customer_party_id"), personal=True),
        Col("status", "si.status", values="invoice_status"),
        Col("subtotal", "si.subtotal", MONEY, group=False, agg=True),
        Col("tax", "si.tax", MONEY, group=False, agg=True),
        Col("total", "si.total", MONEY, group=False, agg=True),
    ),
    STAFF, "issue_date", company_sql="si.company_id", default_sort=("issue_date", "desc")))

# ------------------------------------------------------------------ shipping and services
_add(Dataset(
    "shipments", "shipping",
    "ship.shipment sh LEFT JOIN ship.service_product sp ON sp.id = sh.service_id",
    (
        Col("tracking_no", "sh.tracking_no", group=False),
        Col("created_date", "(sh.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("created_month", "to_char(sh.created_at AT TIME ZONE __TZ__, 'YYYY-MM')"),
        Col("status", "sh.status", values="shipment_status"),
        Col("carrier", PARTY_NAME.format("sh.company_id")),
        Col("service", "sp.name"),
        Col("origin_city", CITY_OF_STATION.format("sh.origin_station_id"), values="cities"),
        Col("dest_city", CITY_OF_STATION.format("sh.dest_station_id"), values="cities"),
        Col("cargo_category", "sh.cargo_category", values="cargo_category"),
        Col("weight_kg", "sh.billable_weight_kg", NUM, group=False, agg=True),
        Col("declared_value", "sh.declared_value", MONEY, group=False, agg=True),
        Col("cod_amount", "sh.cod_amount", MONEY, group=False, agg=True),
        Col("price", "coalesce((sh.price_breakdown ->> 'total')::bigint, 0)", MONEY, group=False, agg=True),
        Col("recipient", "sh.recipient_name", group=False, personal=True),
    ),
    STAFF, "created_date", company_sql="sh.company_id", default_sort=("created_date", "desc")))

_add(Dataset(
    "subscriptions", "services",
    "sales.subscription su LEFT JOIN sales.subscription_plan pl ON pl.id = su.plan_id",
    (
        Col("created_date", "(su.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("plan", "pl.name"),
        Col("operator", PARTY_NAME.format("su.company_id")),
        Col("status", "su.status", values="subscription_status"),
        Col("starts_on", "su.starts_on", DATE),
        Col("ends_on", "su.ends_on", DATE),
        Col("rides_used", "su.rides_used", INT, group=False, agg=True),
        Col("price_paid", "su.price_paid", MONEY, group=False, agg=True),
        Col("subscriber", PARTY_NAME.format("su.party_id"), group=False, personal=True),
    ),
    STAFF, "created_date", company_sql="su.company_id", default_sort=("created_date", "desc")))

_add(Dataset(
    "taxi_requests", "services",
    "taxi.ride_request tr LEFT JOIN ref.city c ON c.id = tr.city_id",
    (
        Col("created_at", "tr.created_at", TIME, group=False),
        Col("created_date", "(tr.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("city", "c.code", values="cities"),
        Col("kind", "tr.kind", values="taxi_kind"),
        Col("status", "tr.status", values="taxi_status"),
        Col("seats", "tr.seats", INT, group=False, agg=True),
        Col("fare_estimate", "tr.fare_estimate", MONEY, group=False, agg=True),
        Col("pickup", "tr.pickup_text", group=False, personal=True),
        Col("dropoff", "tr.dropoff_text", group=False, personal=True),
    ),
    PLATFORM, "created_date", default_sort=("created_at", "desc")))

_add(Dataset(
    "rentals", "services",
    "rent.rental_booking rb",
    (
        Col("created_date", "(rb.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("company", PARTY_NAME.format("rb.company_id")),
        Col("rental_class", "rb.rental_class"),
        Col("status", "rb.status", values="rental_status"),
        Col("pickup_at", "lower(rb.period)", TIME, group=False),
        Col("return_at", "upper(rb.period)", TIME, group=False),
        Col("days", "greatest(1, ceil(extract(epoch FROM (upper(rb.period) - lower(rb.period))) / 86400))::int", INT, group=False, agg=True),
        Col("quoted_total", "rb.quoted_total", MONEY, group=False, agg=True),
        Col("renter", PARTY_NAME.format("rb.renter_party_id"), group=False, personal=True),
    ),
    STAFF, "created_date", company_sql="rb.company_id", default_sort=("created_date", "desc")))

_add(Dataset(
    "freight", "services",
    """frt.freight_request fr
       LEFT JOIN LATERAL (SELECT count(*) AS bids, min(price) AS best FROM frt.freight_bid fb WHERE fb.request_id = fr.id) bd ON true""",
    (
        Col("created_date", "(fr.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("shipper", f"coalesce({PARTY_NAME.format('fr.shipper_company_id')}, {PARTY_NAME.format('fr.shipper_party_id')})", personal=True),
        Col("origin_city", CITY_OF_STATION.format("fr.origin_station_id"), values="cities"),
        Col("dest_city", CITY_OF_STATION.format("fr.dest_station_id"), values="cities"),
        Col("cargo_category", "fr.cargo_category", values="cargo_category"),
        Col("status", "fr.status", values="freight_status"),
        Col("weight_kg", "fr.declared_weight_kg", NUM, group=False, agg=True),
        Col("target_price", "fr.target_price", MONEY, group=False, agg=True),
        Col("bids", "bd.bids", INT, group=False, agg=True),
        Col("best_bid", "bd.best", MONEY, group=False, agg=True),
    ),
    PLATFORM, "created_date", default_sort=("created_date", "desc")))

# ------------------------------------------------------------------ fleet and compliance
_add(Dataset(
    "vehicles", "fleet",
    "fleet.vehicle v",
    (
        Col("plate_no", "v.plate_no", group=False),
        Col("carrier", PARTY_NAME.format("v.company_id")),
        Col("vehicle_class", "v.vehicle_class", values="vehicle_class"),
        Col("vehicle_type", "v.vehicle_type"),
        Col("make", "v.make"),
        Col("model", "v.model"),
        Col("manufacture_year", "v.manufacture_year", INT),
        Col("passenger_seats", "v.passenger_seats", INT, group=False, agg=True),
        Col("status", "v.status", values="vehicle_status"),
        Col("created_date", "(v.created_at AT TIME ZONE __TZ__)::date", DATE),
    ),
    STAFF, "created_date", company_sql="v.company_id", default_sort=("plate_no", "asc")))

_add(Dataset(
    "documents", "fleet",
    "iam.document dc",
    (
        Col("company", PARTY_NAME.format("dc.company_id")),
        Col("owner_type", "dc.owner_type", values="owner_type"),
        Col("doc_type", "dc.doc_type", values="doc_type"),
        Col("issuer", "dc.issuer"),
        Col("status", "dc.status", values="document_status"),
        Col("issue_date", "dc.issue_date", DATE),
        Col("expiry_date", "dc.expiry_date", DATE),
        Col("days_left", "dc.expiry_date - current_date", INT, group=False),
        Col("created_date", "(dc.created_at AT TIME ZONE __TZ__)::date", DATE),
    ),
    STAFF, "created_date", company_sql="dc.company_id", default_sort=("expiry_date", "asc")))

_add(Dataset(
    "travel_documents", "international",
    """sales.ticket_doc td JOIN sales.ticket k ON k.id = td.ticket_id JOIN ops.trip t ON t.id = k.trip_id
       JOIN sales.passenger p ON p.id = k.passenger_id""",
    (
        Col("departure_date", "(t.departure_at AT TIME ZONE __TZ__)::date", DATE),
        Col("carrier", PARTY_NAME.format("t.company_id")),
        Col("trip_no", "t.trip_no"),
        Col("dest_country", "td.dest_country", values="countries"),
        Col("nationality", "p.nationality", values="countries"),
        Col("doc_type", "coalesce(td.doc_type, p.id_type)", values="travel_doc"),
        Col("exception", "td.exception", BOOL),
        Col("status", "td.status", values="doc_check_status"),
        Col("passport_expiry", "td.passport_expiry", DATE, group=False),
        Col("ticket_no", "k.ticket_no", group=False),
        Col("passenger", "coalesce(nullif(concat_ws(' ', p.first_name, p.last_name), ''), p.full_name)", group=False, personal=True),
    ),
    STAFF, "departure_date", company_sql="t.company_id", default_sort=("departure_date", "desc")))

# ------------------------------------------------------------------ platform
_add(Dataset(
    "companies", "platform",
    "iam.company co JOIN iam.party pa ON pa.id = co.id",
    (
        Col("name", "pa.legal_name", group=False),
        Col("company_type", "co.company_type", values="company_type"),
        Col("approval_status", "co.approval_status", values="approval_status"),
        Col("cr_no", "co.cr_no", group=False),
        Col("cr_expiry", "co.cr_expiry", DATE),
        Col("settlement_cycle", "co.settlement_cycle"),
        Col("created_date", "(co.created_at AT TIME ZONE __TZ__)::date", DATE),
        Col("approved_at", "co.approved_at", TIME, group=False),
    ),
    PLATFORM, "created_date", default_sort=("created_date", "desc")))

_add(Dataset(
    "sign_ins", "security",
    "audit.auth_event ae",
    (
        Col("ts", "ae.ts", TIME, group=False),
        Col("date", "(ae.ts AT TIME ZONE __TZ__)::date", DATE),
        Col("event", "ae.event"),
        Col("portal", "ae.portal", values="portal"),
        Col("result", "ae.result"),
        Col("reason", "ae.reason"),
        Col("ip", "host(ae.ip)", personal=True),
        Col("country", "ae.country_code", values="countries"),
    ),
    PLATFORM, "date", permission="audit.view", default_sort=("ts", "desc"), reader="audit"))
