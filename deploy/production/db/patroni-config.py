#!/usr/bin/env python3
"""The Patroni cluster of the two database hosts, through its REST API (reviews of October 2026, H-01).

    masslak-patroni cluster            the members, their roles and lag; exit 0 with one primary and a
                                       synchronous standby streaming, 1 otherwise
    masslak-patroni durability on|off  zero data loss (owner's decision 1, MASSLAK_ZERO_DATA_LOSS): on makes a commit
                                       wait for the synchronous standby even when it is gone (synchronous_mode_strict);
                                       off lets the primary confirm alone while no standby is left

Run in the db proxy container of the application host (deploy/durability.sh does): it asks each database host in
turn (MASSLAK_DB_HOSTS) over TLS, checking the certificate against the internal authority, and signs changes in with
the REST API's login (MASSLAK_PATRONI_REST_USER, MASSLAK_PATRONI_REST_PASSWORD).
"""
import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.request

CA = os.environ.get("MASSLAK_DB_CA", "/tls-src/ca.crt")


def hosts() -> list[str]:
    return [h.strip() for h in os.environ.get("MASSLAK_DB_HOSTS", "").split(",") if h.strip()]


def call(method: str, path: str, body: dict | None = None) -> dict:
    ctx = ssl.create_default_context(cafile=CA)
    errors = []
    for host in hosts():
        req = urllib.request.Request(f"https://{host}:8008{path}", method=method,
                                     data=None if body is None else json.dumps(body).encode())
        if body is not None:
            user = os.environ.get("MASSLAK_PATRONI_REST_USER", "masslak")
            password = os.environ.get("MASSLAK_PATRONI_REST_PASSWORD", "")
            req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode())
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=5, context=ctx) as r:   # nosec B310 - https to the configured hosts
                return json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):            # the host answered and refused the login: asking the other changes nothing
                raise SystemExit(f"{host} refused the change ({exc.code}): check MASSLAK_PATRONI_REST_PASSWORD") from exc
            errors.append(f"{host}: {exc}")
        except (OSError, urllib.error.URLError, ValueError) as exc:
            errors.append(f"{host}: {exc}")
    raise SystemExit("no database host answered: " + "; ".join(errors or ["MASSLAK_DB_HOSTS is empty"]))


def cluster() -> int:
    members = call("GET", "/cluster").get("members", [])
    for m in members:
        print(f"{m.get('name')}  {m.get('host')}  {m.get('role')}  {m.get('state')}  lag={m.get('lag', 0)}  "
              f"timeline={m.get('timeline')}")
    leaders = [m for m in members if m.get("role") == "leader" and m.get("state") == "running"]
    sync = [m for m in members if m.get("role") == "sync_standby" and m.get("state") == "streaming"]
    if len(leaders) != 1:
        print(f"{len(leaders)} running primaries, not one", file=sys.stderr)
        return 1
    if not sync:
        print("no synchronous standby is streaming: a failover now could lose committed writes", file=sys.stderr)
        return 1
    return 0


def durability(mode: str) -> int:
    if mode not in ("on", "off"):
        raise SystemExit("durability on or off")
    call("PATCH", "/config", {"synchronous_mode": True, "synchronous_mode_strict": mode == "on",
                              "postgresql": {"parameters": {"synchronous_commit": "on"}}})
    config = call("GET", "/config")
    print(f"synchronous_mode={config.get('synchronous_mode')} synchronous_mode_strict={config.get('synchronous_mode_strict')}")
    return 0 if bool(config.get("synchronous_mode_strict")) == (mode == "on") else 1


def main(argv: list[str]) -> int:
    if argv[:1] == ["cluster"]:
        return cluster()
    if argv[:1] == ["durability"] and len(argv) == 2:
        return durability(argv[1])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
