"""Runtime configuration, read from environment variables (see deploy/.env.example)."""
from functools import lru_cache
from typing import Optional

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="MASSLAK_", env_file=".env", extra="ignore")

    # Application connection: a login role that is a member of masslak_app (subject to RLS)
    database_url: str = "postgresql://masslak_api:masslak_api@localhost:5432/masslak"
    # Read-only connection for the security console: a login role that is a member of masslak_auditor
    audit_database_url: str = "postgresql://masslak_audit:masslak_audit@localhost:5432/masslak"
    # Optional read replica for reports, so heavy queries never load the booking database (empty: use the main pool)
    reports_database_url: str = ""
    # Optional telemetry database for the history of vehicle positions (review stage D2, db/telemetry/schema.sql); empty:
    # positions stay in ops.geo_event on the primary
    telemetry_database_url: str = ""

    # Secret used to sign QR codes and verification tokens (32+ random bytes in production)
    signing_secret: str = "change-me-in-production-0123456789abcdef"
    session_hours: int = 12
    cookie_secure: bool = True
    # Comma-separated proxy addresses or CIDR ranges whose X-Forwarded-For header is trusted
    trusted_proxies: str = "127.0.0.1,::1"
    # Directory of the built web interface served by the API (frontend/dist)
    static_dir: str = "../frontend/dist"
    # Public address of the site, used in canonical links, the sitemap and share cards (no trailing slash)
    public_url: str = "https://masslak.com"
    # Search console ownership tokens (the content of the verification meta tag), optional
    google_site_verification: str = ""
    bing_site_verification: str = ""
    # Public contact details shown on the contact page; a page line is left out while its value is empty
    support_email: str = ""
    support_phone: str = ""
    support_whatsapp: str = ""
    business_email: str = ""
    office_address: str = ""
    support_hours: str = ""
    # Sandbox mode enables the simulated payment gateway; never enable in production
    sandbox: bool = False
    # Encrypted file store for uploaded documents (a mounted volume; an object store adapter replaces it later)
    files_dir: str = "../data/files"
    max_upload_bytes: int = 4 * 1024 * 1024
    platform_fee: int = 100000            # flat platform fee per booking, minor units (SYP 1,000.00)
    qr_window_seconds: int = 90
    # Requests per minute (token buckets, see ratelimit.py). Sign-in, registration and password requests share
    # buckets in the database across every process: one per account identifier (strict) and one per client address
    # (high, because mobile networks put many subscribers behind one address). The other two are per address and
    # split evenly between the processes of an instance.
    rate_auth_per_minute: int = 10
    rate_auth_ip_per_minute: int = 300
    rate_public_per_minute: int = 240
    rate_api_per_minute: int = 1200
    # The API's own OpenAPI document and its page (/api/openapi.json, /api/docs): open in the sandbox, closed elsewhere
    # unless set to true. The partners' document (/api/v1/openapi.json) is always published.
    api_docs: Optional[bool] = None
    # Seconds a request waits for a database connection of its process before it is answered 503 (busy, repeat it)
    db_acquire_timeout: float = 5.0


@lru_cache
def get_settings() -> Settings:
    return Settings()
