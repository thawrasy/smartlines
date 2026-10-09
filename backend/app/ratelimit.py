"""Per-client request rate limiting (study 16.10: brute force and scraping defence).

Sign-in, registration, password and MFA endpoints draw from token buckets in the database (sec.rate_take, 1068),
shared by every process and instance: one per client address, sized for mobile networks where many subscribers share
one public address, and a strict one per account identifier, taken where the handler reads the identifier. Public
search and the rest of the API use buckets in process memory, per client address; each process enforces its share of
the limit (the instance's processes come from uvicorn's WEB_CONCURRENCY), so an instance as a whole keeps to it.
Several instances behind the proxy each allow the full limit; the proxy or a WAF caps the total if that matters.
"""
from __future__ import annotations

import os
import time
from dataclasses import dataclass, field

import asyncpg

from .config import get_settings
from .errors import ApiError
from .security import identifier_hash

AUTH_PATHS = ("/api/auth/login", "/api/auth/register", "/api/auth/mfa", "/api/auth/password", "/api/auth/refresh", "/api/account/password",
              "/api/family/join")      # family invite codes are guessed like passwords
PUBLIC_PATHS = ("/api/public/", "/api/trips", "/api/verify")


@dataclass
class Bucket:
    tokens: float
    updated: float = field(default_factory=time.monotonic)


class RateLimiter:
    def __init__(self, per_minute: dict[str, int], max_keys: int = 50_000):
        self.per_minute = per_minute
        self.max_keys = max_keys
        self._buckets: dict[tuple[str, str], Bucket] = {}

    def check(self, client: str, bucket: str, now: float | None = None) -> float:
        """Takes one token. Returns 0 when allowed, else the seconds until the next token."""
        rate = self.per_minute[bucket]
        now = time.monotonic() if now is None else now
        key = (client, bucket)
        b = self._buckets.get(key)
        if b is None:
            if len(self._buckets) >= self.max_keys:
                self._evict(now)
            b = self._buckets[key] = Bucket(tokens=rate, updated=now)
        b.tokens = min(rate, b.tokens + (now - b.updated) * rate / 60.0)
        b.updated = now
        if b.tokens >= 1:
            b.tokens -= 1
            return 0.0
        return (1 - b.tokens) * 60.0 / rate

    def _evict(self, now: float) -> None:
        """Drops buckets idle for more than two minutes; they would be full again anyway."""
        for k in [k for k, b in self._buckets.items() if now - b.updated > 120]:
            del self._buckets[k]


def bucket_for(path: str) -> str:
    if path.startswith(AUTH_PATHS):
        return "auth"
    if path.startswith(PUBLIC_PATHS):
        return "public"
    return "api"


_limiter: RateLimiter | None = None


def processes() -> int:
    """The API processes of this instance (uvicorn --workers defaults to WEB_CONCURRENCY), which share its limits."""
    try:
        return max(1, int(os.environ.get("WEB_CONCURRENCY", "1")))
    except ValueError:
        return 1


def limiter() -> RateLimiter:
    """The in-memory buckets of this process: its share of the instance's public and API limits."""
    global _limiter
    if _limiter is None:
        s, n = get_settings(), processes()
        _limiter = RateLimiter({"public": max(1, s.rate_public_per_minute // n), "api": max(1, s.rate_api_per_minute // n)})
    return _limiter


async def take_shared(conn: asyncpg.Connection, bucket: str, key: str, per_minute: int) -> float:
    """One token from a bucket shared by every process (sec.rate_take): 0 when allowed, else seconds to wait."""
    return float(await conn.fetchval("SELECT sec.rate_take($1, $2, $3)", bucket, key, per_minute))


async def check_address(conn: asyncpg.Connection, client: str) -> float:
    """The shared per-address bucket of the sign-in endpoints."""
    return await take_shared(conn, "auth_ip", client, get_settings().rate_auth_ip_per_minute)


async def check_identifier(conn: asyncpg.Connection, identifier: str) -> None:
    """The strict per-account bucket: guessing one account from many addresses is slowed as much as from one, and
    an unknown identifier counts the same as a known one. Only a keyed hash of the identifier is stored."""
    key = identifier_hash(identifier.strip()).hex()[:40]
    wait = await take_shared(conn, "auth_id", key, get_settings().rate_auth_per_minute)
    if wait:
        raise ApiError(429, "RATE_LIMITED", "too many attempts for this account, try again shortly",
                       retry_after=max(1, round(wait)))
