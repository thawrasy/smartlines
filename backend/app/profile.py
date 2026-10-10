"""The production profile, checked when the API and the worker start (reviews of October 2026, package 2: H-05, H-06).

On a production server (anything config.is_test_server() does not call a test server) they refuse to start unless:
  * they run in the production profile (MASSLAK_PROFILE=production, which deploy/production/docker-compose.production.yml
    sets): TLS to the database, archiving off the host, the key service, monitoring;
  * every database connection checks the server's certificate (sslmode=verify-full, with the internal authority's
    certificate as sslrootcert);
  * the data keys come from the key service (MASSLAK_KMS_PROVIDER=vault) and none sits in their own environment
    (MASSLAK_FIELD_KEYS, MASSLAK_BIDX_KEY or MASSLAK_KEK there would put the keys next to the data they protect);
  * their environment holds no secret of the database owner, of replication, of the warehouse, of the backups or of
    pgBackRest (deploy/env-split.sh leaves them out; this catches a container started with the whole deploy/.env).
The migration checks the database side of the profile itself (app.tools.preflight).
"""
from __future__ import annotations

import os
from typing import Mapping
from urllib.parse import parse_qs, urlparse

from .config import get_settings, is_test_server

# secrets only the owner's tools and the infrastructure hold
OWNER_SECRETS = ("POSTGRES_PASSWORD", "MASSLAK_REPLICATION_PASSWORD", "MASSLAK_CDC_PASSWORD", "MASSLAK_DW_PASSWORD",
                 "MASSLAK_DW_ANALYST_PASSWORD", "MASSLAK_TELEMETRY_OWNER_PASSWORD", "MASSLAK_BACKUP_AGE_IDENTITY",
                 "PGBACKREST_REPO1_CIPHER_PASS", "PGBACKREST_REPO1_S3_KEY_SECRET", "MASSLAK_PATRONI_REST_PASSWORD",
                 "MASSLAK_ETCD_TOKEN")
RAW_KEYS = ("MASSLAK_FIELD_KEYS", "MASSLAK_BIDX_KEY", "MASSLAK_KEK")


def verified_tls(url: str) -> bool:
    """A connection URL that encrypts and checks the server's certificate against a given authority."""
    query = parse_qs(urlparse(url).query)
    return query.get("sslmode", [""])[-1] == "verify-full" and bool(query.get("sslrootcert", [""])[-1])


def problems(environ: Mapping[str, str] | None = None) -> list[str]:
    env = os.environ if environ is None else environ
    s = get_settings()
    found = []
    if env.get("MASSLAK_PROFILE", "") != "production":
        found.append("this server is declared production but does not run the production profile "
                     "(deploy/production/docker-compose.production.yml, COMPOSE_FILE in deploy/.env)")
    for name, url in (("MASSLAK_DATABASE_URL", s.database_url), ("MASSLAK_AUDIT_DATABASE_URL", s.audit_database_url),
                      ("MASSLAK_REPORTS_DATABASE_URL", s.reports_database_url)):
        if url and not verified_tls(url):
            found.append(f"{name} does not check the database's certificate (sslmode=verify-full and sslrootcert)")
    if env.get("MASSLAK_KMS_PROVIDER", "").strip().lower() != "vault":
        found.append("the data keys must come from the key service on a production server (MASSLAK_KMS_PROVIDER=vault)")
    held = [k for k in RAW_KEYS if env.get(k, "").strip()]
    if held:
        found.append(f"data keys sit in this process's environment ({', '.join(held)}): on a production server they are "
                     "wrapped by the key service and only the migration may read them, once, to wrap them")
    leaked = [k for k in OWNER_SECRETS if env.get(k, "").strip()]
    if leaked:
        found.append(f"secrets this process must not hold are in its environment ({', '.join(leaked)}): start it with "
                     "deploy/env/<service>.env (deploy/env-split.sh), not the whole deploy/.env")
    return found


def require_in_production() -> None:
    if is_test_server():
        return
    found = problems()
    if found:
        raise RuntimeError("the production profile is incomplete (reviews of October 2026, package 2):\n  - "
                           + "\n  - ".join(found))
