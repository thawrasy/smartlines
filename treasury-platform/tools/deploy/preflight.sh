# Guards shared by the scripts in tools/deploy (DQ-S11-6; docs/adr/0014-deployment-preflight.md). Sourced after
# SQLCMD_OPTS is set.
#   -C in SQLCMD_OPTS trusts any server certificate (DOC-S05 section 5.3). It is refused, before any connection, unless
#   BANKFAS_ALLOW_TRUST_CERT=1, which only CI sets for its throwaway container (tools/ci/db_ci.sh).
#   sa_guard_sql prints a batch that refuses sa, also under another name (its SID is 0x01), unless BANKFAS_ALLOW_SA=1,
#   which only CI sets: in production sa is disabled and every script runs with a person's own login (DOC-S08 section 9).
#   tools/deploy/deploy.sh refuses sa and any sysadmin always (db/ops/deploy_preflight.sql).
for opt in $SQLCMD_OPTS; do
    if [ "$opt" = "-C" ] && [ "${BANKFAS_ALLOW_TRUST_CERT:-}" != "1" ]; then
        echo "$(basename "$0"): -C trusts any server certificate; only CI may pass it (BANKFAS_ALLOW_TRUST_CERT=1, DOC-S05 section 5.3)" >&2
        exit 1
    fi
done
sa_guard_sql() {
    [ "${BANKFAS_ALLOW_SA:-}" = "1" ] && return 0
    printf "IF SUSER_SID() = 0x01 THROW 50144, 'sa is disabled outside CI (DOC-S08 section 9): run this with your own administrator login', 1;\nGO\n"
}
