/* ============================================================================
   BankFas - the checks tools/deploy/deploy.sh runs before db/deploy.sql (DQ-S11-6, gate G4; DOC-S11 section 8.1;
   docs/adr/0014-deployment-preflight.md)

   deploy.sh fills $(BANKFAS_EXPECT_VERSION) and $(BANKFAS_EXPECT_OS) from versions.json in a private temporary copy.
   Nothing runs unless every check passes, in this order:
     50140  the login is sa (by its SID, under any name) or a sysadmin: the deployment runs as bankfas_migrator, a
            member of db_owner only (ADR 0010; THR-44 in DOC-S01). This holds in CI as well.
     50143  the SQL Server build or the Ubuntu release differs from the release register (FR-PLT-045 item 4, G4).
     50141  BankFas does not exist, or not in Arabic_100_CI_AS_SC: prepare_database.sh prepare makes it.
     50142  BankFas already holds tables. db/deploy.sql builds a new database only; an upgrade waits for the
            migration runner (DQ-B11-4, DOC-S11 section 7.2).
   ============================================================================ */
SET NOCOUNT ON;
DECLARE @msg NVARCHAR(2048);
IF SUSER_SID() = 0x01 OR IS_SRVROLEMEMBER(N'sysadmin') = 1
BEGIN
    SET @msg = CONCAT(N'The deployment runs as bankfas_migrator, a member of db_owner only, never as sa or a sysadmin (ADR 0010); this login is ', SUSER_SNAME());
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
IF DB_ID(N'BankFas') IS NULL OR CAST(DATABASEPROPERTYEX(N'BankFas', 'Collation') AS NVARCHAR(128)) <> N'Arabic_100_CI_AS_SC'
    THROW 50141, 'BankFas must exist in the collation Arabic_100_CI_AS_SC: an administrator prepares it with tools/deploy/prepare_database.sh prepare', 1;
DECLARE @tables INT;
EXEC [BankFas].sys.sp_executesql N'SELECT @n = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0', N'@n INT OUTPUT', @n = @tables OUTPUT;
IF @tables > 0
BEGIN
    SET @msg = CONCAT(N'BankFas already holds ', @tables, N' tables: db/deploy.sql builds a new database only, and an upgrade waits for the migration runner (DQ-B11-4)');
    THROW 50142, @msg, 1;
END;
PRINT CONCAT('preflight passed: ', SUSER_SNAME(), ' on SQL Server ', @version, ' (', @host, '), BankFas empty in Arabic_100_CI_AS_SC');
