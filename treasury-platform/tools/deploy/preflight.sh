# Guards shared by the scripts in tools/deploy (DQ-S11-6; docs/adr/0014-deployment-preflight.md). Sourced after
# SQLCMD_OPTS is set.
#   SQLCMD_OPTS takes only the options on the list below, so no spelling of a weaker connection gets through
#   (self-review E7): -l and -t with a number of seconds, -N s or -N m (strict or mandatory encryption; -N o would
#   send everything in clear), -f 65001 (the files read as UTF-8, DQ-S11-3), and -C. -C trusts any server certificate (DOC-S05 section 5.3): it is refused, before
#   any connection, unless BANKFAS_ALLOW_TRUST_CERT=1, which only CI sets for its throwaway container
#   (tools/ci/db_ci.sh). The sqlcmd command itself (SQLCMD) is a path, never a command with options.
#   sa_guard_sql prints a batch that refuses sa, also under another name (its SID is 0x01), unless BANKFAS_ALLOW_SA=1,
#   which only CI sets: in production sa is disabled and every script runs with a person's own login (DOC-S08 section 9).
#   tools/deploy/deploy.sh refuses sa and any sysadmin always (db/ops/deploy_preflight.sql).
bankfas_refuse() { echo "$(basename "$0"): $1" >&2; exit 1; }
case "${SQLCMD:-sqlcmd}" in *[[:space:]]*) bankfas_refuse "SQLCMD is the sqlcmd program, without options: put options in SQLCMD_OPTS" ;; esac
read -r -a bankfas_opts <<< "${SQLCMD_OPTS:-}"   # an array: the caller's own arguments stay as they are
bankfas_i=0
while [ "$bankfas_i" -lt "${#bankfas_opts[@]}" ]; do
    bankfas_o="${bankfas_opts[$bankfas_i]}" bankfas_v="${bankfas_opts[$((bankfas_i + 1))]:-}"
    case "$bankfas_o" in
        -C) [ "${BANKFAS_ALLOW_TRUST_CERT:-}" = "1" ] \
                || bankfas_refuse "-C trusts any server certificate; only CI may pass it (BANKFAS_ALLOW_TRUST_CERT=1, DOC-S05 section 5.3)" ;;
        -l|-t) [[ "$bankfas_v" =~ ^[0-9]{1,4}$ ]] || bankfas_refuse "$bankfas_o takes a number of seconds"; bankfas_i=$((bankfas_i + 1)) ;;
        -N) [[ "$bankfas_v" =~ ^[sm]$ ]] || bankfas_refuse "-N takes s or m: the connection is encrypted (DOC-S05 section 5.3)"; bankfas_i=$((bankfas_i + 1)) ;;
        -Ns|-Nm|-f65001) ;;
        -f) [ "$bankfas_v" = "65001" ] || bankfas_refuse "-f takes 65001: the scripts are UTF-8 (DQ-S11-3)"; bankfas_i=$((bankfas_i + 1)) ;;
        *) bankfas_refuse "SQLCMD_OPTS may hold only -l, -t, -N s|m, -f 65001 and, in CI, -C; '$bankfas_o' is not on the list (self-review E7)" ;;
    esac
    bankfas_i=$((bankfas_i + 1))
done
sa_guard_sql() {
    [ "${BANKFAS_ALLOW_SA:-}" = "1" ] && return 0
    printf "IF SUSER_SID() = 0x01 THROW 50144, 'sa is disabled outside CI (DOC-S08 section 9): run this with your own administrator login', 1;\nGO\n"
}
# bankfas_gate_sql prints db/ops/server_gate.sql (50140 sa, sysadmin or a server right; 50143 the release register,
# gate G4; 50150 nested triggers off) filled from the release register, BANKFAS_VERSIONS or versions.json: deploy.sh
# runs it before its preflight, migrate.sh before baseline and apply (internal review v6, D6).
bankfas_gate_sql() {
    local here versions v os sql
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    versions="${BANKFAS_VERSIONS:-$here/../../versions.json}"
    read -r v os < <(python3 -c 'import json, sys
h = json.load(open(sys.argv[1], encoding="utf-8"))["database_host"]
print(h["sqlserver"]["product_version"], h["os_release"])' "$versions")
    [[ "$v" =~ ^[0-9]+(\.[0-9]+){3}$ && "$os" =~ ^[0-9]+\.[0-9]+$ ]] \
        || bankfas_refuse "$versions must give database_host.sqlserver.product_version and database_host.os_release"
    sql="$(cat "$here/../../db/ops/server_gate.sql")"
    sql="${sql//\$(BANKFAS_EXPECT_VERSION)/$v}"
    sql="${sql//\$(BANKFAS_EXPECT_OS)/$os}"
    printf '%s\n' "$sql"
}
