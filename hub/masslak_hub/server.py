"""What the players on the station's own network reach, and nothing else: one page per screen, its board as JSON, and a
WebSocket that pushes the board as soon as the hub has a new one.

    GET /screen/{code}     the screen's page: the board for its approved player; a waiting page for a player not yet
                           approved (with its own address, to give the administration); nothing for any other device
    GET /board/{code}      the board as JSON, for the page (same rule)
    WS  /ws/{code}         the board pushed on every pull (same rule)
    GET /healthz           paired or not, the last pull, the uplink
"""
from __future__ import annotations

import asyncio
import html
import time
from importlib import resources
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse, Response

from . import players
from .board import view
from .store import Store
from .uplink import Uplink

COOKIE = "masslak_device"
HEADERS = {"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer",
           "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; "
                                      "img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"}
ASSETS = resources.files("masslak_hub") / "assets"


def _asset(name: str) -> str:
    return (ASSETS / name).read_text(encoding="utf-8")


def create_app(store: Store, uplink: Uplink, arp: Path = players.ARP) -> FastAPI:
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    changed = asyncio.Event()
    uplink.on_sync = changed.set

    def decision(code: str, ip: str, cookie: Optional[str]) -> players.Decision:
        sync = store.sync or {}
        mac = players.mac_of(ip, arp)
        if mac:
            uplink.saw(mac, ip)                           # every player that asks is reported, approved or not
        return players.decide(sync.get("screens") or [], sync.get("rejected") or [], store.bindings, code, mac, ip, cookie)

    def notice(status: int, title_en: str, key: str, ip: str, mac: Optional[str]) -> HTMLResponse:
        labels = (store.sync or {}).get("labels") or {}
        lines = [labels.get(loc, {}).get(key) for loc in ("ar", "en")]
        body = "".join(f"<p>{html.escape(t)}</p>" for t in lines if t) or f"<p>{html.escape(title_en)}</p>"
        who = f"<p class=\"address\">MAC {html.escape(mac or '-')} &middot; IP {html.escape(ip)}</p>" if key == "waiting" else ""
        page = _asset("notice.html").replace("{{BODY}}", body + who)
        return HTMLResponse(page, status_code=status, headers=HEADERS)

    @app.get("/screen/{code}")
    async def screen(code: str, request: Request):
        ip = request.client.host if request.client else ""
        d = decision(code, ip, request.cookies.get(COOKIE))
        if d.verdict == "UNKNOWN_SCREEN":
            return notice(404, "This screen shows nothing at the moment", "screenOff", ip, None)
        if d.verdict in ("WAIT", "MISMATCH"):
            return notice(200, "This screen is waiting to be approved by the station's administration", "waiting", ip,
                          players.mac_of(ip, arp))
        if d.verdict == "REFUSED":
            return notice(403, "This device may not show the station's boards", "refused", ip, None)
        page = HTMLResponse(_asset("board.html").replace("{{CODE}}", html.escape(d.screen["code"])), headers=HEADERS)
        if d.verdict == "BIND":
            bindings = store.bindings
            bindings[d.screen["code"]] = {"mac": d.screen["mac"], "key_sha256": players.digest(d.token), "bound_at": time.time()}
            store.save_bindings(bindings)
            page.set_cookie(COOKIE, d.token, max_age=10 * 365 * 86400, httponly=True, samesite="strict", path="/")
        return page

    @app.get("/board/{code}")
    async def board(code: str, request: Request):
        ip = request.client.host if request.client else ""
        d = decision(code, ip, request.cookies.get(COOKIE))
        if d.verdict != "SHOW":
            return JSONResponse({"error": d.verdict}, status_code=403, headers=HEADERS)
        return JSONResponse(view(store.sync or {}, d.screen, time.time()), headers=HEADERS)

    @app.websocket("/ws/{code}")
    async def push(ws: WebSocket, code: str):
        ip = ws.client.host if ws.client else ""
        d = decision(code, ip, ws.cookies.get(COOKIE))
        if d.verdict != "SHOW":
            await ws.close(code=4403)
            return
        await ws.accept()
        try:
            while True:
                screen = next((s for s in (store.sync or {}).get("screens") or [] if s.get("code") == d.screen["code"]), d.screen)
                await ws.send_json(view(store.sync or {}, screen, time.time()))
                changed.clear()
                try:
                    await asyncio.wait_for(changed.wait(), timeout=30)
                except asyncio.TimeoutError:
                    pass                                  # resent every 30 s: the page shows the board is stale
                if decision(code, ip, ws.cookies.get(COOKIE)).verdict != "SHOW":
                    await ws.close(code=4403)             # the player was released or rejected meanwhile
                    return
        except WebSocketDisconnect:
            return

    @app.get("/assets/{name}")
    async def asset(name: str):
        types = {"board.js": "text/javascript", "board.css": "text/css"}
        if name not in types:
            return Response(status_code=404)
        return Response(_asset(name), media_type=types[name], headers={**HEADERS, "Cache-Control": "max-age=300"})

    @app.get("/healthz")
    async def healthz():
        sync = store.sync or {}
        return {"paired": bool(store.key), "synced_at": sync.get("synced_at"), "uplink": "down" if uplink.down_since else "up",
                "screens": len(sync.get("screens") or [])}

    return app
