"""Unit tests for the token-bucket rate limiter."""
from app.ratelimit import RateLimiter, bucket_for


def test_burst_then_refill():
    rl = RateLimiter({"auth": 3})
    assert [rl.check("1.2.3.4", "auth", now=0) for _ in range(3)] == [0, 0, 0]
    wait = rl.check("1.2.3.4", "auth", now=0)
    assert 19 < wait <= 20                       # one token every 20 s at 3 per minute
    assert rl.check("1.2.3.4", "auth", now=21) == 0


def test_clients_and_buckets_are_independent():
    rl = RateLimiter({"auth": 1, "api": 1})
    assert rl.check("a", "auth", now=0) == 0 and rl.check("a", "auth", now=0) > 0
    assert rl.check("b", "auth", now=0) == 0
    assert rl.check("a", "api", now=0) == 0


def test_idle_buckets_are_evicted():
    rl = RateLimiter({"api": 5}, max_keys=2)
    rl.check("a", "api", now=0)
    rl.check("b", "api", now=0)
    rl.check("c", "api", now=500)
    assert ("a", "api") not in rl._buckets


def test_paths_map_to_buckets():
    assert bucket_for("/api/auth/login") == "auth"
    assert bucket_for("/api/auth/mfa/verify") == "auth"
    assert bucket_for("/api/trips/abc") == "public"
    assert bucket_for("/api/bookings") == "api"
