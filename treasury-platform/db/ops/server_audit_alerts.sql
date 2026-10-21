/* ============================================================================
   BankFas - the AL-18 alerts on the SQL Server Audit records (DOC-S12 section 6, DOC-S08 section 10;
   docs/adr/0012-server-audit.md)

   tools/deploy/server_audit.sh alerts and windows run it. It reads the files of BankFas_Audit (db/ops/server_audit.sql)
   and needs only VIEW SERVER SECURITY AUDIT (CI step 20). It is the reference for the rules that the central
   monitoring evaluates on the shipped records (DOC-S12 section 3.5), and the tool of the monthly review and of an
   investigation. Times are UTC.

   Windows. The scripts in tools/deploy declare their own work in the audit with sys.sp_audit_write:
     1101, 1102  a deployment window, opened and closed by prepare_database.sh open and close. It ends at the next
                 close, or 4 hours after it opened if none comes: the window of DOC-S11 section 10 is 2 hours,
                 and a longer silence of the alerts is not a deployment (internal review v6, D17).
     1103, 1104  an administrative change: prepare_database.sh prepare, provision_logins.sh and server_audit.sh apply.
                 It ends at the next 1104 of the same login, which the scripts write even when they fail, or after
                 one hour.
   A window silences the GRANT, AUDIT and SCHEMA rules only for the login that declared it, and a deployment window
   also for bankfas_migrator; changes by anyone else in the same hour still alert. sys.sp_audit_write is open to every
   login, so a declaration proves nothing by itself (self-review E1): a deployment window counts only when the login
   that declared it enabled bankfas_migrator within a minute after, which needs ALTER ANY LOGIN and is audited
   itself; and no declaration from a service login, bankfas_migrator or bankfas_monitor counts. A declaration that
   does not count raises WINDOW. Each one carries its administrator and change reference, and the monthly review matches them with
   the deployment log (DOC-S11 section 10): the windows report lists them.

   Rules, all A1 (AL-18 in DOC-S12 section 6):
     WINDOW         a window declared by a login whose declaration does not count (above)           any time
     BREAKGLASS     a login with breakglass, successful or failed                                    any time
     SA             a change to the sa login (principal 1), except disabling it                    any time
     SERVER_RIGHTS  a server role member added or dropped, or a server permission changed          any time
     DROP_DB        a database dropped                                                             any time
     AUDIT_STOP     the audit stopped                                                              any time
     AUDIT_ROWS     UPDATE or DELETE on aud.AuditLog, aud.SensitiveAccessLog or sec.KeyEvent, or a DELETE on
                    sec.LoginAttempt or cfg.JobRun by anyone but a service login (their retention jobs)   any time
     MIGRATOR       bankfas_migrator enabled, or a login with it, successful or failed      outside a deployment window
     GRANT          a permission granted, denied or revoked, a database role member added or dropped, an ownership
                    taken, or a security policy created, altered or dropped                       outside its login's window
     AUDIT          the audit or one of its specifications altered or dropped (creating one adds
                    records)                       outside its login's window, and never silenced for bankfas_migrator:
                                                   no deployment touches the audit (self-review E2)
     LOGINS         a login renamed (a renamed breakglass would escape BREAKGLASS)                 any time
                    a login created or dropped                                                    outside its login's window
     SERVER_CONFIG  a server setting changed (RECONFIGURE), a credential or a linked server created, altered or
                    dropped, or an object created, altered or dropped in master or msdb           outside its login's window
                    (self-review E6)
     SCHEMA         BankFas or one of its objects created, altered or dropped, except index and statistics
                    maintenance                                                                   outside its login's window
   Errors: 50122 the report is not ALERTS or WINDOWS.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;
IF '$(BANKFAS_ALERTS_REPORT)' NOT IN ('ALERTS', 'WINDOWS') THROW 50122, 'The report must be ALERTS or WINDOWS', 1;
DECLARE @since DATETIME2(7) = CONVERT(DATETIME2(7), N'$(BANKFAS_ALERTS_SINCE)', 126);
-- The service logins of db/ops/service_logins.sql, as in db/ops/server_audit.sql.
DECLARE @svc TABLE (name SYSNAME PRIMARY KEY);
INSERT @svc VALUES (N'bankfas_app_a'), (N'bankfas_app_b'), (N'bankfas_jobs_a'), (N'bankfas_jobs_b'),
                   (N'bankfas_platform_a'), (N'bankfas_platform_b'), (N'bankfas_support_a'), (N'bankfas_support_b');

SELECT event_time, sequence_number, action_id, class_type, succeeded, session_id, server_principal_name,
       session_server_principal_name, database_name, schema_name, object_name, object_id, user_defined_event_id,
       user_defined_information, additional_information, statement
INTO #a
FROM sys.fn_get_audit_file(N'$(BANKFAS_AUDIT_DIR)/BankFas_Audit_*.sqlaudit', DEFAULT, DEFAULT);

-- who: the login of the session, also under EXECUTE AS
ALTER TABLE #a ADD who SYSNAME NULL;
UPDATE #a SET who = COALESCE(NULLIF(session_server_principal_name, N''), server_principal_name);

SELECT o.event_time AS opened, o.user_defined_event_id AS kind, o.who AS opened_by, o.user_defined_information AS info, c.closed,
       CASE WHEN c.closed < DATEADD(HOUR, CASE o.user_defined_event_id WHEN 1101 THEN 4 ELSE 1 END, o.event_time) THEN c.closed
            ELSE DATEADD(HOUR, CASE o.user_defined_event_id WHEN 1101 THEN 4 ELSE 1 END, o.event_time) END AS ends
INTO #w
FROM #a AS o
OUTER APPLY (SELECT MIN(e.event_time) AS closed
             FROM #a AS e
             WHERE e.action_id = 'UDAU' AND e.event_time >= o.event_time
               AND ((o.user_defined_event_id = 1101 AND e.user_defined_event_id = 1102)
                    OR (o.user_defined_event_id = 1103 AND e.user_defined_event_id = 1104 AND e.who = o.who))) AS c
WHERE o.action_id = 'UDAU' AND o.user_defined_event_id IN (1101, 1103) AND o.succeeded = 1
  AND o.who NOT IN (SELECT name FROM @svc) AND o.who NOT IN (N'bankfas_migrator', N'bankfas_monitor')
  AND (o.user_defined_event_id = 1103
       OR EXISTS (SELECT 1 FROM #a AS g
                  WHERE g.action_id = 'LGEA' AND g.class_type = 'SL' AND g.object_name = N'bankfas_migrator' AND g.succeeded = 1
                    AND g.who = o.who AND g.event_time BETWEEN o.event_time AND DATEADD(MINUTE, 1, o.event_time)));

IF '$(BANKFAS_ALERTS_REPORT)' = 'WINDOWS'
BEGIN
    SELECT CASE kind WHEN 1101 THEN 'DEPLOYMENT' ELSE 'CHANGE' END AS kind,
           CONVERT(VARCHAR(23), opened, 126) AS opened, CONVERT(VARCHAR(23), ends, 126) AS ends,
           CASE WHEN closed IS NULL OR closed > ends THEN 'not closed' ELSE 'closed' END AS closing, opened_by, info
    FROM #w WHERE ends >= @since ORDER BY opened;
    RETURN;
END;

WITH e AS (
    SELECT a.*,
           CASE WHEN EXISTS (SELECT 1 FROM #w AS w WHERE w.kind = 1101 AND a.event_time BETWEEN w.opened AND w.ends) THEN 1 ELSE 0 END AS in_deployment,
           CASE WHEN EXISTS (SELECT 1 FROM #w AS w WHERE a.event_time BETWEEN w.opened AND w.ends
                                                     AND (w.opened_by = a.who OR (w.kind = 1101 AND a.who = N'bankfas_migrator')))
                THEN 1 ELSE 0 END AS in_window,
           CASE WHEN a.who IN (SELECT name FROM @svc) THEN 1 ELSE 0 END AS by_service,
           CONCAT(a.schema_name, '.', a.object_name) AS qualified
    FROM #a AS a
    WHERE a.event_time >= @since
), r AS (
    SELECT e.*,
           CASE
             WHEN action_id = 'UDAU' AND user_defined_event_id IN (1101, 1103)
                  AND NOT EXISTS (SELECT 1 FROM #w AS w WHERE w.opened = e.event_time AND w.opened_by = e.who
                                                          AND w.kind = e.user_defined_event_id) THEN 'WINDOW'
             WHEN action_id IN ('LGIS', 'LGIF') AND server_principal_name = N'breakglass' THEN 'BREAKGLASS'
             WHEN class_type = 'SL' AND object_id = 1 AND action_id <> 'LGDA' THEN 'SA'
             WHEN (class_type = 'SG' AND action_id IN ('APRL', 'DPRL'))
               OR (action_id IN ('G', 'GWG', 'D', 'R') AND class_type IN ('SV', 'SL', 'SG', 'EP', 'A')) THEN 'SERVER_RIGHTS'
             WHEN action_id = 'DR' AND class_type = 'DB' THEN 'DROP_DB'
             WHEN action_id = 'AUSC' AND (additional_information LIKE N'%<action>event disabled</action>%'
                                          OR additional_information LIKE N'%<action>destroyed</action>%') THEN 'AUDIT_STOP'
             WHEN database_name = N'BankFas' AND class_type = 'U'
                  AND ((action_id IN ('UP', 'DL') AND qualified IN (N'aud.AuditLog', N'aud.SensitiveAccessLog', N'sec.KeyEvent'))
                       OR (action_id = 'DL' AND qualified IN (N'sec.LoginAttempt', N'cfg.JobRun') AND by_service = 0)) THEN 'AUDIT_ROWS'
             WHEN in_deployment = 0
                  AND ((action_id IN ('LGIS', 'LGIF') AND server_principal_name = N'bankfas_migrator')
                       OR (action_id = 'LGEA' AND class_type = 'SL' AND object_name = N'bankfas_migrator')) THEN 'MIGRATOR'
             WHEN in_window = 0
                  AND (action_id IN ('G', 'GWG', 'D', 'R', 'APRL', 'DPRL', 'TO')
                       OR (class_type = 'SP' AND action_id IN ('CR', 'AL', 'DR'))) THEN 'GRANT'
             WHEN (in_window = 0 OR who = N'bankfas_migrator') AND class_type IN ('A', 'SA', 'DA') AND action_id IN ('AL', 'DR') THEN 'AUDIT'
             WHEN class_type = 'SL' AND (action_id = 'LGNM' OR (action_id IN ('CR', 'DR') AND in_window = 0)) THEN 'LOGINS'
             WHEN in_window = 0
                  AND (action_id = 'ALST'
                       OR (class_type IN ('CD', 'SR') AND action_id IN ('CR', 'AL', 'DR'))
                       OR (database_name IN (N'master', N'msdb') AND action_id IN ('CR', 'AL', 'DR') AND class_type NOT IN ('SL', 'DB'))) THEN 'SERVER_CONFIG'
             WHEN in_window = 0 AND action_id IN ('CR', 'AL', 'DR')
                  AND ((database_name = N'BankFas' AND class_type <> 'DB') OR (class_type = 'DB' AND object_name = N'BankFas'))
                  AND NOT (class_type = 'U' AND action_id = 'AL'
                           AND (LTRIM(statement) LIKE N'ALTER INDEX%' OR LTRIM(statement) LIKE N'UPDATE STATISTICS%')) THEN 'SCHEMA'
           END AS [rule]
    FROM e
)
SELECT [rule], CONVERT(VARCHAR(23), event_time, 126) AS event_time, RTRIM(action_id) AS action_id, class_type,
       CASE WHEN who = server_principal_name THEN who ELSE CONCAT(who, ' as ', server_principal_name) END AS principal,
       database_name, CASE WHEN schema_name = N'' THEN object_name ELSE qualified END AS object,
       LEFT(REPLACE(REPLACE(statement, CHAR(13), ' '), CHAR(10), ' '), 200) AS statement
FROM r
WHERE [rule] IS NOT NULL
ORDER BY event_time, sequence_number;
