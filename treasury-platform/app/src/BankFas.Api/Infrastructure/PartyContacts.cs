using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Core.Text;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Infrastructure;

public sealed record AddressRequest(string? AddressType, bool? IsPrimary, bool? IsCurrent, string? Country, string? Region, string? City, string? District,
    string? Street, string? BuildingNumber, string? UnitNumber, string? PostalCode, string? AdditionalNumber, string? ShortCode, string? PoBoxNumber,
    string? FreeText);
public sealed record ContactMethodRequest(string? Kind, string? Value, string? Label, bool? IsPrimary);

/// <summary>
/// Addresses and contact methods of a party (FR-PTY-011, FR-PTY-012, BR-PTY-015), shared by the company screen, whose
/// addresses are those of its mirror party (FR-ORG-009), and the party screens. One primary current address and one
/// primary method per kind: setting a new one clears the old in the same transaction. A Saudi national address has
/// its fixed formats (building 4 digits, postal code 5 digits, additional number 4 digits).
/// </summary>
public static partial class PartyContacts
{
    private static readonly string[] AddressTypes = ["NATIONAL", "RESIDENTIAL", "WORK", "PO_BOX", "REGISTERED", "OTHER"];
    private static readonly string[] Kinds = ["MOBILE", "PHONE", "EMAIL", "FAX", "WEBSITE", "OTHER"];

    [GeneratedRegex("^[0-9]{4}$")] private static partial Regex Four();
    [GeneratedRegex("^[0-9]{5}$")] private static partial Regex Five();

    private sealed record AddressRow(long AddressId, string AddressType, bool IsPrimary, bool IsCurrent, string Country, string? Region, string? City,
        string? District, string? Street, string? BuildingNumber, string? UnitNumber, string? PostalCode, string? AdditionalNumber, string? ShortCode,
        string? PoBoxNumber, string? FreeText, byte[] RowVersion);

    public static async Task<object> ListAsync(SqlConnection c, long partyId, OpaqueRefs refs, int tenantId, CancellationToken ct)
    {
        var addresses = await c.QueryAsync<AddressRow>(new CommandDefinition(
            """
            SELECT a.AddressId, a.AddressType, a.IsPrimary, a.IsCurrent, co.Iso2 AS Country, a.Region, a.City, a.District, a.Street, a.BuildingNumber, a.UnitNumber,
                   a.PostalCode, a.AdditionalNumber, a.ShortCode, a.PoBoxNumber, a.[FreeText], a.RowVersion
              FROM pty.Address AS a JOIN ref.Country AS co ON co.CountryId = a.CountryId
             WHERE a.PartyId = @p ORDER BY a.IsCurrent DESC, a.IsPrimary DESC, a.AddressId;
            """, new { p = partyId }, cancellationToken: ct));
        var methods = await c.QueryAsync<(long Id, string Kind, string Value, string NormalizedValue, string? Label, bool IsPrimary)>(new CommandDefinition(
            "SELECT ContactMethodId, Kind, Value, NormalizedValue, Label, IsPrimary FROM pty.ContactMethod WHERE PartyId = @p ORDER BY Kind, IsPrimary DESC, ContactMethodId;",
            new { p = partyId }, cancellationToken: ct));
        return new
        {
            addresses = addresses.Select(a => new
            {
                id = refs.ItemRef(tenantId, "address", a.AddressId), addressType = a.AddressType, isPrimary = a.IsPrimary, isCurrent = a.IsCurrent,
                country = a.Country, region = a.Region, city = a.City, district = a.District, street = a.Street, buildingNumber = a.BuildingNumber,
                unitNumber = a.UnitNumber, postalCode = a.PostalCode, additionalNumber = a.AdditionalNumber, shortCode = a.ShortCode,
                poBoxNumber = a.PoBoxNumber, freeText = a.FreeText, etag = ETags.Of(a.RowVersion),
            }),
            contactMethods = methods.Select(m => new
            {
                id = refs.ItemRef(tenantId, "contact-method", m.Id), kind = m.Kind, value = m.Value, normalizedValue = m.NormalizedValue, label = m.Label, isPrimary = m.IsPrimary,
            }),
        };
    }

