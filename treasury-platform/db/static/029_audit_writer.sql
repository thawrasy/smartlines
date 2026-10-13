/* ============================================================================
   BankFas - 029: security and platform events audited by the database itself (FR-PLT-022, BR-PLT-009; O-25 in
   tools/dbgen/erd_open_items.py; DQ-F03-10; docs/adr/0007-audit-written-by-the-database.md)

   The procedures of 030 and 035 to 038 change accounts, sessions, bindings and tenants. Several run before any
   binding, where the application cannot write a tenant's audit row (rls.fn_AuditWrite needs a bound tenant), and
   operators have no tenant at all. So each of them writes its own aud.AuditLog row, in the same transaction as the
   change: an event and its audit row commit or roll back together, and no event depends on the application.
     aud.usp_WriteEvent         internal: one row. Runs as its caller (the procedures run as tp_auth_exec, which the
                                write filter admits); no role may execute it. The actor is given as a user or an
                                operator id and stored as that account's PublicId. The client address and the
                                correlation id default to the binding's context keys.
     sec.TR_LoginAttempt_Audit  every row of sec.LoginAttempt (login successes and failures, MFA and recovery-code
                                failures, lockouts) gets an audit row. The application may delete login attempts
                                (005); their audit rows stay, since nobody may update or delete aud.AuditLog (R6 of
                                O-24, DQ-F03-10).
   Tenant rows (TenantId set) are what the tenant's audit viewer shows; platform rows (TenantId NULL) are for the
   operators only (rls.fn_AuditRead). The hash chain (ChainSeq, PrevHash, RowHash) stays empty until FR-PLT-025 is
   built in S2; its writer must then cover these rows too.

   Events (Action; Category; Severity HIGH where BR-PLT-009 asks for it):
     tenant rows   LOGIN_SUCCESS, FAILED_PASSWORD, DENIED_LOCKED, DENIED_TENANT, FAILED_MFA, LOCKOUT (trigger);
                   MFA_ENROLLED, RECOVERY_CODE_USED, LOGOUT, SESSION_TERMINATED, PASSWORD_CHANGED, PASSWORD_RESET,
                   PASSWORD_RESET_REQUESTED, INVITATION_ACCEPTED, LINK_ISSUED, USER_UNLOCKED, MFA_RESET (HIGH),
                   USER_STATUS_CHANGED (035); SECURITY.
                   SUPPORT_ACCESS_BOUND (036; SECURITY, HIGH), JOB_BOUND (037; SYSTEM),
                   FIRST_ADMIN_INVITED (038; CONFIG, HIGH).
     platform rows OPERATOR_LOGIN_SUCCESS, OPERATOR_LOGIN_FAILED, OPERATOR_LOGIN_DENIED, OPERATOR_MFA_FAILED,
                   OPERATOR_LOCKOUT (HIGH), OPERATOR_LOGOUT, OPERATOR_UNLOCKED, OPERATOR_BOOTSTRAPPED (HIGH),
                   OPERATOR_INVITED (HIGH), OPERATOR_SETUP_COMPLETED, OPERATOR_RESET (HIGH), OPERATOR_STATUS_CHANGED
                   (036); TENANT_CREATED, TENANT_STATUS_CHANGED (HIGH when SUSPENDED, CLOSED or ARCHIVED_READ_ONLY)
                   (038); PLATFORM.
   No row holds a password hash, a token, a secret or an e-mail address; an attempt with an unknown e-mail address
   has no actor.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO
CREATE OR ALTER PROCEDURE aud.usp_WriteEvent
    @TenantId        INT,                       -- NULL: a platform event
    @Action          VARCHAR(60),
    @Category        VARCHAR(15),
    @ActorType       VARCHAR(8),                -- USER, OPERATOR, SYSTEM or JOB
    @ActorUserId     BIGINT = NULL,
    @ActorOperatorId INT = NULL,
    @Severity        VARCHAR(4) = 'INFO',
    @Result          VARCHAR(7) = 'SUCCESS',
    @EntityType      VARCHAR(60) = NULL,
    @EntityId        BIGINT = NULL,
    @BeforeJson      NVARCHAR(MAX) = NULL,
    @AfterJson       NVARCHAR(MAX) = NULL,
    @IpAddress       VARCHAR(45) = NULL,
    @UserAgent       NVARCHAR(400) = NULL,
    @CorrelationId   UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId,
                         BeforeJson, AfterJson, CorrelationId, IpAddress, UserAgent, Result)
    VALUES (@TenantId, SYSUTCDATETIME(), @ActorType,
            CASE WHEN @ActorUserId IS NOT NULL
                     THEN (SELECT PublicId FROM sec.AppUser WHERE TenantId = @TenantId AND AppUserId = @ActorUserId)
                 WHEN @ActorOperatorId IS NOT NULL
                     THEN (SELECT PublicId FROM plat.PlatformOperator WHERE PlatformOperatorId = @ActorOperatorId) END,
            @Action, @Category, @Severity, @EntityType, @EntityId, @BeforeJson, @AfterJson,
            COALESCE(@CorrelationId, CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER)),
            COALESCE(@IpAddress, CAST(SESSION_CONTEXT(N'ClientIp') AS VARCHAR(45))), @UserAgent, @Result);
END;
GO
CREATE OR ALTER TRIGGER sec.TR_LoginAttempt_Audit ON sec.LoginAttempt
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId,
                         CorrelationId, IpAddress, UserAgent, Result)
    SELECT i.TenantId, SYSUTCDATETIME(), 'USER', u.PublicId, i.Outcome, 'SECURITY', 'INFO',
           CASE WHEN i.UserId IS NOT NULL THEN 'sec.AppUser' END, i.UserId,
           CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER), i.IpAddress, i.UserAgent,
           CASE WHEN i.Outcome = 'LOGIN_SUCCESS' THEN 'SUCCESS'
                WHEN i.Outcome LIKE 'DENIED%' OR i.Outcome = 'LOCKOUT' THEN 'DENIED'
                ELSE 'FAILED' END
    FROM inserted AS i
    LEFT JOIN sec.AppUser AS u ON u.TenantId = i.TenantId AND u.AppUserId = i.UserId;
END;
GO
