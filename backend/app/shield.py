"""The platform shield (schema file 1142; owner's request, October 2026).

Three parts, each process running its own copy:

* The application firewall: every request is read before any route runs. The method, the address and its query, the
  headers a client controls (never the cookie or the authorization header) and a JSON or form body are looked at
  for attack patterns: SQL injection, script injection, shell commands chained into a value (`; ping ...`, `$(...)`),
  path traversal, template and JNDI lookups, cloud metadata addresses, null bytes; known scanners by their agent;
  probes for files no route serves (/.env, /.git, /wp-admin, *.php); oversized requests. A hit is refused with 403 and
  recorded (sec.waf_strike); the policy's number of hits in its window blocks the address for a while. Statements are
  always parameterised and every route validates its input, so the firewall is one layer more, not the only one.
  Values named like secrets (passwords, codes, tokens) are not inspected: a password may hold any characters.
* The traffic counters: each process counts its requests per 10-second window (refusals, errors, firewall hits,
  failed sign-ins, its busiest addresses) and adds them to sec.traffic_sample every 10 seconds. The worker reads the
  last minute against the usual once a minute (sec.evaluate_traffic) and alerts the security staff.
* The shield level, read from sec.shield_state at most every few seconds: ELEVATED halves the request limits; LOCKDOWN
  stops the platform's traffic until the security staff have checked, except the platform console, sign-in, payment
  notices, health checks and addresses on an allow rule. The one-session rule per portal is read with it.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import socket
import time
import uuid
from collections import Counter
from dataclasses import dataclass
from typing import Any, Optional
from urllib.parse import parse_qsl, unquote_plus

log = logging.getLogger("masslak.shield")

# ------------------------------------------------------------------ firewall rules
_I = re.IGNORECASE
RULES: tuple[tuple[str, re.Pattern], ...] = (
    ("sql_injection", re.compile(
        r"\bunion\b[\s(]{1,20}(all\s+)?\bselect\b"
        r"|\b(pg_sleep|benchmark|waitfor\s+delay|dbms_pipe\.receive_message)\s*\("
        r"|\bsleep\s*\(\s*\d+\s*\)"
        r"|'\s*(or|and)\s+'?\d+'?\s*=\s*'?\d+"
        r"|'\s*(or|and)\s+'[^']{0,20}'\s*=\s*'"
        r"|;\s*(drop|truncate|alter)\s+(table|database|schema)\b"
        r"|\binformation_schema\b|\bpg_catalog\.|\bpg_shadow\b|\bxp_cmdshell\b"
        r"|\binto\s+(out|dump)file\b|\bload_file\s*\(", _I)),
    ("script_injection", re.compile(
        r"<\s*script\b|<\s*/\s*script\s*>|<\s*iframe\b|<\s*object\b|<\s*embed\b"
        r"|<[^>]{0,80}\bon(error|load|mouseover|focus|click|begin|animationstart)\s*="
        r"|javascript\s*:|vbscript\s*:|data\s*:\s*text/html|document\.cookie|\bsrcdoc\s*=", _I)),
    ("command_injection", re.compile(
        r"(;|\|\|?|&&|\$\(|`)\s*(ping|nc|ncat|netcat|curl|wget|bash|sh|zsh|cat|rm|chmod|chown|python3?|perl|php|ruby"
        r"|nslookup|dig|whoami|id|uname|ifconfig|ip\s+a|powershell|cmd(\.exe)?)\b"
        r"|\$\{IFS\}|\$IFS\$|/bin/(ba)?sh\b|\bcmd\.exe\b", _I)),
    ("path_traversal", re.compile(r"\.\./|\.\.\\|/etc/(passwd|shadow|hosts)\b|/proc/self/|\bc:\\windows\\", _I)),
    ("template_injection", re.compile(r"\$\{\s*jndi\s*:|\$\{\s*(env|sys|java|lower|upper)\s*:|\{\{\s*(7\s*\*\s*7|config|self|request|cycler|joiner)\b|<%=|#\{\s*7\s*\*\s*7\s*\}", _I)),
    ("metadata_address", re.compile(r"169\.254\.169\.254|metadata\.google\.internal|100\.100\.100\.200|fd00:ec2::254", _I)),
    ("null_byte", re.compile(r"\x00")),
)
# the body is free text in places (a support message, a note): only the unambiguous patterns apply there
BODY_RULES = {"sql_injection", "script_injection", "command_injection", "template_injection", "metadata_address", "null_byte"}
BODY_TRAVERSAL = re.compile(r"/etc/(passwd|shadow)\b|/proc/self/", _I)

SCANNERS = re.compile(
    r"sqlmap|nikto|\bnmap\b|masscan|zgrab|nuclei|acunetix|nessus|openvas|wpscan|dirbuster|gobuster|\bffuf\b|feroxbuster"
    r"|\bhydra\b|w3af|arachni|jaeles|commix|havij|netsparker|appscan|burpcollaborator|interactsh|zmeu|morfeus", _I)
PROBES = re.compile(
    r"/(\.env|\.git|\.svn|\.hg|\.htaccess|\.htpasswd|\.ds_store|\.aws|\.ssh|wp-admin|wp-login|wp-content|wp-includes|xmlrpc\.php"
    r"|phpmyadmin|pma|myadmin|cgi-bin|actuator|server-status|vendor/phpunit|boaform|hnap1|owa/|autodiscover|telescope|_ignition"
    r"|console/|solr/|jmx-console|manager/html)"
    r"|\.(php\d?|asp|aspx|jsp|cgi|pl|env|bak|old|orig|sql|ini|swp|map)$", _I)
# bait addresses (1167): paths no route serves and no honest client asks for; robots.txt names /backup/ as disallowed,
# which only a scanner reads as an invitation. A touch blocks the address at once (sec.bait_touch).
BAIT = re.compile(r"^/(api/internal|api/debug|api/v0|api/private|backup|db-backup)(/|$)", _I)
BAD_METHODS = {"TRACE", "TRACK", "CONNECT", "DEBUG", "PROPFIND", "PROPPATCH", "MKCOL", "COPY", "MOVE", "LOCK", "UNLOCK"}
HEADERS_INSPECTED = ("user-agent", "referer", "x-forwarded-host", "origin", "x-original-url", "x-rewrite-url")
SECRET_KEYS = re.compile(r"pass(word)?|secret|token|code|otp|pin|signature|refresh|credential", _I)
MAX_URL, MAX_HEADER, MAX_HEADERS, MAX_PARAMS, MAX_BODY_INSPECT = 2048, 8192, 100, 100, 256 * 1024
BODY_EXEMPT = ("/api/payments/notify",)    # provider notices are signed and checked by their handler


@dataclass
class Hit:
    rule: str
    location: str
    sample: str


def _decoded(text: str) -> str:
    """The text as the application will read it: URL-decoded twice (an encoded % hides one level)."""
    once = unquote_plus(text)
    return unquote_plus(once) if "%" in once else once


def _match(text: str, rules=None) -> Optional[tuple[str, str]]:
    for name, pattern in RULES:
        if rules is not None and name not in rules:
            continue
        m = pattern.search(text)
        if m:
            return name, text[max(0, m.start() - 20): m.end() + 20]
    return None


def inspect_line(method: str, path: str, query: str, headers: dict[str, str]) -> Optional[Hit]:
    """Checks what every request carries before its body: method, address, query and the inspected headers."""
    if method.upper() in BAD_METHODS:
        return Hit("bad_method", "METHOD", method[:10])
    if len(path) + len(query) > MAX_URL:
        return Hit("oversize", "SIZE", f"url {len(path) + len(query)}")
    if len(headers) > MAX_HEADERS or any(len(v) > MAX_HEADER for v in headers.values()):
        return Hit("oversize", "SIZE", "headers")
    p = _decoded(path)
    if PROBES.search(p):
        return Hit("probe", "PATH", p[:160])
    found = _match(p)
    if found:
        return Hit(found[0], "PATH", found[1])
    if query:
        params = parse_qsl(query, keep_blank_values=True)
        if len(params) > MAX_PARAMS:
            return Hit("oversize", "SIZE", f"{len(params)} parameters")
        for k, v in params:
            if SECRET_KEYS.search(k):
                continue
            found = _match(_decoded(f"{k}={v}"))
            if found:
                return Hit(found[0], "QUERY", found[1])
    agent = headers.get("user-agent", "")
    if SCANNERS.search(agent):
        return Hit("scanner", "AGENT", agent[:160])
    for name in HEADERS_INSPECTED:
        value = headers.get(name)
        if value:
            found = _match(_decoded(value))
            if found:
                return Hit(found[0], "HEADER", f"{name}: {found[1]}")
    return None


def _strings(value: Any, key: str = "", depth: int = 0, out: list | None = None) -> list[tuple[str, str]]:
    out = [] if out is None else out
    if len(out) > 2000 or depth > 12:
        return out
    if isinstance(value, dict):
        for k, v in value.items():
            if not SECRET_KEYS.search(str(k)):
                _strings(v, str(k), depth + 1, out)
    elif isinstance(value, list):
        for v in value:
            _strings(v, key, depth + 1, out)
    elif isinstance(value, str):
        out.append((key, value))
    return out


def inspect_body(path: str, content_type: str, body: bytes) -> Optional[Hit]:
    """A JSON or form body: each string value (not those named like secrets) against the unambiguous patterns."""
    if not body or len(body) > MAX_BODY_INSPECT or path.startswith(BODY_EXEMPT):
        return None
    ct = content_type.split(";", 1)[0].strip().lower()
    try:
        if ct == "application/json":
            values = _strings(json.loads(body))
        elif ct == "application/x-www-form-urlencoded":
            values = [(k, v) for k, v in parse_qsl(body.decode("utf-8", "replace"), keep_blank_values=True) if not SECRET_KEYS.search(k)]
        else:
            return None        # files and other bodies have their own checks (type, size, virus scan)
    except (ValueError, UnicodeDecodeError):
        return None            # a body the route cannot read is refused by the route itself
    for _key, text in values:
        found = _match(text, BODY_RULES) or (("path_traversal", text[:160]) if BODY_TRAVERSAL.search(text) else None)
        if found:
            return Hit(found[0], "BODY", found[1])
    return None


# ------------------------------------------------------------------ the shield level and policy
_state: dict = {"level": "NORMAL", "policy": {"waf_mode": "BLOCK"}, "session_policy": {}}
_loaded_at = 0.0
REFRESH_SECONDS = 5.0


def stale() -> bool:
    return time.monotonic() - _loaded_at > REFRESH_SECONDS


def load(view: Optional[dict]) -> None:
    """Keeps the shield as sec.shield_view() returned it (read in the request's first round trip when stale)."""
    global _state, _loaded_at
    if view:
        _state = view if isinstance(view, dict) else json.loads(view)
    _loaded_at = time.monotonic()


def level() -> str:
    return _state.get("level", "NORMAL")


def policy() -> dict:
    return _state.get("policy") or {}


def waf_mode() -> str:
    return policy().get("waf_mode", "BLOCK")


def session_mode(portal: str) -> str:
    """SINGLE (a new sign-in ends the account's other sessions in that portal) unless the platform set MULTI."""
    return (_state.get("session_policy") or {}).get(portal, "SINGLE")


LOCKDOWN_OPEN = ("/api/health", "/api/ready", "/api/metrics", "/api/auth/", "/api/payments/notify")


def lockdown_allows(path: str, scope: str, rule_action: Optional[str], signed_in: bool) -> bool:
    """What still passes in a lockdown: the platform console, sign-in (staff must reach the console), payment notices
    (money already paid is not lost), health checks, addresses on an allow rule, and signed-in accounts when the
    policy keeps them."""
    if rule_action == "ALLOW" or scope == "ADMIN" or path.startswith(LOCKDOWN_OPEN):
        return True
    return signed_in and bool(policy().get("lockdown_allow_signed_in"))


# ------------------------------------------------------------------ traffic counters
class Traffic:
    """This process's counts per 10-second window; at most 5000 addresses a window, the busiest 20 kept."""
    WINDOW = 10
    MAX_ADDRESSES = 5000

    def __init__(self) -> None:
        self.windows: dict[int, dict] = {}

    def _w(self, now: float) -> dict:
        start = int(now // self.WINDOW * self.WINDOW)
        w = self.windows.get(start)
        if w is None:
            w = self.windows[start] = {"requests": 0, "err_4xx": 0, "err_5xx": 0, "blocked": 0, "limited": 0,
                                       "waf": 0, "auth_fail": 0, "top": Counter()}
        return w

    def record(self, ip: str, status: int, kind: Optional[str] = None, now: Optional[float] = None) -> None:
        w = self._w(time.time() if now is None else now)
        w["requests"] += 1
        if 400 <= status < 500:
            w["err_4xx"] += 1
        elif status >= 500:
            w["err_5xx"] += 1
        if kind in ("blocked", "limited", "waf", "auth_fail"):
            w[kind] += 1
        top = w["top"]
        if ip in top or len(top) < self.MAX_ADDRESSES:
            top[ip] += 1

    def take_closed(self, now: Optional[float] = None) -> list[tuple[int, dict]]:
        """The windows that ended, removed from memory (the current one keeps counting)."""
        current = int((time.time() if now is None else now) // self.WINDOW * self.WINDOW)
        done = sorted(k for k in self.windows if k < current)
        return [(k, self.windows.pop(k)) for k in done]


traffic = Traffic()
INSTANCE = f"{socket.gethostname()[:60]}:{os.getpid()}"


async def flush(conn, closed: list[tuple[int, dict]]) -> int:
    from datetime import datetime, timezone
    for start, w in closed:
        top = {ip: n for ip, n in w["top"].most_common(20)}
        await conn.execute(
            "SELECT sec.add_traffic_sample($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb)",
            datetime.fromtimestamp(start, timezone.utc), INSTANCE, w["requests"], w["err_4xx"], w["err_5xx"],
            w["blocked"], w["limited"], w["waf"], w["auth_fail"], json.dumps(top))
    return len(closed)


async def publisher() -> None:
    """Background task of each API process: closed windows go to the database every 10 seconds."""
    from . import db
    while True:
        await asyncio.sleep(Traffic.WINDOW)
        closed = traffic.take_closed()
        if not closed:
            continue
        try:
            async with db.transaction(db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")) as conn:
                await flush(conn, closed)
        except Exception:                      # noqa: BLE001 - the counters must never stop the API
            log.warning("traffic sample not written; %d windows dropped", len(closed), exc_info=True)


def is_bait(path: str) -> bool:
    return bool(BAIT.match(path))


async def bait_touch(conn, ip: str, method: str, path: str, agent: str) -> Optional[int]:
    """Records the touch and blocks the address, unless an approved exception lets it through (1167)."""
    return await conn.fetchval("SELECT sec.bait_touch($1::inet, $2, $3, $4)", ip, method, path[:300], agent[:200])


async def strike(conn, ip: str, method: str, path: str, hit: Hit, agent: str, blocked: bool) -> int:
    return await conn.fetchval("SELECT sec.waf_strike($1::inet, $2, $3, $4, $5, $6, $7, $8)",
                               ip, method, path[:300], hit.rule, hit.location, hit.sample[:160], agent[:200], blocked)