    private static string? T(string? s, int max, string field)
    {
        if (s is null) return null;
        var v = s.Trim();
        if (v.Length > max) throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is up to {max} characters.");
        return v.Length == 0 ? null : v;
    }

    private static async Task<int> CountryIdAsync(SqlConnection c, SqlTransaction tx, string? iso2, CancellationToken ct) =>
        await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CountryId FROM ref.Country WHERE Iso2 = @iso2 AND IsActive = 1;",
            new { iso2 = iso2?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("COUNTRY_UNKNOWN", "Choose a country from the list.");

    private static void CheckNational(AddressRequest a, string type, string? country)
    {
        if (type == "PO_BOX" && string.IsNullOrWhiteSpace(a.PoBoxNumber)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A PO box address needs its box number.");
        if (type != "NATIONAL" || !string.Equals(country, "SA", StringComparison.OrdinalIgnoreCase)) return;
        if (a.BuildingNumber is null || !Four().IsMatch(a.BuildingNumber.Trim())
            || a.PostalCode is null || !Five().IsMatch(a.PostalCode.Trim())
            || (a.AdditionalNumber is { Length: > 0 } add && !Four().IsMatch(add.Trim())))
            throw ApiProblemException.Invalid("V-PTY-ADDRESS", "A Saudi national address has a 4-digit building number, a 5-digit postal code and a 4-digit additional number.");
    }

    public static async Task<long> AddAddressAsync(SqlConnection c, SqlTransaction tx, long partyId, AddressRequest a, CancellationToken ct)
    {
        var type = a.AddressType?.Trim().ToUpperInvariant();
        if (type is null || !AddressTypes.Contains(type)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the address type.");
        CheckNational(a, type, a.Country);
        var country = await CountryIdAsync(c, tx, a.Country, ct);
        var primary = a.IsPrimary == true;
        if (primary)
            await c.ExecuteAsync(new CommandDefinition("UPDATE pty.Address SET IsPrimary = 0, UpdatedAt = SYSUTCDATETIME() WHERE PartyId = @p AND IsPrimary = 1;",
                new { p = partyId }, tx, cancellationToken: ct));
        return await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT pty.Address (TenantId, PartyId, AddressType, IsPrimary, IsCurrent, CountryId, Region, City, District, Street, BuildingNumber, UnitNumber,
                                PostalCode, AdditionalNumber, ShortCode, PoBoxNumber, [FreeText], CreatedBy)
            OUTPUT inserted.AddressId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @p, @type, @primary, 1, @country, @region, @city, @district, @street, @building, @unit,
                    @postal, @additional, @short, @pobox, @free, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """,
            new
            {
                p = partyId, type, primary, country, region = T(a.Region, 100, "region"), city = T(a.City, 100, "city"), district = T(a.District, 100, "district"),
                street = T(a.Street, 150, "street"), building = T(a.BuildingNumber, 20, "building number"), unit = T(a.UnitNumber, 20, "unit number"),
                postal = T(a.PostalCode, 20, "postal code"), additional = T(a.AdditionalNumber, 20, "additional number"), @short = T(a.ShortCode, 20, "short code"),
                pobox = T(a.PoBoxNumber, 30, "PO box"), free = T(a.FreeText, 500, "text"),
            }, tx, cancellationToken: ct));
    }

    /// <summary>Marks an address no longer current (an address is never deleted, so the records that cite it keep it).</summary>
    public static async Task RetireAddressAsync(SqlConnection c, SqlTransaction tx, long partyId, long addressId, CancellationToken ct)
    {
        var n = await c.ExecuteAsync(new CommandDefinition(
            "UPDATE pty.Address SET IsCurrent = 0, IsPrimary = 0, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE AddressId = @a AND PartyId = @p;",
            new { a = addressId, p = partyId }, tx, cancellationToken: ct));
        if (n == 0) throw ApiProblemException.NotFound();
    }

    public static Task<long> AddContactMethodAsync(SqlConnection c, SqlTransaction tx, long partyId, string? partyCountryIso2, ContactMethodRequest m,
        CancellationToken ct) => AddContactMethodAsync(c, tx, Owner.Party, partyId, partyCountryIso2, m, ct);

    /// <summary>The owner of a contact method: a party, an institution, one of its units or one of its contacts (pty.ContactMethod CHECK 1).</summary>
    public enum Owner { Party, Institution, Unit, Contact }

    private static string Column(Owner o) => o switch
    {
        Owner.Party => "PartyId", Owner.Institution => "InstitutionId", Owner.Unit => "UnitId", _ => "ContactId",
    };

    public static async Task<object[]> MethodsAsync(SqlConnection c, SqlTransaction? tx, Owner owner, long ownerId, OpaqueRefs refs, int tenantId, CancellationToken ct)
    {
        var methods = await c.QueryAsync<(long Id, string Kind, string Value, string NormalizedValue, string? Label, bool IsPrimary)>(new CommandDefinition(
            $"SELECT ContactMethodId, Kind, Value, NormalizedValue, Label, IsPrimary FROM pty.ContactMethod WHERE {Column(owner)} = @o ORDER BY Kind, IsPrimary DESC, ContactMethodId;",
            new { o = ownerId }, tx, cancellationToken: ct));
        return [.. methods.Select(m => (object)new
        {
            id = refs.ItemRef(tenantId, "contact-method", m.Id), kind = m.Kind, value = m.Value, normalizedValue = m.NormalizedValue, label = m.Label, isPrimary = m.IsPrimary,
        })];
    }

    public static async Task<long> AddContactMethodAsync(SqlConnection c, SqlTransaction tx, Owner owner, long ownerId, string? countryIso2, ContactMethodRequest m,
        CancellationToken ct)
    {
        var column = Column(owner);
        var partyId = ownerId;
        var partyCountryIso2 = countryIso2;
        var kind = m.Kind?.Trim().ToUpperInvariant();
        if (kind is null || !Kinds.Contains(kind)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the kind of contact.");
        var value = T(m.Value, 200, "value") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the value.");
        var dial = await c.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT DialCode FROM ref.Country WHERE Iso2 = @iso;",
            new { iso = partyCountryIso2 ?? "SA" }, tx, cancellationToken: ct));
        var normalized = kind switch
        {
            "MOBILE" or "PHONE" or "FAX" => Normalizer.Phone(value, dial) ?? throw ApiProblemException.Invalid("V-PTY-PHONE", "The phone number is not valid."),
            "EMAIL" => Normalizer.Email(value) ?? throw ApiProblemException.Invalid("V-PTY-EMAIL", "The e-mail address is not valid."),
            _ => value.ToLowerInvariant(),
        };
        if (m.IsPrimary == true)
            await c.ExecuteAsync(new CommandDefinition($"UPDATE pty.ContactMethod SET IsPrimary = 0, UpdatedAt = SYSUTCDATETIME() WHERE {column} = @p AND Kind = @kind AND IsPrimary = 1;",
                new { p = partyId, kind }, tx, cancellationToken: ct));
        try
        {
            return await c.ExecuteScalarAsync<long>(new CommandDefinition(
                $"""
                DECLARE @o TABLE (Id BIGINT);
                INSERT pty.ContactMethod (TenantId, {column}, Kind, Value, NormalizedValue, Label, IsPrimary, CreatedBy)
                OUTPUT inserted.ContactMethodId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @p, @kind, @value, @normalized, @label, @primary, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { p = partyId, kind, value, normalized, label = T(m.Label, 100, "label"), primary = m.IsPrimary == true }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "CONTACT_EXISTS", "This contact is already recorded.");
        }
    }

    public static Task DeleteContactMethodAsync(SqlConnection c, SqlTransaction tx, long partyId, long id, CancellationToken ct) =>
        DeleteContactMethodAsync(c, tx, Owner.Party, partyId, id, ct);

    public static async Task DeleteContactMethodAsync(SqlConnection c, SqlTransaction tx, Owner owner, long ownerId, long id, CancellationToken ct)
    {
        var n = await c.ExecuteAsync(new CommandDefinition($"DELETE FROM pty.ContactMethod WHERE ContactMethodId = @id AND {Column(owner)} = @p;", new { id, p = ownerId }, tx,
            cancellationToken: ct));
        if (n == 0) throw ApiProblemException.NotFound();
    }

    public static string Json(object o) => JsonSerializer.Serialize(o);
}
