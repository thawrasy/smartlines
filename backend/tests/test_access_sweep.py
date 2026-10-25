"""Access sweep over the whole API (wave 7, owner's notes 20-32): every read address of a portal is refused to anyone
not signed in and to the sessions of the other portals, and no address answers with a server error. The addresses are
taken from the application itself, so a new route is covered the day it is added.

A refusal is 401 or 403; 404 is accepted for a module switched off or an object that does not exist; 422 for a
required parameter checked before the sign-in. A 2xx answer to the wrong portal, or any 5xx, fails the sweep."""
import re
import uuid

import pytest

from app.main import app
from test_e2e import OWNER_URL, client, login

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

# the portal that owns each prefix
OWNERS = {"/api/admin/": "PLATFORM", "/api/security/": "PLATFORM", "/api/carrier/": "OPERATOR",
          "/api/agency/": "AGENCY", "/api/driver/": "DRIVER"}
SESSIONS = {"PLATFORM": ("admin@masslak.test", "PLATFORM"), "OPERATOR": ("owner@carrier.test", "OPERATOR"),
            "AGENCY": ("agency@agency.test", "AGENCY"), "DRIVER": ("driver@carrier.test", "DRIVER"),
            "PASSENGER": ("passenger@masslak.test", "PASSENGER")}
REFUSED = {401, 403, 404, 422}


def _addresses():
    out = []
    for path, ops in app.openapi()["paths"].items():
        if "get" not in ops:
            continue
        owner = next((o for p, o in OWNERS.items() if path.startswith(p)), None)
        if owner is None:
            continue
        # a path parameter takes a value that names nothing: a uuid for *uid*, else a number
        concrete = re.sub(r"\{([^}]+)\}", lambda m: str(uuid.uuid4()) if "uid" in m.group(1) or m.group(1) in ("key", "uuid") else "999999999", path)
        out.append((owner, path, concrete))
    return out


ADDRESSES = _addresses()


def test_the_sweep_covers_every_portal():
    owners = {o for o, _, _ in ADDRESSES}
    assert owners == {"PLATFORM", "OPERATOR", "AGENCY", "DRIVER"} and len(ADDRESSES) > 150, (owners, len(ADDRESSES))


def test_nobody_signed_in_reads_a_portal_address():
    anon = client()
    wrong = [(path, r.status_code) for _, path, url in ADDRESSES if (r := anon.get(url)).status_code not in REFUSED]
    assert not wrong, f"answered without a sign-in: {wrong[:20]}"


@pytest.mark.parametrize("portal", sorted(SESSIONS))
def test_a_portal_session_reads_no_other_portal_address(portal):
    session = login(*SESSIONS[portal])
    wrong = []
    for owner, path, url in ADDRESSES:
        if owner == portal:
            continue
        r = session.get(url)
        if r.status_code not in REFUSED:
            wrong.append((path, r.status_code))
    assert not wrong, f"the {portal} session read addresses of other portals: {wrong[:20]}"


@pytest.mark.parametrize("portal", ["PLATFORM", "OPERATOR", "AGENCY", "DRIVER"])
def test_no_address_of_its_own_portal_fails_on_the_server(portal):
    session = login(*SESSIONS[portal])
    broken = [(path, r.status_code) for owner, path, url in ADDRESSES if owner == portal and (r := session.get(url)).status_code >= 500]
    assert not broken, f"server errors in the {portal} portal: {broken[:20]}"
