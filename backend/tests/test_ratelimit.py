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


def test_the_number_of_buckets_never_exceeds_the_cap():
    # reviews of release 1.49.0, F-01: a flood of new addresses that stay active used to grow the table past max_keys
    rl = RateLimiter({"api": 5}, max_keys=100)
    for i in range(1000):
        rl.check(f"10.0.{i // 250}.{i % 250}", "api", now=i * 0.01)
        assert len(rl._buckets) <= 100
    # the least recently used went first; a client seen again keeps its bucket
    assert ("10.0.3.249", "api") in rl._buckets and ("10.0.0.0", "api") not in rl._buckets


def test_a_returning_client_is_kept_ahead_of_newer_ones():
    rl = RateLimiter({"api": 5}, max_keys=2)
    rl.check("a", "api", now=0)
    rl.check("b", "api", now=1)
    rl.check("a", "api", now=2)                  # a is used again: b is now the least recently used
    rl.check("c", "api", now=3)
    assert ("a", "api") in rl._buckets and ("b", "api") not in rl._buckets and len(rl._buckets) == 2


def test_an_ipv6_client_is_counted_by_its_network():
    from app.ratelimit import client_key
    assert client_key("2001:db8:1:2:aaaa::1") == client_key("2001:db8:1:2:ffff:ffff:ffff:ffff") == "2001:db8:1:2::/64"
    assert client_key("2001:db8:1:3::1") != client_key("2001:db8:1:2::1")
    assert client_key("::ffff:192.0.2.7") == "192.0.2.7" and client_key("192.0.2.7") == "192.0.2.7"
    rl = RateLimiter({"api": 2})
    assert rl.check("2001:db8:1:2::1", "api", now=0) == 0 and rl.check("2001:db8:1:2::2", "api", now=0) == 0
    assert rl.check("2001:db8:1:2::3", "api", now=0) > 0          # a fresh address in the same /64 shares the bucket
