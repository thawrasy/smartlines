"""The API contract cannot break a client silently (review of release 1.47.0, R-51): the code is compared with the
baseline in docs/api (app/tools/api_baseline.py), and the responses the web interface and the mobile apps cannot do
without keep their fields and types. A deliberate break is accepted with a reason, recorded in docs/api/API_CHANGES.md:

    python -m app.tools.api_baseline write --reason "..."                       # requests, parameters, statuses
    MASSLAK_ACCEPT_SHAPES="reason" pytest tests/test_api_baseline.py            # response shapes (running server)
"""
import json
import os
import uuid
from datetime import date

import pytest

from app.tools import api_baseline as ab
from test_e2e import OWNER_URL, bookable_trip, client, day, free_seats, login, publish_fresh_trip, syrian


def test_no_change_breaks_a_client_against_the_baseline():
    breaks = ab.breaking(ab.load(), ab.current())
    assert not breaks, ("changes that would break a client already in use (accept a deliberate one with "
                        "python -m app.tools.api_baseline write --reason ...):\n  " + "\n  ".join(breaks))


def _op(body=None, params=None, responses=None):
    return {"parameters": params or {}, "body": body and {"required": True, "content": {"application/json": body}},
            "responses": responses or {"200": {}}}


BOOKING = {"type": "object", "required": ["trip_uid"], "properties": {
    "trip_uid": {"type": "string"}, "category": {"type": "string", "enum": ["ADULT", "CHILD"]},
    "note": {"type": "string", "maxLength": 200, "nullable": True}}}
REPLY = {"type": "object", "required": ["ref", "status"], "properties": {
    "ref": {"type": "string"}, "status": {"type": "string", "enum": ["PAID", "HELD"]}, "total": {"type": "integer"}}}


def _with(base: dict, path: list, value) -> dict:
    out = json.loads(json.dumps(base))
    node = out
    for key in path[:-1]:
        node = node[key]
    if value is KeyError:
        node.pop(path[-1])
    else:
        node[path[-1]] = value
    return out


@pytest.mark.parametrize("new, expected", [
    ({}, "removed"),
    ({"POST /x": _op(_with(BOOKING, ["required"], ["trip_uid", "category"]), responses={"200": REPLY})}, "category: now required"),
    ({"POST /x": _op(_with(BOOKING, ["properties", "category", "enum"], ["ADULT"]), responses={"200": REPLY})}, 'no longer accepts "CHILD"'),
    ({"POST /x": _op(_with(BOOKING, ["properties", "note", "maxLength"], 100), responses={"200": REPLY})}, "maxLength tightened"),
    ({"POST /x": _op(_with(BOOKING, ["properties", "trip_uid", "type"], "integer"), responses={"200": REPLY})}, "type ['string'] became"),
    ({"POST /x": _op(BOOKING, responses={"200": _with(REPLY, ["required"], ["ref"])})}, "status: no longer always returned"),
    ({"POST /x": _op(BOOKING, responses={"200": _with(REPLY, ["properties", "status", "enum"], ["PAID", "HELD", "VOID"])})}, 'may now return "VOID"'),
    ({"POST /x": _op(BOOKING, responses={"201": REPLY})}, "response 200: removed"),
    ({"POST /x": _op(BOOKING, params={"query:lang": {"required": True, "schema": {"type": "string"}}}, responses={"200": REPLY})},
     "new required parameter"),
])
def test_what_breaks_a_client_is_named(new, expected):
    old = {"app": {"POST /x": _op(BOOKING, responses={"200": REPLY})}}
    breaks = ab.breaking(old, {"app": new})
    assert any(expected in b for b in breaks), breaks


def test_additions_do_not_break_a_client():
    old = {"app": {"POST /x": _op(BOOKING, responses={"200": REPLY})}}
    wider = _with(BOOKING, ["properties", "category", "enum"], ["ADULT", "CHILD", "INFANT"])
    wider = _with(wider, ["properties", "note", "maxLength"], 500)
    wider["properties"]["seat"] = {"type": "integer"}
    reply = _with(REPLY, ["properties", "fee"], {"type": "integer"})
    reply["required"].append("fee")
    new = {"app": {"POST /x": _op(wider, params={"query:page": {"required": False, "schema": {"type": "integer"}}},
                                  responses={"200": reply, "202": {}}),
                   "GET /y": _op()}}
    assert ab.breaking(old, new) == []


