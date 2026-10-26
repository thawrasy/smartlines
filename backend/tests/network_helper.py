"""A route of the network for tests (1163, N11): proposed by the platform administrator, approved by the geography
officer, in effect at once. Carriers then define their services on it."""
import secrets

from test_e2e import login


def network_route(stations: list[str], kms: list[float], name: str = "Test route") -> str:
    """stations: station uids in order; kms: each one's distance from the start (the first 0). Returns the route's uid."""
    admin, geo = login("admin@masslak.test", "PLATFORM"), login("geo@masslak.test", "PLATFORM")
    r = admin.post("/api/admin/network/routes", json={
        "name_en": f"{name} {secrets.token_hex(3)}", "name_ar": f"{name} ar",
        "version": {"distance_km": kms[-1], "stops": [{"station_uid": s, "km": k} for s, k in zip(stations, kms)]}})
    assert r.status_code == 201, r.text
    decided = geo.post(f"/api/admin/network/versions/{r.json()['version_uid']}/decide", json={"approve": True})
    assert decided.json()["status"] == "ACTIVE", decided.text
    return r.json()["uid"]
