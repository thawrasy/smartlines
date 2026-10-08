"""The report catalog: ready-made reports on the datasets, by area.

Each report is a dataset with a spec (columns or grouping and totals, fixed filters, order). Users can open any
report as the starting point of a custom one. Titles and descriptions live in backend/app/i18n (reports.titles).
"""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Report:
    code: str
    dataset: str
    spec: dict
    aggregate: bool = False                  # grouped report: no personal data, open to the regulator
    portals: frozenset = field(default=frozenset())   # empty: every portal the dataset allows
    chart: str = ""                          # bar or line over the first group column, for the screen
    period: bool = True                      # filtered by a date period (inventories and registers are not)


def g(group: list, totals: list, filters: list = None, sort: list = None) -> dict:
    return {"group_by": group, "totals": totals, "filters": filters or [], "sort": sort or [[group[0], "asc"]]}


def ls(columns: list, filters: list = None, sort: list = None) -> dict:
    return {"columns": columns, "filters": filters or [], "sort": sort or []}


CONFIRMED = [["status", "in", ["CONFIRMED", "COMPLETED"]]]
P, A = "PLATFORM", "AGENCY"

REPORTS: list[Report] = [
    # ------------------------------------------------------------ sales
    Report("sales.daily", "bookings", g(["created_date"], [["count", "*"], ["sum", "passengers"], ["sum", "total_amount"]], CONFIRMED),
           aggregate=True, chart="line"),
    Report("sales.monthly", "bookings", g(["created_month"], [["count", "*"], ["sum", "passengers"], ["sum", "fares"],
                                                              ["sum", "platform_fee"], ["sum", "total_amount"]], CONFIRMED),
           aggregate=True, chart="bar"),
    Report("sales.by_carrier", "bookings", g(["carrier"], [["count", "*"], ["sum", "passengers"], ["sum", "total_amount"]], CONFIRMED,
                                             [["sum__total_amount", "desc"]]), aggregate=True, portals=frozenset({P}), chart="bar"),
    Report("sales.by_route", "bookings", g(["origin_city", "dest_city"], [["count", "*"], ["sum", "passengers"], ["sum", "total_amount"]],
                                           CONFIRMED, [["sum__passengers", "desc"]]), aggregate=True, chart="bar"),
    Report("sales.by_channel", "bookings", g(["channel"], [["count", "*"], ["sum", "total_amount"]], CONFIRMED), aggregate=True,
           chart="bar"),
    Report("sales.bookings", "bookings", ls(["booking_ref", "created_at", "status", "carrier", "trip_no", "origin_city", "dest_city",
                                             "channel", "passengers", "total_amount"], sort=[["created_at", "desc"]])),
    Report("sales.cancellations", "bookings", ls(["booking_ref", "cancelled_at", "carrier", "trip_no", "passengers", "total_amount",
                                                  "cancel_reason"], [["status", "eq", "CANCELLED"]],
                                                 [["cancelled_at", "desc"]])),
    Report("sales.agency", "bookings", ls(["booking_ref", "created_at", "agency", "carrier", "trip_no", "passengers", "total_amount",
                                           "status"], [["channel", "eq", "AGENCY"]], [["created_at", "desc"]]),
           portals=frozenset({P, A})),
    Report("sales.by_agency", "bookings", g(["agency"], [["count", "*"], ["sum", "passengers"], ["sum", "total_amount"]],
                                            CONFIRMED + [["channel", "eq", "AGENCY"]], [["sum__total_amount", "desc"]]),
           aggregate=True, portals=frozenset({P}), chart="bar"),
    Report("sales.tickets", "tickets", ls(["ticket_no", "booking_ref", "status", "trip_no", "departure_date", "from_station",
                                           "to_station", "fare_brand", "seat_no", "passenger", "total_amount"],
                                          sort=[["departure_date", "desc"]])),
    Report("sales.by_fare_brand", "tickets", g(["fare_brand"], [["count", "*"], ["sum", "total_amount"]],
                                               [["status", "in", ["ISSUED", "BOARDED"]]]), aggregate=True, chart="bar"),
    # ------------------------------------------------------------ operations
    Report("ops.load_factor", "trips", ls(["trip_no", "departure_at", "carrier", "origin_city", "dest_city", "vehicle", "seats_total",
                                           "seats_sold", "boarded", "load_factor", "revenue"], sort=[["departure_at", "desc"]])),
    Report("ops.by_route", "trips", g(["origin_city", "dest_city"], [["count", "*"], ["sum", "seats_total"], ["sum", "seats_sold"],
                                                                     ["sum", "revenue"]], sort=[["sum__seats_sold", "desc"]]),
           aggregate=True, chart="bar"),
    Report("ops.punctuality", "trips", g(["carrier"], [["count", "*"], ["avg", "departure_delay_min"], ["max", "departure_delay_min"]],
                                         [["status", "in", ["DEPARTED", "COMPLETED"]]]), aggregate=True,
           portals=frozenset({P}), chart="bar"),
    Report("ops.trips_by_status", "trips", g(["status"], [["count", "*"], ["sum", "seats_sold"]]), aggregate=True, chart="bar"),
    Report("ops.incidents", "incidents", ls(["occurred_at", "type", "severity", "injuries", "status", "carrier", "vehicle", "trip_no",
                                             "police_report_no"], sort=[["occurred_at", "desc"]])),
    Report("ops.incidents_by_type", "incidents", g(["type", "severity"], [["count", "*"]]), aggregate=True, chart="bar"),
    # ------------------------------------------------------------ finance
    Report("fin.wallet_movements", "wallet_movements", ls(["created_at", "txn_type", "wallet_type", "wallet_owner", "credit", "debit",
                                                           "balance_after", "reference"], sort=[["created_at", "desc"]])),
    Report("fin.movements_by_type", "wallet_movements", g(["txn_type"], [["count", "*"], ["sum", "credit"], ["sum", "debit"]]),
           aggregate=True, chart="bar"),
    Report("fin.topups", "payments", g(["created_date", "method"], [["count", "*"], ["sum", "amount"], ["sum", "fee"]],
                                       [["purpose", "eq", "TOPUP"], ["status", "eq", "SUCCESS"]]), aggregate=True, chart="line"),
    Report("fin.payments", "payments", ls(["created_at", "purpose", "provider", "method", "status", "amount", "fee", "provider_ref"],
                                          sort=[["created_at", "desc"]])),
    Report("fin.settlements", "settlements", ls(["company", "period_from", "period_to", "status", "gross", "commission", "tax", "refunds",
                                                 "net", "approved_at"], sort=[["period_from", "desc"]])),
    Report("fin.withdrawals", "withdrawals", ls(["created_at", "company", "status", "amount", "decided_at", "paid_at", "bank_ref"],
                                                sort=[["created_at", "desc"]])),
    Report("fin.cash_aging", "cash_aging", ls(["carrier", "owed", "credit_limit", "days_0_7", "days_8_30", "days_31_60", "days_61_90",
                                               "days_over_90", "overdue", "oldest_unpaid_date"], sort=[["overdue", "desc"]]),
           period=False),
    Report("fin.invoices", "invoices", ls(["invoice_no", "issue_date", "due_date", "company", "customer", "status", "subtotal", "tax",
                                           "total"], sort=[["issue_date", "desc"]])),
    Report("fin.invoices_monthly", "invoices", g(["issue_month"], [["count", "*"], ["sum", "subtotal"], ["sum", "tax"], ["sum", "total"]]),
           aggregate=True, chart="bar"),
    # ------------------------------------------------------------ shipping and services
    Report("ship.shipments", "shipments", ls(["tracking_no", "created_date", "status", "carrier", "service", "origin_city", "dest_city",
                                              "weight_kg", "price"], sort=[["created_date", "desc"]])),
    Report("ship.by_status", "shipments", g(["status"], [["count", "*"], ["sum", "weight_kg"], ["sum", "price"]]), aggregate=True,
           chart="bar"),
    Report("ship.by_route", "shipments", g(["origin_city", "dest_city"], [["count", "*"], ["sum", "price"]],
                                           sort=[["count__*", "desc"]]), aggregate=True, chart="bar"),
    Report("svc.subscriptions", "subscriptions", g(["plan", "status"], [["count", "*"], ["sum", "rides_used"], ["sum", "price_paid"]]),
           aggregate=True, chart="bar"),
    Report("svc.taxi", "taxi_requests", g(["city", "status"], [["count", "*"], ["sum", "fare_estimate"]]), aggregate=True, chart="bar"),
    Report("svc.rentals", "rentals", ls(["created_date", "company", "rental_class", "status", "pickup_at", "return_at", "days",
                                         "quoted_total"], sort=[["created_date", "desc"]])),
    Report("svc.freight", "freight", ls(["created_date", "origin_city", "dest_city", "cargo_category", "status", "weight_kg",
                                         "target_price", "bids", "best_bid"], sort=[["created_date", "desc"]])),
    # ------------------------------------------------------------ fleet, compliance and international
    Report("fleet.vehicles", "vehicles", ls(["plate_no", "carrier", "vehicle_class", "make", "model", "manufacture_year",
                                             "passenger_seats", "status"], sort=[["plate_no", "asc"]]), period=False),
    Report("fleet.expiring_documents", "documents", ls(["company", "owner_type", "doc_type", "issuer", "status", "expiry_date",
                                                        "days_left"], [["days_left", "lte", 60]], [["expiry_date", "asc"]]), period=False),
    Report("intl.travel_documents", "travel_documents", g(["dest_country", "doc_type"], [["count", "*"]],
                                                          sort=[["count__*", "desc"]]), aggregate=True, chart="bar"),
    Report("intl.exceptions", "travel_documents", ls(["departure_date", "carrier", "trip_no", "dest_country", "nationality", "doc_type",
                                                      "status", "passenger"], [["exception", "eq", True]],
                                                     [["departure_date", "desc"]])),
    # ------------------------------------------------------------ platform and security
    Report("plat.companies", "companies", ls(["name", "company_type", "approval_status", "cr_no", "cr_expiry", "created_date"],
                                             sort=[["created_date", "desc"]]), period=False),
    Report("sec.failed_sign_ins", "sign_ins", g(["date", "portal"], [["count", "*"]], [["result", "ne", "SUCCESS"]],
                                                [["date", "desc"]]), chart="line"),
]

BY_CODE = {r.code: r for r in REPORTS}
CATEGORY_OF = {"sales": "sales", "ops": "operations", "fin": "finance", "ship": "shipping", "svc": "services", "fleet": "fleet",
               "intl": "international", "plat": "platform", "sec": "security"}
