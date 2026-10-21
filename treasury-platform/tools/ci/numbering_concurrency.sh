#!/usr/bin/env bash
# Numbering under concurrency (FR-PLT-026: two concurrent requests never get the same number; BR-PLT-010: a rolled-back
# number is not lost). Several connections allocate numbers of one gap-free sequence at the same time, each in its
# own transactions, and a quarter of those transactions roll back. The committed numbers must then run 1..N with no
# duplicate and no gap. A second check: a gap-free number is refused outside a transaction (50029), and a sequence
# that allows gaps works there.
# The test commits its own tenant and removes it at the end. Prints PASS or FAIL lines, like the .sql tests.
#
# Environment: SQLCMDPASSWORD (sa), SQL_SERVER (default localhost,1433), SQLCMD (default sqlcmd),
#              WORKERS (default 6), PER_WORKER (default 25)
set -euo pipefail
# shellcheck source=tools/ci/ci_guard.sh
. "$(cd "$(dirname "$0")" && pwd)/ci_guard.sh"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
WORKERS="${WORKERS:-6}"
PER_WORKER="${PER_WORKER:-25}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sq() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas "$@"; }
# Statements go through files: the older Linux sqlcmd corrupts long -Q arguments.
run() { printf '%s\n' "$1" > "$TMP/stmt.sql"; shift; sq -i "$TMP/stmt.sql" "$@"; }

BIND="DECLARE @t INT = (SELECT TenantId FROM plat.Tenant WHERE Code = 'tst-conc'), @tk UNIQUEIDENTIFIER = NEWID();
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken) VALUES (@@SPID, @t, 0, @tk);
EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @tk;"
UNBIND="DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;"

cleanup_sql="SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM plat.Tenant WHERE Code = 'tst-conc')
BEGIN
    $BIND
    DELETE FROM cfg.NumberIssue WHERE TenantId = @t;
    DELETE FROM cfg.NumberSequence WHERE TenantId = @t;
    DELETE FROM cfg.NumberSequenceDefinition WHERE TenantId = @t;
    $UNBIND
    DELETE FROM sec.SessionBinding WHERE BoundTenantId = @t;
    DELETE FROM plat.Tenant WHERE TenantId = @t;
END"

