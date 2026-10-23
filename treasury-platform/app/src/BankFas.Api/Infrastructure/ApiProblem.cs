using BankFas.Data;

namespace BankFas.Api.Infrastructure;

/// <summary>An error the API answers with as problem+json (RFC 9457; DOC-B04 section 6): an HTTP status and a stable code.</summary>
public sealed class ApiProblemException(int status, string code, string title) : Exception(title)
{
    public int Status { get; } = status;
    public string Code { get; } = code;

    public static ApiProblemException Unauthorized(string code = "SESSION_INVALID", string title = "Sign in again.") => new(401, code, title);
    public static ApiProblemException Forbidden(string code = "FORBIDDEN", string title = "You may not do this.") => new(403, code, title);
    public static ApiProblemException NotFound() => new(404, "NOT_FOUND", "Not found.");
    public static ApiProblemException Invalid(string code, string title) => new(422, code, title);
}

/// <summary>
/// Database errors as API problems (DOC-B04 section 6; the error catalogue of the brief, section 1.6). Every failure
/// before a password is proven reads the same (FR-PLT-012); an unmapped error is a 500 with the correlation id only.
/// </summary>
public static class DbProblemMap
{
    public static (int Status, string Code, string Title)? Map(int number) => number switch
    {
        DbErrors.InvalidArgument => (400, "INVALID_ARGUMENT", "The request is not complete or not valid."),
        DbErrors.TenantUnavailable or DbErrors.NoValidSession => (401, "SESSION_INVALID", "Sign in again."),
        DbErrors.InvalidCredentials => (401, "INVALID_CREDENTIALS", "Invalid email or password."),
        DbErrors.TenantClosedToUser => (403, "TENANT_UNAVAILABLE", "This account is not available to you at the moment."),
        DbErrors.MfaEnrolmentRequired => (409, "MFA_ENROLMENT_REQUIRED", "Set up your authenticator first."),
        DbErrors.InvalidRecoveryCode => (401, "MFA_INVALID", "The code is not valid."),
        DbErrors.CurrentPasswordWrong => (422, "CURRENT_PASSWORD_INVALID", "The current password is not correct."),
        DbErrors.PasswordUsedRecently => (422, "PASSWORD_REUSED", "Choose a password you have not used recently."),
        DbErrors.ReenrolmentLinkRequired => (422, "LINK_REQUIRED", "Open the link from your e-mail to set up your authenticator again."),
        DbErrors.InvalidLink => (422, "LINK_INVALID", "This link has expired or has been used."),
        DbErrors.LinkNotIssuable => (409, "LINK_NOT_ISSUABLE", "A link cannot be sent for this account in its current state."),
        DbErrors.NotLocked => (409, "NOT_LOCKED", "The account is not locked."),
        DbErrors.StatusChangeNotAllowed => (409, "STATUS_CHANGE_NOT_ALLOWED", "This status change is not allowed."),
        DbErrors.SettingRefused => (422, "SETTING_REFUSED", "The value is outside what the platform allows."),
        DbErrors.OperatorAdminRequired => (403, "STEP_UP_REQUIRED", "Confirm with a fresh authenticator code."),
        DbErrors.NoSupportGrant => (403, "NO_SUPPORT_GRANT", "There is no active support access to this account."),
        DbErrors.CodeReserved or DbErrors.CodeInUse => (409, "CODE_UNAVAILABLE", "This sub-domain is not available."),
        DbErrors.CloseWaitsForExport => (409, "EXPORT_REQUIRED", "Closing waits for the data export."),
        DbErrors.RolesNotSeeded => (409, "NOT_READY", "The account is still being prepared."),
        DbErrors.SeedRowsOnly => (409, "SYSTEM_ITEM", "System and locked items come from the default packs only."),
        DbErrors.GrantFinal => (409, "GRANT_FINAL", "A revoked or superseded grant is final, and an active grant keeps its terms: change it with a new grant that replaces it."),
        DbErrors.PathThroughCompany => (422, "V-ORG-OWN-PATH", "A path through a company of the account follows from that company's own holdings; record its holders there (BR-ORG-008)."),
        DbErrors.ApprovedFinal => (409, "APPROVED_FINAL", "An approved record is fixed; change it with a new version."),
        DbErrors.CovenantTestFinal => (409, "TEST_FINAL", "An evaluated covenant test is a fact: it is reviewed, and a new evaluation is a new row."),
        DbErrors.StatementFinal => (409, "STATEMENT_FINAL", "A statement changes only as a draft; a submitted or approved one is fixed (a change is a new version)."),
        DbErrors.ConsolidationRefused => (422, "V-FIN-CONSOLIDATION", "Only a holding enters consolidated statements, with one parent unit, itself, and at least one other unit (BR-FIN-013)."),
        DbErrors.FlowLevel => (409, "FLOW_LEVEL", "A month's flow to a bank is entered at the level of the bank or per facility, not both (BR-FIN-016)."),
        DbErrors.AssessmentState or DbErrors.AssessmentBudget or DbErrors.GroupSupportRefused or DbErrors.ScorecardFinal
            => (409, "ASSESSMENT_STATE", "The assessment is not in a state that allows this, or what it read changed: compute it again."),
        DbErrors.VersionRefused => (409, "VERSION_REFUSED", "Only a built presentation version is chosen, with a reason (BR-FIN-037)."),
        DbErrors.EndorsementRefused => (409, "ENDORSEMENT_REFUSED", "The assessment cannot be endorsed by this user or without its reason (BR-FIN-042)."),
        DbErrors.FigureConfirmed => (409, "FIGURE_CONFIRMED", "A confirmed monthly figure is fixed: another user reopens it first."),
        DbErrors.AssessmentUnknown => (409, "EVIDENCE_PACK_REFUSED", "An evidence pack is built of the endorsed assessment that is still the approved one (BR-FIN-049)."),
        DbErrors.PeriodClosed => (409, "PERIOD_CLOSED", "The reporting period is closed."),
        DbErrors.CloseRefused => (409, "CLOSE_REFUSED", "Reopen the latest close of the company first."),
        DbErrors.ActorMismatch => (403, "ACTOR_MISMATCH", "Only the signed-in user may be recorded as the preparer, approver or confirmer."),
        DbErrors.ActorPermission => (403, "FORBIDDEN", "You may not do this."),
        DbErrors.SamePerson => (409, "SAME_PERSON", "Another user confirms or approves what this user prepared."),
        DbErrors.RateFinal => (409, "APPROVED_FINAL", "An approved record is fixed; change it with a new version."),
        DbErrors.NumberingNotConfigured => (409, "NUMBERING_NOT_CONFIGURED", "No active numbering is defined for this kind of record; an administrator sets it up first."),
        DbErrors.NumberVoidRefused => (409, "NUMBER_VOID_REFUSED", "A number is voided with a reason, and only an issued one."),
        DbErrors.TermsLocked => (409, "TERMS_LOCKED", "Locked terms do not change; a change is a new version (BR-LCT-019)."),
        DbErrors.TemplatePublished => (409, "TEMPLATE_PUBLISHED", "A published template does not change; a change is a new version (BR-WFL-019)."),
        DbErrors.ReservationFinal => (409, "RESERVATION_FINAL", "A converted or released reservation is final; reserve again (BR-FAC-015)."),
        DbErrors.RowFilterWriteRefused => (403, "TENANT_READ_ONLY", "The account is read-only in its current status."),
        DbErrors.PermissionDenied or DbErrors.ColumnPermissionDenied => (403, "FORBIDDEN", "You may not do this."),
        DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation => (409, "CONFLICT", "A record with these values already exists."),
        DbErrors.CheckViolation => (422, "VALIDATION_FAILED", "A value is not valid."),
        DbErrors.NullNotAllowed => (422, "REQUIRED_FIELD", "A required field is missing."),
        _ => null,
    };
}
