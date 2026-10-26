"""Bank and insurer registries (owner's requests N6 and N9, migration 1156): entries reviewed by a second person before
companies see them, changes to a reviewed entry kept as proposals, the owner's tables imported as UNVERIFIED, company bank
accounts at a bank and branch of the registry, and insurance policies that pick their insurer from it."""
import io
import uuid

import pytest

from test_e2e import OWNER_URL, login, owner_sql
from test_users_and_roles import NEW_PASSWORD, add_staff, role_uid

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
NAME_AR = "\u0645\u0635\u0631\u0641 \u0627\u0644\u0627\u062e\u062a\u0628\u0627\u0631"


def code() -> str:
    return "T" + uuid.uuid4().hex[:7].upper()


def swift() -> str:
    """A well-formed SWIFT/BIC of its own: four letters, the country, a two-character location."""
    import random
    return "".join(random.choices("ABCDEFGHIJKLMNOPQRSTUVWXYZ", k=4)) + "SYDA"


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def second(admin):
    email, _ = add_staff(admin, [role_uid(admin, "PLATFORM_OPERATIONS")])
    return login(email, "PLATFORM", NEW_PASSWORD)


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


def bank(admin, second, **extra) -> dict:
    body = {"code": code(), "name_ar": NAME_AR, "name_en": "Test Bank " + uuid.uuid4().hex[:4], "swift_bic": None, **extra}
    r = admin.post("/api/admin/registry/banks", json=body)
    assert r.status_code == 201 and r.json()["status"] == "PENDING_REVIEW", r.text
    uid = r.json()["uid"]
    assert second.post(f"/api/admin/registry/banks/{uid}/review", json={"decision": "ACCEPT"}).json()["status"] == "ACTIVE"
    return {**body, "uid": uid}


def picker(c, kind="banks") -> dict:
    return {x["uid"]: x for x in c.get(f"/api/registry/{kind}").json()[kind]}


def test_a_bank_reaches_companies_only_after_another_person_reviews_it(admin, second, carrier):
    first, changed = swift(), swift()
    body = {"code": code(), "name_ar": NAME_AR, "name_en": "Review Bank", "swift_bic": first, "bank_type": "PRIVATE"}
    r = admin.post("/api/admin/registry/banks", json=body)
    uid = r.json()["uid"]
    assert uid not in picker(carrier)
    own = admin.post(f"/api/admin/registry/banks/{uid}/review", json={"decision": "ACCEPT"})
    assert own.status_code == 409 and own.json()["error"]["code"] == "FOUR_EYES"
    assert admin.post("/api/admin/registry/banks", json=body).json()["error"]["code"] == "CODE_TAKEN"
    assert second.post(f"/api/admin/registry/banks/{uid}/review", json={"decision": "ACCEPT"}).json()["status"] == "ACTIVE"
    seen = picker(carrier)[uid]
    assert seen["swift_bic"] == first and "notes" not in seen and "status" not in seen

    # a change to a reviewed bank waits for a second person; until then companies see the reviewed entry
    r = admin.put(f"/api/admin/registry/banks/{uid}", json={**body, "swift_bic": changed})
    assert r.status_code == 200 and r.json()["pending_changes"] == {"swift_bic": changed}, r.text
    assert admin.put(f"/api/admin/registry/banks/{uid}", json=body).json()["error"]["code"] == "CHANGE_PENDING"
    assert picker(carrier)[uid]["swift_bic"] == first
    assert admin.post(f"/api/admin/registry/banks/{uid}/review", json={"decision": "ACCEPT"}).json()["error"]["code"] == "FOUR_EYES"
    assert second.post(f"/api/admin/registry/banks/{uid}/review", json={"decision": "ACCEPT"}).json()["change"] == "APPLIED"
    assert picker(carrier)[uid]["swift_bic"] == changed

    # the central bank stays in the registry, hidden from companies
    central = bank(admin, second, bank_type="CENTRAL")
    assert central["uid"] not in picker(carrier) and central["uid"] in picker(admin)
    assert carrier.post("/api/admin/registry/banks", json=body).status_code == 403
    assert second.post(f"/api/admin/registry/banks/{uid}/retire").json()["status"] == "RETIRED"
    assert uid not in picker(carrier)


