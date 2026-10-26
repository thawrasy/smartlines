"""Published event contracts (systems review of study 3.8, recommendation 10): every event a partner can subscribe to
has a JSON Schema in docs/integration/events, one file per type and version, and the envelope has its own.

* Every subscribable type (integration/scopes.py EVENTS) has a schema, and every schema is a subscribable type.
* Within a published version a field is never removed or retyped and a required field never dropped (baseline.json).
* With MASSLAK_EVENT_CONTRACTS_LIVE=1 (a CI step after the whole suite), every event the tests left in the outbox is
  wrapped in its envelope as a receiver gets it and checked against the envelope and its type's schema. Rows a test
  writes by hand to exercise a failure carry "test_fixture": true and are left out.
"""
import json
import os
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator

from app.modules.integration.scopes import EVENTS
from app.modules.integration.webhooks import envelope

DIR = Path(__file__).resolve().parents[2] / "docs" / "integration" / "events"
ENVELOPE = json.loads((DIR / "envelope.v1.json").read_text(encoding="utf-8"))
BASELINE = json.loads((DIR / "baseline.json").read_text(encoding="utf-8"))["versions"]


def schemas() -> dict[tuple[str, int], dict]:
    out = {}
    for f in DIR.glob("*.v*.json"):
        s = json.loads(f.read_text(encoding="utf-8"))
        if "x-event-type" in s:
            assert f.name == f"{s['x-event-type']}.v{s['x-schema-version']}.json", f.name
            out[(s["x-event-type"], s["x-schema-version"])] = s
    return out


def test_every_subscribable_event_has_a_schema_and_no_schema_is_orphaned():
    assert {t for t, _ in schemas()} == set(EVENTS)


def test_the_schemas_are_valid_json_schema():
    Draft202012Validator.check_schema(ENVELOPE)
    for s in schemas().values():
        Draft202012Validator.check_schema(s)
        assert set(s["required"]) <= set(s["properties"]), s["title"]


def test_a_published_version_only_grows():
    current = schemas()
    for key, frozen in BASELINE.items():
        t, v = key.rsplit("@", 1)
        s = current.get((t, int(v)))
        assert s, f"{key} was published and cannot disappear"
        props = {k: p["type"] for k, p in s["properties"].items()}
        for name, kind in frozen["properties"].items():
            assert props.get(name) == kind, f"{key}: {name} removed or retyped; publish a new version instead"
        assert set(frozen["required"]) <= set(s["required"]), f"{key}: a required field was dropped"
    assert set(f"{t}@{v}" for t, v in current) == set(BASELINE), "record a new schema version in baseline.json"


def test_the_envelope_the_worker_builds_matches_its_schema():
    from datetime import datetime, timezone
    env = envelope("6f1c0000-0000-4000-8000-000000000001", "webhook.ping", datetime.now(timezone.utc),
                   {"endpoint": "e", "message": "test delivery"}, include_pii=False, aggregate="webhook_endpoint", sequence=1)
    Draft202012Validator(ENVELOPE).validate(env)
    Draft202012Validator(schemas()[("webhook.ping", 1)]).validate(env["data"])


@pytest.mark.skipif(os.environ.get("MASSLAK_EVENT_CONTRACTS_LIVE") != "1", reason="run after the whole suite (CI)")
def test_every_event_the_suite_produced_matches_its_contract():
    from test_e2e import OWNER_URL
    import asyncio
    import asyncpg

    async def rows():
        conn = await asyncpg.connect(OWNER_URL)
        try:
            return await conn.fetch(
                """SELECT event_uid, event_type, created_at, payload, schema_version, correlation_id, aggregate_type, aggregate_seq
                     FROM sys.outbox_event WHERE event_type = ANY($1::text[])
                      AND NOT coalesce(payload @> '{"test_fixture": true}', false)""", list(EVENTS))
        finally:
            await conn.close()
    known, failures, seen = schemas(), [], set()
    for r in asyncio.run(rows()):
        payload = json.loads(r["payload"]) if isinstance(r["payload"], str) else r["payload"]
        for pii in (True, False):
            env = envelope(r["event_uid"], r["event_type"], r["created_at"], payload, include_pii=pii,
                           schema_version=r["schema_version"], correlation_id=r["correlation_id"],
                           aggregate=r["aggregate_type"], sequence=r["aggregate_seq"])
            errors = [e.message for e in Draft202012Validator(ENVELOPE).iter_errors(env)]
            schema = known.get((r["event_type"], r["schema_version"]))
            errors += ["no schema for this version"] if schema is None else [
                f"{'/'.join(map(str, e.path))}: {e.message}" for e in Draft202012Validator(schema).iter_errors(env["data"])]
            if errors:
                failures.append(f"{r['event_type']} v{r['schema_version']} {r['event_uid']}: {errors[:3]}")
        seen.add(r["event_type"])
    assert not failures, "\n".join(failures[:20])
    assert len(seen) >= 8, f"too few event types to check: {sorted(seen)}"
