"""Per-client request rate limiting (study 16.10: brute force and scraping defence).

A token bucket per (client address, bucket). Sign-in, registration and MFA endpoints get a small bucket;
public search a medium one; everything else a generous one. Buckets live in process memory, which is enough
for a single API instance; with several instances behind the proxy, move them to a shared store (Redis) or
enforce the same limits at the edge.
"""
from __future__ import annotations

import time
from dataclasses import dataclass, field

from .config import get_settings

AUTH_PATHS = ("/api/auth/login", "/api/auth/register", "/api/auth/mfa", "/api/auth/password", "/api/auth/refresh", "/api/account/password")
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


def limiter() -> RateLimiter:
    global _limiter
    if _limiter is None:
        s = get_settings()
        _limiter = RateLimiter({"auth": s.rate_auth_per_minute, "public": s.rate_public_per_minute,
                                "api": s.rate_api_per_minute})
    return _limiter
