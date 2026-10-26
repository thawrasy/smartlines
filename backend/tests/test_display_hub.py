"""Station displays on a closed network (owner's note N46, 1179): the station's administration makes a one-time code;
the hub joins with the hash of its own key; a player that asks the hub waits until the administration approves it for
a screen; the hub pulls that screen's board with the player's address, and reports the players it sees: an approved
player stamps its screen seen, the same player at another address is reported, an unknown device waits. A revoked
hub is refused."""
import hashlib
import secrets
import uuid

import pytest

from test_boarding_stations import ADMIN, set_setting, station_session, stations_module
from test_e2e import OWNER_URL, client, login, owner_sql
from test_station_display_screens import ALL, _leaves_soon, _stop_station
from test_station_sales import _company
from test_use_case_gaps import fresh_trip

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

MAC, IP = "3c:22:fb:0a:0b:0c", "10.20.0.11"


def hub_client(key: str):
    c = client()
    c.headers.update({"X-Hub-Key": key, "X-Hub-Version": "test"})
    return c


def test_a_hub_serves_the_screens_of_its_station_to_the_players_the_administration_approved():
    admin = login(*ADMIN)
    trip = fresh_trip()
    _leaves_soon(trip["id"])
    origin = _stop_station(trip["id"], False)
    manager = _company(admin, "Hub Station Administration " + uuid.uuid4().hex[:4])
    stranger = _company(admin, "Hub Other Company " + uuid.uuid4().hex[:4])
    stations_module(admin, True)
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        assert admin.put(f"/api/admin/boarding/stations/{origin}", json={
            "enabled": True, "displays": True, "manager_company_uid": manager["uid"], "display_kinds": ALL}).status_code == 200
        staff = station_session(manager)
        dep = staff.post("/api/station/screens", json={"station_uid": origin, "kind": "DEPARTURES", "label": "Gates hall"}).json()["uid"]

        # a one-time code, shown once; another company is not this station's administration
        r = station_session(stranger).post("/api/station/hubs/pairing", json={"station_uid": origin, "label": "Server room"})
        assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_STATION_ADMIN"
        r = staff.post("/api/station/hubs/pairing", json={"station_uid": origin, "label": "Server room"})
        assert r.status_code == 201, r.text
        code = r.json()["code"]
        assert len(code) == 8

        # the hub joins with the hash of the key it keeps; the code is used once
        key = secrets.token_urlsafe(48)
        body = {"code": code, "key_sha256": hashlib.sha256(key.encode()).hexdigest(), "version": "test"}
        joined = client().post("/api/hub/pair", json=body)
        assert joined.status_code == 201 and joined.json()["station_uid"] == origin, joined.text
        again = client().post("/api/hub/pair", json={**body, "key_sha256": hashlib.sha256(b"other").hexdigest()})
        assert again.status_code == 404 and again.json()["error"]["code"] == "HUB_CODE_UNKNOWN"
        assert client().get("/api/hub/sync").status_code == 401
        assert hub_client("not-a-key").get("/api/hub/sync").json()["error"]["code"] == "HUB_KEY_INVALID"
        hub = hub_client(key)
        s = hub.get("/api/hub/sync").json()
        assert s["screens"] == [] and s["station"]["uid"] == origin
        assert s["labels"]["en"]["departures"] == "Departures" and s["labels"]["ar"]["status"]["SEE_COUNTER"]
        assert "ALP" in s["cities"] or s["cities"]

        # a player asks the hub: it waits for the administration
        assert hub.post("/api/hub/report", json={"players": [{"mac": MAC.upper().replace(":", "-"), "ip": IP}]}).json()["waiting"] == 1
        view = staff.get("/api/station/hubs", params={"station_uid": origin}).json()
        player = next(p for p in view["players"] if p["mac"] == MAC)
        assert player["status"] == "WAITING" and player["ip"] == IP
        assert any(e["kind"] == "UNKNOWN_DEVICE" and e["mac"] == MAC for e in view["events"])

        # the screen gets its code and group; then the player is approved for it
        r = staff.post(f"/api/station/hubs/players/{player['uid']}", json={"approve": True, "screen_uid": dep})
        assert r.status_code == 409 and r.json()["error"]["code"] == "SCREEN_CODE_REQUIRED"
        assert staff.put(f"/api/station/hubs/screens/{dep}", json={"code": "bad code"}).json()["error"]["code"] == "SCREEN_CODE_INVALID"
        assert staff.put(f"/api/station/hubs/screens/{dep}", json={"code": "dep-1", "group": "Departure gates"}).status_code == 200
        assert staff.post(f"/api/station/hubs/players/{player['uid']}", json={"approve": True, "screen_uid": dep}).status_code == 200
        assert staff.post(f"/api/station/hubs/players/{player['uid']}", json={"approve": False}).json()["error"]["code"] == "PLAYER_DECIDED"

        # the hub now serves the screen: its code, group, player and board (public data only)
        s = hub.get("/api/hub/sync").json()
        screen = s["screens"][0]
        assert (screen["code"], screen["group"], screen["mac"], screen["ip"]) == ("DEP-1", "Departure gates", MAC, IP)
        assert any(d["trip_no"] == trip["trip_no"] for d in screen["board"]["departures"])
        assert not any(k in str(s) for k in ("passenger", "booking_ref", "seat_no"))
        # pulling does not stamp the screen seen; its player reporting does
        owner_sql("UPDATE net.station_screen SET last_seen_at = NULL WHERE uid = $1::uuid", dep)
        hub.get("/api/hub/sync")
        assert owner_sql("SELECT last_seen_at FROM net.station_screen WHERE uid = $1::uuid", dep) is None
        assert hub.post("/api/hub/report", json={"players": [{"mac": MAC, "ip": IP}], "uplink_gap_seconds": 300}).json()["seen"] == 1
        assert owner_sql("SELECT last_seen_at IS NOT NULL FROM net.station_screen WHERE uid = $1::uuid", dep)
        # the same player at another address is reported, and the screen is not stamped by it
        assert hub.post("/api/hub/report", json={"players": [{"mac": MAC, "ip": "10.20.0.99"}]}).json()["mismatch"] == 1
        view = staff.get("/api/station/hubs", params={"station_uid": origin}).json()
        kinds = {e["kind"] for e in view["events"]}
        assert {"ADDRESS_MISMATCH", "UPLINK_RESTORED"} <= kinds
        assert next(x for x in view["screens"] if x["uid"] == dep)["code"] == "DEP-1"
        assert view["hubs"][0]["online"] and view["hubs"][0]["screens"] == 1

        # a second device is rejected; the hub learns to refuse it
        other_mac = "aa:bb:cc:00:11:22"
        hub.post("/api/hub/report", json={"players": [{"mac": other_mac, "ip": "10.20.0.12"}]})
        stray = next(p for p in staff.get("/api/station/hubs", params={"station_uid": origin}).json()["players"] if p["mac"] == other_mac)
        assert staff.post(f"/api/station/hubs/players/{stray['uid']}", json={"approve": False}).status_code == 200
        assert other_mac in hub.get("/api/hub/sync").json()["rejected"]
        assert hub.post("/api/hub/report", json={"players": [{"mac": "not-a-mac", "ip": IP}]}).status_code == 422

        # the player is released: the screen waits for another; then the hub is revoked with a reason
        assert staff.delete(f"/api/station/hubs/screens/{dep}/player").status_code == 200
        assert hub.get("/api/hub/sync").json()["screens"] == []
        hub_uid = view["hubs"][0]["uid"]
        assert staff.post(f"/api/station/hubs/{hub_uid}/revoke", json={"reason": "x"}).status_code == 422
        assert staff.post(f"/api/station/hubs/{hub_uid}/revoke", json={"reason": "box replaced"}).status_code == 200
        assert hub.get("/api/hub/sync").json()["error"]["code"] == "HUB_KEY_INVALID"
        # the platform sees the same
        assert admin.get(f"/api/admin/boarding/stations/{origin}/hubs").json()["hubs"][0]["revoke_reason"] == "box replaced"
        assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action LIKE 'boarding.hub_%'") >= 3
    finally:
        owner_sql("DELETE FROM net.station_screen WHERE station_id = (SELECT id FROM net.station WHERE uid = $1::uuid)", origin)
        admin.put(f"/api/admin/boarding/stations/{origin}", json={"enabled": False, "displays": False, "display_kinds": ALL})
        set_setting(admin, "boarding.stations.enabled", False)
        stations_module(admin, False)
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])
