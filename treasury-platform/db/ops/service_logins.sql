/* ============================================================================
   BankFas - service logins (DOC-S08 section 3, DQ-S08-1; docs/adr/0009-service-logins.md)

   One SQL login per process, each mapped to the one database role it needs:
       bankfas_app_<set>       tp_app        the web application of the tenants
       bankfas_jobs_<set>      tp_jobs       the background job worker (tp_jobs is a member of tp_app)
       bankfas_platform_<set>  tp_platform   the operator panel
       bankfas_support_<set>   tp_support    temporary support sessions (tp_support is a member of tp_readonly)
   <set> is a or b: two identical accounts per process, so a secret is rotated without downtime (DOC-S08 section 6).
   No reporting login until a use is decided (DQ-S08-6).

   This is a template: tools/deploy/provision_logins.sh fills the $(...) values in a private temporary copy, runs it
   with the database administrator's login (it creates server logins, which the deployment login may not) after
   db/deploy.sql, and deletes the copy. The secrets never appear on a command line.
   Safe to run again: an existing login gets the new secret; an existing user keeps its role. A new login is created
   disabled, and the four are enabled only at the end, once every check has passed (internal review v6, D15).
   It refuses (50100 to 50103) a login that is a member of a server role or holds a server right but CONNECT SQL, a
   user in any other role or holding a direct permission, and anyone who may impersonate tp_auth_exec, whose rights
   pass the row filters (DOC-S08 section 3).
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
GO
IF '$(BANKFAS_LOGIN_SET)' NOT IN ('a', 'b') THROW 50100, 'The login set must be a or b', 1;
IF DB_ID(N'BankFas') IS NULL THROW 50100, 'Deploy the database before the logins', 1;
GO
IF SUSER_ID(N'bankfas_app_$(BANKFAS_LOGIN_SET)') IS NULL
BEGIN
    CREATE LOGIN [bankfas_app_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_APP_PASSWORD)', DEFAULT_DATABASE = [BankFas], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [bankfas_app_$(BANKFAS_LOGIN_SET)] DISABLE;   -- enabled at the end, once every check has passed
END
ELSE
    ALTER LOGIN [bankfas_app_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_APP_PASSWORD)';
GO
IF SUSER_ID(N'bankfas_jobs_$(BANKFAS_LOGIN_SET)') IS NULL
BEGIN
    CREATE LOGIN [bankfas_jobs_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_JOBS_PASSWORD)', DEFAULT_DATABASE = [BankFas], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [bankfas_jobs_$(BANKFAS_LOGIN_SET)] DISABLE;   -- enabled at the end, once every check has passed
END
ELSE
    ALTER LOGIN [bankfas_jobs_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_JOBS_PASSWORD)';
GO
IF SUSER_ID(N'bankfas_platform_$(BANKFAS_LOGIN_SET)') IS NULL
BEGIN
    CREATE LOGIN [bankfas_platform_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_PLATFORM_PASSWORD)', DEFAULT_DATABASE = [BankFas], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [bankfas_platform_$(BANKFAS_LOGIN_SET)] DISABLE;   -- enabled at the end, once every check has passed
END
ELSE
    ALTER LOGIN [bankfas_platform_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_PLATFORM_PASSWORD)';
GO
IF SUSER_ID(N'bankfas_support_$(BANKFAS_LOGIN_SET)') IS NULL
BEGIN
    CREATE LOGIN [bankfas_support_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_SUPPORT_PASSWORD)', DEFAULT_DATABASE = [BankFas], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
    ALTER LOGIN [bankfas_support_$(BANKFAS_LOGIN_SET)] DISABLE;   -- enabled at the end, once every check has passed
END
ELSE
    ALTER LOGIN [bankfas_support_$(BANKFAS_LOGIN_SET)] WITH PASSWORD = N'$(BANKFAS_SUPPORT_PASSWORD)';
GO
USE [BankFas];
GO
-- Users and roles, then the checks. Nothing below holds a secret.
DECLARE @set CHAR(1) = '$(BANKFAS_LOGIN_SET)';
DECLARE @accounts TABLE (LoginName SYSNAME PRIMARY KEY, RoleName SYSNAME NOT NULL);
INSERT @accounts VALUES (CONCAT(N'bankfas_app_', @set), N'tp_app'), (CONCAT(N'bankfas_jobs_', @set), N'tp_jobs'),
                        (CONCAT(N'bankfas_platform_', @set), N'tp_platform'), (CONCAT(N'bankfas_support_', @set), N'tp_support');
DECLARE @login SYSNAME, @role SYSNAME, @sql NVARCHAR(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT LoginName, RoleName FROM @accounts;
OPEN c; FETCH NEXT FROM c INTO @login, @role;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DATABASE_PRINCIPAL_ID(@login) IS NULL
    BEGIN
        SET @sql = CONCAT(N'CREATE USER ', QUOTENAME(@login), N' FOR LOGIN ', QUOTENAME(@login), N' WITH DEFAULT_SCHEMA = [dbo];');
        EXEC sys.sp_executesql @sql;
    END;
    IF IS_ROLEMEMBER(@role, @login) <> 1
    BEGIN
        SET @sql = CONCAT(N'ALTER ROLE ', QUOTENAME(@role), N' ADD MEMBER ', QUOTENAME(@login), N';');
        EXEC sys.sp_executesql @sql;
    END;
    FETCH NEXT FROM c INTO @login, @role;
END;
CLOSE c; DEALLOCATE c;

IF EXISTS (SELECT 1 FROM sys.server_role_members AS m JOIN sys.server_principals AS p ON p.principal_id = m.member_principal_id
           WHERE p.name LIKE N'bankfas[_]%[_][ab]' AND p.name NOT LIKE N'bankfas[_]migrator%')
    THROW 50101, 'A service login is a member of a server role', 1;
IF EXISTS (SELECT 1 FROM sys.database_role_members AS m
           JOIN sys.database_principals AS u ON u.principal_id = m.member_principal_id
           JOIN sys.database_principals AS r ON r.principal_id = m.role_principal_id
           JOIN (VALUES (N'app', N'tp_app'), (N'jobs', N'tp_jobs'), (N'platform', N'tp_platform'), (N'support', N'tp_support')) AS a (Svc, RoleName)
             ON u.name IN (CONCAT(N'bankfas_', a.Svc, N'_a'), CONCAT(N'bankfas_', a.Svc, N'_b'))
           WHERE r.name <> a.RoleName)
    THROW 50102, 'A service user is a member of a role other than its own', 1;
IF EXISTS (SELECT 1 FROM sys.database_permissions AS p JOIN sys.database_principals AS u ON u.principal_id = p.grantee_principal_id
           WHERE u.name LIKE N'bankfas[_]%[_][ab]' AND p.permission_name <> N'CONNECT')
    THROW 50102, 'A service user holds a direct permission; rights come from its role only', 1;
IF EXISTS (SELECT 1 FROM sys.database_permissions AS p
           WHERE p.class = 4 AND p.permission_name = N'IMPERSONATE' AND p.state IN ('G', 'W')
             AND p.major_id = DATABASE_PRINCIPAL_ID(N'tp_auth_exec'))
    THROW 50103, 'Someone may impersonate tp_auth_exec', 1;
GO
USE [master];
GO
-- a service login holds no right on the server but to connect (internal review v6, D15)
IF EXISTS (SELECT 1 FROM sys.server_permissions AS p JOIN sys.server_principals AS l ON l.principal_id = p.grantee_principal_id
           WHERE l.name IN (N'bankfas_app_$(BANKFAS_LOGIN_SET)', N'bankfas_jobs_$(BANKFAS_LOGIN_SET)', N'bankfas_platform_$(BANKFAS_LOGIN_SET)', N'bankfas_support_$(BANKFAS_LOGIN_SET)')
             AND p.permission_name <> N'CONNECT SQL' AND p.state IN ('G', 'W'))
    THROW 50101, 'A service login holds a right on the server other than CONNECT SQL', 1;
ALTER LOGIN [bankfas_app_$(BANKFAS_LOGIN_SET)] ENABLE;
ALTER LOGIN [bankfas_jobs_$(BANKFAS_LOGIN_SET)] ENABLE;
ALTER LOGIN [bankfas_platform_$(BANKFAS_LOGIN_SET)] ENABLE;
ALTER LOGIN [bankfas_support_$(BANKFAS_LOGIN_SET)] ENABLE;
PRINT CONCAT('service logins of set ', '$(BANKFAS_LOGIN_SET)', ' ready: bankfas_app, bankfas_jobs, bankfas_platform, bankfas_support');
GO
