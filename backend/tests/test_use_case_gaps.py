"""The gaps found by the review of the use cases (October 2026), end to end: the platform opens tracking alerts on its
own (1100)."""
import pytest

from test_e2e import OWNER_URL, login, owner_sql, publish_fresh_trip
from test_notifications import run_worker


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_silent_departed_trip_alerts_the_carrier():
    publish_fresh_trip()
    o = login("owner@carrier.test", "OPERATOR")
    trip = owner_sql("""SELECT t.id, t.trip_no FROM ops.trip t JOIN iam.company_member m ON m.company_id = t.company_id
                         JOIN iam.app_user u ON u.id = m.user_id
                        WHERE u.email = 'owner@carrier.test' AND t.status = 'PUBLISHED'
                          AND NOT EXISTS (SELECT 1 FROM sales.ticket k WHERE k.trip_id = t.id)
                        ORDER BY t.id DESC LIMIT 1""", fetch=True)
    owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '10 minutes',
                 arrival_at = now() + interval '3 hours' WHERE id = $1""", trip["id"])
    try:
        run_worker()
        alert = owner_sql("""SELECT kind, severity FROM ops.tracking_alert WHERE trip_id = $1 AND status = 'OPEN'""", trip["id"], fetch=True)
        assert alert and alert["kind"] == "SIGNAL_LOST" and alert["severity"] == "MEDIUM"
        board = o.get("/api/carrier/dashboard").json()
        assert any(a["kind"] == "TRACKING_SIGNAL_LOST" and a["subject"] == trip["trip_no"] for a in board["alerts"])
        run_worker()                    # the next pass sends the notice and does not open a second alert
        assert owner_sql("SELECT count(*) FROM ops.tracking_alert WHERE trip_id = $1", trip["id"]) == 1
        told = o.get("/api/notifications").json()["notifications"]
        assert any(n["template_code"] == "tracking.signal_lost" and n["payload"].get("trip_no") == trip["trip_no"] for n in told)
    finally:
        owner_sql("UPDATE ops.tracking_alert SET status = 'RESOLVED', resolved_at = now() WHERE trip_id = $1 AND status = 'OPEN'", trip["id"])
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])
