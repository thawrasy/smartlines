"""Regulator dashboard: aggregated, read-only indicators. Every view is recorded in the activity log."""
from fastapi import APIRouter, Depends, Request

from .. import db
from ..deps import Principal, context_for, require_permission
from ..util import row_dict, rows

router = APIRouter(prefix="/api/regulator", tags=["regulator"])
can_view = require_permission("regulator.dashboard", "report.platform")


@router.get("/dashboard")
async def dashboard(request: Request, pr: Principal = Depends(can_view)):
    async with db.transaction(context_for(request, pr)) as conn:
        k = await conn.fetchrow(
            """SELECT
                 (SELECT count(*) FROM iam.company WHERE approval_status = 'APPROVED') AS carriers,
                 (SELECT count(*) FROM iam.company WHERE approval_status = 'PENDING') AS carriers_pending,
                 (SELECT count(*) FROM fleet.vehicle WHERE status = 'BLOCKED') AS blocked_vehicles,
                 (SELECT count(*) FROM ops.tracking_alert WHERE status = 'OPEN') AS open_alerts,
                 (SELECT count(*) FROM crm."case" WHERE status NOT IN ('RESOLVED','CLOSED','REJECTED')) AS open_cases,
                 (SELECT coalesce(sum(balance), 0) FROM fin.wallet WHERE wallet_type = 'USER') AS customer_funds,
                 -- escrow is a shared (DEFERRED) wallet: its stored balance leaves out entries not yet rolled up
                 (SELECT coalesce(sum(fin.wallet_balance(id)), 0) FROM fin.wallet WHERE wallet_type = 'ESCROW') AS escrow_funds""")
        otp = await conn.fetchrow(
            """SELECT count(*) FILTER (WHERE delay_min <= 10) AS on_time, count(*) AS total
                 FROM ops.trip_stop_event WHERE kind = 'DEPART' AND ts > now() - interval '30 days'""")
        lines = await conn.fetch(
            """SELECT ca.code AS origin_city, cb.code AS dest_city, count(DISTINCT t.company_id) AS carriers,
                      count(*) AS trips_7d,
                      (SELECT count(*) FROM sales.ticket k JOIN ops.trip tt ON tt.id = k.trip_id
                         WHERE tt.route_id = ANY(array_agg(t.route_id)) AND k.status <> 'CANCELLED') AS tickets
                 FROM ops.trip t JOIN net.route r ON r.id = t.route_id
                 JOIN net.station sa ON sa.id = r.origin_station_id JOIN ref.city ca ON ca.id = sa.city_id
                 JOIN net.station sb ON sb.id = r.dest_station_id JOIN ref.city cb ON cb.id = sb.city_id
                WHERE t.departure_at > now() - interval '7 days' AND t.status <> 'CANCELLED'
                GROUP BY ca.code, cb.code ORDER BY trips_7d DESC LIMIT 20""")
    request.state.audit = {"action": "regulator.dashboard.view"}
    on_time_pct = round(100 * otp["on_time"] / otp["total"]) if otp["total"] else None
    return {**row_dict(k), "on_time_pct": on_time_pct, "lines": rows(lines)}
