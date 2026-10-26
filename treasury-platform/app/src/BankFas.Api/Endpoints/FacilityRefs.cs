using System.Globalization;
using BankFas.Api.Infrastructure;
using BankFas.Core.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The facility file and the platform reference of a facility (BR-FAC-021, docs/31 row 75). A company's file with a bank
/// is COMPANY-BANK-NNNN (the company's and the lead bank's reference codes and a serial of that pair); it holds every
/// contract of the relation over its life. The first approval of a facility puts it in a file: the file of the facility
/// it renews, else the company's open file with that bank, else a new one; and writes its reference once, CLASS-FILE for
/// the first contract of its class in the file (CAP-SA05-ANB-0001) and CLASS-FILE-NN for the next (CAP-SA05-ANB-0001-02).
/// The revision check refuses the first approval while a part is missing.
/// </summary>
internal static class FacilityRefs
{
    internal sealed record Parts(string? Company, string? Bank, string? Class, long? CompanyId, long? BankId, long? PreviousFileId)
    {
        /// <summary>The parts are complete: the class, and the file of the renewed facility or the two codes of a file.</summary>
        public bool Complete => FacilityReference.IsClassCode(Class)
            && (PreviousFileId is not null || (FacilityReference.IsCompanyCode(Company) && FacilityReference.IsBankCode(Bank) && BankId is not null));

        public string? Stem => Complete ? $"{Class}-{Company}-{Bank}" : null;
    }

    internal static async Task<Parts> PartsAsync(SqlConnection c, SqlTransaction? tx, long facility, CancellationToken ct)
    {
        var row = await c.QuerySingleAsync<(string? Company, long CompanyId, string? Class, long? PreviousFile)>(new CommandDefinition(
            """
            SELECT co.RefCode, co.CompanyId, li.Code,
                   (SELECT m.FacilityFileId FROM fac.FacilityFileFacility AS m WHERE m.FacilityId = f.PreviousFacilityId)
              FROM fac.Facility AS f JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
              LEFT JOIN cat.LookupItem AS li ON li.LookupItemId = f.FacilityClassId
             WHERE f.FacilityId = @f;
            """, new { f = facility }, tx, cancellationToken: ct));
        var lead = await KycEndpoints.LeadBankAsync(c, tx, facility, int.MaxValue, ct);
        var bank = lead is null ? null : await c.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT RefCode FROM ins.Institution WHERE InstitutionId = @i;", new { i = lead }, tx, cancellationToken: ct));
        return new Parts(row.Company, bank, row.Class, row.CompanyId, lead, row.PreviousFile);
    }

    /// <summary>What keeps the facility from its reference, as findings of the revision check (V-FAC-REF).</summary>
    internal static IEnumerable<string> Missing(Parts p)
    {
        if (p.Complete) yield break;
        if (p.PreviousFileId is null && !FacilityReference.IsCompanyCode(p.Company)) yield return "The borrower has no reference code (two to six characters, a letter first): set it on the company.";
        if (p.PreviousFileId is null && !FacilityReference.IsBankCode(p.Bank)) yield return "The lead bank has no reference code (three capital letters): set it on the institution.";
        if (!FacilityReference.IsClassCode(p.Class)) yield return "The facility has no class (CAP, STL, MTL, LTL ...): choose it on the facility.";
    }

    /// <summary>The file a facility goes into and its reference there, without writing anything: what the card previews.</summary>
    internal static async Task<(string? FileRef, string Reference)?> PreviewAsync(SqlConnection c, SqlTransaction? tx, Parts p, CancellationToken ct)
    {
        if (!p.Complete) return null;
        var file = await FileOfAsync(c, tx, p, ct);
        var fileRef = file?.Ref ?? FacilityReference.FileRef(p.Company!, p.Bank!, await NextSerialAsync(c, tx, p, ct));
        var seq = file is null ? 1 : await NextSeqAsync(c, tx, file.Value.Id, p.Class!, ct);
        return (file?.Ref, FacilityReference.ContractRef(p.Class!, fileRef, seq));
    }

