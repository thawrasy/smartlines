#!/usr/bin/env python3
"""Failover drill (expert review of October 2026, stage D6; docs/operations/RUNBOOKS.md, section 23).

    python3 db/tools/failover_drill.py --dsn "postgresql://<owner>@hostA:5432,hostB:5432/masslak?target_session_attrs=read-write" \\
        --kill "<command that stops the primary>" [--promote "<command that promotes the standby>"] \\
        [--api https://<site>/api/ready [--api-ca ca.crt]] [--rate 20] [--warmup 10] [--settle 15] [--json evidence.json]

Writes numbered rows to sys.failover_probe (schema file 1065) at a steady rate through the same kind of connection
string the API uses (every server listed, the primary chosen by target_session_attrs), records each commit the
server acknowledged, then runs --kill. With Patroni the standby is promoted on its own; without it, --promote runs
after --promote-after seconds (a stand-in for Patroni's detection). The writer reconnects as the API's pool would.
Afterwards it reads the probe rows back from the new primary and reports:
  * RTO: from the first failed write to the first write the new primary acknowledged (target: 60 s, RUNBOOKS.md 3);
  * RPO: acknowledged rows the new primary does not have, and the time they span (target: none lost with a
    synchronous standby, otherwise within 60 s);
  * the API's readiness (/api/ready) during the drill, when --api is given: how long it was not ready.
Exit status 0 when both targets are met. Run it on staging, never on production: it stops a database server.
"""
import argparse
import asyncio
import json
import shlex
import ssl
import subprocess
import sys
import time
import urllib.request
import uuid

import asyncpg


async def connect(dsn: str) -> asyncpg.Connection:
    # an owner login: the probe table is the platform's (row security), and the drill reads server settings
    return await asyncpg.connect(dsn, timeout=3, command_timeout=5)


async def writer(a, drill: uuid.UUID, state: dict) -> None:
    conn, seq = None, 0
    while not state["done"]:
        started = time.monotonic()
        try:
            if conn is None or conn.is_closed():
                conn = await connect(a.dsn)
                state["servers"].add(await conn.fetchval("SELECT host(inet_server_addr()) || ':' || inet_server_port()"))
            seq += 1
            await conn.execute("INSERT INTO sys.failover_probe (drill, seq) VALUES ($1, $2)", drill, seq)
            now = time.time()
            state["acked"][seq] = now
            if state["first_failure"] is not None and state["recovered"] is None:
                state["recovered"] = now
        except (OSError, asyncpg.PostgresError, asyncpg.exceptions.InterfaceError,
                asyncpg.exceptions.TargetServerAttributeNotMatched, asyncio.TimeoutError) as exc:
            if state["first_failure"] is None and state["killed_at"] is not None:
                state["first_failure"] = time.time()
            state["errors"][type(exc).__name__] = state["errors"].get(type(exc).__name__, 0) + 1
            if conn is not None:
                conn.terminate()
            conn = None
            await asyncio.sleep(0.2)
            continue
        await asyncio.sleep(max(0.0, 1.0 / a.rate - (time.monotonic() - started)))
    if conn is not None:
        await conn.close()


async def readiness(url: str, ca: str | None, state: dict) -> None:
    down_since = None
    ctx = ssl.create_default_context(cafile=ca) if ca else None
    while not state["done"]:
        try:
            ok = await asyncio.to_thread(lambda: urllib.request.urlopen(url, timeout=2, context=ctx).status == 200)  # nosec B310 - operator's own URL
        except Exception:                                                                              # noqa: BLE001 - any failure is "not ready"
            ok = False
        now = time.time()
        if not ok and down_since is None:
            down_since = now
        if ok and down_since is not None:
            state["api_down"].append(round(now - down_since, 1))
            down_since = None
        await asyncio.sleep(0.5)
    if down_since is not None:
        state["api_down"].append(round(time.time() - down_since, 1))


def run(cmd: str) -> int:
    return subprocess.run(shlex.split(cmd), capture_output=True, text=True).returncode  # nosec B603 - operator's command


