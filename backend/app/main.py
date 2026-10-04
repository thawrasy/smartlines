"""Masslak API application."""
from contextlib import asynccontextmanager
from pathlib import Path

import asyncpg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from . import db
from .config import get_settings
from .errors import ApiError, api_error_handler, db_error_handler
from .middleware import RequestContextMiddleware
from .modules.agency import api as agency_api
from .routers import admin, auth, bookings, carrier, driver, public, regulator, security, verify, wallet


@asynccontextmanager
async def lifespan(_: FastAPI):
    await db.open_pools()
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
    return response


for r in (auth.router, public.router, bookings.router, wallet.router, carrier.router, driver.router,
          admin.router, security.router, regulator.router, verify.router, agency_api.router):
    app.include_router(r)


# The built web interface (frontend/dist) is served by the same process; unknown paths fall back to
# index.html so the client-side router can handle them.
_static = Path(get_settings().static_dir).resolve()
if (_static / "index.html").exists():
    app.mount("/assets", StaticFiles(directory=_static / "assets"), name="assets")

    @app.get("/{path:path}", include_in_schema=False)
    async def spa(path: str):
        if path.startswith("api/"):
            return JSONResponse({"error": {"code": "NOT_FOUND", "message": "unknown endpoint"}}, status_code=404)
        candidate = (_static / path).resolve()
        if path and candidate.is_file() and _static in candidate.parents:
            return FileResponse(candidate)
        return FileResponse(_static / "index.html")
