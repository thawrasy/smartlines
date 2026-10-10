"""Per-client request rate limiting (study 16.10: brute force and scraping defence).

Buckets in the database (sec.rate_take, 1068) are shared by every process and instance, so adding servers never
raises a limit (reviews of October 2026, M-03):
  * sign-in, registration, password and MFA endpoints: one bucket per client address, sized for mobile networks where
    many subscribers share one public address, and a strict one per account identifier, taken where the handler
    reads the identifier;
  * public search and verification: one bucket per client address, taken in the round trip that already reads the
    address rules, so it adds no connection;
  * the partner API: one bucket per API client, at the client's own limit.
The rest of the API (signed-in accounts, each request tied to a session) uses buckets in process memory, per client
address; each process enforces its share (the instance's processes come from uvicorn's WEB_CONCURRENCY). Their number
never exceeds max_keys: idle buckets go first, and with every bucket in use the least recently used one goes, so a flood
of new addresses cannot grow the process's memory (reviews of release 1.49.0, F-01).

An IPv6 client is counted by its /64 network, everywhere: one subscriber is usually given a whole /64 and could
otherwise draw a fresh bucket for every request.
"""
from __future__ import annotations

import ipaddress
import os
import time
from collections import OrderedDict
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


def client_key(address: str) -> str:
    """The key a client's buckets are counted under: its IPv4 address, or the /64 network of its IPv6 address."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return address
    if ip.version == 4:
        return str(ip)
    if ip.ipv4_mapped is not None:                  # ::ffff:192.0.2.7 is the IPv4 client 192.0.2.7
        return str(ip.ipv4_mapped)
    return str(ipaddress.IPv6Network((int(ip) >> 64 << 64, 64)))


class RateLimiter:
    def __init__(self, per_minute: dict[str, int], max_keys: int = 50_000):
        self.per_minute = per_minute
        self.max_keys = max_keys
        self._buckets: OrderedDict[tuple[str, str], Bucket] = OrderedDict()   # least recently used first

    def check(self, client: str, bucket: str, now: float | None = None) -> float:
        """Takes one token. Returns 0 when allowed, else the seconds until the next token."""
        rate = self.per_minute[bucket]
        now = time.monotonic() if now is None else now
        key = (client_key(client), bucket)
        b = self._buckets.get(key)
        if b is None:
            if len(self._buckets) >= self.max_keys:
                self._evict(now)
            b = self._buckets[key] = Bucket(tokens=rate, updated=now)
        else:
            self._buckets.move_to_end(key)
        b.tokens = min(rate, b.tokens + (now - b.updated) * rate / 60.0)
        b.updated = now
        if b.tokens >= 1:
            b.tokens -= 1
            return 0.0
        return (1 - b.tokens) * 60.0 / rate

    def _evict(self, now: float) -> None:
        """Makes room for one bucket: drops the buckets idle for more than two minutes (they would be full again anyway),
        which are the first in the order of use, and while none is idle the least recently used one."""
        while self._buckets:
            oldest = next(iter(self._buckets.values()))
            if now - oldest.updated <= 120 and len(self._buckets) < self.max_keys:
                break
            self._buckets.popitem(last=False)


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
        _limiter = RateLimiter({"api": max(1, s.rate_api_per_minute // n)})
    return _limiter


async def take_shared(conn: asyncpg.Connection, bucket: str, key: str, per_minute: int) -> float:
    """One token from a bucket shared by every process (sec.rate_take): 0 when allowed, else seconds to wait."""
    return float(await conn.fetchval("SELECT sec.rate_take($1, $2, $3)", bucket, key, per_minute))


async def check_address(conn: asyncpg.Connection, client: str) -> float:
    """The shared per-address bucket of the sign-in endpoints."""
    return await take_shared(conn, "auth_ip", client, get_settings().rate_auth_ip_per_minute)


async def check_public(conn: asyncpg.Connection, client: str) -> float:
    """The shared per-address bucket of public search and verification."""
    return await take_shared(conn, "public_ip", client, get_settings().rate_public_per_minute)


async def check_api_client(conn: asyncpg.Connection, client_id: int, per_minute: int) -> float:
    """The shared bucket of one partner API client, at its own limit (iam.api_client.rate_limit_per_min)."""
    return await take_shared(conn, "api_client", str(client_id), per_minute)


async def check_identifier(conn: asyncpg.Connection, identifier: str) -> None:
    """The strict per-account bucket: guessing one account from many addresses is slowed as much as from one, and
    an unknown identifier counts the same as a known one. Only a keyed hash of the identifier is stored."""
    key = identifier_hash(identifier.strip()).hex()[:40]
    wait = await take_shared(conn, "auth_id", key, get_settings().rate_auth_per_minute)
    if wait:
        raise ApiError(429, "RATE_LIMITED", "too many attempts for this account, try again shortly",
                       retry_after=max(1, round(wait)))