async def drill(a) -> dict:
    drill_id = uuid.uuid4()
    state = {"done": False, "acked": {}, "errors": {}, "servers": set(), "first_failure": None, "recovered": None,
             "killed_at": None, "api_down": []}
    tasks = [asyncio.create_task(writer(a, drill_id, state))]
    if a.api:
        tasks.append(asyncio.create_task(readiness(a.api, a.api_ca, state)))
    await asyncio.sleep(a.warmup)
    before = len(state["acked"])
    # the primary as it was: which server, and whether a standby confirmed every commit (no loss expected then)
    conn = await connect(a.dsn)
    try:
        old = dict(await conn.fetchrow(
            """SELECT host(inet_server_addr()) || ':' || inet_server_port() AS server,
                      current_setting('synchronous_standby_names') AS synchronous_standby_names,
                      (SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming') AS standbys,
                      (SELECT count(*) FROM pg_stat_replication WHERE sync_state IN ('sync', 'quorum')) AS sync_standbys"""))
    finally:
        await conn.close()
    state["killed_at"] = time.time()
    kill_rc = await asyncio.to_thread(run, a.kill)
    promote_rc = None
    if a.promote:
        await asyncio.sleep(a.promote_after)
        promote_rc = await asyncio.to_thread(run, a.promote)
    deadline = time.time() + a.timeout
    while state["recovered"] is None and time.time() < deadline:
        await asyncio.sleep(0.2)
    await asyncio.sleep(a.settle)
    state["done"] = True
    await asyncio.gather(*tasks)

    conn = await connect(a.dsn)
    try:
        kept = {r["seq"] for r in await conn.fetch("SELECT seq FROM sys.failover_probe WHERE drill = $1", drill_id)}
        primary = await conn.fetchval("SELECT host(inet_server_addr()) || ':' || inet_server_port()")
        standby = await conn.fetchval("SELECT pg_is_in_recovery()")
    finally:
        await conn.close()
    lost = sorted(s for s in state["acked"] if s not in kept)
    rto = round(state["recovered"] - state["first_failure"], 2) if state["recovered"] and state["first_failure"] else None
    rpo_seconds = round(state["acked"][lost[-1]] - state["acked"][lost[0]], 2) if lost else 0.0
    result = {
        "drill": str(drill_id), "kill_exit": kill_rc, "promote_exit": promote_rc,
        "acknowledged_before_kill": before, "acknowledged": len(state["acked"]), "kept": len(kept & set(state["acked"])),
        "lost": len(lost), "lost_seconds": rpo_seconds, "rto_seconds": rto, "errors": state["errors"],
        "servers_written": sorted(state["servers"]), "old_primary": old, "new_primary": primary,
        "new_primary_is_standby": standby, "api_not_ready_seconds": state["api_down"],
        "targets": {"rto_seconds": a.rto, "rpo_seconds": a.rpo},
    }
    result["passed"] = (rto is not None and rto <= a.rto and not standby
                        and (len(lost) == 0 if a.rpo == 0 else rpo_seconds <= a.rpo))
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--dsn", required=True, help="every server, with target_session_attrs=read-write; an owner login")
    ap.add_argument("--kill", required=True, help="command that stops the primary")
    ap.add_argument("--promote", help="command that promotes the standby (not needed with Patroni)")
    ap.add_argument("--promote-after", type=float, default=0.0, help="seconds between the kill and --promote")
    ap.add_argument("--api", help="the API's /api/ready address, watched during the drill")
    ap.add_argument("--api-ca", help="the authority the API's certificate is checked against (default: the system's)")
    ap.add_argument("--rate", type=float, default=20.0, help="writes a second (default 20)")
    ap.add_argument("--warmup", type=float, default=10.0, help="seconds of writes before the kill (default 10)")
    ap.add_argument("--settle", type=float, default=5.0, help="seconds of writes after recovery (default 5)")
    ap.add_argument("--timeout", type=float, default=180.0, help="seconds to wait for recovery (default 180)")
    ap.add_argument("--rto", type=float, default=60.0, help="target seconds back to writing (default 60)")
    ap.add_argument("--rpo", type=float, default=0.0, help="target seconds of acknowledged writes lost (default 0: none)")
    ap.add_argument("--json", help="write the result here as evidence")
    a = ap.parse_args()
    result = asyncio.run(drill(a))
    text = json.dumps(result, indent=1)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
