/* ============================================================================
   BankFas - the checks tools/deploy/deploy.sh runs before db/deploy.sql (DQ-S11-6, gate G4; DOC-S11 section 8.1;
   docs/adr/0014-deployment-preflight.md)

   deploy.sh fills $(BANKFAS_EXPECT_VERSION) and $(BANKFAS_EXPECT_OS) from versions.json in a private temporary copy,
   and runs it and db/deploy.sql in one session: deploy.sql starts only after the mark this script sets at its end.
   Nothing runs unless every check passes, in this order:
     50140  the login is sa (by its SID, under any name), holds CONTROL SERVER or ALTER ANY LOGIN, or is a member of
            any server role (sysadmin, securityadmin, the ##MS_...## roles and the rest; self-review E9): the
            deployment runs as bankfas_migrator, a member of db_owner only (ADR 0010; THR-44 in DOC-S01). This holds in
            CI as well.
     50143  the SQL Server build or the Ubuntu release differs from the release register (FR-PLT-045 item 4, G4).
     50141  BankFas does not exist, or not in Arabic_100_CI_AS_SC: prepare_database.sh prepare makes it.
     50145  RECURSIVE_TRIGGERS is ON in BankFas. The copy triggers of 044 write the tables they read (the request
            and its stage instance), and they hold only while a trigger does not fire itself again (self-review A7).
     50142  BankFas is not as prepare_database.sh leaves it: it holds a table or any other object, a database
            trigger, a schema, a user or role but bankfas_migrator, an assembly, a key or certificate, a database
            credential or audit specification, or lets guest connect (self-review E4: a database made ready by someone
            else would carry its objects into the deployment). db/deploy.sql builds a new database only; an upgrade
            waits for the migration runner (DQ-B11-4, DOC-S11 section 7.2).
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
IF DB_ID(N'BankFas') IS NULL OR CAST(DATABASEPROPERTYEX(N'BankFas', 'Collation') AS NVARCHAR(128)) <> N'Arabic_100_CI_AS_SC'
    THROW 50141, 'BankFas must exist in the collation Arabic_100_CI_AS_SC: an administrator prepares it with tools/deploy/prepare_database.sh prepare', 1;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'BankFas' AND is_recursive_triggers_on = 1)
    THROW 50145, 'RECURSIVE_TRIGGERS must be OFF in BankFas: the copy triggers hold only while a trigger does not fire itself again (ALTER DATABASE BankFas SET RECURSIVE_TRIGGERS OFF)', 1;
DECLARE @tables INT, @found NVARCHAR(1000);
EXEC [BankFas].sys.sp_executesql N'SELECT @n = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0;
SELECT @f = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(k.n, N'' '', k.what)), N'', '')
FROM (SELECT COUNT(*) AS n, N''objects'' AS what FROM sys.objects WHERE is_ms_shipped = 0
      UNION ALL SELECT COUNT(*), N''database triggers'' FROM sys.triggers WHERE parent_class = 0
      UNION ALL SELECT COUNT(*), N''schemas'' FROM sys.schemas WHERE schema_id BETWEEN 5 AND 16383
      UNION ALL SELECT COUNT(*), N''users or roles'' FROM sys.database_principals
                WHERE principal_id > 4 AND is_fixed_role = 0 AND name <> N''bankfas_migrator''
      UNION ALL SELECT COUNT(*), N''assemblies'' FROM sys.assemblies WHERE is_user_defined = 1
      UNION ALL SELECT COUNT(*), N''keys or certificates'' FROM (SELECT name FROM sys.certificates UNION ALL SELECT name FROM sys.asymmetric_keys
                UNION ALL SELECT name FROM sys.symmetric_keys WHERE name NOT LIKE N''##%'') AS x
      UNION ALL SELECT COUNT(*), N''database credentials'' FROM sys.database_scoped_credentials
      UNION ALL SELECT COUNT(*), N''audit specifications'' FROM sys.database_audit_specifications
      UNION ALL SELECT COUNT(*), N''guest connect'' FROM sys.database_permissions
                WHERE grantee_principal_id = DATABASE_PRINCIPAL_ID(N''guest'') AND permission_name = ''CONNECT'' AND state IN (''G'', ''W'')) AS k
WHERE k.n > 0;', N'@n INT OUTPUT, @f NVARCHAR(1000) OUTPUT', @n = @tables OUTPUT, @f = @found OUTPUT;
IF @tables > 0
BEGIN
    SET @msg = CONCAT(N'BankFas already holds ', @tables, N' tables: db/deploy.sql builds a new database only, and an upgrade waits for the migration runner (DQ-B11-4)');
    THROW 50142, @msg, 1;
END;
IF @found IS NOT NULL
BEGIN
    SET @msg = CONCAT(N'BankFas is not as prepare_database.sh leaves it: it holds ', @found, N'. db/deploy.sql builds a new database only (DQ-B11-4, self-review E4)');
    THROW 50142, @msg, 1;
END;
-- db/deploy.sql runs in the same session and starts only after this mark (50146).
EXEC sys.sp_set_session_context @key = N'bankfas.preflight', @value = 1, @read_only = 1;
PRINT CONCAT('preflight passed: ', SUSER_SNAME(), ' on SQL Server ', @version, ' (', @host, '), BankFas empty in Arabic_100_CI_AS_SC');
