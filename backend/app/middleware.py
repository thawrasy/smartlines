"""Request middleware: request id, client address, IP rules (sec.ip_rule) and the activity log."""
import ipaddress
import time
import uuid

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from . import db, ratelimit
from .config import get_settings

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


class RequestContextMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request.state.request_id = uuid.uuid4()
        request.state.client_ip = client_ip(request)
        request.state.principal = None
        request.state.api_client_id = None  # set by the integration API key check
        request.state.audit = None          # handlers may set {"action","object_type","object_id","reason"}
        path = request.url.path
        started = time.monotonic()
        if not path.startswith("/api/"):
            return await call_next(request)

        scope = portal_scope_for_path(path)
        bucket = ratelimit.bucket_for(path)
        ctx = db.Context(request_id=request.state.request_id, ip=request.state.client_ip, scope="SYSTEM")
        async with db.transaction(ctx) as conn:
            decision = await conn.fetchrow("SELECT action, rule_id FROM sec.ip_decision($1::inet, $2)",
                                           request.state.client_ip, scope)
            # sign-in endpoints: the address's bucket is shared by every process (1068), in this same round trip
            wait = await ratelimit.check_address(conn, request.state.client_ip) if bucket == "auth" else 0.0
        if decision and decision["action"] == "BLOCK":
            await self._log(request, scope, "request.blocked", "BLOCKED", 403, started,
                            reason=f"ip_rule {decision['rule_id']}")
            return JSONResponse({"error": {"code": "IP_BLOCKED", "message": "access from this address is blocked"}},
                                status_code=403)

        if bucket != "auth":
            wait = ratelimit.limiter().check(request.state.client_ip, bucket)
        if wait:
            await self._log(request, scope, "request.rate_limited", "BLOCKED", 429, started, reason="rate limit")
            return JSONResponse({"error": {"code": "RATE_LIMITED", "message": "too many requests, try again shortly"}},
                                status_code=429, headers={"Retry-After": str(max(1, round(wait)))})

        # CSRF defence in depth: browsers cannot add this header cross-site without CORS approval
        # (the integration API authenticates with keys in a header, never cookies, so it needs no such header)
        if request.method in MUTATING and not path.startswith(("/api/payments/notify", "/api/v1/")) \
                and request.headers.get(CLIENT_HEADER) not in ("web", "android", "ios"):
            return JSONResponse({"error": {"code": "CLIENT_HEADER_REQUIRED", "message": "missing client header"}},
                                status_code=400)

        response = await call_next(request)
        if request.state.api_client_id:
            from .modules.integration.auth import record_usage
            await record_usage(request.state.api_client_id, response.status_code >= 400)
        if request.method in MUTATING or request.state.audit:
            result = "SUCCESS" if response.status_code < 400 else ("DENIED" if response.status_code in (401, 403) else "ERROR")
            await self._log(request, scope, None, result, response.status_code, started)
        response.headers["X-Request-Id"] = str(request.state.request_id)
        return response

    async def _log(self, request: Request, scope: str, action, result: str, status: int, started: float, reason=None):
        pr = request.state.principal
        audit = request.state.audit or {}
        route = request.scope.get("route")
        action = action or audit.get("action") or (getattr(route, "name", None) or request.url.path)
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
                    request.method, request.url.path[:300], str(action)[:120], audit.get("object_type"),
                    audit.get("object_id"), result, status, int((time.monotonic() - started) * 1000),
                    reason or audit.get("reason"), request.state.api_client_id,
                )
        except Exception:  # the activity log must never break the request itself
            pass


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
