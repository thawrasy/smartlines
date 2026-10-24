#!/usr/bin/env python3
"""Architecture fitness checks on the built database, against an accepted baseline (independent review, round 9, Team:
the rules of the design are checked by CI on every change, not by a reviewer once).

It fails when the built database has
* a foreign key with no index starting with its columns that is not in the baseline (a delete or update of the parent
  row scans the child table and locks it): a new foreign key comes with its index;
* a SECURITY DEFINER function that is not in the baseline, or one a role can execute that the baseline does not grant:
  a new definer function, or a wider grant, is a reviewed change of the baseline in the same commit;
* any SECURITY DEFINER function PUBLIC can execute (1135), or any table, view or sequence granted to PUBLIC (an
  extension's own catalogs aside, such as PostGIS's spatial_ref_sys);
* a table with no data class in sys.table_class (1039).
It reports baseline entries that no longer exist (remove them: the baseline only shrinks or is changed on purpose).
Schema dependency cycles are db/tools/schema_dependencies.py.

    python3 db/tools/fitness.py <database> [--write-baseline] [psql connection args...]

The baseline is db/fitness_baseline.json. --write-baseline rewrites it from the database; the diff of that file is the
privilege change between two releases, which the reviewer of the change reads.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "db" / "fitness_baseline.json"
SKIP = "('pg_catalog', 'information_schema', 'public', 'pg_toast')"

QUERIES = {
    "unindexed_foreign_keys": f"""
SELECT coalesce(json_agg(c.oid::regclass::text || '.' || k.conname ORDER BY 1), '[]')
  FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE k.contype = 'f' AND NOT c.relispartition AND k.conparentid = 0 AND n.nspname NOT IN {SKIP}
   AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = k.conrelid
                     AND (i.indkey::int2[])[0:cardinality(k.conkey) - 1] @> k.conkey
                     AND (i.indkey::int2[])[0:cardinality(k.conkey) - 1] <@ k.conkey)""",
    "definer_functions": f"""
SELECT coalesce(json_object_agg(f, roles ORDER BY f), '{{}}') FROM (
  SELECT p.oid::regprocedure::text AS f,
         (SELECT coalesce(json_agg(r.rolname ORDER BY r.rolname), '[]') FROM pg_roles r
           WHERE r.oid <> p.proowner AND NOT r.rolsuper AND r.rolname NOT LIKE 'pg\\_%'
             AND has_function_privilege(r.oid, p.oid, 'EXECUTE')) AS roles
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE p.prosecdef AND n.nspname NOT IN {SKIP}) d""",
    "public_definer_functions": f"""
SELECT coalesce(json_agg(p.oid::regprocedure::text ORDER BY 1), '[]')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE p.prosecdef AND n.nspname NOT IN {SKIP} AND has_function_privilege('public', p.oid, 'EXECUTE')""",
    "public_relations": f"""
SELECT coalesce(json_agg(DISTINCT c.oid::regclass::text), '[]')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
 WHERE n.nspname NOT IN {SKIP} AND a.grantee = 0
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')""",
    "unclassified_tables": f"""
SELECT coalesce(json_agg(c.oid::regclass::text ORDER BY 1), '[]')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition AND n.nspname NOT IN {SKIP} AND n.nspname NOT LIKE 'pg\\_temp%'
   AND NOT EXISTS (SELECT 1 FROM sys.table_class t WHERE t.table_name = n.nspname || '.' || c.relname)""",
}


def query(db: str, args: list[str], sql: str):
    out = subprocess.run(["psql", *args, "-d", db, "-XAtqc", sql], check=True, capture_output=True, text=True)  # nosec B603 B607
    return json.loads(out.stdout)


def check(found: dict, base: dict) -> tuple[list[str], list[str]]:
    bad, stale = [], []
    allowed = set(base.get("unindexed_foreign_keys", []))
    bad += [f"foreign key without an index: {k} (add the index in the same schema file)"
            for k in found["unindexed_foreign_keys"] if k not in allowed]
    stale += [f"unindexed_foreign_keys: {k}" for k in sorted(allowed - set(found["unindexed_foreign_keys"]))]
    granted = base.get("definer_functions", {})
    for f, roles in found["definer_functions"].items():
        if f not in granted:
            bad.append(f"SECURITY DEFINER function not in the baseline: {f} (executable by {', '.join(roles) or 'its owner only'})")
        else:
            bad += [f"{f}: {r} can execute it, the baseline does not grant it" for r in roles if r not in granted[f]]
    stale += [f"definer_functions: {f}" for f in sorted(set(granted) - set(found["definer_functions"]))]
    stale += [f"definer_functions: {f}: {r} no longer granted" for f, roles in granted.items()
              if f in found["definer_functions"] for r in roles if r not in found["definer_functions"][f]]
    bad += [f"PUBLIC can execute the SECURITY DEFINER function {f}" for f in found["public_definer_functions"]]
    bad += [f"PUBLIC holds a privilege on {r}" for r in found["public_relations"]]
    bad += [f"table without a data class in sys.table_class: {t}" for t in found["unclassified_tables"]]
    return bad, stale


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    db, rest = sys.argv[1], sys.argv[2:]
    write = "--write-baseline" in rest
    args = [a for a in rest if a != "--write-baseline"]
    found = {k: query(db, args, q) for k, q in QUERIES.items()}
    if write:
        BASELINE.write_text(json.dumps({
            "about": "Accepted state of db/tools/fitness.py: foreign keys without an index (only shrinks) and the roles "
                     "that may execute each SECURITY DEFINER function (a change here is a reviewed privilege change)",
            "unindexed_foreign_keys": found["unindexed_foreign_keys"],
            "definer_functions": found["definer_functions"]}, indent=1, sort_keys=False) + "\n")
        print(f"wrote {BASELINE.relative_to(ROOT)}")
        return 0
    bad, stale = check(found, json.loads(BASELINE.read_text()))
    print(f"foreign keys without an index: {len(found['unindexed_foreign_keys'])} (baseline allows these, no new one)")
    print(f"SECURITY DEFINER functions: {len(found['definer_functions'])}, PUBLIC executes {len(found['public_definer_functions'])}")
    for s in stale:
        print(f"stale baseline entry (remove it, or --write-baseline): {s}")
    for b in bad:
        print(f"FAIL {b}")
    print("architecture fitness: " + ("OK" if not bad else f"{len(bad)} problem(s)"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
