"""Masslak API application."""
import asyncio
from contextlib import asynccontextmanager
from pathlib import Path

import asyncpg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import db, logredact, logs, metrics
from .config import get_settings
from .errors import (ApiError, api_error_handler, db_error_handler, pool_busy_handler, store_unavailable_handler,
                     unreachable_handler)
from .middleware import HeadAsGet, RequestContextMiddleware
from .modules.agency import api as agency_api
from .modules.cash import api as cash_api
from .modules.fleet import api as fleet_api
from .modules.payouts import api as payouts_api
from .modules.documents import api as documents_api
from .modules.documents import storage
from .modules.notify import api as notify_api
from .modules.account import api as account_api
from .modules.reports import api as reports_api
from .modules.payments import api as payments_api
from .modules.integration import console as integration_console
from .modules.integration import v1 as integration_v1
from .modules.family import api as family_api
from .modules.support import api as support_api
from .modules.manifests import api as manifests_api
from .modules.parcels import api as parcels_api
from .modules.seo import pages as seo_pages
from .modules.seo.app_shell import shell as app_shell
from .modular import api as modular_api
from .modular import workflows as modular_workflows
from .routers import admin, auth, bookings, carrier, driver, public, regulator, security, verify, wallet


logredact.install()                       # personal data and secrets never reach the logs, whoever logs them
logs.configure("api")                     # one JSON object per line outside the sandbox (app/logs.py)


@asynccontextmanager
async def lifespan(_: FastAPI):
    from .security import require_keys_in_production
    require_keys_in_production()          # no default or weak signing keys outside the sandbox (review stage A1)
    from . import profile
    profile.require_in_production()       # TLS to the database, the key service, no owner secret (package 2, H-05, H-06)
    await db.open_pools()
    from . import egress
    egress.require_in_production()        # outbound traffic only through the egress proxy (T3-02)
    from .modules.notify import providers
    providers.require_in_production()     # no personal data in plain message logs outside the sandbox (R-27)
    storage.store()                       # a wrong file store setting stops the start, not the first upload
    await db.require_reports_replica()    # reports read the replica, never the booking database (architecture review)
    if not get_settings().sandbox:
        # fail at start, not at the first booking: production needs real keys from KMS or Vault (review 3.12)
        from . import crypto
        async with db.raw_connection() as conn:
            await crypto.cipher(conn)
    from . import release
    rel = await release.current()
    app.version = rel["version"] if rel else "unknown"    # the release the database is at, not a number kept by hand
    logs.set_version(app.version)
    # the durability the owner chose (decision 1): compared by the monitoring with what the database does
    metrics.gauge("masslak_zero_data_loss_configured", 1.0 if get_settings().zero_data_loss else 0.0)
    publishing = asyncio.create_task(metrics.publisher()) if metrics._processes() > 1 else None
    yield
    if publishing:
        publishing.cancel()
        metrics.publish()                 # the last figures of this process stay in the instance's totals
    await db.close_pools()


# The internal API's document lists every route; production does not publish it (code review of October 2026, 3.1)
_docs = get_settings().api_docs if get_settings().api_docs is not None else get_settings().sandbox
app = FastAPI(title="Masslak API", version="unknown", lifespan=lifespan, redoc_url=None,
              docs_url="/api/docs" if _docs else None, openapi_url="/api/openapi.json" if _docs else None)
app.add_middleware(RequestContextMiddleware)
app.add_exception_handler(ApiError, api_error_handler)
app.add_exception_handler(asyncpg.PostgresError, db_error_handler)
app.add_exception_handler(db.PoolBusy, pool_busy_handler)      # pool exhausted for longer than db_acquire_timeout
app.add_exception_handler(storage.StoreUnavailable, store_unavailable_handler)   # the object store for files is down
# no server reachable, or none of the listed ones is the primary yet (failover, review stage D6)
app.add_exception_handler(ConnectionError, unreachable_handler)
app.add_exception_handler(asyncpg.exceptions.TargetServerAttributeNotMatched, unreachable_handler)


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
          support_api.router, support_api.admin, cash_api.router, seo_pages.router, parcels_api.customer, parcels_api.carrier):
    app.include_router(r)

app.add_middleware(metrics.MetricsMiddleware)   # request counts and latency per route (T3-16)
app.add_middleware(HeadAsGet)          # added last, so it wraps everything else


# The built web interface (frontend/dist) is served by the same process; unknown paths fall back to
# index.html so the client-side router can handle them.
_static = Path(get_settings().static_dir).resolve()
# top-level paths of the web app (frontend/src/App.tsx; tests/test_api_contract.py keeps the two in step); anything else
# is a real 404 (no "soft 404" pages for search engines)
APP_PATHS = {"", "account", "admin", "agency", "booking", "carrier", "driver", "family", "login", "m", "mfa", "parcels", "pay", "register",
             "regulator", "search", "security", "services", "support", "track", "trip", "trips", "verify", "wallet"}
if (_static / "index.html").exists():
    app.mount("/assets", StaticFiles(directory=_static / "assets"), name="assets")

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
