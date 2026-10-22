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
        DbErrors.RowFilterWriteRefused => (403, "TENANT_READ_ONLY", "The account is read-only in its current status."),
        DbErrors.PermissionDenied or DbErrors.ColumnPermissionDenied => (403, "FORBIDDEN", "You may not do this."),
        DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation => (409, "CONFLICT", "A record with these values already exists."),
        DbErrors.CheckViolation => (422, "VALIDATION_FAILED", "A value is not valid."),
        DbErrors.NullNotAllowed => (422, "REQUIRED_FIELD", "A required field is missing."),
        _ => null,
    };
}