def test_a_company_account_picks_a_bank_and_branch_and_is_unverified_until_finance_decides(admin, second, carrier):
    head = swift()
    b = bank(admin, second, swift_bic=head)
    r = admin.post(f"/api/admin/registry/banks/{b['uid']}/branches",
                   json={"name_ar": NAME_AR, "name_en": "Head office", "is_head_office": True, "swift_bic": head + "HOF"})
    branch = r.json()["uid"]
    assert admin.post(f"/api/admin/registry/branches/{branch}/review", json={"decision": "ACCEPT"}).json()["error"]["code"] == "FOUR_EYES"
    assert second.post(f"/api/admin/registry/branches/{branch}/review", json={"decision": "ACCEPT"}).json()["status"] == "ACTIVE"
    assert [x["uid"] for x in picker(carrier)[b["uid"]]["branches"]] == [branch]

    from test_payouts import make_iban
    r = carrier.post("/api/finance/bank-accounts", json={"bank_uid": str(uuid.uuid4()), "holder_name": "Demo Carrier A", "iban": make_iban()})
    assert r.status_code == 422 and r.json()["error"]["code"] == "BANK_UNKNOWN"
    r = carrier.post("/api/finance/bank-accounts", json={"bank_uid": b["uid"], "branch_uid": branch, "holder_name": "Demo Carrier A",
                                                         "iban": make_iban(), "account_no": "0012345678", "is_default": True})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    acct = next(a for a in carrier.get("/api/finance/bank-accounts").json()["accounts"] if a["uid"] == uid)
    assert acct["swift_bic"] == head + "HOF" and acct["branch_uid"] == branch and acct["is_default"] is True
    assert acct["verification_status"] == "UNVERIFIED" and acct["account_no_last4"] == "5678" and "account_no" not in acct
    stored = owner_sql("SELECT account_no_enc FROM iam.bank_account WHERE uid = $1", uuid.UUID(uid))
    assert b"0012345678" not in stored                                          # encrypted at rest
    # one default per company
    other = carrier.post("/api/finance/bank-accounts", json={"bank_uid": b["uid"], "holder_name": "Demo Carrier A", "iban": make_iban()}).json()["uid"]
    assert carrier.post(f"/api/finance/bank-accounts/{other}/default").status_code == 200
    mine = {a["uid"]: a for a in carrier.get("/api/finance/bank-accounts").json()["accounts"]}
    assert mine[other]["is_default"] and not mine[uid]["is_default"]

    finance = login("finance@masslak.test", "PLATFORM")
    assert finance.post(f"/api/admin/finance/bank-accounts/{other}/reject", json={"reason": "holder differs"}).status_code == 200
    mine = {a["uid"]: a for a in carrier.get("/api/finance/bank-accounts").json()["accounts"]}
    assert mine[other]["verification_status"] == "REJECTED" and not mine[other]["is_default"]
    assert carrier.post(f"/api/finance/bank-accounts/{other}/default").json()["error"]["code"] == "BANK_ACCOUNT_NOT_USABLE"
    assert finance.post(f"/api/admin/finance/bank-accounts/{uid}/verify").status_code == 200
    assert {a["uid"]: a for a in carrier.get("/api/finance/bank-accounts").json()["accounts"]}[uid]["verification_status"] == "VERIFIED_MANUAL"
    assert carrier.post(f"/api/finance/bank-accounts/{uid}/disable").status_code == 200


def _workbook(rows: list[list]) -> bytes:
    from openpyxl import Workbook
    wb = Workbook()
    ws = wb.active
    ws.title = "banks_import"
    for r in rows:
        ws.append(r)
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


def test_the_owner_table_comes_in_unverified_and_waiting_for_review(admin, second):
    head = ["code", "name_ar", "name_en", "swift_bic", "swift_status", "is_central_bank", "governorate", "city", "phone", "email", "website"]
    good, odd = code(), code()
    rows = [head, [good, NAME_AR, "Imported Bank", swift(), "TO_VERIFY", "no", "Damascus", "Damascus", "+963 11 2218000",
                   "info@example.com", "https://example.com"],
            [odd, NAME_AR, "Short Swift Bank", "PCBSYDA", "TO_VERIFY", "no", None, None, None, None, None]]
    bad = admin.post("/api/admin/registry/banks/import",
                     files={"file": ("b.xlsx", _workbook(rows + [[code(), NAME_AR, "Bad", None, None, "no", None, None, None, "not-an-email", None]]))})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "REGISTRY_FILE_ROWS", bad.text
    assert not owner_sql("SELECT count(*) FROM ref.bank WHERE code = $1", good)              # nothing of a refused file
    r = admin.post("/api/admin/registry/banks/import", files={"file": ("b.xlsx", _workbook(rows))})
    assert r.status_code == 200 and sorted(r.json()["created"]) == sorted([good, odd]), r.text
    again = admin.post("/api/admin/registry/banks/import", files={"file": ("b.xlsx", _workbook(rows))}).json()
    assert again["created"] == [] and sorted(again["skipped"]) == sorted([good, odd])
    entries = {x["code"]: x for x in picker(admin).values()}
    assert entries[good]["status"] == "PENDING_REVIEW" and entries[good]["verification_status"] == "UNVERIFIED"
    assert entries[good]["source"] == "IMPORT" and entries[good]["address"] == {"governorate": "Damascus", "city": "Damascus"}
    assert entries[odd]["swift_bic"] is None and entries[odd]["swift_status"] == "INVALID" and entries[odd]["swift_reported"] == "PCBSYDA"
    assert admin.post("/api/admin/registry/banks/import", files={"file": ("b.xlsx", b"not a workbook")}).json()["error"]["code"] == "REGISTRY_FILE_FORMAT"


def test_carriers_pick_a_reviewed_insurer_and_reinsurers_stay_hidden(admin, second, carrier):
    made = {}
    for kind in ("CONVENTIONAL", "REINSURANCE"):
        r = admin.post("/api/admin/registry/insurers", json={"code": code(), "name_ar": NAME_AR, "name_en": f"Insurer {kind} {uuid.uuid4().hex[:4]}",
                                                             "insurance_kind": kind, "ownership": "PRIVATE", "lat": 33.51, "lng": 36.29})
        assert r.status_code == 201, r.text
        made[kind] = r.json()["uid"]
        second.post(f"/api/admin/registry/insurers/{made[kind]}/review", json={"decision": "ACCEPT"})
    seen = picker(carrier, "insurers")
    assert made["CONVENTIONAL"] in seen and made["REINSURANCE"] not in seen
    ids = {owner_sql("SELECT id FROM ref.insurer WHERE uid = $1", uuid.UUID(u)): k for k, u in made.items()}
    options = {o["id"] for o in carrier.get("/api/r/insurance-policy/lookup/insurer_id", params={"q": "Insurer"}).json()["options"]}
    assert any(ids.get(i) == "CONVENTIONAL" for i in options) and not any(ids.get(i) == "REINSURANCE" for i in options)
