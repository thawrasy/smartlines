/* ============================================================================
   The tenant pack CORE.ROLES in the database (db/static/057_core_roles.sql, tools/dbgen/core_roles_pack.py;
   FR-PLT-008, FR-PLT-018, DOC-B05 section 5.1, owner decision 35, ADR 0035; external review v5.0, E2).

   Run against a deployed BankFas database (with the platform seed) that holds no real data:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/core_roles_tests.sql
   Each case runs in a transaction of its own on a new tenant and is rolled back (a refusal under XACT_ABORT ends
   the transaction). The job binding is written the way sec.usp_SetJobContext writes it, without read-only keys, so
   the cases can rebind. Each case prints one line that starts with PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
IF DATABASE_PRINCIPAL_ID(N'tp_test_rjob') IS NULL CREATE USER [tp_test_rjob] WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID(N'tp_test_rapp') IS NULL CREATE USER [tp_test_rapp] WITHOUT LOGIN;
ALTER ROLE [tp_jobs] ADD MEMBER [tp_test_rjob];
ALTER ROLE [tp_app] ADD MEMBER [tp_test_rapp];
GO
CREATE TABLE #K (k VARCHAR(20) COLLATE DATABASE_DEFAULT PRIMARY KEY, v BIGINT);
GO
-- A new open tenant with its service account and an invited administrator; the connection bound as @JobKey.
CREATE PROCEDURE #Fix @JobKey VARCHAR(80) = 'JOB-PLT-ONBOARD'
AS
BEGIN
    DECLARE @t INT, @svc BIGINT, @token UNIQUEIDENTIFIER = NEWID(), @plan INT = (SELECT PlanId FROM plat.[Plan] WHERE Code = 'STANDARD'),
            @country INT = (SELECT CountryId FROM ref.Country WHERE Iso2 = 'SA');
    DELETE FROM #K;
    INSERT plat.Tenant (Code, NameAr, NameEn, PlanId, HomeCountryId, Status, TimeZone)
    VALUES ('tst-roles', N'أ', N'Roles', @plan, @country, 'ACTIVE', 'UTC');
    SET @t = SCOPE_IDENTITY();
    DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
    INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind) VALUES (@@SPID, @t, 0, @token, 'JOB');
    EXEC sys.sp_set_session_context @key = N'TenantId', @value = @t;
    EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status, IsSystemUser) VALUES (@t, N'service@roles.invalid', N'Service', 'ACTIVE', 1);
    SET @svc = SCOPE_IDENTITY();
    UPDATE sec.SessionBinding SET BoundUserId = @svc WHERE SessionId = @@SPID;
    EXEC sys.sp_set_session_context @key = N'UserId', @value = @svc;
    EXEC sys.sp_set_session_context @key = N'JobKey', @value = @JobKey;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status) VALUES (@t, N'admin@roles.invalid', N'Admin', 'INVITED');
    INSERT #K VALUES ('t', @t), ('svc', @svc), ('admin', SCOPE_IDENTITY());
END;
GO
CREATE PROCEDURE #Try @sql NVARCHAR(MAX), @err INT OUTPUT, @out NVARCHAR(4000) = NULL OUTPUT, @JobKey VARCHAR(80) = 'JOB-PLT-ONBOARD'
AS
BEGIN
    SELECT @err = NULL, @out = NULL;
    BEGIN TRANSACTION;
    EXEC #Fix @JobKey;
    BEGIN TRY
        EXEC sys.sp_executesql @sql, N'@out NVARCHAR(4000) OUTPUT', @out OUTPUT;
        SET @err = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER();
    END CATCH;
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
END;
GO

DECLARE @e INT, @e2 INT, @o NVARCHAR(4000), @o2 NVARCHAR(4000);

/* CR1: the onboarding job seeds the 8 system roles with their seed keys and the 393 default links of the pack, and
   logs one INITIAL run. */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @c INT;
    EXECUTE AS USER = N''tp_test_rjob''; EXEC sec.usp_SeedCoreRoles @Created = @c OUTPUT; REVERT;
    SET @out = CONCAT((SELECT STRING_AGG(Code, '','') WITHIN GROUP (ORDER BY Code) FROM sec.Role
                       WHERE TenantId = @t AND IsSystem = 1 AND IsActive = 1 AND SeedKey = ''ROLE.'' + Code), ''/'',
                      (SELECT COUNT(*) FROM sec.RolePermission WHERE TenantId = @t), ''/'', @c, ''/'',
                      (SELECT CONCAT(RunKind, '':'', CreatedCount, '':'', SkippedModifiedCount) FROM cfg.SeedRun WHERE TenantId = @t AND PackKey = ''CORE.ROLES''));', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = 'AU,FA,FO,RK,RQ,TA,TE,TM/393/401/INITIAL:401:0'
    PRINT 'PASS CR1: the onboarding job seeds the 8 system roles and their 393 default permissions, and logs the run';
