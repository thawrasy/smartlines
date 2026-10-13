/* ============================================================================
   BankFas - the monitoring login bankfas_monitor (DQ-S12-6; DOC-S12 sections 3.5 and 6, DOC-S08 section 3;
   docs/adr/0013-monitor-login-and-deployment-checks.md)

   One login for the monitoring agent, the audit check and the post-deployment check. It sees the state and the
   definitions of the server and of BankFas, and no row of any table:
     server  VIEW SERVER PERFORMANCE STATE  sessions, waits and log space (DOC-S10 section 9, AL-14)
             VIEW SERVER SECURITY STATE     the audit status (tools/deploy/server_audit.sh check, HS-8)
             VIEW SERVER SECURITY AUDIT     the audit files (server_audit.sh alerts and windows, AL-18)
             VIEW ANY SECURITY DEFINITION   the audit and its specifications; password hashes stay hidden
     msdb    SELECT on dbo.backupset and dbo.backupmediafamily: the backup history (DOC-S09, AL-15)
     BankFas VIEW DEFINITION: the catalogue that tools/dbgen/check_deployed.py compares with the generated DDL;
             no role, no SELECT, no EXECUTE
   It is a member of no server role and of no database role.

   This is a template: tools/deploy/provision_monitor.sh fills $(BANKFAS_MONITOR_PASSWORD) in a private temporary
   copy and deletes it. Run it with an administrator's own login after db/deploy.sql, inside the window. Safe to run
   again: the login takes the new secret (rotation, DOC-S08 section 6) and is enabled; what exists stays.
   It refuses a monitoring login or user that holds more than the above (50130 server, 50131 BankFas, 50132 msdb),
   so a right added by hand is found at the next run.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
GO
IF DB_ID(N'BankFas') IS NULL THROW 50131, 'Deploy the database before the monitoring login', 1;
IF SUSER_ID(N'bankfas_monitor') IS NULL
    CREATE LOGIN [bankfas_monitor] WITH PASSWORD = N'$(BANKFAS_MONITOR_PASSWORD)', DEFAULT_DATABASE = [master], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
ELSE
    ALTER LOGIN [bankfas_monitor] WITH PASSWORD = N'$(BANKFAS_MONITOR_PASSWORD)';
ALTER LOGIN [bankfas_monitor] ENABLE;
GRANT VIEW SERVER PERFORMANCE STATE, VIEW SERVER SECURITY STATE, VIEW SERVER SECURITY AUDIT, VIEW ANY SECURITY DEFINITION
    TO [bankfas_monitor];
IF EXISTS (SELECT 1 FROM sys.server_role_members AS m JOIN sys.server_principals AS p ON p.principal_id = m.member_principal_id
           WHERE p.name = N'bankfas_monitor')
    THROW 50130, 'The monitoring login is a member of a server role', 1;
IF EXISTS (SELECT 1 FROM sys.server_permissions AS p
           WHERE p.grantee_principal_id = SUSER_ID(N'bankfas_monitor')
             AND (p.state <> 'G' OR p.permission_name NOT IN (N'CONNECT SQL', N'VIEW SERVER PERFORMANCE STATE',
                  N'VIEW SERVER SECURITY STATE', N'VIEW SERVER SECURITY AUDIT', N'VIEW ANY SECURITY DEFINITION')))
    THROW 50130, 'The monitoring login holds a server permission beyond its view rights', 1;
GO
USE [msdb];
GO
IF DATABASE_PRINCIPAL_ID(N'bankfas_monitor') IS NULL CREATE USER [bankfas_monitor] FOR LOGIN [bankfas_monitor];
GRANT SELECT ON dbo.backupset TO [bankfas_monitor];
GRANT SELECT ON dbo.backupmediafamily TO [bankfas_monitor];
IF EXISTS (SELECT 1 FROM sys.database_role_members WHERE member_principal_id = DATABASE_PRINCIPAL_ID(N'bankfas_monitor'))
   OR EXISTS (SELECT 1 FROM sys.database_permissions AS p
              WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'bankfas_monitor')
                AND NOT (p.state = 'G' AND ((p.class = 0 AND p.permission_name = N'CONNECT')
                         OR (p.class = 1 AND p.permission_name = N'SELECT' AND p.minor_id = 0
                             AND p.major_id IN (OBJECT_ID(N'dbo.backupset'), OBJECT_ID(N'dbo.backupmediafamily'))))))
    THROW 50132, 'The monitoring user in msdb holds more than the backup history', 1;
GO
USE [BankFas];
GO
IF DATABASE_PRINCIPAL_ID(N'bankfas_monitor') IS NULL CREATE USER [bankfas_monitor] FOR LOGIN [bankfas_monitor];
GRANT VIEW DEFINITION TO [bankfas_monitor];
IF EXISTS (SELECT 1 FROM sys.database_role_members WHERE member_principal_id = DATABASE_PRINCIPAL_ID(N'bankfas_monitor'))
    THROW 50131, 'The monitoring user is a member of a role in BankFas', 1;
IF EXISTS (SELECT 1 FROM sys.database_permissions AS p
           WHERE p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'bankfas_monitor')
             AND NOT (p.state = 'G' AND p.class = 0 AND p.permission_name IN (N'CONNECT', N'VIEW DEFINITION')))
    THROW 50131, 'The monitoring user holds a permission in BankFas beyond VIEW DEFINITION', 1;
PRINT 'monitoring login bankfas_monitor ready: server and database state and definitions, the audit files, the backup history; no row';
GO
