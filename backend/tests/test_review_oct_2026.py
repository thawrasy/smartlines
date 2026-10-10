"""The reviews of October 2026, package 1: findings fixed in the application code (C-01 and C-02 have their own files,
test_verified_context.py and test_telemetry.py).

M-01  a payer comes back to the platform's own address, never to the Host header a client sent
M-05  generic record views never return a credential, whatever columns a table gains later
M-12  the sandbox's payment simulator is opened by the payer only
"""
import asyncio
import os
import uuid

import asyncpg
import pytest
from starlette.requests import Request

from app import config
from app.deps import public_base
from app.modular import engine
from app.modular.specs import RESOURCES
from test_e2e import client, new_passenger

OWNER_URL = os.environ.get("MASSLAK_OWNER_URL")


def _request(host: str) -> Request:
    return Request({"type": "http", "method": "POST", "scheme": "https", "path": "/api/payments/topups", "query_string": b"",
                    "server": (host, 443), "headers": [(b"host", host.encode())]})


def test_the_return_address_is_the_platforms_not_the_host_header(monkeypatch):
    settings = config.get_settings()
    monkeypatch.setattr(settings, "public_url", "https://masslak.example/")
    monkeypatch.setattr(settings, "sandbox", False)
    assert public_base(_request("evil.example")) == "https://masslak.example"
    monkeypatch.setattr(settings, "sandbox", True)          # a sandbox reached as localhost keeps its own address
    assert public_base(_request("localhost:8077")) == "https://localhost:8077"


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_no_record_view_returns_a_credential():
    async def run():
        conn = await asyncpg.connect(OWNER_URL)
        try:
            leaks = {}
            for res in RESOURCES.values():
                meta = await engine.table_meta(conn, res.table)
                shown = set(engine.detail_columns(meta, res)) | set(res.list) | set(res.form)
                bad = sorted(c for c in shown if engine.SECRET_COLUMN.search(c))
                if bad:
                    leaks[res.key] = bad
            ride = await engine.table_meta(conn, "taxi.ride")
            return leaks, engine.detail_columns(ride, RESOURCES["taxi-ride"])
        finally:
            await conn.close()
    leaks, ride_columns = asyncio.run(run())
    assert leaks == {}, leaks
    assert "share_token" not in ride_columns and "id" in ride_columns   # the ride's sharing link stays out of the record
    for name in ("mfa_secret_enc", "iban_bidx", "webhook_secret", "password", "share_token", "recovery_codes", "otp_code"):
        assert engine.SECRET_COLUMN.search(name), name
    for name in ("token_id", "previous_hash", "signature", "status", "company_id", "pin_code_length"):
        assert not engine.SECRET_COLUMN.search(name), name


def test_only_the_payer_opens_the_sandbox_simulator():
    payer, other = new_passenger(), new_passenger()
    r = payer.post("/api/payments/topups", json={"method": "CARD", "amount": 150000, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert client().get(f"/api/payments/test/{uid}").status_code == 401
    assert client().post(f"/api/payments/test/{uid}", json={"approve": True}).status_code == 401
    assert other.get(f"/api/payments/test/{uid}").status_code == 404
    assert other.post(f"/api/payments/test/{uid}", json={"approve": True}).status_code == 404
    assert payer.get(f"/api/payments/test/{uid}").json()["amount"] == 150000
    assert payer.post(f"/api/payments/test/{uid}", json={"approve": True}).json()["status"] == "SUCCESS"
