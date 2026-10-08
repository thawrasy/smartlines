"""The business rule matrix stays true (expert review of October 2026, stage C5).

docs/database/invariants.json says, for each rule, whether the database, the application or both keep it, which
objects and functions do, and which tests prove it. These tests fail when a name in it no longer exists: a trigger
renamed, a function moved, a test removed. A rule is then either re-pointed at what keeps it now, or found unkept.
"""
import ast
import importlib
import json
import os
import re
import subprocess
import sys

import pytest

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(BACKEND)
with open(os.path.join(ROOT, "docs", "database", "invariants.json"), encoding="utf-8") as f:
    MATRIX = json.load(f)
RULES = MATRIX["rules"]
OBJECT = re.compile(r"^(trigger|constraint|function|table) ([a-z_]+)\.([a-z_]+)(?:\.([a-z0-9_]+))?$")


def test_every_rule_is_complete():
    ids = [r["id"] for r in RULES]
    assert len(ids) == len(set(ids)), "rule ids repeat"
    problems = []
    for r in RULES:
        if r["owner"] not in MATRIX["owners"]:
            problems.append(f"{r['id']}: unknown owner {r['owner']}")
        if r["owner"] in ("database", "both") and not r["database"]:
            problems.append(f"{r['id']}: kept by the database but names no database object")
        if r["owner"] in ("application", "both") and not r["application"]:
            problems.append(f"{r['id']}: kept by the application but names no function")
        if not r["tests"]["db"] and not r["tests"]["api"]:
            problems.append(f"{r['id']}: no test proves it")
        if len(r["rule"]) < 20 or len(r["why"]) < 20:
            problems.append(f"{r['id']}: the rule and why its owner keeps it need a sentence each")
        for o in r["database"]:
            m = OBJECT.match(o)
            if not m or bool(m.group(4)) != (m.group(1) in ("trigger", "constraint")):
                problems.append(f"{r['id']}: {o!r} is not 'trigger|constraint schema.table.name' or 'function|table schema.name'")
    assert problems == []


def test_application_functions_exist():
    missing = []
    for r in RULES:
        for ref in r["application"]:
            module, _, name = ref.partition(":")
            target = importlib.import_module(module)
            for part in name.split("."):
                target = getattr(target, part, None)
            if not callable(target):
                missing.append(f"{r['id']}: {ref}")
    assert missing == []


def test_database_test_descriptions_exist():
    text = open(os.path.join(ROOT, "db", "tests", "run_tests.sql"), encoding="utf-8").read()
    missing = [f"{r['id']}: {d}" for r in RULES for d in r["tests"]["db"]
               if "'" + d.replace("'", "''") + "'" not in text and "PASS  " + d not in text]
    assert missing == []


def test_api_tests_exist():
    missing = []
    for r in RULES:
        for node in r["tests"]["api"]:
            path, _, name = node.partition("::")
            full = os.path.join(BACKEND, path)
            names = set()
            if os.path.exists(full):
                tree = ast.parse(open(full, encoding="utf-8").read())
                names = {n.name for n in tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))}
            if name not in names:
                missing.append(f"{r['id']}: {node}")
    assert missing == []


def test_the_rendered_matrix_is_current():
    tool = os.path.join(ROOT, "db", "tools", "gen_invariants.py")
    run = subprocess.run([sys.executable, tool, "--check"], capture_output=True, text=True)
    assert run.returncode == 0, run.stderr


def test_database_objects_exist():
    """Every trigger, constraint, function and table the matrix names is in the built database, and enabled."""
    import asyncio

    import asyncpg

    if not os.environ.get("MASSLAK_OWNER_URL"):
        pytest.skip("needs MASSLAK_OWNER_URL")
    queries = {
        "trigger": "SELECT tgenabled <> 'D' FROM pg_trigger WHERE tgrelid = to_regclass($1) AND tgname = $2 AND NOT tgisinternal",
        "constraint": "SELECT convalidated FROM pg_constraint WHERE conrelid = to_regclass($1) AND conname = $2",
        "function": "SELECT true FROM pg_proc WHERE pronamespace = to_regnamespace($1) AND proname = $2 LIMIT 1",
        "table": "SELECT relkind IN ('r', 'p') FROM pg_class WHERE oid = to_regclass($1 || '.' || $2)",
    }

    async def check() -> list:
        conn = await asyncpg.connect(os.environ["MASSLAK_OWNER_URL"])
        try:
            missing = []
            for r in RULES:
                for ref in r["database"]:
                    kind, schema, name, member = OBJECT.match(ref).groups()
                    args = (f"{schema}.{name}", member) if member else (schema, name)
                    if not await conn.fetchval(queries[kind], *args):
                        missing.append(f"{r['id']}: {ref}")
            return missing
        finally:
            await conn.close()
    assert asyncio.run(check()) == []
