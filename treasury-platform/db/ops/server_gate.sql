/* ============================================================================
   BankFas - the checks of the server and of the login that every schema change runs first: tools/deploy/deploy.sh
   (before db/ops/deploy_preflight.sql) and tools/deploy/migrate.sh (baseline and apply; internal review v6, D6).
   Both fill $(BANKFAS_EXPECT_VERSION) and $(BANKFAS_EXPECT_OS) from versions.json (preflight.sh, bankfas_gate_sql).
     50140  the login is sa (by its SID, under any name), holds CONTROL SERVER or ALTER ANY LOGIN, or is a member of
            any server role: a schema change runs as bankfas_migrator, a member of db_owner only (ADR 0010; THR-44 in
            DOC-S01; self-review E9). This holds in CI as well.
     50143  the SQL Server build or the Ubuntu release differs from the release register (FR-PLT-045 item 4, G4).
     50150  the server option "nested triggers" is off (A14): the audit rows written by triggers (029) are chained by
            a trigger (055), and the guards of 052 to 054 must fire inside the copy triggers of 044.
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @msg NVARCHAR(2048);
DECLARE @roles NVARCHAR(1000) = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), name), N', ') FROM sys.server_principals
                                 WHERE type = 'R' AND name <> N'public' AND IS_SRVROLEMEMBER(name) = 1);
IF SUSER_SID() = 0x01 OR IS_SRVROLEMEMBER(N'sysadmin') = 1 OR @roles IS NOT NULL
   OR HAS_PERMS_BY_NAME(NULL, NULL, 'CONTROL SERVER') = 1 OR HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY LOGIN') = 1
BEGIN
    SET @msg = CONCAT(N'The deployment runs as bankfas_migrator, a member of db_owner only, never as sa, a server role member or a holder of a server-wide right (ADR 0010); this login is ',
                      SUSER_SNAME(), CASE WHEN @roles IS NOT NULL THEN CONCAT(N', member of ', @roles) END);
    THROW 50140, @msg, 1;
END;
DECLARE @version NVARCHAR(128) = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),
        @host NVARCHAR(200) = SUBSTRING(@@VERSION, CHARINDEX(N' on ', @@VERSION) + 4, 200);
SET @host = LEFT(@host, CHARINDEX(N')', @host + N')'));
IF @version <> N'$(BANKFAS_EXPECT_VERSION)' OR @@VERSION NOT LIKE N'% on Linux (Ubuntu $(BANKFAS_EXPECT_OS)[. ]%'
BEGIN
    SET @msg = CONCAT(N'SQL Server ', @version, N' on ', @host, N' differs from the release register: SQL Server $(BANKFAS_EXPECT_VERSION) on Ubuntu $(BANKFAS_EXPECT_OS) (versions.json, gate G4)');
    THROW 50143, @msg, 1;
END;
IF NOT EXISTS (SELECT 1 FROM sys.configurations WHERE name = N'nested triggers' AND value_in_use = 1)
    THROW 50150, 'The server option "nested triggers" must be 1: the audit chain and the guards fire inside other triggers (sp_configure ''nested triggers'', 1)', 1;
GO
