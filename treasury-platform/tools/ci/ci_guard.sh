# Sourced by tools/ci/db_ci.sh and by every script it runs (internal review v6, D9, D10). They drop and build BankFas
# again, as sa, with the allowances only CI gives itself; none of them may reach a server that is not a throwaway.
#   - BANKFAS_ALLOW_SA=1 must be set: db_ci.sh sets it; a script started by hand without it stops here.
#   - The server is on this machine (localhost, 127.0.0.1, ::1, (local) or .), unless BANKFAS_CI_THROWAWAY_SERVER=1
#     says another one is a throwaway server too (self-review E8).
#   - ci_guard_drop, before anything drops BankFas: a database that holds a tenant other than those of the
#     performance scripts (perf-...) is real data, wherever it is: through an SSH tunnel a production server also
#     answers on localhost (D10). The tests leave no tenant behind (step 23).
ci_guard_refuse() { echo "$(basename "$0"): $1" >&2; exit 1; }
[ "${BANKFAS_ALLOW_SA:-}" = "1" ] || ci_guard_refuse "a CI script: run it through tools/ci/db_ci.sh, which sets the CI allowances (BANKFAS_ALLOW_SA=1)"
ci_host="${SQL_SERVER:-localhost,1433}"; ci_host="${ci_host%%,*}"; ci_host="${ci_host#tcp:}"
case "$ci_host" in
    localhost|127.0.0.1|::1|"(local)"|.) ;;
    *) [ "${BANKFAS_CI_THROWAWAY_SERVER:-}" = "1" ] \
           || ci_guard_refuse "CI drops BankFas: it runs only against a server on this machine, not $ci_host (set BANKFAS_CI_THROWAWAY_SERVER=1 for a throwaway server)" ;;
esac
# the T-SQL batch that refuses, before a DROP DATABASE, a BankFas that holds real tenants
ci_guard_drop_sql() {   # dynamic, so that a server without BankFas compiles it (a fresh CI container)
    printf '%s\n' "IF DB_ID(N'BankFas') IS NOT NULL
    EXEC (N'IF OBJECT_ID(N''BankFas.plat.Tenant'') IS NOT NULL AND EXISTS (SELECT 1 FROM [BankFas].plat.Tenant WHERE Code NOT LIKE N''perf-%'')
        THROW 50991, ''BankFas holds tenants that no CI or performance run made: this is not a throwaway server (ci_guard.sh, D10)'', 1;');"
}