def test_response_shapes_name_a_field_gone_or_retyped():
    old = ab.shape({"ref": "AB12", "total": 100, "tickets": [{"seat": 1, "name": "A"}, {"seat": 2, "name": None}]})
    assert ab.shape_breaks(old, ab.shape({"ref": "AB12", "total": 100, "extra": 1, "tickets": [{"seat": 3, "name": "B"}]}), "r") == []
    assert ab.shape_breaks(old, ab.shape({"ref": "AB12", "total": 100, "tickets": []}), "r") == []     # no rows today
    assert ab.shape_breaks(old, ab.shape({"ref": "AB12", "tickets": [{"seat": "3", "name": "B"}]}), "r") == \
        ["r.tickets[].seat: number became string", "r.total: removed"]


# ------------------------------------------------------------------ the responses clients depend on, on a running server
@pytest.fixture(scope="module")
def booked():
    pax = login("passenger@masslak.test", "PASSENGER")
    trip = bookable_trip(pax)
    if trip is None:
        publish_fresh_trip()
        trip = bookable_trip(pax)
    seat = free_seats(pax, trip, 1)[0]
    h = pax.post("/api/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"],
                                     "seat_nos": [seat]})
    assert h.status_code == 201, h.text
    r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": trip["uid"],
                                        "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "passengers": [syrian(seat)],
                                        "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    return pax, trip, r.json()


def _responses(pax, trip, booking) -> dict:
    seg = {"from_seq": trip["from_seq"], "to_seq": trip["to_seq"]}
    out = {"POST /api/bookings": booking}
    found = [pax.get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(d), "passengers": 1}).json()
             for d in range(1, 7)]
    out["GET /api/trips/search"] = next((f for f in found if f["trips"]), found[0])
    for name, (who, path, params) in {
        "GET /api/health": (client(), "/api/health", None),
        "GET /api/auth/me": (pax, "/api/auth/me", None),
        "GET /api/trips/{uid}": (pax, f"/api/trips/{trip['uid']}", seg),
        "GET /api/wallet": (pax, "/api/wallet", None),
        "GET /api/bookings": (pax, "/api/bookings", None),
        "GET /api/bookings/{ref}": (pax, f"/api/bookings/{booking['booking_ref']}", None),
        "GET /api/notifications": (pax, "/api/notifications", None),
    }.items():
        r = who.get(path, params=params)
        assert r.status_code == 200, (name, r.text[:300])
        out[name] = r.json()
    operator = login("owner@carrier.test", "OPERATOR")
    for name, path in {"GET /api/carrier/trips": "/api/carrier/trips",
                       "GET /api/carrier/trips/{uid}/manifest": f"/api/carrier/trips/{trip['uid']}/manifest"}.items():
        r = operator.get(path)
        if r.status_code == 200:                     # the manifest only for the operator's own trips
            out[name] = r.json()
    return out


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_the_responses_clients_depend_on_keep_their_fields(booked):
    now = {name: ab.shape(body) for name, body in _responses(*booked).items()}
    accept = os.environ.get("MASSLAK_ACCEPT_SHAPES")
    old = json.loads(ab.SHAPES.read_text(encoding="utf-8")) if ab.SHAPES.exists() else {}
    breaks = [b for name in sorted(old) if name in now for b in ab.shape_breaks(old[name], now[name], name)]
    breaks += [f"{name}: not checked any more" for name in sorted(set(old) - set(now))]
    if accept:
        ab.SHAPES.write_text(json.dumps({**old, **now}, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        if breaks:
            with ab.CHANGES.open("a", encoding="utf-8") as f:
                f.write(f"\n## {date.today().isoformat()}: {accept}\n\n" + "".join(f"- {b}\n" for b in breaks))
        return
    assert old, "no recorded shapes: run once with MASSLAK_ACCEPT_SHAPES='first record'"
    assert not breaks, ("response fields the clients use were removed or changed (accept with "
                        "MASSLAK_ACCEPT_SHAPES='reason'):\n  " + "\n  ".join(breaks))
