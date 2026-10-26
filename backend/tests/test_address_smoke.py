"""Addresses no other test names (the comprehensive review before release 1.52.0): each is called by the portal that owns
it, with a value that names nothing or an empty body, and must answer without a server error. A refusal, a missing
object or an invalid body is a correct answer here; the behaviour itself is covered where the feature is tested."""
import uuid

import pytest

from test_e2e import OWNER_URL, login

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

U = str(uuid.uuid4())
ADDRESSES = [
    ("PLATFORM", "GET", "/api/admin/violations/review"), ("PLATFORM", "POST", f"/api/admin/violations/{U}/review"),
    ("PLATFORM", "POST", "/api/security/shield/alerts/999999999/acknowledge"), ("PLATFORM", "GET", "/api/admin/payments/recent"),
    ("PLATFORM", "PUT", f"/api/admin/payments/fee-rules/{U}"), ("PLATFORM", "POST", f"/api/admin/boarding/operator-grants/{U}/revoke"),
    ("PLATFORM", "GET", "/api/admin/manifests"), ("PLATFORM", "POST", f"/api/admin/manifests/deliveries/{U}/done"),
    ("PLATFORM", "POST", "/api/admin/loyalty/vouchers/accept"), ("PLATFORM", "PUT", "/api/admin/miles/tiers/NOPE"),
    ("OPERATOR", "GET", "/api/carrier/stations"), ("OPERATOR", "DELETE", "/api/carrier/counter/holds/nohold"),
    ("OPERATOR", "POST", "/api/carrier/counter/bookings/quote"), ("OPERATOR", "POST", f"/api/carrier/parcels/tariffs/{U}/retire"),
    ("OPERATOR", "POST", f"/api/carrier/schedule-requests/{U}/withdraw"), ("OPERATOR", "GET", "/api/carrier/freight/documents/NODOC"),
    ("OPERATOR", "POST", "/api/carrier/freight/documents/NODOC/void"),
    ("STATION", "DELETE", "/api/station/holds/nohold"), ("STATION", "GET", "/api/station/sales/summary"),
    ("PASSENGER", "GET", "/api/w/taxi/cities"), ("PASSENGER", "GET", "/api/w/taxi/requests/mine"),
    ("PASSENGER", "GET", "/api/w/rental/bookings/mine"), ("PASSENGER", "GET", "/api/payments/mine"),
    ("PASSENGER", "GET", "/api/family/offers"), ("PASSENGER", "PATCH", "/api/auth/me/locale"),
]
SESSIONS = {"PLATFORM": ("admin@masslak.test", "PLATFORM"), "OPERATOR": ("owner@carrier.test", "OPERATOR"),
            "STATION": ("station@station.test", "STATION"), "PASSENGER": ("passenger@masslak.test", "PASSENGER")}


@pytest.fixture(scope="module")
def sessions():
    return {k: login(*v) for k, v in SESSIONS.items()}


@pytest.mark.parametrize("portal,method,url", ADDRESSES, ids=[f"{m} {u}" for _, m, u in ADDRESSES])
def test_the_address_answers_without_a_server_error(sessions, portal, method, url):
    r = sessions[portal].request(method, url, json={} if method != "GET" else None)
    assert r.status_code < 500, f"{method} {url}: {r.status_code} {r.text[:300]}"