# Setup: a tenant with one gap-free and one gaps-allowed sequence, committed.
run "$cleanup_sql" >/dev/null
run "SET NOCOUNT ON;
ALTER TABLE plat.Tenant NOCHECK CONSTRAINT FK_Tenant_HomeCountryId;
INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone)
SELECT 'tst-conc', N'C', N'C', (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'), 1, 'ACTIVE', 'UTC';
ALTER TABLE plat.Tenant WITH CHECK CHECK CONSTRAINT FK_Tenant_HomeCountryId;
$BIND
INSERT cfg.NumberSequenceDefinition (TenantId, SequenceKey, Pattern, ScopeLevel, PeriodBasis, GapPolicy)
VALUES (@t, 'CONC', N'C-{seq:000000}', 'TENANT', 'NONE', 'GAP_FREE'), (@t, 'CONC_GAPS', N'G-{seq}', 'TENANT', 'NONE', 'ALLOW_GAPS');
$UNBIND
-- a common start time for the workers, so that they really run at the same moment
UPDATE plat.Tenant SET NameEn = CONVERT(NVARCHAR(30), DATEADD(SECOND, 8, SYSUTCDATETIME()), 126) WHERE TenantId = @t;" >/dev/null

# Workers: each allocates PER_WORKER numbers, one transaction each, and rolls back every fourth.
cat > "$TMP/worker.sql" <<SQL
SET NOCOUNT ON;
$BIND
DECLARE @i INT = 0, @n NVARCHAR(60), @wait INT = DATEDIFF(MILLISECOND, SYSUTCDATETIME(),
        (SELECT CAST(NameEn AS DATETIME2) FROM plat.Tenant WHERE TenantId = @t));
IF @wait > 0
BEGIN
    DECLARE @until DATETIME = DATEADD(MILLISECOND, @wait, CAST(0 AS DATETIME));
    WAITFOR DELAY @until;
END;
WHILE @i < $PER_WORKER
BEGIN
    BEGIN TRANSACTION;
    EXEC cfg.usp_AllocateNumber @SequenceKey = 'CONC', @EntityType = 'conc.worker', @EntityId = __W__, @IssuedNumber = @n OUTPUT;
    WAITFOR DELAY '00:00:00.010';                 -- hold the counter while the other workers queue on it
    IF @i % 4 = 3 ROLLBACK TRANSACTION; ELSE COMMIT TRANSACTION;
    SET @i = @i + 1;
END;
$UNBIND
SQL
pids=()
for w in $(seq 1 "$WORKERS"); do
    sed "s/__W__/$w/" "$TMP/worker.sql" > "$TMP/worker$w.sql"   # the worker number, as the entity of its numbers
    sq -i "$TMP/worker$w.sql" > "$TMP/worker$w.out" 2>&1 &
    pids+=($!)
done
failed=0
for p in "${pids[@]}"; do wait "$p" || failed=1; done
if [ "$failed" -ne 0 ]; then
    cat "$TMP"/worker*.out
    echo "FAIL C1: a worker failed"
    run "$cleanup_sql" >/dev/null
    exit 1
fi
expected=$(( WORKERS * (PER_WORKER - PER_WORKER / 4) ))

run "SET NOCOUNT ON;
$BIND
DECLARE @cnt INT, @lo BIGINT, @hi BIGINT, @dist INT, @dup INT, @next BIGINT;
SELECT @cnt = COUNT(*), @lo = MIN(i.SeqValue), @hi = MAX(i.SeqValue), @dist = COUNT(DISTINCT i.SeqValue),
       @dup = COUNT(*) - COUNT(DISTINCT i.IssuedNumber)
FROM cfg.NumberIssue AS i JOIN cfg.NumberSequence AS s ON s.NumberSequenceId = i.SequenceId
JOIN cfg.NumberSequenceDefinition AS d ON d.NumberSequenceDefinitionId = s.DefinitionId
WHERE d.SequenceKey = 'CONC' AND d.TenantId = @t;
SELECT @next = s.NextValue FROM cfg.NumberSequence AS s JOIN cfg.NumberSequenceDefinition AS d ON d.NumberSequenceDefinitionId = s.DefinitionId
WHERE d.SequenceKey = 'CONC' AND d.TenantId = @t;
-- How often the next number went to a different connection: well above the worker count only if they interleaved.
DECLARE @switches INT = (SELECT COUNT(*) FROM (SELECT EntityId, LAG(EntityId) OVER (ORDER BY SeqValue) AS Prev
                                                FROM cfg.NumberIssue WHERE TenantId = @t AND EntityType = 'conc.worker') AS x
                         WHERE x.Prev IS NOT NULL AND x.Prev <> x.EntityId);
IF @cnt = $expected AND @lo = 1 AND @hi = @cnt AND @dist = @cnt AND @dup = 0 AND @next = @cnt + 1 AND @switches > 2 * $WORKERS
    PRINT CONCAT('PASS C1: $WORKERS concurrent connections took ', @cnt, ' numbers, 1 to ', @hi, ', with no duplicate and no gap after ', $WORKERS * ($PER_WORKER / 4), ' rollbacks (', @switches, ' switches between connections)');
ELSE
    PRINT CONCAT('FAIL C1: count ', @cnt, ' (expected $expected), min ', @lo, ', max ', @hi, ', distinct ', @dist, ', duplicates ', @dup, ', next ', @next, ', switches ', @switches);
DECLARE @e INT = NULL, @g NVARCHAR(60);
BEGIN TRY EXEC cfg.usp_AllocateNumber @SequenceKey = 'CONC'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH;
EXEC cfg.usp_AllocateNumber @SequenceKey = 'CONC_GAPS', @IssuedNumber = @g OUTPUT;
IF @e = 50029 AND @g = N'G-1'
    PRINT 'PASS C2: a gap-free number is refused outside a transaction, and a sequence that allows gaps works there';
ELSE PRINT CONCAT('FAIL C2: outside a transaction (', @e, ' ', @g, ')');
$UNBIND" -h -1 -W
run "$cleanup_sql" >/dev/null
