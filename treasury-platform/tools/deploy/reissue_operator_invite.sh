#!/usr/bin/env bash
# A new link for the first operator administrator when the one bootstrap_operator.sh printed was lost or has expired
# before the set-up (docs/62 section 9.8). It works only while no operator has finished the set-up: it revokes the
# unused links of the invited administrator, adds a new 48-hour one and writes OPERATOR_INVITATION_REISSUED (HIGH) to
# the audit log. Once an administrator is active, the next ones are invited and reset from the panel instead.
# It runs as the personal sysadmin login of docs/62 section 8.6 (the deployment login is disabled outside the
# deployment window). Like bootstrap_operator.sh, the token is 32 random bytes kept in a private temporary file, the
# database keeps only its SHA-256, and the link is shown once on the terminal.
#
# Usage: tools/deploy/reissue_operator_invite.sh <your SQL login>   (it asks the password)
# Environment: SQL_SERVER (default db.bankfas.internal,1433), SQLCMD, BANKFAS_PANEL_URL (default https://admin.localhost:8443).
set -euo pipefail

SQL_SERVER="${SQL_SERVER:-db.bankfas.internal,1433}"
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
PANEL="${BANKFAS_PANEL_URL:-https://admin.localhost:8443}"
LOGIN="${1:?your personal SQL login}"

fail() { echo "reissue_operator_invite: $*" >&2; exit 1; }
[[ "$LOGIN" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "the SQL login has a character outside [A-Za-z0-9_.-]"
[[ "${LOGIN,,}" != sa && "${LOGIN,,}" != sa_disabled ]] || fail "use your personal login, not sa"
[[ "$PANEL" =~ ^https://[a-z0-9.-]+(:[0-9]{2,5})?/?$ ]] || fail "BANKFAS_PANEL_URL is https://<host>[:port]"
if [ -z "${SQLCMDPASSWORD:-}" ]; then read -rsp "Password of $LOGIN: " SQLCMDPASSWORD; echo; fi
export SQLCMDPASSWORD

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
( umask 077; head -c 32 /dev/urandom > "$WORK/token.bin" )
hex="$(od -An -tx1 -v "$WORK/token.bin" | tr -d ' \n')"
link_token="$(base64 -w0 < "$WORK/token.bin" | tr '+/' '-_' | tr -d '=')"
( umask 077; cat > "$WORK/reissue.sql" <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM plat.PlatformOperator WITH (UPDLOCK, HOLDLOCK) WHERE Status <> 'INVITED')
    THROW 50023, 'An operator has finished the set-up: invite or reset from the panel', 1;
DECLARE @oid INT = (SELECT MIN(PlatformOperatorId) FROM plat.PlatformOperator WHERE Role = 'OPERATOR_ADMIN' AND Status = 'INVITED');
IF @oid IS NULL THROW 50016, 'No invited operator administrator: run tools/deploy/bootstrap_operator.sh', 1;
UPDATE plat.OperatorToken SET RevokedAt = SYSUTCDATETIME() WHERE OperatorId = @oid AND UsedAt IS NULL AND RevokedAt IS NULL;
INSERT plat.OperatorToken (OperatorId, Purpose, TokenHash, ExpiresAt, SentTo)
SELECT @oid, 'INVITATION', HASHBYTES('SHA2_256', 0x$hex), DATEADD(HOUR, 48, SYSUTCDATETIME()), Email
FROM plat.PlatformOperator WHERE PlatformOperatorId = @oid;
EXEC aud.usp_WriteEvent @TenantId = NULL, @Action = 'OPERATOR_INVITATION_REISSUED', @Category = 'PLATFORM', @ActorType = 'SYSTEM',
     @Severity = 'HIGH', @EntityType = 'plat.PlatformOperator', @EntityId = @oid;
COMMIT TRANSACTION;
SELECT Email FROM plat.PlatformOperator WHERE PlatformOperatorId = @oid;
GO
SQL
)
"$SQLCMD" -S "$SQL_SERVER" -U "$LOGIN" -d BankFas -I -b -h -1 -i "$WORK/reissue.sql" > "$WORK/out" 2>&1 || {
    cat "$WORK/out" >&2; fail "nothing was changed"; }
echo "A new link for $(tr -d ' \r' < "$WORK/out" | grep -m1 @), valid for 48 hours, shown this once (the old ones are revoked):"
echo "  ${PANEL%/}/setup#token=$link_token"
