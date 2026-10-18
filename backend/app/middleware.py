"""Request middleware: request id, client address, IP rules (sec.ip_rule) and the activity log."""
import ipaddress
import logging
import re
import time
import uuid
from typing import Optional

from fastapi import Request
from fastapi.responses import JSONResponse, PlainTextResponse
from starlette.middleware.base import BaseHTTPMiddleware

from . import db, logs, ratelimit, shield
from .config import get_settings
from .errors import pool_busy_handler

MUTATING = {"POST", "PUT", "PATCH", "DELETE"}
CLIENT_HEADER = "x-masslak-client"


def portal_scope_for_path(path: str) -> str:
    """Maps a request path to the sec.ip_rule scope it falls under."""
    if path.startswith("/api/admin") or path.startswith("/api/security") or path.startswith("/api/regulator"):
        return "ADMIN"
    if path.startswith("/api/carrier"):
        return "OPERATOR"
    if path.startswith("/api/driver"):
        return "DRIVER"
    if path.startswith("/api/agency"):
        return "AGENCY"
    if path.startswith("/api/payments/notify"):
        return "PAYMENT_WEBHOOK"
    if path.startswith("/api/v1/"):
        return "API"
    return "PASSENGER"


def _trusted_networks():
    nets = []
    for item in get_settings().trusted_proxies.split(","):
        if item.strip():
            nets.append(ipaddress.ip_network(item.strip(), strict=False))
    return nets


def _is_trusted(addr: str, nets) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip in n for n in nets)


def client_ip(request: Request) -> str:
    """The client address. X-Forwarded-For is honoured only when the peer is a trusted proxy, and it is read
    from the right: each proxy appends the address it saw, so the first untrusted hop from the right is the
    client. Entries further left are supplied by the client and cannot be trusted."""
    peer = request.client.host if request.client else "127.0.0.1"
    nets = _trusted_networks()
    forwarded = request.headers.get("x-forwarded-for")
    if not forwarded or not _is_trusted(peer, nets):
        return peer
    hops = [h.strip() for h in forwarded.split(",") if h.strip()]
    for hop in reversed(hops):
        try:
            ipaddress.ip_address(hop)
        except ValueError:
            return peer
        if not _is_trusted(hop, nets):
            return hop
    return hops[0] if hops else peer


def visitor_country(request: Request) -> Optional[str]:
    """The visitor's country as the edge proxy names it (1141), or None; anything but a two-letter code (XX, T1 for Tor)
    counts as unknown. The proxy sets the header on every request, replacing what a client sent. It only chooses the
    first language a visitor sees, so a forged value costs nothing: no right, price or limit depends on it."""
    value = (request.headers.get(get_settings().country_header) or "").strip().upper()
    return value if re.fullmatch(r"[A-Z]{2}", value) and value != "XX" else None


ACCESS = logging.getLogger("masslak.access")


def _route(request: Request) -> str:
    """The route template (/api/bookings/{ref}), never the raw path with its identifiers."""
    route = request.scope.get("route")
    return getattr(route, "path", None) or "unmatched"


_WORD = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")


def _endpoint(request: Request) -> str:
    """What the activity log records as the endpoint (reviews of release 1.49.0, F-02): the route template, or, for a
    request refused before routing (a blocked address, a rate limit), the path with every segment that is not a plain
    word replaced by *. A token in a path (a report delivery's) or an identifier never reaches the log."""
    route = getattr(request.scope.get("route"), "path", None)
    if route:
        return route
    return "/".join(seg if not seg or _WORD.match(seg) else "*" for seg in request.url.path.split("/"))


class RequestContextMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request.state.request_id = uuid.uuid4()
        # the trace this request belongs to (W3C traceparent), kept for its logs, outbox events and outbound calls
        request.state.trace_id = logs.trace_from_header(request.headers.get("traceparent"))
        logs.request_id.set(str(request.state.request_id))
        logs.trace_id.set(request.state.trace_id)
        request.state.phases = {}
        logs.phases.set(request.state.phases)
        request.state.error_code = None
        request.state.client_ip = client_ip(request)
        request.state.principal = None
        request.state.api_client_id = None  # set by the integration API key check
        request.state.audit = None          # handlers may set {"action","object_type","object_id","reason"}
        path = request.url.path
        started = time.monotonic()
        if not path.startswith("/api/"):
            # the web pages: probes for files no route serves, scanners and odd methods are refused here too (1142)
            hit = shield.inspect_line(request.method, path, request.url.query, dict(request.headers)) \
                if shield.waf_mode() != "OFF" else None
            if hit:
                refused = await self._waf_refused(request, path, hit, started, page=True)
                if refused is not None:
                    return refused
            return await call_next(request)
        try:
            response = await self._api(request, call_next, path, started)
        except Exception:
            ACCESS.exception("request failed", extra={"method": request.method, "route": _route(request),
                                                      "status": 500, "duration_ms": int((time.monotonic() - started) * 1000)})
            raise
        response.headers["traceparent"] = logs.traceparent(request.state.trace_id)
        ACCESS.info("request", extra={"method": request.method, "route": _route(request), "status": response.status_code,
                                      "duration_ms": int((time.monotonic() - started) * 1000),
                                      **({"error_code": request.state.error_code} if request.state.error_code else {}),
                                      **logs.phase_fields(request.state.phases)})
        return response

    async def _api(self, request: Request, call_next, path: str, started: float):
        scope = portal_scope_for_path(path)
        bucket = ratelimit.bucket_for(path)
        ip = request.state.client_ip
        # the application firewall reads the request before anything else does (1142)
        hit = None
        if shield.waf_mode() != "OFF":
            hit = shield.inspect_line(request.method, path, request.url.query, dict(request.headers))
            if hit is None and request.method in MUTATING:
                length = request.headers.get("content-length")
                if length is None or (length.isdigit() and int(length) <= shield.MAX_BODY_INSPECT):
                    hit = shield.inspect_body(path, request.headers.get("content-type", ""), await request.body())
        elevated = shield.level() == "ELEVATED"
        ctx = db.Context(request_id=request.state.request_id, ip=ip, scope="SYSTEM")
        try:
            async with db.transaction(ctx) as conn:
                if shield.stale():
                    shield.load(await conn.fetchval("SELECT sec.shield_view()"))
                decision = await conn.fetchrow("SELECT action, rule_id FROM sec.ip_decision($1::inet, $2)", ip, scope)
                blocked = bool(decision and decision["action"] == "BLOCK")
                if hit and not blocked:
                    await shield.strike(conn, ip, request.method, path, hit, request.headers.get("user-agent", ""),
                                        shield.waf_mode() == "BLOCK")
                # sign-in and public endpoints: the address's bucket is shared by every process (1068), in this round
                # trip; a raised shield takes two tokens a request, halving the limits
                wait = 0.0
                if not blocked and not (hit and shield.waf_mode() == "BLOCK"):
                    for _ in range(2 if elevated else 1):
                        if bucket == "auth":
                            wait = wait or await ratelimit.check_address(conn, ratelimit.client_key(ip))
                        elif bucket == "public":
                            wait = wait or await ratelimit.check_public(conn, ratelimit.client_key(ip))
        except db.PoolBusy:
            # raised outside the routes, so the application's exception handlers would not see it
            return await pool_busy_handler(request, db.PoolBusy())
        if blocked:
            request.state.error_code = "IP_BLOCKED"
            shield.traffic.record(ip, 403, "blocked")
            await self._log(request, scope, "request.blocked", "BLOCKED", 403, started,
                            reason=f"ip_rule {decision['rule_id']}")
            return JSONResponse({"error": {"code": "IP_BLOCKED", "message": "access from this address is blocked"}},
                                status_code=403)
        if hit and shield.waf_mode() == "BLOCK":
            return await self._waf_refused(request, path, hit, started, scope=scope, recorded=True)
        if shield.level() == "LOCKDOWN" and not shield.lockdown_allows(
                path, scope, decision["action"] if decision else None,
                bool(request.cookies.get("msk_session") or request.headers.get("authorization"))):
            request.state.error_code = "SHIELD_LOCKDOWN"
            shield.traffic.record(ip, 503, "blocked")
            return JSONResponse({"error": {"code": "SHIELD_LOCKDOWN",
                                           "message": "the platform is paused for a security check; try again shortly"}},
                                status_code=503, headers={"Retry-After": "60"})

        if bucket == "api":
            wait = ratelimit.limiter().check(ip, bucket)
            if not wait and elevated:
                wait = ratelimit.limiter().check(ip, bucket)
        if wait:
            shield.traffic.record(ip, 429, "limited")
            request.state.error_code = "RATE_LIMITED"
            await self._log(request, scope, "request.rate_limited", "BLOCKED", 429, started, reason="rate limit")
            return JSONResponse({"error": {"code": "RATE_LIMITED", "message": "too many requests, try again shortly"}},
                                status_code=429, headers={"Retry-After": str(max(1, round(wait)))})

        # CSRF defence in depth: browsers cannot add this header cross-site without CORS approval
        # (the integration API authenticates with keys in a header, never cookies, so it needs no such header)
        if request.method in MUTATING and not path.startswith(("/api/payments/notify", "/api/v1/")) \
                and request.headers.get(CLIENT_HEADER) not in ("web", "android", "ios"):
            request.state.error_code = "CLIENT_HEADER_REQUIRED"
            return JSONResponse({"error": {"code": "CLIENT_HEADER_REQUIRED", "message": "missing client header"}},
                                status_code=400)

        response = await call_next(request)
        shield.traffic.record(ip, response.status_code,
                              "auth_fail" if bucket == "auth" and response.status_code in (401, 423) else None)
        if request.state.api_client_id:
            from .modules.integration.auth import record_usage
            await record_usage(request.state.api_client_id, response.status_code >= 400)
        if request.method in MUTATING or request.state.audit:
            result = "SUCCESS" if response.status_code < 400 else ("DENIED" if response.status_code in (401, 403) else "ERROR")
            await self._log(request, scope, None, result, response.status_code, started)
        response.headers["X-Request-Id"] = str(request.state.request_id)
        return response

    async def _waf_refused(self, request: Request, path: str, hit, started: float, *, scope: str = "PASSENGER",
                           page: bool = False, recorded: bool = False):
        """A request the firewall refused: recorded (its address blocked at the policy's number of hits), counted, and
        answered without saying which rule matched. On the web pages a probe looks like a page that does not exist."""
        ip = request.state.client_ip
        blocking = shield.waf_mode() == "BLOCK"
        if not recorded:
            try:
                async with db.transaction(db.Context(request_id=request.state.request_id, ip=ip, scope="SYSTEM")) as conn:
                    await shield.strike(conn, ip, request.method, path, hit, request.headers.get("user-agent", ""), blocking)
            except Exception:                  # noqa: BLE001 - a failed record must not open the door
                logging.getLogger("masslak.shield").warning("firewall hit not recorded", exc_info=True)
        if page and not blocking:
            return None                        # detect mode: noted, the page is served
        shield.traffic.record(ip, 404 if page else 403, "waf")
        if page:
            return PlainTextResponse("Not found", status_code=404)
        request.state.error_code = "REQUEST_REJECTED"
        await self._log(request, scope, "request.firewall", "BLOCKED", 403, started, reason=f"waf {hit.rule} in {hit.location}")
        return JSONResponse({"error": {"code": "REQUEST_REJECTED", "message": "the request was rejected by the platform firewall"}},
                            status_code=403)

    async def _log(self, request: Request, scope: str, action, result: str, status: int, started: float, reason=None):
        pr = request.state.principal
        audit = request.state.audit or {}
        route = request.scope.get("route")
        action = action or audit.get("action") or (getattr(route, "name", None) or _endpoint(request))
        try:
            async with db.raw_connection() as conn:
                await conn.execute(
                    """INSERT INTO audit.activity_log (request_id, actor_type, user_id, company_id, session_id, portal, ip,
                         user_agent, http_method, endpoint, action, object_type, object_id, result, http_status,
                         latency_ms, reason, api_client_id)
                       VALUES ($1, $2, $3, $4, $5, $6, $7::inet, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)""",
                    request.state.request_id, "API_CLIENT" if request.state.api_client_id else "USER" if pr else "SYSTEM",
                    pr.user_id if pr else None, pr.company_id if pr else None, pr.session_id if pr else None,
                    pr.portal if pr else scope, request.state.client_ip, request.headers.get("user-agent", "")[:300],
                    request.method, _endpoint(request)[:300], str(action)[:120], audit.get("object_type"),
                    audit.get("object_id"), result, status, int((time.monotonic() - started) * 1000),
                    reason or audit.get("reason"), request.state.api_client_id,
                )
        except Exception as exc:  # the activity log must never break the request itself, but a gap must be seen
            db.AUDIT_WRITE_FAILURES[0] += 1
            logging.getLogger("masslak.audit").warning(
                "activity log not written for %s %s (%s %s); data changes stay in audit.row_change",
                request.method, _endpoint(request)[:120], exc.__class__.__name__, getattr(exc, "sqlstate", ""))


class HeadAsGet:
    """Answers HEAD like GET without the body. FastAPI routes declare GET only, and monitors and crawlers that check
    a page with HEAD would otherwise get 405."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "HEAD":
            return await self.app(scope, receive, send)

        async def send_headers_only(message):
            if message["type"] == "http.response.body":
                if message.get("more_body"):
                    return
                message = {"type": "http.response.body", "body": b"", "more_body": False}
            await send(message)

        await self.app({**scope, "method": "GET"}, receive, send_headers_only)
