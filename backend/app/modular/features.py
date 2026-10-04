"""Reading and enforcing the module switches (sys.setting "features")."""
import json
import time
from typing import Optional

from fastapi import Depends

from .. import db
from ..errors import ApiError

_cache: dict = {"at": 0.0, "value": {}}
TTL_SECONDS = 5.0          # a switch takes effect on every worker within this time


async def load(conn=None, fresh: bool = False) -> dict:
    """The features document as {key: bool}."""
    if not fresh and time.monotonic() - _cache["at"] < TTL_SECONDS:
        return _cache["value"]
    sql = "SELECT value::text FROM sys.setting WHERE key = 'features'"
    if conn is None:
        async with db.raw_connection() as c:
            raw = await c.fetchval(sql)
    else:
        raw = await conn.fetchval(sql)
    value = {k: bool(v) for k, v in json.loads(raw or "{}").items()}
    _cache.update(at=time.monotonic(), value=value)
    return value


def invalidate() -> None:
    _cache["at"] = 0.0


async def is_on(key: Optional[str]) -> bool:
    return key is None or (await load()).get(key, False)


def require_module(key: str):
    """Dependency: the endpoint exists only while its module is switched on."""
    async def dep() -> None:
        if not await is_on(key):
            raise ApiError(404, "MODULE_DISABLED", f"module {key} is switched off")
    return Depends(dep)
