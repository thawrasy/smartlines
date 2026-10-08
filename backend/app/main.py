"""Masslak API application."""
from contextlib import asynccontextmanager
from pathlib import Path

import asyncpg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import db, metrics
from .config import get_settings
from .errors import ApiError, api_error_handler, db_error_handler
from .middleware import HeadAsGet, RequestContextMiddleware
from .modules.agency import api as agency_api
from .modules.fleet import api as fleet_api
from .modules.payouts import api as payouts_api
from .modules.documents import api as documents_api
from .modules.notify import api as notify_api
from .modules.account import api as account_api
from .modules.reports import api as reports_api
from .modules.payments import api as payments_api
from .modules.integration import console as integration_console
from .modules.integration import v1 as integration_v1
from .modules.family import api as family_api
from .modules.manifests import api as manifests_api
from .modules.seo import pages as seo_pages
from .modules.seo.app_shell import shell as app_shell
from .modular import api as modular_api
from .modular import workflows as modular_workflows
from .routers import admin, auth, bookings, carrier, driver, public, regulator, security, verify, wallet


@asynccontextmanager
async def lifespan(_: FastAPI):
    await db.open_pools()
    from . import egress
    egress.require_in_production()        # outbound traffic only through the egress proxy (T3-02)
    await db.require_reports_replica()    # reports read the replica, never the booking database (architecture review)
    if not get_settings().sandbox:
        # fail at start, not at the first booking: production needs real keys from KMS or Vault (review 3.12)
        from . import crypto
        async with db.raw_connection() as conn:
            await crypto.cipher(conn)
    yield
    await db.close_pools()


app = FastAPI(title="Masslak API", version="0.1.0", lifespan=lifespan,
              docs_url="/api/docs", openapi_url="/api/openapi.json", redoc_url=None)
app.add_middleware(RequestContextMiddleware)
app.add_exception_handler(ApiError, api_error_handler)
app.add_exception_handler(asyncpg.PostgresError, db_error_handler)


@app.exception_handler(RequestValidationError)
async def validation_handler(_: Request, exc: RequestValidationError):
    errors = exc.errors()
    fields = [".".join(str(p) for p in e["loc"][1:]) for e in errors]
    # Model rules raise "CODE: message"; the first such code becomes the error code
    code = next((e["msg"].split("Value error, ", 1)[-1].split(":", 1)[0] for e in errors
                 if e.get("type") == "value_error" and ":" in e["msg"]), "VALIDATION_FAILED")
    return JSONResponse({"error": {"code": code, "message": "invalid request", "fields": fields}}, status_code=422)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Permissions-Policy", "camera=(self), geolocation=(self), microphone=()")
    response.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
        "font-src 'self' https://fonts.gstatic.com; script-src 'self'; connect-src 'self'; frame-ancestors 'none'")
    if request.url.path.startswith("/api/"):
        response.headers.setdefault("Cache-Control", "no-store")
        response.headers.setdefault("X-Robots-Tag", "noindex, nofollow")
    return response


for r in (metrics.router, auth.router, public.router, bookings.router, wallet.router, carrier.router, driver.router,
          admin.router, security.router, regulator.router, verify.router, agency_api.router,
          fleet_api.router, payouts_api.company, payouts_api.platform,
          documents_api.company, documents_api.platform, notify_api.router,
          account_api.router, account_api.platform, modular_api.router, modular_workflows.router, reports_api.router, payments_api.router,
          integration_console.router, integration_v1.router, family_api.router, manifests_api.carrier, manifests_api.platform,
          seo_pages.router):
    app.include_router(r)

app.add_middleware(metrics.MetricsMiddleware)   # request counts and latency per route (T3-16)
app.add_middleware(HeadAsGet)          # added last, so it wraps everything else


# The built web interface (frontend/dist) is served by the same process; unknown paths fall back to
# index.html so the client-side router can handle them.
_static = Path(get_settings().static_dir).resolve()
if (_static / "index.html").exists():
    app.mount("/assets", StaticFiles(directory=_static / "assets"), name="assets")

    # top-level paths of the web app; anything else is a real 404 (no "soft 404" pages for search engines)
    APP_PATHS = {"", "account", "admin", "agency", "booking", "carrier", "driver", "family", "login", "m", "mfa", "pay", "register",
                 "regulator", "search", "security", "services", "track", "trip", "trips", "verify", "wallet"}

    @app.get("/{path:path}", include_in_schema=False)
    async def spa(path: str):
        if path.startswith("api/"):
            return JSONResponse({"error": {"code": "NOT_FOUND", "message": "unknown endpoint"}}, status_code=404)
        candidate = (_static / path).resolve()
        if path and candidate.is_file() and _static in candidate.parents:
            return FileResponse(candidate)
        known = path.split("/", 1)[0] in APP_PATHS
        # the app's own screens are not landing pages: only the home page is indexed, the /ar and /en pages carry the content
        headers = {} if path == "" else {"X-Robots-Tag": "noindex, follow"}
        return HTMLResponse(app_shell(_static / "index.html"), status_code=200 if known else 404, headers=headers)
