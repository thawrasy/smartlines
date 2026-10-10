"""Re-audit of design 3.8 (1049): monitoring, report links, position devices, retries of money events."""
import os

import httpx
import pytest

from test_e2e import BASE, login, owner_sql

TOKEN = os.environ.get("MASSLAK_METRICS_TOKEN")


# ------------------------------------------------------------------ T3-16 metrics
@pytest.mark.skipif(not TOKEN, reason="needs MASSLAK_METRICS_TOKEN on the API and here")
def test_metrics_need_the_token_and_expose_slis_and_database_health():
    login("passenger@masslak.test", "PASSENGER").get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": "2030-01-01"})
    assert httpx.get(f"{BASE}/api/metrics").status_code == 401
    assert httpx.get(f"{BASE}/api/metrics", headers={"Authorization": "Bearer wrong"}).status_code == 401
    r = httpx.get(f"{BASE}/api/metrics", headers={"Authorization": f"Bearer {TOKEN}"})
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/plain")
    body = r.text
    assert 'masslak_http_requests_total{method="GET",route="/api/trips/search",group="search",status="2xx"}' in body
    assert 'masslak_http_request_duration_seconds_bucket{method="GET",route="/api/trips/search",group="search",le="0.1"}' in body
    for name in ("masslak_db_up 1", "masslak_outbox_oldest_pending_seconds", "masslak_wallet_mismatches", "masslak_geo_partitions_missing",
                 "masslak_db_wal_archive_last_success_age_seconds", "masslak_db_lock_waiters", "masslak_db_deadlocks_total",
                 "masslak_job_last_success_age_seconds", "masslak_files_pending_scan", "masslak_db_pool_size"):
        assert name in body, name
    # no personal data in the scrape: routes are templates, never concrete ids, e-mails or tokens
    import re
    assert not re.search(r"[\w.+-]+@[\w-]+\.[\w.]+", body)
    assert not re.search(r'route="[^"]*([0-9a-f]{8}-[0-9a-f]{4}|/\d+(/|"))', body)
    # job and instance are the scrape's own labels: a series carrying them is renamed (exported_job) and no rule finds it
    assert not re.search(r'[{,](job|instance)="', body)


# ------------------------------------------------------------------ T3-05 sensitive reports by link
def _last_email_to(addr: str) -> dict:
    import json
    from pathlib import Path
    from app.config import get_settings
    path = Path(get_settings().files_dir).resolve().parent / "messages" / "email.jsonl"
    found = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if f'"to": "{addr}"' in line]
    return found[-1]