ELSE PRINT CONCAT('FAIL CR1: ', @e, ' ', @o);

/* CR2: a second run adds nothing. What the tenant changed stays: a removed link is not put back and a renamed role
   keeps its name; the run counts and lists both (FR-PLT-008). */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @c INT, @s INT;
    EXECUTE AS USER = N''tp_test_rjob''; EXEC sec.usp_SeedCoreRoles; REVERT;
    DELETE rp FROM sec.RolePermission AS rp JOIN sec.Role AS r ON r.TenantId = rp.TenantId AND r.RoleId = rp.RoleId
                                            JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId
    WHERE rp.TenantId = @t AND r.Code = ''RK'' AND p.Code = ''fin.view'';
    UPDATE sec.Role SET NameEn = N''Account administrator'' WHERE TenantId = @t AND Code = ''TA'';
    EXECUTE AS USER = N''tp_test_rjob''; EXEC sec.usp_SeedCoreRoles @Created = @c OUTPUT, @Skipped = @s OUTPUT; REVERT;
    SET @out = CONCAT(@c, ''/'', @s, ''/'', (SELECT COUNT(*) FROM sec.RolePermission WHERE TenantId = @t), ''/'',
                      (SELECT NameEn FROM sec.Role WHERE TenantId = @t AND Code = ''TA''), ''/'',
                      (SELECT CONCAT(JSON_VALUE(DiffJson, ''$.roles[0].seedKey''), '':'', JSON_VALUE(DiffJson, ''$.roles[0].change''), '':'',
                                     JSON_VALUE(DiffJson, ''$.missingLinks[0].seedKey''), '':'', JSON_VALUE(DiffJson, ''$.missingLinks[0].permission''))
                       FROM cfg.SeedRun WHERE TenantId = @t AND PackKey = ''CORE.ROLES'' AND RunKind = ''RERUN''));', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = '0/2/392/Account administrator/ROLE.TA:RENAMED:ROLE.RK:fin.view'
    PRINT 'PASS CR2: a second run adds nothing, keeps what the tenant changed, and lists it for review';
ELSE PRINT CONCAT('FAIL CR2: ', @e, ' ', @o);

/* CR3: the links per role are those of the pack, and the locked permissions (BR-PLT-019) are on TM and FO only. */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t'');
    EXECUTE AS USER = N''tp_test_rjob''; EXEC sec.usp_SeedCoreRoles; REVERT;
    SET @out = CONCAT(
        (SELECT STRING_AGG(CONCAT(Code, '' '', n), '','') WITHIN GROUP (ORDER BY Code)
         FROM (SELECT r.Code, COUNT(*) AS n FROM sec.RolePermission AS rp JOIN sec.Role AS r ON r.TenantId = rp.TenantId AND r.RoleId = rp.RoleId
               WHERE rp.TenantId = @t GROUP BY r.Code) AS x), ''/'',
        (SELECT STRING_AGG(CAST(CONCAT(r.Code, '':'', p.Code) AS NVARCHAR(MAX)), '','') WITHIN GROUP (ORDER BY r.Code, p.Code)
         FROM sec.RolePermission AS rp JOIN sec.Role AS r ON r.TenantId = rp.TenantId AND r.RoleId = rp.RoleId
         JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId
         WHERE rp.TenantId = @t AND p.LockedToRoleCodes IS NOT NULL AND r.Code NOT IN (''TM'', ''FO'')), ''/'',
        (SELECT COUNT(*) FROM sec.RolePermission AS rp JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId
         WHERE rp.TenantId = @t AND p.LockedToRoleCodes IS NOT NULL));', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = 'AU 31,FA 9,FO 100,RK 10,RQ 19,TA 46,TE 51,TM 127//10'
    PRINT 'PASS CR3: each role has the permissions of the pack, and the locked permissions are on TM and FO only';
ELSE PRINT CONCAT('FAIL CR3: ', @e, ' ', @o);

