"""Extracts the business rules the platform enforces, for the rules catalog: the errors raised by the database functions
(read from the live database, so only the current definition of each function counts), the CHECK constraints of the
tables, and the errors raised by the API. Each rule lists the tests that mention its code.

    PGPASSWORD=... python3 rules_catalog.py <database> [-h host] [-U user]

Output: work2/rules.json."""
import ast, json, os, re, subprocess, sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
APP = os.path.join(ROOT, "backend", "app")
SKIP_SCHEMAS = ("pg_catalog", "information_schema", "public", "gis", "pg_toast")


def psql(db, args, sql):
    out = subprocess.run(["psql", *args, "-d", db, "-AtX", "-F", "\x1f", "-R", "\x1e", "-c", sql],
                         capture_output=True, text=True, check=True).stdout
    return [r.split("\x1f") for r in out.split("\x1e") if r.strip()]


def database_rules(db, args):
    skip = ",".join(f"'{s}'" for s in SKIP_SCHEMAS)
    funcs = psql(db, args, f"""SELECT n.nspname, p.proname, p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                WHERE n.nspname NOT IN ({skip}) AND p.prosrc ~ 'RAISE EXCEPTION'""")
    triggers = defaultdict(set)
    for fschema, fname, table in psql(db, args, f"""SELECT pn.nspname, p.proname, c.oid::regclass::text FROM pg_trigger t
                                                    JOIN pg_proc p ON p.oid = t.tgfoid JOIN pg_namespace pn ON pn.oid = p.pronamespace
                                                    JOIN pg_class c ON c.oid = t.tgrelid WHERE NOT t.tgisinternal"""):
        triggers[f"{fschema}.{fname}"].add(table)
    rules, seen = [], set()
    for schema, name, src in funcs:
        for m in re.finditer(r"RAISE\s+EXCEPTION\s+'((?:[^']|'')*)'", src, re.I):
            text = m.group(1).replace("''", "'")
            code, _, message = text.partition(":")
            if not re.fullmatch(r"[A-Z][A-Z0-9_]{2,}", code.strip()):
                code, message = "", text
            key = (schema, name, code.strip(), message.strip())
            if key in seen:
                continue
            seen.add(key)
            fn = f"{schema}.{name}"
            rules.append(dict(domain=schema, where=fn, code=code.strip(), message=message.strip(),
                              trigger_on=sorted(triggers.get(fn, ())), kind="trigger" if fn in triggers else "function"))
    return rules


def constraints(db, args):
    skip = ",".join(f"'{s}'" for s in SKIP_SCHEMAS)
    rows = psql(db, args, f"""SELECT n.nspname, c.conrelid::regclass::text, c.conname, pg_get_constraintdef(c.oid)
                               FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
                              WHERE c.contype = 'c' AND n.nspname NOT IN ({skip}) ORDER BY 2, 3""")
    return [dict(domain=s, table=t, name=n, definition=d) for s, t, n, d in rows]


def api_rules():
    rules = []
    for dirpath, _, files in os.walk(APP):
        for f in sorted(files):
            if not f.endswith(".py"):
                continue
            path = os.path.join(dirpath, f)
            tree = ast.parse(open(path).read())
            parents = {}
            for node in ast.walk(tree):
                for child in ast.iter_child_nodes(node):
                    parents[child] = node
            for node in ast.walk(tree):
                if not (isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", None)) == "ApiError"):
                    continue
                a = node.args
                if len(a) < 2 or not isinstance(a[0], ast.Constant) or not isinstance(a[1], ast.Constant):
                    continue
                message = ""
                if len(a) > 2:
                    message = a[2].value if isinstance(a[2], ast.Constant) else ast.unparse(a[2])
                fn, p = None, parents.get(node)
                while p is not None and fn is None:
                    if isinstance(p, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        fn = p.name
                    p = parents.get(p)
                rel = os.path.relpath(path, APP)
                module = rel.split(os.sep)[1] if rel.startswith("modules") else rel.split(os.sep)[0].replace(".py", "")
                rules.append(dict(domain=module, where=f"{rel}:{fn}", status=a[0].value, code=a[1].value, message=str(message)))
    return rules


def tests_mentioning(codes):
    files = []
    for d in (os.path.join(ROOT, "backend", "tests"), os.path.join(ROOT, "db", "tests")):
        for f in sorted(os.listdir(d)):
            if f.endswith((".py", ".sql")):
                files.append((f, open(os.path.join(d, f)).read()))
    found = {}
    for code in codes:
        if not code:
            continue
        pat = re.compile(rf"\b{re.escape(code)}\b")
        found[code] = [f for f, text in files if pat.search(text)]
    return found


def main():
    db, args = sys.argv[1], sys.argv[2:]
    dbr, apir, cons = database_rules(db, args), api_rules(), constraints(db, args)
    tests = tests_mentioning({r["code"] for r in dbr + apir})
    for r in dbr + apir:
        r["tests"] = tests.get(r["code"], [])
    os.makedirs(os.path.join(HERE, "work2"), exist_ok=True)
    json.dump(dict(database=dbr, api=apir, constraints=cons), open(os.path.join(HERE, "work2", "rules.json"), "w"), indent=1)
    tested = sum(1 for r in dbr + apir if r["tests"])
    print(f"database rules {len(dbr)}, API rules {len(apir)}, CHECK constraints {len(cons)}, rules with a test {tested}")


if __name__ == "__main__":
    main()
