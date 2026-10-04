"""Runtime configuration, read from environment variables (see deploy/.env.example)."""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="MASSLAK_", env_file=".env", extra="ignore")

    # Application connection: a login role that is a member of masslak_app (subject to RLS)
    database_url: str = "postgresql://masslak_api:masslak_api@localhost:5432/masslak"
    # Read-only connection for the security console: a login role that is a member of masslak_auditor
    audit_database_url: str = "postgresql://masslak_audit:masslak_audit@localhost:5432/masslak"

    # Secret used to sign QR codes and verification tokens (32+ random bytes in production)
    signing_secret: str = "change-me-in-production-0123456789abcdef"
    session_hours: int = 12
    cookie_secure: bool = True
    # Comma-separated proxy addresses or CIDR ranges whose X-Forwarded-For header is trusted
    trusted_proxies: str = "127.0.0.1,::1"
    # Directory of the built web interface served by the API (frontend/dist)
    static_dir: str = "../frontend/dist"
    # Sandbox mode enables the simulated payment gateway; never enable in production
    sandbox: bool = False
    platform_fee: int = 100000            # flat platform fee per booking, minor units (SYP 1,000.00)
    qr_window_seconds: int = 90
    # Requests per minute per client address (token buckets, see ratelimit.py)
    rate_auth_per_minute: int = 20
    rate_public_per_minute: int = 240
    rate_api_per_minute: int = 1200


@lru_cache
def get_settings() -> Settings:
    return Settings()
