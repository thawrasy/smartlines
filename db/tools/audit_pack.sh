#!/usr/bin/env bash
# Builds the evidence pack for the second phase of the third-party audit from a built database and the running API.
#   db/tools/audit_pack.sh <database> <output dir> [psql connection args]
# The API address comes from MASSLAK_TEST_URL (default http://localhost:8000). Nothing secret is exported: the pack holds
# the schema, roles, grants, policies, functions and inventories, never rows of business data or key material.
set -euo pipefail
DB="${1:?database}"; OUT="${2:?output directory}"; shift 2
mkdir -p "$OUT"
q() { psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -A -F $'\t' --pset footer=off; }
csv() { local name="$1" sql="$2"; shift 2; psql "$@" -d "$DB" -v ON_ERROR_STOP=1 -q -c "COPY ($sql) TO STDOUT WITH CSV HEADER" > "$OUT/$name.csv"; }

pg_dump "$@" --schema-only --no-owner --no-privileges -d "$DB" > "$OUT/schema.sql"
pg_dumpall "$@" --roles-only --no-role-passwords > "$OUT/roles.sql" 2>/dev/null || q "$@" -c "SELECT rolname, rolsuper, rolbypassrls, rolcanlogin FROM pg_roles WHERE rolname LIKE 'masslak%'" > "$OUT/roles.tsv"

csv role_attributes "SELECT rolname, rolsuper, rolbypassrls, rolcanlogin, rolinherit FROM pg_roles WHERE rolname LIKE 'masslak%' ORDER BY 1" "$@"
csv role_membership "SELECT r.rolname AS role, m.rolname AS member_of FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.member JOIN pg_roles m ON m.oid = a.roleid WHERE r.rolname LIKE 'masslak%' ORDER BY 1, 2" "$@"
csv table_grants "SELECT table_schema || '.' || table_name AS table_name, grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privileges FROM information_schema.role_table_grants WHERE grantee LIKE 'masslak%' GROUP BY 1, 2 ORDER BY 1, 2" "$@"
csv hidden_columns "SELECT c.table_schema || '.' || c.table_name AS table_name, r.rolname AS role, string_agg(c.column_name, ',' ORDER BY c.ordinal_position) AS hidden_columns FROM information_schema.columns c CROSS JOIN pg_roles r WHERE r.rolname LIKE 'masslak%' AND c.table_schema NOT IN ('pg_catalog','information_schema') AND has_any_column_privilege(r.rolname, format('%I.%I', c.table_schema, c.table_name), 'SELECT') AND NOT has_column_privilege(r.rolname, format('%I.%I', c.table_schema, c.table_name), c.column_name, 'SELECT') GROUP BY 1, 2 ORDER BY 1, 2" "$@"
csv policies "SELECT schemaname || '.' || tablename AS table_name, policyname, permissive, cmd, roles::text, qual, with_check FROM pg_policies ORDER BY 1, 2" "$@"
csv security_inventory "SELECT * FROM sys.v_security_inventory ORDER BY 1" "$@"
csv security_definer_functions "SELECT p.oid::regprocedure::text AS function, pg_get_userbyid(p.proowner) AS owner, array_to_string(p.proconfig, ';') AS settings, has_function_privilege('masslak_app', p.oid, 'EXECUTE') AS app_can_execute FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE p.prosecdef AND n.nspname NOT IN ('pg_catalog','information_schema','gis') ORDER BY 1" "$@"
csv triggers "SELECT tgrelid::regclass::text AS table_name, tgname, tgfoid::regproc::text AS function, tgenabled, tgdeferrable FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1, 2" "$@"
csv foreign_keys "SELECT conrelid::regclass::text AS table_name, conname, pg_get_constraintdef(oid) AS definition, convalidated FROM pg_constraint WHERE contype = 'f' AND conparentid = 0 ORDER BY 1, 2" "$@"
csv polymorphic_references "SELECT * FROM sys.polymorphic_reference ORDER BY 1, 2" "$@"
csv orphan_findings "SELECT * FROM sys.find_orphans()" "$@"
csv schema_dependencies "SELECT * FROM sys.v_schema_dependency ORDER BY 1, 2" "$@"
csv phase_map "SELECT tp.table_name, tp.phase_code, pp.feature_keys::text AS switches, tp.module FROM sys.table_phase tp JOIN sys.project_phase pp ON pp.code = tp.phase_code ORDER BY 1" "$@"
csv compliance_requirements "SELECT code, domain, applies_to, subject_type, license_type, level, required_from, authority FROM sys.compliance_requirement ORDER BY 1" "$@"
csv jsonb_inventory "SELECT * FROM sys.v_jsonb_inventory ORDER BY 1, 2" "$@"
csv tables_without_primary_key "SELECT n.nspname || '.' || c.relname AS table_name FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND n.nspname NOT IN ('pg_catalog','information_schema') AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)" "$@"
csv policy_matrix "SELECT * FROM sys.v_policy_matrix ORDER BY 1, 5" "$@"
csv json_contracts "SELECT table_name, column_name, kind, version, spec::text, note FROM sys.json_contract ORDER BY 1, 2" "$@"
csv json_contract_violations "SELECT * FROM sys.json_contract_violations()" "$@"
csv lifecycle_matrix "SELECT * FROM gov.v_lifecycle_matrix ORDER BY 1" "$@"
csv ddl_changes_outside_migrations "SELECT occurred_at, command_tag, object_identity, session_user_name FROM audit.ddl_event WHERE NOT in_migration ORDER BY id" "$@"
csv extensions "SELECT extname, extversion, n.nspname AS schema FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY 1" "$@"
q "$@" -c "SELECT version()" > "$OUT/server_version.txt"

API="${MASSLAK_TEST_URL:-http://localhost:8000}"
if curl -sf "$API/api/health" > /dev/null 2>&1; then
  curl -sf "$API/api/openapi.json" -o "$OUT/openapi.json" || echo "openapi.json not served at $API/api/openapi.json" > "$OUT/openapi.MISSING"
else
  echo "API not reachable at $API; start it and rerun for openapi.json" > "$OUT/openapi.MISSING"
fi
( cd "$OUT" && sha256sum ./* > SHA256SUMS )
echo "audit pack written to $OUT ($(ls "$OUT" | wc -l) files)"