    /// <summary>Puts a facility that has no reference into its file and writes its reference; returns the reference.</summary>
    internal static async Task<string?> AssignAsync(SqlConnection c, SqlTransaction tx, long facility, DateTime effectiveFrom, CancellationToken ct)
    {
        if (await c.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT PlatformRef FROM fac.Facility WHERE FacilityId = @f;", new { f = facility }, tx,
                cancellationToken: ct)) is { } existing)
            return existing;
        var p = await PartsAsync(c, tx, facility, ct);
        if (!p.Complete) throw ApiProblemException.Invalid("V-FAC-REF", "The facility's reference needs the borrower's and the lead bank's reference codes and the facility's class.");
        var file = await FileOfAsync(c, tx, p, ct, lockRows: true);
        if (file is null)
        {
            var serial = await NextSerialAsync(c, tx, p, ct, lockRows: true);
            var fileRef = FacilityReference.FileRef(p.Company!, p.Bank!, serial);
            var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT fac.FacilityFile (TenantId, FileRef, CompanyId, InstitutionId, Serial, Status, OpenedOn, CreatedBy)
                OUTPUT inserted.FacilityFileId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @c, @b, @s, 'OPEN', @on, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { r = fileRef, c = p.CompanyId, b = p.BankId, s = serial, on = effectiveFrom.Date }, tx, cancellationToken: ct));
            file = (id, fileRef);
        }
        var seq = await NextSeqAsync(c, tx, file.Value.Id, p.Class!, ct, lockRows: true);
        var reference = FacilityReference.ContractRef(p.Class!, file.Value.Ref, seq);
        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT fac.FacilityFileFacility (TenantId, FacilityFileId, FacilityId, ClassCode, SeqInClass, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @file, @f, @cls, @seq, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            UPDATE fac.Facility SET PlatformRef = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FacilityId = @f AND PlatformRef IS NULL;
            """, new { file = file.Value.Id, f = facility, cls = p.Class, seq, r = reference }, tx, cancellationToken: ct));
        return reference;
    }

    /// <summary>The file of the renewed facility, else the company's newest open file with the lead bank.</summary>
    private static async Task<(long Id, string Ref)?> FileOfAsync(SqlConnection c, SqlTransaction? tx, Parts p, CancellationToken ct, bool lockRows = false) =>
        await c.QuerySingleOrDefaultAsync<(long, string)?>(new CommandDefinition(
            $"""
            SELECT TOP (1) FacilityFileId, FileRef FROM fac.FacilityFile {(lockRows ? "WITH (UPDLOCK, HOLDLOCK)" : "")}
             WHERE FacilityFileId = @prev OR (@prev IS NULL AND CompanyId = @c AND InstitutionId = @b AND Status = 'OPEN')
             ORDER BY Serial DESC;
            """, new { prev = p.PreviousFileId, c = p.CompanyId, b = p.BankId }, tx, cancellationToken: ct));

    private static Task<int> NextSerialAsync(SqlConnection c, SqlTransaction? tx, Parts p, CancellationToken ct, bool lockRows = false) =>
        c.ExecuteScalarAsync<int>(new CommandDefinition(
            $"SELECT ISNULL(MAX(Serial), 0) + 1 FROM fac.FacilityFile {(lockRows ? "WITH (UPDLOCK, HOLDLOCK)" : "")} WHERE CompanyId = @c AND InstitutionId = @b;",
            new { c = p.CompanyId, b = p.BankId }, tx, cancellationToken: ct));

    private static Task<int> NextSeqAsync(SqlConnection c, SqlTransaction? tx, long file, string cls, CancellationToken ct, bool lockRows = false) =>
        c.ExecuteScalarAsync<int>(new CommandDefinition(
            $"SELECT ISNULL(MAX(SeqInClass), 0) + 1 FROM fac.FacilityFileFacility {(lockRows ? "WITH (UPDLOCK, HOLDLOCK)" : "")} WHERE FacilityFileId = @f AND ClassCode = @cls;",
            new { f = file, cls }, tx, cancellationToken: ct));

    /// <summary>The lookup item of a facility class: an active item of FACILITY_CLASS whose code is three capital letters.</summary>
    internal static async Task<int> ClassAsync(SqlConnection c, SqlTransaction? tx, string code, CancellationToken ct)
    {
        var v = code.Trim().ToUpperInvariant();
        if (!FacilityReference.IsClassCode(v)) throw ApiProblemException.Invalid("V-FAC-CLASS", "The facility class is three capital letters, such as CAP, STL, MTL or LTL.");
        return await c.ExecuteScalarAsync<int?>(new CommandDefinition(
            """
            SELECT li.LookupItemId FROM cat.LookupItem AS li JOIN cat.LookupList AS ll ON ll.LookupListId = li.LookupListId
             WHERE ll.Code = 'FACILITY_CLASS' AND li.Code = @c AND li.Status = 'ACTIVE';
            """, new { c = v }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-FAC-CLASS", string.Format(CultureInfo.InvariantCulture, "{0} is not an active facility class of the catalogue.", v));
    }
}