/* CR4 (E2): the endorsement now has a seeded holder outside the preparing line. A user given RK holds
   fin.credit.endorse and neither fin.credit.assess nor fin.credit.approve; no seeded role holds the endorsement with
   either; AU and RK are the endorsers, TM and FO and FA prepare. */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @u BIGINT;
    EXECUTE AS USER = N''tp_test_rjob''; EXEC sec.usp_SeedCoreRoles; REVERT;
    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, Status) VALUES (@t, N''risk@roles.invalid'', N''Risk'', ''INVITED'');
    SET @u = SCOPE_IDENTITY();
    INSERT sec.UserRole (TenantId, UserId, RoleId) SELECT @t, @u, RoleId FROM sec.Role WHERE TenantId = @t AND Code = ''RK'';
    SET @out = CONCAT(
        (SELECT COUNT(*) FROM sec.fn_UserHasPermission(@t, @u, ''fin.credit.endorse'')), ''/'',
        (SELECT COUNT(*) FROM sec.fn_UserHasPermission(@t, @u, ''fin.credit.assess'')) + (SELECT COUNT(*) FROM sec.fn_UserHasPermission(@t, @u, ''fin.credit.approve'')), ''/'',
        (SELECT STRING_AGG(Code, '','') WITHIN GROUP (ORDER BY Code) FROM (
            SELECT DISTINCT r.Code FROM sec.RolePermission AS rp JOIN sec.Role AS r ON r.TenantId = rp.TenantId AND r.RoleId = rp.RoleId
            JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId WHERE rp.TenantId = @t AND p.Code = ''fin.credit.endorse'') AS x), ''/'',
        (SELECT STRING_AGG(Code, '','') WITHIN GROUP (ORDER BY Code) FROM (
            SELECT DISTINCT r.Code FROM sec.RolePermission AS rp JOIN sec.Role AS r ON r.TenantId = rp.TenantId AND r.RoleId = rp.RoleId
            JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId WHERE rp.TenantId = @t AND p.Code IN (''fin.credit.assess'', ''fin.credit.approve'')) AS y), ''/'',
        (SELECT COUNT(*) FROM sec.Role AS r WHERE r.TenantId = @t
            AND EXISTS (SELECT 1 FROM sec.RolePermission AS a JOIN sec.Permission AS p ON p.PermissionId = a.PermissionId
                        WHERE a.TenantId = @t AND a.RoleId = r.RoleId AND p.Code = ''fin.credit.endorse'')
            AND EXISTS (SELECT 1 FROM sec.RolePermission AS a JOIN sec.Permission AS p ON p.PermissionId = a.PermissionId
                        WHERE a.TenantId = @t AND a.RoleId = r.RoleId AND p.Code IN (''fin.credit.assess'', ''fin.credit.approve''))));', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = '1/0/AU,RK/FA,FO,TM/0'
    PRINT 'PASS CR4: the risk officer RK is seeded and endorses from outside the line that prepares and approves (E2)';
ELSE PRINT CONCAT('FAIL CR4: ', @e, ' ', @o);

/* CR5: only the onboarding job seeds the roles: the tenant application has no right (229), another job is refused
   (50003). */
EXEC #Try N'EXECUTE AS USER = N''tp_test_rapp''; BEGIN TRY EXEC sec.usp_SeedCoreRoles; END TRY BEGIN CATCH REVERT; THROW; END CATCH; REVERT;', @e OUTPUT;
EXEC #Try N'EXEC sec.usp_SeedCoreRoles;', @e2 OUTPUT, NULL, 'JOB-WFL-SLA';
IF @e = 229 AND @e2 = 50003
    PRINT 'PASS CR5: only the onboarding job runs the pack (the application 229, another job 50003)';
ELSE PRINT CONCAT('FAIL CR5: application ', @e, ', other job ', @e2);

/* CR6: onboarding stages B and C together: the job seeds the roles, then invites the first administrator, who holds
   the administrator's permissions through TA and no business permission. */
EXEC #Try N'DECLARE @t INT = (SELECT v FROM #K WHERE k = ''t''), @a BIGINT = (SELECT v FROM #K WHERE k = ''admin''), @tok VARBINARY(64) = CRYPT_GEN_RANDOM(32);
    EXECUTE AS USER = N''tp_test_rjob'';
    EXEC sec.usp_SeedCoreRoles;
    EXEC sec.usp_InviteFirstAdministrator @UserId = @a, @Token = @tok;
    REVERT;
    SET @out = CONCAT((SELECT COUNT(*) FROM sec.fn_UserHasPermission(@t, @a, ''sec.user.manage'')), ''/'',
                      (SELECT COUNT(*) FROM sec.fn_UserHasPermission(@t, @a, ''audit.view'')), ''/'',
                      (SELECT COUNT(*) FROM sec.fn_UserHasPermission(@t, @a, ''fin.view'')) + (SELECT COUNT(*) FROM sec.fn_UserHasPermission(@t, @a, ''party.identity.reveal'')));', @e OUTPUT, @o OUTPUT;
IF @e = 0 AND @o = '1/1/0'
    PRINT 'PASS CR6: after the pack the first administrator is invited with TA: users and audit, no business data';
ELSE PRINT CONCAT('FAIL CR6: ', @e, ' ', @o);
GO
ALTER ROLE [tp_jobs] DROP MEMBER [tp_test_rjob];
ALTER ROLE [tp_app] DROP MEMBER [tp_test_rapp];
DROP USER [tp_test_rjob];
DROP USER [tp_test_rapp];
GO