@pytest.mark.skipif(not os.environ.get("MASSLAK_OWNER_URL"), reason="needs MASSLAK_OWNER_URL")
def test_a_sensitive_report_needs_consent_and_goes_by_a_personal_link():
    import subprocess
    import sys
    admin = login("admin@masslak.test", "PLATFORM")
    body = {"code": "sales.daily", "frequency": "DAILY", "format": "CSV", "locale": "en"}
    r = admin.post("/api/reports/schedules", json={**body, "recipients": ["admin@masslak.test"]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "REPORT_CONSENT_REQUIRED"
    # a sensitive report never goes to a whole domain, only to named accounts
    r = admin.post("/api/reports/schedules", json={**body, "recipients": ["ops@masslak.com"], "confirm_sensitive": True})
    assert r.status_code == 422 and r.json()["error"]["code"] == "REPORT_RECIPIENT_NOT_ALLOWED"
    r = admin.post("/api/reports/schedules", json={**body, "recipients": ["admin@masslak.test"], "confirm_sensitive": True})
    assert r.status_code == 201 and r.json()["sensitive"] is True, r.text
    uid = r.json()["uid"]
    assert owner_sql("SELECT consent_by IS NOT NULL AND consent_at IS NOT NULL FROM rpt.report_schedule WHERE uid = $1::uuid", uid)
    owner_sql("UPDATE rpt.report_schedule SET next_run_at = now() - interval '1 minute' WHERE uid = $1::uuid", uid)
    out = subprocess.run([sys.executable, "-m", "app.modules.notify.worker", "--once"], cwd=os.path.join(os.path.dirname(__file__), ".."),
                         capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr[-2000:]
    mail = _last_email_to("admin@masslak.test")
    assert "attachments" not in mail and "/api/reports/deliveries/" in mail["body"]
    token = mail["body"].split("/api/reports/deliveries/")[1].split()[0]
    # the recipient downloads it; the download is counted and logged
    got = admin.get(f"/api/reports/deliveries/{token}")
    assert got.status_code == 200 and got.headers["content-disposition"].startswith("attachment") and got.headers["cache-control"] == "no-store"
    row = owner_sql("""SELECT d.id, d.download_count FROM rpt.report_delivery d JOIN rpt.report_schedule s ON s.id = d.schedule_id
                        WHERE s.uid = $1::uuid""", uid, fetch=True)
    assert row["download_count"] == 1
    assert owner_sql("SELECT count(*) FROM audit.data_access_log WHERE object_type = 'report_delivery' AND object_id = $1", row["id"]) == 1
    # anybody else gets nothing, and the link expires
    assert login("security@masslak.test", "PLATFORM").get(f"/api/reports/deliveries/{token}").status_code == 404
    owner_sql("UPDATE rpt.report_delivery SET expires_at = now() - interval '1 minute' WHERE id = $1", row["id"])
    r = admin.get(f"/api/reports/deliveries/{token}")
    assert r.status_code == 410 and r.json()["error"]["code"] == "REPORT_LINK_EXPIRED"
    assert admin.delete(f"/api/reports/schedules/{uid}").status_code == 200


# ------------------------------------------------------------------ T3-11 positions from a registered device
def test_positions_carry_the_device_and_a_failed_attestation_rejects_them():
    import uuid as _uuid

    import test_e2e as e2e
    from test_mobile import bearer, mobile_login
    e2e.publish_fresh_trip()
    r, _ = mobile_login(e2e.FRESH_DRIVERS[-1], "DRIVER", e2e.FRESH_DRIVER_PASSWORD)
    assert r.status_code == 200, r.text
    d = bearer(r.json()["access_token"])
    trip = d.get("/api/driver/trips").json()["trips"][-1]["uid"]
    point = {"trip_uid": trip, "lat": 33.51, "lng": 36.29, "accuracy_m": 6, "provider": "GPS"}
    ev = str(_uuid.uuid4())
    assert d.post("/api/driver/location", json={**point, "event_id": ev, "seq": 1}).json()["trust"] == "HIGH"
    assert owner_sql("SELECT device_id IS NOT NULL FROM ops.geo_event WHERE event_id = $1::uuid", ev)
    r = d.post("/api/driver/device/attestation", json={"provider": "SIMULATED", "token": "tampered-device-0001"})
    assert r.status_code == 200 and r.json()["attestation"] == "FAILED"
    bad = d.post("/api/driver/location", json={**point, "event_id": str(_uuid.uuid4()), "seq": 2}).json()
    assert bad["trust"] == "REJECTED" and "DEVICE_FAILED" in bad["flags"]


# ------------------------------------------------------------------ T3-12 resending a money or authority event
@pytest.mark.skipif(not os.environ.get("MASSLAK_OWNER_URL"), reason="needs MASSLAK_OWNER_URL")
def test_resending_a_cancellation_waits_for_a_platform_approval():
    from test_integration import make_client
    owner, admin = login("owner@carrier.test", "OPERATOR"), login("admin@masslak.test", "PLATFORM")
    uid, _ = make_client(owner, admin, name="Refund listener", kind="CARRIER", scopes=["bookings:read", "webhooks:manage"])
    hook = owner.post(f"/api/integrations/clients/{uid}/webhooks", json={"url": "https://partner-t3.example/hook", "events": ["booking.cancelled"]})
    assert hook.status_code == 201, hook.text
    duid = owner_sql("""WITH ev AS (INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, status)
                                     VALUES ('booking.cancelled', 'booking', 1, '{}', 'PUBLISHED') RETURNING id)
                        INSERT INTO sys.webhook_delivery (endpoint_id, outbox_event_id, event_type, status, attempts)
                        SELECT e.id, ev.id, 'booking.cancelled', 'DEAD', 8 FROM sys.webhook_endpoint e, ev WHERE e.uid = $1::uuid
                        RETURNING delivery_uid::text""", hook.json()["uid"])
    r = owner.post(f"/api/integrations/clients/{uid}/deliveries/{duid}/retry")
    assert r.status_code == 200 and r.json()["status"] == "APPROVAL_PENDING", r.text
    assert owner_sql("SELECT status FROM sys.webhook_delivery WHERE delivery_uid = $1::uuid", duid) == "DEAD"
    req = next(x for x in admin.get("/api/admin/delivery-retries").json()["requests"] if x["delivery_uid"] == duid)
    assert owner.get("/api/admin/delivery-retries").status_code == 403
    r = admin.post(f"/api/admin/delivery-retries/{req['uid']}/decision", json={"approve": True, "note": "Partner lost the event"})
    assert r.status_code == 200 and r.json()["status"] == "APPROVED"
    assert owner_sql("SELECT status FROM sys.webhook_delivery WHERE delivery_uid = $1::uuid", duid) == "PENDING"


# ------------------------------------------------------------------ owner decision: time-bound external reviewers
@pytest.mark.skipif(not os.environ.get("MASSLAK_OWNER_URL"), reason="needs MASSLAK_OWNER_URL")
def test_external_reviewer_access_is_granted_by_a_second_person_and_ends():
    admin = login("admin@masslak.test", "PLATFORM")
    body = {"email": "regulator@masslak.test", "organisation": "Independent test lab", "purpose": "Penetration test of the API and portals",
            "engagement_ref": "PT-2026-01"}
    r = admin.post("/api/admin/external-access", json={**body, "days": 45})
    assert r.status_code == 409 and r.json()["error"]["code"] == "EXTERNAL_ACCESS_TOO_LONG"
    r = admin.post("/api/admin/external-access", json={**body, "days": 14})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert owner_sql("""SELECT ur.valid_to IS NOT NULL AND ur.valid_to < now() + interval '15 days' FROM iam.user_role ur
                         JOIN iam.role r ON r.id = ur.role_id JOIN iam.app_user u ON u.id = ur.user_id
                        WHERE r.code = 'EXTERNAL_AUDITOR' AND u.email = 'regulator@masslak.test'""")
    listed = next(g for g in admin.get("/api/admin/external-access").json()["grants"] if g["uid"] == uid)
    assert listed["active"] and listed["granted_by"] == "admin@masslak.test"
    assert login("owner@carrier.test", "OPERATOR").get("/api/admin/external-access").status_code == 403
    assert admin.post(f"/api/admin/external-access/{uid}/revoke").json()["revoked"] is True
    assert owner_sql("""SELECT ur.valid_to <= now() FROM iam.user_role ur JOIN iam.role r ON r.id = ur.role_id
                         JOIN iam.app_user u ON u.id = ur.user_id WHERE r.code = 'EXTERNAL_AUDITOR' AND u.email = 'regulator@masslak.test'""")
