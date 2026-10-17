"""The settings guard (db/guard, schema file 1084; reviews of release 1.49.0).

Row-level security and the ledger, requirement, file-scan and cargo guards trust transaction settings that only the
platform's own functions may set. Loaded with the database server, db/guard/masslak_guard.c defines each of them with
the superuser context, so a login cannot set them with SET, SET LOCAL, RESET, its connection options or ALTER ROLE.

GUARDED_SETTINGS is the same list as the module's and sys.guarded_settings() (backend/tests/test_settings_guard.py
compares the three). The production preflight reads it straight from pg_settings, before the schema exists; the
API's readiness check asks sys.guard_status().
"""
from __future__ import annotations

GUARDED_SETTINGS: tuple[str, ...] = (
    "app.user_id", "app.company_id", "app.scope", "app.api_client_id", "app.request_id", "app.ip",
    "app.session_id", "app.party_id", "app.new_rows",
    "fin.posting_entry", "masslak.requirement_change", "masslak.cargo_backfill", "masslak.migrating",
)

# the guarded settings the server enforces (superuser context); all of them when the guard is loaded
ENFORCED_SQL = "SELECT count(*) FROM pg_settings WHERE name = ANY($1::text[]) AND context = 'superuser'"
