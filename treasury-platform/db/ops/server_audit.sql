/* ============================================================================
   BankFas - SQL Server Audit of the database server (DOC-S08 section 10, DQ-S08-10; DOC-S12 section 3.5, DQ-S12-5;
   docs/adr/0012-server-audit.md)

   tools/deploy/server_audit.sh runs it with an administrator's own login:
     APPLY  before the first deployment, so the deployment itself is recorded, and inside every deployment window
            after db/deploy.sql. What already matches stays running untouched, so a second run changes nothing.
     CHECK  changes nothing and fails (50121) unless everything below is in place and the audit is writing (HS-8 in
            DOC-S10, R-08 in DOC-S11).
   What it keeps in place:
     BankFas_Audit           the server audit: files of 256 MB, at most 40, in $(BANKFAS_AUDIT_DIR) (V5, DOC-S10
                             section 3), written within a second. A file that cannot be written does not stop the
                             server (ON_FAILURE = CONTINUE, DQ-S12-5); the check and the alert on a stopped audit do.
                             A successful login of a service process is not recorded, because the pools open
                             connections all day; its failed logins are (DOC-S08 section 10).
     BankFas_Audit_Server    logins, principals and role members, permissions and ownership, object and database
                             changes, backups and restores, server settings, the audit itself, and the windows that
                             the scripts in tools/deploy declare (user-defined events 1101 to 1104).
     BankFas_Audit_Database  in BankFas, once it is deployed: every UPDATE or DELETE on aud.AuditLog,
                             aud.SensitiveAccessLog and sec.KeyEvent, and every DELETE on sec.LoginAttempt and
                             cfg.JobRun, by anyone. BY public covers dbo and sysadmin, which pass every DENY (CI step 20).
   The alerts on these records (AL-18 in DOC-S12 section 6) are db/ops/server_audit_alerts.sql.
   Errors: 50120 the audit folder does not exist, 50121 the audit is not as defined here or not writing.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
GO
IF '$(BANKFAS_AUDIT_MODE)' NOT IN ('APPLY', 'CHECK') THROW 50121, 'The mode must be APPLY or CHECK', 1;
IF NOT EXISTS (SELECT 1 FROM sys.dm_os_file_exists(N'$(BANKFAS_AUDIT_DIR)') WHERE file_is_a_directory = 1)
    THROW 50120, 'The audit folder does not exist: create it on its own volume, owned by mssql (DOC-S10 section 3)', 1;
GO
-- The definition. The service logins are those of db/ops/service_logins.sql; db/ops/server_audit_alerts.sql names them too.
CREATE TABLE #svc (name SYSNAME COLLATE DATABASE_DEFAULT PRIMARY KEY);
INSERT #svc VALUES (N'bankfas_app_a'), (N'bankfas_app_b'), (N'bankfas_jobs_a'), (N'bankfas_jobs_b'),
                   (N'bankfas_platform_a'), (N'bankfas_platform_b'), (N'bankfas_support_a'), (N'bankfas_support_b');
CREATE TABLE #grp (name NVARCHAR(128) COLLATE DATABASE_DEFAULT PRIMARY KEY);
INSERT #grp VALUES
    -- DOC-S08 section 10
    (N'SUCCESSFUL_LOGIN_GROUP'), (N'FAILED_LOGIN_GROUP'), (N'LOGIN_CHANGE_PASSWORD_GROUP'),
    (N'SERVER_ROLE_MEMBER_CHANGE_GROUP'), (N'SERVER_PRINCIPAL_CHANGE_GROUP'), (N'SERVER_PERMISSION_CHANGE_GROUP'),
    (N'DATABASE_ROLE_MEMBER_CHANGE_GROUP'), (N'DATABASE_PRINCIPAL_CHANGE_GROUP'), (N'DATABASE_PERMISSION_CHANGE_GROUP'),
    (N'SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP'), (N'SCHEMA_OBJECT_CHANGE_GROUP'), (N'AUDIT_CHANGE_GROUP'),
    -- DOC-S12 section 3.5
    (N'BACKUP_RESTORE_GROUP'), (N'DATABASE_CHANGE_GROUP'), (N'DATABASE_OBJECT_CHANGE_GROUP'),
    -- ADR 0012: the declared windows; grants on a schema, the database or a login; ownership, which passes every
    -- permission; server settings and server objects (endpoints, linked servers, credentials)
    (N'USER_DEFINED_AUDIT_GROUP'), (N'DATABASE_OBJECT_PERMISSION_CHANGE_GROUP'), (N'SERVER_OBJECT_PERMISSION_CHANGE_GROUP'),
    (N'DATABASE_OWNERSHIP_CHANGE_GROUP'), (N'DATABASE_OBJECT_OWNERSHIP_CHANGE_GROUP'), (N'SCHEMA_OBJECT_OWNERSHIP_CHANGE_GROUP'),
    (N'SERVER_OPERATION_GROUP'), (N'SERVER_OBJECT_CHANGE_GROUP');
CREATE TABLE #obj (action_name NVARCHAR(60) COLLATE DATABASE_DEFAULT, object_name NVARCHAR(256) COLLATE DATABASE_DEFAULT,
                   PRIMARY KEY (action_name, object_name));
INSERT #obj VALUES (N'UPDATE', N'aud.AuditLog'), (N'DELETE', N'aud.AuditLog'),
                   (N'UPDATE', N'aud.SensitiveAccessLog'), (N'DELETE', N'aud.SensitiveAccessLog'),
                   (N'UPDATE', N'sec.KeyEvent'), (N'DELETE', N'sec.KeyEvent'),
                   (N'DELETE', N'sec.LoginAttempt'), (N'DELETE', N'cfg.JobRun');
CREATE TABLE #result (seq INT PRIMARY KEY, part NVARCHAR(80), outcome NVARCHAR(200));
GO
DECLARE @mode VARCHAR(5) = '$(BANKFAS_AUDIT_MODE)', @dir NVARCHAR(260) = N'$(BANKFAS_AUDIT_DIR)', @sql NVARCHAR(MAX), @outcome NVARCHAR(200);
-- A predicate takes an action as the number of its four characters read backwards (LGIS, a successful login).
DECLARE @lgis NVARCHAR(12) = CAST(CONVERT(INT, CONVERT(VARBINARY(4), REVERSE('LGIS'))) AS NVARCHAR(12));
DECLARE @where NVARCHAR(MAX) = N'NOT (action_id = ' + @lgis + N' AND ('
    + (SELECT STRING_AGG(CAST(N'server_principal_name = ''' + name + N'''' AS NVARCHAR(MAX)), N' OR ') WITHIN GROUP (ORDER BY name) FROM #svc) + N'))';
-- The same predicate as SQL Server stores it in sys.server_audits.
DECLARE @stored NVARCHAR(MAX) = N'(NOT ([action_id]=(' + @lgis + N') AND ('
    + (SELECT STRING_AGG(CAST(N'[server_principal_name]=''' + name + N'''' AS NVARCHAR(MAX)), N' OR ') WITHIN GROUP (ORDER BY name) FROM #svc) + N')))';
DECLARE @target NVARCHAR(MAX) = N'TO FILE (FILEPATH = N''' + @dir + N''', MAXSIZE = 256 MB, MAX_ROLLOVER_FILES = 40, RESERVE_DISK_SPACE = OFF)'
    + N' WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE) WHERE ' + @where + N';';
DECLARE @matches BIT = CASE WHEN EXISTS (
    SELECT 1 FROM sys.server_file_audits
    WHERE name = N'BankFas_Audit' AND log_file_path = CASE WHEN RIGHT(@dir, 1) = N'/' THEN @dir ELSE @dir + N'/' END
      AND max_file_size = 256 AND max_rollover_files = 40 AND reserve_disk_space = 0 AND queue_delay = 1000
      AND on_failure = 0 AND predicate = @stored) THEN 1 ELSE 0 END;

IF @mode = 'CHECK'
    SET @outcome = CASE WHEN @matches = 0 THEN N'missing or not as defined'
                        WHEN NOT EXISTS (SELECT 1 FROM sys.dm_server_audit_status WHERE name = N'BankFas_Audit' AND status_desc = N'STARTED')
                             THEN N'not started' END;
ELSE IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = N'BankFas_Audit')
BEGIN
    SET @sql = N'CREATE SERVER AUDIT [BankFas_Audit] ' + @target;
    EXEC (@sql);
    SET @outcome = N'created';
END
ELSE IF @matches = 0
BEGIN
    ALTER SERVER AUDIT [BankFas_Audit] WITH (STATE = OFF);
    SET @sql = N'ALTER SERVER AUDIT [BankFas_Audit] ' + @target;
    EXEC (@sql);
    SET @outcome = N'changed';
END;
IF @mode = 'APPLY' AND (SELECT is_state_enabled FROM sys.server_audits WHERE name = N'BankFas_Audit') = 0
BEGIN
    ALTER SERVER AUDIT [BankFas_Audit] WITH (STATE = ON);
    SET @outcome = ISNULL(@outcome, N'started');
END;
INSERT #result VALUES (1, N'server audit BankFas_Audit', ISNULL(@outcome, N'unchanged'));
GO
-- The server specification: exactly the groups above, on this audit.
DECLARE @mode VARCHAR(5) = '$(BANKFAS_AUDIT_MODE)', @sql NVARCHAR(MAX), @outcome NVARCHAR(200);
DECLARE @guid UNIQUEIDENTIFIER = (SELECT audit_guid FROM sys.server_audits WHERE name = N'BankFas_Audit');
DECLARE @spec INT = (SELECT server_specification_id FROM sys.server_audit_specifications WHERE name = N'BankFas_Audit_Server');
DECLARE @matches BIT = CASE WHEN @spec IS NOT NULL
     AND (SELECT audit_guid FROM sys.server_audit_specifications WHERE server_specification_id = @spec) = @guid
     AND NOT EXISTS (SELECT name FROM #grp
                     EXCEPT SELECT audit_action_name FROM sys.server_audit_specification_details WHERE server_specification_id = @spec)
     AND NOT EXISTS (SELECT audit_action_name FROM sys.server_audit_specification_details WHERE server_specification_id = @spec
                     EXCEPT SELECT name FROM #grp) THEN 1 ELSE 0 END;
IF @mode = 'CHECK'
    SET @outcome = CASE WHEN @matches = 0 THEN N'missing or not as defined'
                        WHEN (SELECT is_state_enabled FROM sys.server_audit_specifications WHERE server_specification_id = @spec) = 0
                             THEN N'off' END;
ELSE IF @matches = 0
BEGIN
    IF @spec IS NOT NULL
    BEGIN
        ALTER SERVER AUDIT SPECIFICATION [BankFas_Audit_Server] WITH (STATE = OFF);
        DROP SERVER AUDIT SPECIFICATION [BankFas_Audit_Server];
    END;
    SET @sql = N'CREATE SERVER AUDIT SPECIFICATION [BankFas_Audit_Server] FOR SERVER AUDIT [BankFas_Audit] '
             + (SELECT STRING_AGG(CAST(N'ADD (' + name + N')' AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY name) FROM #grp)
             + N' WITH (STATE = ON);';
    EXEC (@sql);
    SET @outcome = CASE WHEN @spec IS NULL THEN N'created' ELSE N'changed' END;
END
ELSE IF (SELECT is_state_enabled FROM sys.server_audit_specifications WHERE server_specification_id = @spec) = 0
BEGIN
    ALTER SERVER AUDIT SPECIFICATION [BankFas_Audit_Server] WITH (STATE = ON);
    SET @outcome = N'started';
END;
INSERT #result VALUES (2, N'server specification BankFas_Audit_Server', ISNULL(@outcome, N'unchanged'));
GO
-- The database specification, once db/deploy.sql has created the tables.
DECLARE @mode VARCHAR(5) = '$(BANKFAS_AUDIT_MODE)', @outcome NVARCHAR(200);
IF DB_ID(N'BankFas') IS NULL
    SET @outcome = N'not deployed yet';
ELSE
BEGIN
    DECLARE @db NVARCHAR(MAX) = N'
DECLARE @guid UNIQUEIDENTIFIER = (SELECT audit_guid FROM sys.server_audits WHERE name = N''BankFas_Audit'');
DECLARE @spec INT = (SELECT database_specification_id FROM sys.database_audit_specifications WHERE name = N''BankFas_Audit_Database'');
DECLARE @want TABLE (action_name NVARCHAR(60) COLLATE DATABASE_DEFAULT, object_id INT, object_name NVARCHAR(256) COLLATE DATABASE_DEFAULT);
INSERT @want SELECT action_name, OBJECT_ID(object_name), object_name FROM #obj;
IF EXISTS (SELECT 1 FROM @want WHERE object_id IS NULL)
BEGIN
    SET @outcome = CASE @mode WHEN ''CHECK'' THEN N''the audited tables are missing'' ELSE N''waits for db/deploy.sql'' END;
    RETURN;
END;
DECLARE @matches BIT = CASE WHEN @spec IS NOT NULL
     AND (SELECT audit_guid FROM sys.database_audit_specifications WHERE database_specification_id = @spec) = @guid
     AND NOT EXISTS (SELECT action_name, object_id, 0 FROM @want
                     EXCEPT SELECT audit_action_name, major_id, audited_principal_id FROM sys.database_audit_specification_details
                            WHERE database_specification_id = @spec AND class = 1 AND audited_result = N''SUCCESS AND FAILURE'')
     AND NOT EXISTS (SELECT audit_action_name, major_id, audited_principal_id FROM sys.database_audit_specification_details
                     WHERE database_specification_id = @spec
                     EXCEPT SELECT action_name, object_id, 0 FROM @want) THEN 1 ELSE 0 END;
IF @mode = ''CHECK''
    SET @outcome = CASE WHEN @matches = 0 THEN N''missing or not as defined''
                        WHEN (SELECT is_state_enabled FROM sys.database_audit_specifications WHERE database_specification_id = @spec) = 0
                             THEN N''off'' END;
ELSE IF @matches = 0
BEGIN
    IF @spec IS NOT NULL
    BEGIN
        ALTER DATABASE AUDIT SPECIFICATION [BankFas_Audit_Database] WITH (STATE = OFF);
        DROP DATABASE AUDIT SPECIFICATION [BankFas_Audit_Database];
    END;
    DECLARE @sql NVARCHAR(MAX) = N''CREATE DATABASE AUDIT SPECIFICATION [BankFas_Audit_Database] FOR SERVER AUDIT [BankFas_Audit] ''
        + (SELECT STRING_AGG(CAST(N''ADD ('' + action_name + N'' ON OBJECT::'' + QUOTENAME(OBJECT_SCHEMA_NAME(object_id)) + N''.''
                                  + QUOTENAME(OBJECT_NAME(object_id)) + N'' BY [public])'' AS NVARCHAR(MAX)), N'', '')
                  WITHIN GROUP (ORDER BY object_name, action_name) FROM @want)
        + N'' WITH (STATE = ON);'';
    EXEC (@sql);
    SET @outcome = CASE WHEN @spec IS NULL THEN N''created'' ELSE N''changed'' END;
END
ELSE IF (SELECT is_state_enabled FROM sys.database_audit_specifications WHERE database_specification_id = @spec) = 0
BEGIN
    ALTER DATABASE AUDIT SPECIFICATION [BankFas_Audit_Database] WITH (STATE = ON);
    SET @outcome = N''started'';
END;';
    EXEC [BankFas].sys.sp_executesql @db, N'@mode VARCHAR(5), @outcome NVARCHAR(200) OUTPUT', @mode = @mode, @outcome = @outcome OUTPUT;
END;
INSERT #result VALUES (3, N'database specification BankFas_Audit_Database', ISNULL(@outcome, N'unchanged'));
GO
DECLARE @line NVARCHAR(MAX) = (SELECT STRING_AGG(part + N': ' + outcome, N'; ') WITHIN GROUP (ORDER BY seq) FROM #result);
IF '$(BANKFAS_AUDIT_MODE)' = 'CHECK'
BEGIN
    IF EXISTS (SELECT 1 FROM #result WHERE outcome NOT IN (N'unchanged', N'not deployed yet'))
    BEGIN
        DECLARE @msg NVARCHAR(2048) = N'The audit is not in place: ' + @line;
        THROW 50121, @msg, 1;
    END;
    PRINT CONCAT('audit in place and writing (', @line, ')');
END
ELSE
    PRINT @line;
GO
