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
    # Which server this is: development, staging or production (deploy/.env). Unset outside the sandbox counts as
    # production for the checks that allow a shortcut on test servers only.
    environment: str = ""
    # Encrypted file store for uploaded documents and generated reports (app/modules/documents/storage.py): "local", a
    # mounted volume (files_dir), or "s3", an S3-compatible object store with server-side encryption, shared by every
    # API server (code review of October 2026). python -m app.tools.files_move copies a volume into the object store.
    files_backend: str = "local"
    files_dir: str = "../data/files"
    files_s3_endpoint: str = ""           # https://s3.eu-central-1.amazonaws.com, https://minio.internal:9000, ...
    files_s3_bucket: str = ""
    files_s3_region: str = "us-east-1"
    files_s3_prefix: str = ""             # optional folder inside the bucket
    files_s3_access_key: str = ""
    files_s3_secret_key: str = ""
    files_s3_secret_key_file: str = ""    # or the secret in a file (a Docker secret), never in the image
    files_s3_sse: str = "AES256"          # server-side encryption asked for on every write: AES256 or aws:kms
    files_s3_kms_key_id: str = ""         # with aws:kms, the key (empty: the bucket's default key)
    files_s3_path_style: bool = True      # bucket in the path (MinIO, SeaweedFS, most stores); false: in the host name
    files_s3_via_proxy: bool = False      # true for a cloud store: through the egress proxy, its domain allowlisted
    files_s3_timeout: float = 15.0
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


def is_test_server() -> bool:
    """A sandbox, or a server declared development or staging; anything else is treated as production."""
    st = get_settings()
    return st.sandbox or st.environment.strip().lower() in ("development", "staging")


@lru_cache
def get_settings() -> Settings:
    return Settings()
