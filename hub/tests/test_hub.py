"""The display hub on its own: which player sees which screen, the board while the uplink is cut, the pages, the push,
and the uplink's pull and report against a stand-in platform."""
import asyncio
import json
import time
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

from masslak_hub import players
from masslak_hub.board import view
from masslak_hub.server import COOKIE, create_app
from masslak_hub.store import Store
from masslak_hub.uplink import Uplink

MAC, IP = "3c:22:fb:01:02:03", "10.20.0.11"
LATER = (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat()
EARLIER = (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat()


def board(at=LATER, status="SCHEDULED"):
    return {"kind": "DEPARTURES", "languages": ["ar", "en"], "rotate_seconds": 10,
            "station": {"code": "SY-DAM-C001", "name": "Damascus", "time_zone": "Asia/Damascus"},
            "departures": [{"at": at, "city": "Aleppo", "city_code": "ALP", "via": [], "status": status, "carrier": "Demo",
                            "trip_no": "DCA-1", "trip_code": "DC 1", "bay": "3"}], "arrivals": []}


def sync(screens=None, rejected=None):
    return {"hub": {"uid": "h", "label": "Server room"}, "station": {"code": "SY-DAM-C001"},
            "screens": screens if screens is not None else [{"code": "DEP-1", "kind": "DEPARTURES", "label": "Hall", "group": "Gates",
                                                             "mac": MAC, "ip": IP, "board": board()}],
            "rejected": rejected or [], "cities": {"ALP": {"en": "Aleppo", "ar": "x"}}, "labels": {"en": {"waiting": "Waiting"}}}


# ------------------------------------------------------------------ who sees what
def test_only_the_approved_player_at_its_address_with_its_key_sees_the_board():
    s = sync()["screens"]
    assert players.decide(s, [], {}, "nope", MAC, IP, None).verdict == "UNKNOWN_SCREEN"
    assert players.decide(s, [], {}, "DEP-1", None, IP, None).verdict == "REFUSED"            # not on the screens' network
    assert players.decide(s, [], {}, "DEP-1", "aa:bb:cc:dd:ee:ff", IP, None).verdict == "WAIT"  # another device: waits
    assert players.decide(s, [], {}, "DEP-1", MAC, "10.20.0.99", None).verdict == "MISMATCH"   # the player elsewhere
    assert players.decide(s, [MAC], {}, "DEP-1", MAC, IP, None).verdict == "REFUSED"           # rejected
    first = players.decide(s, [], {}, "dep-1", MAC, IP, None)
    assert first.verdict == "BIND" and first.token
    bound = {"DEP-1": {"mac": MAC, "key_sha256": players.digest(first.token)}}
    assert players.decide(s, [], bound, "DEP-1", MAC, IP, first.token).verdict == "SHOW"
    assert players.decide(s, [], bound, "DEP-1", MAC, IP, None).verdict == "REFUSED"           # MAC and IP copied, no key
    assert players.decide(s, [], bound, "DEP-1", MAC, IP, "forged").verdict == "REFUSED"


def test_the_hardware_address_comes_from_the_arp_table(tmp_path):
    arp = tmp_path / "arp"
    arp.write_text("IP address       HW type     Flags       HW address            Mask     Device\n"
                   f"{IP}       0x1         0x2         3C:22:FB:01:02:03     *        eth1\n"
                   "10.20.0.12       0x1         0x0         00:00:00:00:00:00     *        eth1\n")
    assert players.mac_of(IP, arp) == MAC
    assert players.mac_of("10.20.0.12", arp) is None                                           # incomplete entry
    assert players.mac_of("10.20.0.13", arp) is None
    assert players.mac_of(IP, tmp_path / "missing") is None


# ------------------------------------------------------------------ the board when the uplink is cut
def test_a_stale_board_says_since_when_and_never_shows_a_passed_trip_on_time():
    fresh = {**sync(), "synced_at": time.time()}
    screen = {**fresh["screens"][0], "board": board(at=EARLIER)}
    assert view(fresh, screen, time.time())["board"]["departures"][0]["status"] == "SCHEDULED"
    old = {**fresh, "synced_at": time.time() - 600}
    out = view(old, screen, time.time())
    assert out["stale"] is True and out["board"]["departures"][0]["status"] == "SEE_COUNTER"
    done = {**screen, "board": board(at=EARLIER, status="DEPARTED")}
    assert view(old, done, time.time())["board"]["departures"][0]["status"] == "DEPARTED"
    ahead = {**screen, "board": board(at=LATER)}
    assert view(old, ahead, time.time())["board"]["departures"][0]["status"] == "SCHEDULED"


# ------------------------------------------------------------------ the pages and the push
@pytest.fixture()
def hub(tmp_path):
    store = Store(tmp_path / "state")
    store.save_pairing("k" * 40, "https://platform.test", {"label": "Server room", "station_code": "SY-DAM-C001"})
    store.save_sync(sync())
    arp = tmp_path / "arp"
    # the test client connects as "testclient": the ARP table names it as the screen's player at first
    arp.write_text(f"IP address HW type Flags HW address Mask Device\ntestclient 0x1 0x2 {MAC} * eth1\n")
    up = Uplink(store, httpx.AsyncClient(base_url="https://platform.test"))
    screens = sync()["screens"]
    screens[0]["ip"] = "testclient"
    store.save_sync(sync(screens))
    return store, up, arp


def test_the_player_is_bound_once_then_shown_and_a_copy_without_the_key_is_refused(hub):
    store, up, arp = hub
    app = create_app(store, up, arp)
    with TestClient(app) as c:
        r = c.get("/screen/DEP-1")
        assert r.status_code == 200 and "board.js" in r.text and COOKIE in r.cookies
        assert "script-src 'self'" in r.headers["content-security-policy"]
        assert store.bindings["DEP-1"]["mac"] == MAC
        b = c.get("/board/DEP-1").json()
        assert b["board"]["departures"][0]["city_code"] == "ALP" and b["cities"]["ALP"]["en"] == "Aleppo"
        with c.websocket_connect("/ws/DEP-1") as ws:
            assert ws.receive_json()["screen"]["code"] == "DEP-1"
        assert MAC in up.seen
    with TestClient(app) as other:                                    # same MAC and IP, but not the key
        assert other.get("/screen/DEP-1").status_code == 403
        assert other.get("/board/DEP-1").status_code == 403


def test_a_device_not_approved_sees_its_address_to_give_the_administration(hub):
    store, up, arp = hub
    arp.write_text("IP address HW type Flags HW address Mask Device\ntestclient 0x1 0x2 aa:bb:cc:dd:ee:ff * eth1\n")
    with TestClient(create_app(store, up, arp)) as c:
        r = c.get("/screen/DEP-1")
        assert r.status_code == 200 and "aa:bb:cc:dd:ee:ff" in r.text and "Waiting" in r.text
        assert c.get("/board/DEP-1").status_code == 403
        assert c.get("/screen/NOPE").status_code == 404
        assert c.get("/assets/../store.py").status_code == 404
        assert c.get("/healthz").json()["paired"] is True
    assert "aa:bb:cc:dd:ee:ff" in up.seen                              # reported as waiting


# ------------------------------------------------------------------ the uplink
def test_the_uplink_keeps_the_last_boards_when_cut_and_reports_the_gap(tmp_path):
    store = Store(tmp_path / "s")
    store.save_pairing("secret-key", "https://platform.test", {"label": "Hub"})
    calls = {"up": True, "reports": []}

    def platform(request: httpx.Request) -> httpx.Response:
        assert request.headers["X-Hub-Key"] == "secret-key"
        if not calls["up"]:
            raise httpx.ConnectError("cut")
        if request.url.path == "/api/hub/sync":
            return httpx.Response(200, json=sync())
        calls["reports"].append(json.loads(request.content))
        return httpx.Response(200, json={"seen": 1})

    async def scenario():
        async with httpx.AsyncClient(base_url="https://platform.test", transport=httpx.MockTransport(platform)) as client:
            up = Uplink(store, client)
            assert await up.pull() and store.sync["screens"][0]["code"] == "DEP-1"
            store.save_bindings({"DEP-1": {"mac": MAC, "key_sha256": "x"}, "OLD-1": {"mac": MAC, "key_sha256": "y"}})
            assert await up.pull() and list(store.bindings) == ["DEP-1"]           # a screen gone forgets its player
            calls["up"] = False
            assert not await up.pull() and up.down_since is not None
            assert store.sync["screens"][0]["code"] == "DEP-1"                       # the last boards stay
            up.down_since -= 125
            calls["up"] = True
            assert await up.pull() and up.down_since is None and up.gap_to_report >= 125
            up.saw(MAC, IP)
            assert await up.report()
            assert calls["reports"][-1]["uplink_gap_seconds"] >= 125 and calls["reports"][-1]["players"] == [{"mac": MAC, "ip": IP}]
            assert up.gap_to_report == 0

    asyncio.run(scenario())
