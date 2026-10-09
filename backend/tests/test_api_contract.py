"""Every API address the web interface and the mobile apps call exists on the server, with that method (code review of
October 2026, 6.1). Read from the sources, so a route renamed or removed on one side fails here, before a user meets a
404 in a screen nobody opened in testing. Addresses built at run time from variables are matched segment by segment;
an address only known up to a slash must be the beginning of some route."""
import re
from pathlib import Path

from app.main import APP_PATHS, app

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT / "frontend" / "src", ROOT / "mobile" / "src"]
# api.get("/api/...") and the like: the method is known; any other literal starting with /api/ (fetch, links) is
# checked for its address only
CALL = re.compile(r"\bapi\.(get|post|put|patch|del|upload)\s*(?:<(?:[^<>]|<[^<>]*>)*>)?\(\s*(['\"`])(/api/[^'\"`]*)\2")
LITERAL = re.compile(r"(['\"`])(/api/[^'\"`\s]*)\1")
METHOD = {"get": "GET", "post": "POST", "put": "PUT", "patch": "PATCH", "del": "DELETE", "upload": "POST"}
# Addresses joined to a base chosen at run time: the selling channel's API (frontend/src/channel.ts: passenger, agency,
# counter) and the settlement view's (company or platform finance). Each joined address is checked with every base,
# except the few a screen offers on one channel only, listed here with that channel.
BASES = {"ch.api": re.compile(r'\bapi: "(/api[^"]*)"'), "base": re.compile(r'\bbase="(/api[^"]*)"')}
JOINED = re.compile(r"\bapi\.(get|post|put|patch|del|upload)\s*(?:<(?:[^<>]|<[^<>]*>)*>)?\(\s*`\$\{(ch\.api|base)\}(/[^`]*)`")
ONE_CHANNEL = {"/bookings/${b.booking_ref}/collect": {"/api/carrier/counter"}}     # cash collected at the counter


# routes the server answers that its own document leaves out
UNLISTED = [("/api/v1/openapi.json", {"GET"}), ("/api/metrics", {"GET"})]


def routes() -> list[tuple[list[str], set[str]]]:
    """The server's routes, from the document FastAPI builds from them (whether or not it is published)."""
    out = [(p.strip("/").split("/"), m) for p, m in UNLISTED]
    for path, ops in app.openapi()["paths"].items():
        if path.startswith("/api/"):
            out.append((path.strip("/").split("/"), {k.upper() for k in ops if k in ("get", "post", "put", "patch", "delete")}))
    return out


def _segment_matches(route_seg: str, call_seg: str) -> bool:
    if route_seg.startswith("{"):
        return call_seg != ""
    if "${" not in call_seg:
        return route_seg == call_seg
    pattern = "".join(".+" if part.startswith("${") else re.escape(part) for part in re.split(r"(\$\{[^}]*\})", call_seg))
    return re.fullmatch(pattern, route_seg) is not None


def matches(route: list[str], call: list[str], prefix: bool) -> bool:
    for i, seg in enumerate(route):
        if seg.endswith(":path}"):                     # {rest:path} takes the remaining segments
            return len(call) > i
        if i >= len(call):
            return prefix
        if not _segment_matches(seg, call[i]):
            return False
    return len(call) == len(route)


def _files():
    for root in SOURCES:
        yield from ((f, f.read_text()) for f in sorted(root.rglob("*.ts*")))


def calls() -> list[tuple[str, str, str | None, bool]]:
    """(file:line, address, method or None, only a prefix)"""
    files = list(_files())
    bases = {name: {m.group(1) for _, text in files for m in rx.finditer(text)} for name, rx in BASES.items()}
    assert all(bases.values()), bases
    found = []
    for f, text in files:
        seen = {m.start(1) for rx in BASES.values() for m in rx.finditer(text)}       # the bases themselves
        for m in CALL.finditer(text):
            seen.add(m.start(3))
            found.append((f, text, m.start(3), m.group(3), METHOD[m.group(1)]))
        for m in JOINED.finditer(text):
            for b in ONE_CHANNEL.get(m.group(3), bases[m.group(2)]):
                found.append((f, text, m.start(3), b + m.group(3), METHOD[m.group(1)]))
        for m in LITERAL.finditer(text):
            if m.start(2) not in seen:
                found.append((f, text, m.start(2), m.group(2), None))
    out = []
    for f, text, pos, address, method in found:
        where = f"{f.relative_to(ROOT)}:{text.count(chr(10), 0, pos) + 1}"
        path = re.sub(r"[?#].*$", "", address)
        out.append((where, path, method, path.endswith("/")))
    return out


def test_every_address_the_clients_call_exists_with_its_method():
    table = routes()
    assert len(table) > 250
    missing = []
    for where, path, method, prefix in calls():
        segs = path.rstrip("/").strip("/").split("/")
        hits = [m for r, m in table if matches(r, segs, prefix)]
        if not hits:
            missing.append(f"{where}  {method or 'ANY'} {path}  (no such route)")
        elif method and not any(method in m for m in hits):
            missing.append(f"{where}  {method} {path}  (the route exists for {sorted(set().union(*hits))} only)")
    assert not missing, "the clients call addresses the server does not have:\n" + "\n".join(missing)


def test_the_check_finds_a_wrong_address():
    table = routes()
    assert any(matches(r, "api/auth/me".split("/"), False) for r, _ in table)
    assert not any(matches(r, "api/auth/mee".split("/"), False) for r, _ in table)
    assert any(matches(r, "api/bookings/${ref}/payments".split("/"), False) for r, _ in table)
    assert not any(matches(r, "api/bookings/${ref}/paymnts".split("/"), False) for r, _ in table)
    joined = [c for c in calls() if c[1].endswith("/holds")]
    assert {c[1] for c in joined} >= {"/api/holds", "/api/agency/holds", "/api/carrier/counter/holds"}


def test_every_screen_of_the_web_app_is_served_as_a_page():
    """The server answers 404 outside the app's own top-level paths; a screen it does not know (support was one)
    reaches its users with a 404 status, which crawlers and monitors take at its word."""
    routes = re.findall(r'<Route path="([^"*:]*)', (ROOT / "frontend" / "src" / "App.tsx").read_text())
    assert routes
    assert {r.split("/")[0] for r in routes} - APP_PATHS == set()
