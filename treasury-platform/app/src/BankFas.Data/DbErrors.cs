using Microsoft.Data.SqlClient;

namespace BankFas.Data;

/// <summary>The error numbers the database raises (brief section 1.6; the error lists at the top of each db/static file).</summary>
public static class DbErrors
{
    public const int InvalidArgument = 50001;
    public const int TenantUnavailable = 50002;
    public const int NoValidSession = 50003;
    public const int AlreadyBound = 50004;
    public const int InvalidCredentials = 50005;
    public const int TenantClosedToUser = 50006;
    public const int MfaEnrolmentRequired = 50008;
    public const int InvalidRecoveryCode = 50009;
    public const int CurrentPasswordWrong = 50010;
    public const int PasswordUsedRecently = 50011;
    public const int ReenrolmentLinkRequired = 50013;
    public const int RecoveryCodesRequired = 50014;
    public const int HistoryCandidatesIncomplete = 50015;
    public const int LinkNotIssuable = 50016;
    public const int InvalidLink = 50017;
    public const int NotLocked = 50018;
    public const int StatusChangeNotAllowed = 50019;
    public const int SettingRefused = 50020;
    public const int OperatorAdminRequired = 50021;
    public const int NoSupportGrant = 50022;
    public const int CodeReserved = 50025;
    public const int CodeInUse = 50026;
    public const int CloseWaitsForExport = 50027;
    public const int RolesNotSeeded = 50028;
    public const int SeedRowsOnly = 50174;
    public const int KeyNotActive = 50098;
    public const int RowFilterWriteRefused = 33504;
    public const int PermissionDenied = 229;
    public const int ColumnPermissionDenied = 230;
    public const int UniqueViolation = 2627;
    public const int UniqueIndexViolation = 2601;
    public const int CheckViolation = 547;
    public const int NullNotAllowed = 515;
    public const int Deadlock = 1205;

    /// <summary>The number of the first error of a database exception, or null for any other exception.</summary>
    public static int? NumberOf(Exception exception) => exception is SqlException sql ? sql.Number : null;

    public static bool Is(this Exception exception, int number) => NumberOf(exception) == number;
}
