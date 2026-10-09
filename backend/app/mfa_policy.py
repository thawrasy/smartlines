"""The platform's two-factor sign-in policy (owner's decision 2; review of release 1.47.0, R-31).

sys.setting 'auth.mfa' says which methods are open (an authenticator app, a text message, a WhatsApp message; one or
more) and which portals must use one. The security officers change it from the security console. A method sent by
message is offered only when this server can deliver on that channel (MASSLAK_NOTIFY_SMS, MASSLAK_NOTIFY_WHATSAPP);
the authenticator app needs no delivery, so it remains the way in when nothing else is open.

Two rules do not depend on the setting: platform staff always use a second factor outside the sandbox, and anyone who
enrolled one uses it. Passengers may opt in. Each process reads the setting at most every CACHE_SECONDS.
"""
from __future__ import annotations

import json
import time
from dataclasses import dataclass

import asyncpg

from .config import get_settings

METHODS = ("TOTP", "SMS", "WHATSAPP")
MESSAGE_METHODS = ("SMS", "WHATSAPP")
PORTALS = ("PLATFORM", "INSPECTOR", "OPERATOR", "DRIVER", "AGENCY", "PASSENGER")
ALWAYS = ("PLATFORM",)                 # outside the sandbox, whatever the setting says
CACHE_SECONDS = 30
DEFAULT = {"methods": list(METHODS), "required_portals": ["PLATFORM", "INSPECTOR", "OPERATOR", "DRIVER", "AGENCY"],
           "enforce_in_sandbox": False, "code_minutes": 5, "resend_seconds": 60, "sends_per_hour": 5}


@dataclass(frozen=True)
class Policy:
    methods: tuple[str, ...]
    required_portals: tuple[str, ...]
    enforce_in_sandbox: bool
    code_minutes: int
    resend_seconds: int
    sends_per_hour: int

    @classmethod
    def of(cls, raw: dict) -> "Policy":
        v = {**DEFAULT, **(raw or {})}
        return cls(tuple(m for m in METHODS if m in v["methods"]), tuple(p for p in PORTALS if p in v["required_portals"]),
                   bool(v["enforce_in_sandbox"]), int(v["code_minutes"]), int(v["resend_seconds"]), int(v["sends_per_hour"]))

    def public(self) -> dict:
        return {"methods": list(self.methods), "required_portals": list(self.required_portals),
                "enforce_in_sandbox": self.enforce_in_sandbox, "code_minutes": self.code_minutes,
                "resend_seconds": self.resend_seconds, "sends_per_hour": self.sends_per_hour}

    def available(self) -> list[str]:
        """The methods a person can use on this server now: open in the policy and, for messages, deliverable."""
        from .modules.notify import providers
        out = [m for m in self.methods if m == "TOTP" or providers.enabled(m)]
        return out or ["TOTP"]

    def requires(self, portal: str) -> bool:
        sandbox = get_settings().sandbox
        if portal in ALWAYS and not sandbox:
            return True
        return portal in self.required_portals and (self.enforce_in_sandbox or not sandbox)


_cache: tuple[float, Policy] | None = None


async def current(conn: asyncpg.Connection) -> Policy:
    global _cache
    now = time.monotonic()
    if _cache and _cache[0] > now:
        return _cache[1]
    raw = await conn.fetchval("SELECT value::text FROM sys.setting WHERE key = 'auth.mfa'")
    policy = Policy.of(json.loads(raw) if raw else {})
    _cache = (now + CACHE_SECONDS, policy)
    return policy


def forget() -> None:
    """After a change in this process; the other processes follow within CACHE_SECONDS."""
    global _cache
    _cache = None


def enrolled(factors: list[str], policy: Policy) -> bool:
    """Whether the person can pass the second step: a verified factor of a method open on this server."""
    return bool(set(factors) & set(policy.available()))
