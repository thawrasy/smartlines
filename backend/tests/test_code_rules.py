"""Code rules checked on every build (expert review of October 2026, stage C). Unit tests: the code is read, not run.

* system scope: every db.system_scope use is listed, function by function, with a reason (governance_registry.py);
  a new use or a moved one fails until a reviewer adds it.
* stored wallet balances: shared wallets store a balance that lags their newest entries, so the application reads
  fin.wallet_balance(id) or ledger.counted(); a direct read of the stored balance, or of a raw wallet row, is allowed
  only where the registry says the wallet's balance is exact.
"""
import ast
import os
import re
from collections import Counter

from governance_registry import BALANCE_READS, SYSTEM_SCOPE, WALLET_ROWS

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WALLET_TABLE = re.compile(r"\bfin\.wallet\b")
STORED_BALANCE = re.compile(r"(?<![\w])(?<!AS )(?<!as )(?:[a-z_]+\.)?balance\b", re.I)    # "... AS balance" names a result
RAW_ROW = re.compile(r"\bSELECT\s+(?:[a-z_]+\.)?\*|\bRETURNING\s+\*", re.I)


def sources():
    for root, _, files in os.walk(os.path.join(BACKEND, "app")):
        for name in sorted(files):
            if name.endswith(".py"):
                path = os.path.join(root, name)
                yield os.path.relpath(path, BACKEND), ast.parse(open(path, encoding="utf-8").read())


def strings(tree) -> list[str]:
    return [n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)]


def scope_uses() -> Counter:
    uses: Counter = Counter()
    for rel, tree in sources():
        def visit(node, stack):
            for child in ast.iter_child_nodes(node):
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    visit(child, stack + [child.name])
                    continue
                if isinstance(child, ast.Call):
                    fn = child.func
                    name = fn.attr if isinstance(fn, ast.Attribute) else getattr(fn, "id", None)
                    if name == "system_scope":
                        uses[(rel, ".".join(stack) or "<module>")] += 1
                visit(child, stack)
        visit(tree, [])
    return uses


def compare(found: Counter, registry: dict, what: str) -> list[str]:
    problems = []
    for key, n in sorted(found.items()):
        if key not in registry:
            problems.append(f"{key}: {n} new {what}; review it and add it to governance_registry.py with a reason")
        elif registry[key][0] != n:
            problems.append(f"{key}: {n} {what}, the registry says {registry[key][0]}; review the change")
    for key in sorted(set(registry) - set(found)):
        problems.append(f"{key}: listed in governance_registry.py but no longer in the code; remove the entry")
    problems += [f"{key}: no reason given" for key, (_, why) in registry.items() if len(why.strip()) < 10]
    return problems


def test_every_system_scope_use_is_reviewed():
    assert compare(scope_uses(), SYSTEM_SCOPE, "system_scope use(s)") == []


def test_stored_wallet_balances_are_read_only_where_exact():
    balances, rows = Counter(), Counter()
    for rel, tree in sources():
        for s in strings(tree):
            if not WALLET_TABLE.search(s):
                continue
            if STORED_BALANCE.search(s):
                balances[rel] += 1
            if RAW_ROW.search(s):
                rows[rel] += 1
    problems = compare(balances, BALANCE_READS, "direct read(s) of fin.wallet.balance")
    problems += compare(rows, WALLET_ROWS, "raw fin.wallet row read(s)")
    assert problems == []


def test_the_rules_catch_what_they_are_for():
    """The patterns themselves: they find the reads they exist for and leave the approved forms alone."""
    assert STORED_BALANCE.search("SELECT coalesce(sum(balance), 0) FROM fin.wallet WHERE wallet_type = 'ESCROW'")
    assert STORED_BALANCE.search("SELECT w.balance FROM fin.wallet w")
    for fine in ("SELECT fin.wallet_balance($1)", "fin.wallet_balance(w.id) AS balance", "SELECT hold_balance FROM fin.wallet", "balance_mode = 'DEFERRED'",
                 "e.balance_after"):
        assert not STORED_BALANCE.search(fine), fine
    assert RAW_ROW.search("SELECT * FROM fin.wallet WHERE id = $1") and RAW_ROW.search("INSERT ... RETURNING *")
    assert not WALLET_TABLE.search("SELECT * FROM fin.wallet_reconciliation")


def test_each_system_scope_use_is_counted_by_its_site():
    """At run time every entry into the system scope is counted under its calling function (masslak_system_scope_total)."""
    import asyncio

    from app import db

    class Conn:
        async def execute(self, *args):
            return None

    async def create_booking():
        async with db.system_scope(Conn(), db.Context(request_id=__import__("uuid").uuid4(), ip="127.0.0.1")):
            pass
    before = db.SCOPE_USES.copy()
    asyncio.run(create_booking())
    gained = db.SCOPE_USES - before
    assert list(gained) == ["../tests/test_code_rules.py:test_each_system_scope_use_is_counted_by_its_site.<locals>.create_booking"]


DELETE_SQL = re.compile(r"\bDELETE\s+FROM\s+([a-z_]+\.[a-z_]+)", re.I)


def test_every_delete_in_the_code_has_its_grant():
    """The application deletes only from the tables in sys.app_delete_grant (1059): a new DELETE in the code, or a module
    list that allows deletes, needs its row there first, or it would fail with permission denied in production."""
    import asyncio

    import asyncpg
    import pytest

    if not os.environ.get("MASSLAK_OWNER_URL"):
        pytest.skip("needs MASSLAK_OWNER_URL")
    from app.modular.specs import RESOURCES
    wanted = {t.lower() for _, tree in sources() for s in strings(tree) for t in DELETE_SQL.findall(s)}
    wanted |= {r.table for r in RESOURCES.values() if r.delete}

    async def granted():
        conn = await asyncpg.connect(os.environ["MASSLAK_OWNER_URL"])
        try:
            return {r["table_name"] for r in await conn.fetch("SELECT table_name FROM sys.app_delete_grant")}
        finally:
            await conn.close()
    assert sorted(wanted - asyncio.run(granted())) == []
