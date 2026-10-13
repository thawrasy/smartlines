#!/usr/bin/env bash
# Service logins (tools/deploy/provision_logins.sh, db/ops/service_logins.sql, ADR 0009, DOC-S08 section 3): the
# provisioning creates one login per process, each connects with its own secret and holds its role's rights only,
# a secret is rotated by running it again or through the second account of the pair, and weak or exposed secrets,
# extra role memberships and impersonation of tp_auth_exec are refused. Prints PASS or FAIL lines like the .sql tests.
# The logins it creates are dropped at the end.
#
# Environment: SQLCMDPASSWORD (sa), SQL_SERVER (default localhost,1433), SQLCMD (default sqlcmd)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
SA_PW="${SQLCMDPASSWORD:?set SQLCMDPASSWORD to the sa password}"
TMP="$(mktemp -d)"
SEC="$TMP/secrets"
mkdir -m 700 "$SEC"
trap 'rm -rf "$TMP"' EXIT

sa_run() { printf '%s\n' "$1" > "$TMP/sa.sql"; SQLCMDPASSWORD="$SA_PW" "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -h -1 -W -i "$TMP/sa.sql"; }
as_login() {   # login, secret, statement
    printf '%s\n' "$3" > "$TMP/login.sql"
    SQLCMDPASSWORD="$2" "$SQLCMD" -S "$SQL_SERVER" -U "$1" -C -d BankFas -I -b -h -1 -W -i "$TMP/login.sql" 2>/dev/null
}
ask() { as_login "$@" || true; }   # for a value: an error leaves it empty, and the check then fails
provision() {  # set, [--generate]; output goes to $TMP/provision.out
    SQLCMDPASSWORD="$SA_PW" SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$SEC" BANKFAS_LOGIN_SET="$1" \
        bash "$ROOT/tools/deploy/provision_logins.sh" ${2:-} > "$TMP/provision.out" 2>&1
}
secret() { cat "$SEC/$1.secret"; }
cleanup_sql="SET NOCOUNT ON; USE [BankFas];
DECLARE @n SYSNAME, @sql NVARCHAR(300);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.database_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S';
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP USER ' + QUOTENAME(@n); EXEC sys.sp_executesql @sql; FETCH NEXT FROM c INTO @n; END;
CLOSE c; DEALLOCATE c;
DECLARE l CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.server_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S';
OPEN l; FETCH NEXT FROM l INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP LOGIN ' + QUOTENAME(@n); EXEC master.sys.sp_executesql @sql; FETCH NEXT FROM l INTO @n; END;
CLOSE l; DEALLOCATE l;"
sa_run "$cleanup_sql" >/dev/null

# LG1: --generate writes four private secret files; each login connects and is a member of its own role only.
if provision a --generate; then
    files=$(find "$SEC" -name '*_a.secret' -perm 600 | wc -l)
    who="SET NOCOUNT ON; SELECT CONCAT(IS_MEMBER('tp_app'), IS_MEMBER('tp_jobs'), IS_MEMBER('tp_platform'), IS_MEMBER('tp_support'), IS_MEMBER('tp_readonly'), IS_SRVROLEMEMBER('sysadmin'), IS_MEMBER('db_owner'));"
    got="$(ask bankfas_app_a "$(secret bankfas_app_a)" "$who") $(ask bankfas_jobs_a "$(secret bankfas_jobs_a)" "$who") $(ask bankfas_platform_a "$(secret bankfas_platform_a)" "$who") $(ask bankfas_support_a "$(secret bankfas_support_a)" "$who")"
    if [ "$files" -eq 4 ] && [ "$got" = "1000000 1100000 0010000 0001100" ]; then
        echo "PASS LG1: one login per process, each with a private secret file and the membership of its own role only"
    else echo "FAIL LG1: files $files, memberships $got"; fi
else cat "$TMP/provision.out"; echo "FAIL LG1: provisioning failed"; fi

# LG2: each login holds what its process needs and not what the others need.
p() { printf "HAS_PERMS_BY_NAME('%s', 'OBJECT', '%s')" "$1" "$2"; }
q="SET NOCOUNT ON; SELECT CONCAT($(p sec.usp_SetSessionContext EXECUTE), $(p sec.usp_SetJobContext EXECUTE), $(p sec.usp_SetSupportContext EXECUTE), $(p plat.usp_CreateTenant EXECUTE), $(p cfg.usp_StartDataExport EXECUTE), $(p plat.Tenant SELECT), $(p org.Company SELECT), $(p cfg.TenantSetting INSERT));"
r_app="$(ask bankfas_app_a "$(secret bankfas_app_a)" "$q")"
r_job="$(ask bankfas_jobs_a "$(secret bankfas_jobs_a)" "$q")"
r_pla="$(ask bankfas_platform_a "$(secret bankfas_platform_a)" "$q")"
r_sup="$(ask bankfas_support_a "$(secret bankfas_support_a)" "$q")"
# columns: bind a user session, bind a job, bind support, create a tenant, run an export, read plat.Tenant, read
# org.Company, write a tenant setting. The panel reads the tenant register but no tenant table; support only reads.
if [ "$r_app" = "10000011" ] && [ "$r_job" = "11001011" ] && [ "$r_pla" = "00010100" ] && [ "$r_sup" = "00100010" ]; then
    echo "PASS LG2: the web, job, panel and support logins each hold their own procedures and table rights only"
else echo "FAIL LG2: app $r_app, jobs $r_job, platform $r_pla, support $r_sup"; fi

# LG3: rotation in place: a new secret file and a second run; the old secret stops working, the role stays.
old="$(secret bankfas_app_a)"
rm -f "$SEC/bankfas_app_a.secret"
if provision a --generate && ! as_login bankfas_app_a "$old" "SELECT 1;" >/dev/null \
   && [ "$(ask bankfas_app_a "$(secret bankfas_app_a)" "SET NOCOUNT ON; SELECT IS_MEMBER('tp_app');")" = "1" ]; then
    echo "PASS LG3: running the provisioning again rotates a secret: the old one is refused, the new one keeps the role"
else echo "FAIL LG3: rotation in place"; fi

# LG4: the second account of each pair (set b) works next to the first, for rotation without downtime.
if provision b --generate \
   && [ "$(ask bankfas_jobs_b "$(secret bankfas_jobs_b)" "SET NOCOUNT ON; SELECT IS_MEMBER('tp_jobs');")" = "1" ] \
   && [ "$(ask bankfas_jobs_a "$(secret bankfas_jobs_a)" "SET NOCOUNT ON; SELECT IS_MEMBER('tp_jobs');")" = "1" ]; then
    echo "PASS LG4: the a and b accounts of a pair connect side by side with their own secrets"
else echo "FAIL LG4: second account of the pair"; fi

# LG5: a weak secret or a secret file others can read is refused before anything changes.
good="$(secret bankfas_support_a)"
printf 'short-secret' > "$SEC/bankfas_support_a.secret"
provision a && weak=accepted || weak=refused
printf '%s' "$good" > "$SEC/bankfas_support_a.secret"; chmod 644 "$SEC/bankfas_support_a.secret"
provision a && open=accepted || open=refused
chmod 600 "$SEC/bankfas_support_a.secret"
if [ "$weak" = refused ] && [ "$open" = refused ] && as_login bankfas_support_a "$good" "SELECT 1;" >/dev/null; then
    echo "PASS LG5: a weak secret or a readable secret file is refused, and the login keeps its secret"
else echo "FAIL LG5: weak $weak, readable $open"; fi

# LG6: the provisioning stops when a service user gets another role (50102) or someone may impersonate
# tp_auth_exec (50103).
sa_run "USE [BankFas]; ALTER ROLE [db_datareader] ADD MEMBER [bankfas_app_a];" >/dev/null
provision a && extra=accepted || extra=refused
grep -q 'other than its own' "$TMP/provision.out" && extra_msg=1 || extra_msg=0
sa_run "USE [BankFas]; ALTER ROLE [db_datareader] DROP MEMBER [bankfas_app_a]; GRANT IMPERSONATE ON USER::[tp_auth_exec] TO [tp_app];" >/dev/null
provision a && imp=accepted || imp=refused
grep -q 'impersonate tp_auth_exec' "$TMP/provision.out" && imp_msg=1 || imp_msg=0
sa_run "USE [BankFas]; REVOKE IMPERSONATE ON USER::[tp_auth_exec] FROM [tp_app];" >/dev/null
if [ "$extra" = refused ] && [ "$extra_msg" = 1 ] && [ "$imp" = refused ] && [ "$imp_msg" = 1 ] && provision a; then
    echo "PASS LG6: an extra role for a service user or a grant to impersonate tp_auth_exec stops the provisioning"
else echo "FAIL LG6: extra role $extra ($extra_msg), impersonation $imp ($imp_msg)"; fi

sa_run "$cleanup_sql" >/dev/null
