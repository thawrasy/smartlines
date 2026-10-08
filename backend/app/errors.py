"""Uniform error responses: {"error": {"code", "message"}}.

The message is a developer-facing English text; user interfaces translate the code (i18n),
and no logic depends on the message (study section 31).
"""
import logging
import re

import asyncpg
from fastapi import Request
from fastapi.responses import JSONResponse


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str = "", **details):
        self.status, self.code, self.message, self.details = status, code, message or code, details


def not_found(what: str = "resource") -> ApiError:
    return ApiError(404, "NOT_FOUND", f"{what} not found")


def forbidden(message: str = "not allowed") -> ApiError:
    return ApiError(403, "FORBIDDEN", message)


async def api_error_handler(_: Request, exc: ApiError) -> JSONResponse:
    body = {"error": {"code": exc.code, "message": exc.message, **exc.details}}
    return JSONResponse(body, status_code=exc.status)


# Database business errors are raised as "CODE: detail" (see db/schema); map them to 409/422
_DB_CODE = re.compile(r"^([A-Z][A-Z_]+)(?::|$)")


async def db_error_handler(_: Request, exc: asyncpg.PostgresError) -> JSONResponse:
    msg = str(exc)
    if isinstance(exc, asyncpg.UniqueViolationError):
        return JSONResponse({"error": {"code": "ALREADY_EXISTS", "message": "duplicate value"}}, status_code=409)
    if isinstance(exc, asyncpg.ExclusionViolationError):
        return JSONResponse({"error": {"code": "SCHEDULE_CONFLICT", "message": "overlapping assignment"}}, status_code=409)
    if isinstance(exc, (asyncpg.CheckViolationError, asyncpg.ForeignKeyViolationError, asyncpg.NotNullViolationError)):
        return JSONResponse({"error": {"code": "INVALID_VALUE", "message": exc.__class__.__name__}}, status_code=422)
    if isinstance(exc, asyncpg.InsufficientPrivilegeError):
        return JSONResponse({"error": {"code": "FORBIDDEN", "message": "not allowed"}}, status_code=403)
    # the role's time limits (db/create_login_roles.sql, review stage A7): a statement that ran too long, a lock that
    # was not free in time, or a transaction left idle; the request can be repeated, nothing of it was kept
    if isinstance(exc, (asyncpg.QueryCanceledError, asyncpg.LockNotAvailableError,
                        asyncpg.IdleInTransactionSessionTimeoutError)):
        logging.getLogger("masslak.db").warning("database time limit reached %s: %s", exc.sqlstate, msg)
        return JSONResponse({"error": {"code": "SERVICE_BUSY", "message": "the database did not answer in time"}},
                            status_code=503, headers={"Retry-After": "2"})
    m = _DB_CODE.match(msg)
    if isinstance(exc, asyncpg.RaiseError) and m:
        return JSONResponse({"error": {"code": m.group(1), "message": msg}}, status_code=409)
    # unexpected: keep the database's own message in the server log (never in the response)
    logging.getLogger("masslak.db").error("unexpected database error %s: %s", getattr(exc, "sqlstate", "?"), msg)
    return JSONResponse({"error": {"code": "SERVER_ERROR", "message": "unexpected database error"}}, status_code=500)
