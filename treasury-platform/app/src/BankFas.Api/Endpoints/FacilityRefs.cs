using System.Globalization;
using BankFas.Api.Infrastructure;
using BankFas.Core.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The platform reference of a facility (BR-FAC-021, <see cref="FacilityReference"/>): the borrower's reference code,
/// the lead bank's (the sole, lead or agent lender, else the first), the facility's class and the year it is in force
/// from. The revision check refuses the first approval while a part is missing; the approval writes it once, and it does
/// not change after. A renewal keeps the stem of its predecessor's reference, so a later change of a code does not
/// split the chain.
/// </summary>
internal static class FacilityRefs
{
    internal sealed record Parts(string? Company, string? Bank, string? Class, string? PreviousRef)
    {
        public string? Stem => FacilityReference.StemOf(PreviousRef)
            ?? (FacilityReference.IsCompanyCode(Company) && FacilityReference.IsBankCode(Bank) && FacilityReference.IsClassCode(Class)
                ? FacilityReference.Stem(Company!, Bank!, Class!) : null);
    }

    internal static async Task<Parts> PartsAsync(SqlConnection c, SqlTransaction? tx, long facility, CancellationToken ct)
    {
        var row = await c.QuerySingleAsync<(string? Company, string? Class, string? PreviousRef)>(new CommandDefinition(
            """
            SELECT co.RefCode, li.Code, pf.PlatformRef
              FROM fac.Facility AS f JOIN org.Company AS co ON co.CompanyId = f.BorrowerCompanyId
              LEFT JOIN cat.LookupItem AS li ON li.LookupItemId = f.FacilityClassId
              LEFT JOIN fac.Facility AS pf ON pf.FacilityId = f.PreviousFacilityId
             WHERE f.FacilityId = @f;
            """, new { f = facility }, tx, cancellationToken: ct));
        var lead = await KycEndpoints.LeadBankAsync(c, tx, facility, int.MaxValue, ct);
        var bank = lead is null ? null : await c.ExecuteScalarAsync<string?>(new CommandDefinition(
            "SELECT RefCode FROM ins.Institution WHERE InstitutionId = @i;", new { i = lead }, tx, cancellationToken: ct));
        return new Parts(row.Company, bank, row.Class, row.PreviousRef);
    }

    /// <summary>What keeps the facility from its reference, as findings of the revision check (V-FAC-REF).</summary>
    internal static IEnumerable<string> Missing(Parts p)
    {
        if (p.Stem is not null) yield break;
        if (!FacilityReference.IsCompanyCode(p.Company)) yield return "The borrower has no reference code (two or three characters, a letter first): set it on the company.";
        if (!FacilityReference.IsBankCode(p.Bank)) yield return "The lead bank has no reference code (three capital letters): set it on the institution.";
        if (!FacilityReference.IsClassCode(p.Class)) yield return "The facility has no class (CAP, STL, MTL, LTL ...): choose it on the facility.";
    }

    /// <summary>Writes the reference of a facility that has none: the stem, the year it is in force from, and a serial when the pair is taken.</summary>
    internal static async Task<string?> AssignAsync(SqlConnection c, SqlTransaction tx, long facility, DateTime effectiveFrom, CancellationToken ct)
    {
        if (await c.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT PlatformRef FROM fac.Facility WHERE FacilityId = @f;", new { f = facility }, tx,
                cancellationToken: ct)) is { } existing)
            return existing;
        var stem = (await PartsAsync(c, tx, facility, ct)).Stem
            ?? throw ApiProblemException.Invalid("V-FAC-REF", "The facility's reference needs the borrower's and the lead bank's reference codes and the facility's class.");
        var prefix = FacilityReference.Compose(stem, effectiveFrom.Year);
        var taken = await c.QueryAsync<string>(new CommandDefinition(
            "SELECT PlatformRef FROM fac.Facility WITH (UPDLOCK, HOLDLOCK) WHERE PlatformRef = @p OR PlatformRef LIKE @like;",
            new { p = prefix, like = prefix + "-%" }, tx, cancellationToken: ct));
        var reference = FacilityReference.Next(stem, effectiveFrom.Year, taken);
        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE fac.Facility SET PlatformRef = @r, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FacilityId = @f AND PlatformRef IS NULL;",
            new { r = reference, f = facility }, tx, cancellationToken: ct));
        return reference;
    }

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
