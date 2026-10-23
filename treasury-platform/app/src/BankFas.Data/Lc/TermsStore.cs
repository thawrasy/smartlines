using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BankFas.Core.Lc;
using BankFas.Core.Text;
using BankFas.Core.Workflow;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>
/// The terms of a letter-of-credit request (spec 14 sections 5 and 6.2; S3 batch E): one lc.LcTerms version per request
/// and purpose, written as a draft with its document clauses and charges and locked by lc.validate_terms at the
/// submission (BR-LCT-019). A locked version changes only in its treasury fields until TreasuryHash (044); a change of
/// the requester's fields after a return supersedes it with a new draft version. Values travel as the field keys of
/// the dictionary (LC.BASE); the column of each key is fixed here, and a key the requester may not set is refused.
/// </summary>
public static class TermsStore
{
    private enum Kind { Text, Int, Dec, Date, Bool, Enum, Currency, Incoterm, Counterparty, Account }

    private sealed record Col(string Column, Kind Kind, bool Treasury = false, int Max = 0);

    private static readonly Dictionary<string, Col> Map = new(StringComparer.Ordinal)
    {
        ["scope"] = new("Scope", Kind.Enum), ["lcType"] = new("LcType", Kind.Enum), ["deferralDays"] = new("DeferralDays", Kind.Int),
        ["maturityBasis"] = new("MaturityBasis", Kind.Enum), ["mixedPaymentText"] = new("MixedPaymentText", Kind.Text, Max: 500),
        ["availableWith"] = new("AvailableWith", Kind.Enum), ["draftRequired"] = new("DraftRequired", Kind.Bool), ["draftDrawee"] = new("DraftDrawee", Kind.Enum),
        ["confirmation"] = new("Confirmation", Kind.Enum), ["confirmingBankName"] = new("ConfirmingBankName", Kind.Text, Max: 200),
        ["confirmingBankBic"] = new("ConfirmingBankBic", Kind.Text, Max: 11), ["isTransferable"] = new("IsTransferable", Kind.Bool),
        ["assignmentOfProceedsText"] = new("AssignmentOfProceedsText", Kind.Text, Max: 500), ["beneficiary"] = new("BeneficiaryCounterpartyId", Kind.Counterparty),
        ["advisingBankName"] = new("AdvisingBankName", Kind.Text, Max: 200), ["advisingBankAddress"] = new("AdvisingBankAddress", Kind.Text, Max: 300),
        ["advisingBankBic"] = new("AdvisingBankBic", Kind.Text, Max: 11), ["currencyId"] = new("CurrencyId", Kind.Currency), ["amount"] = new("Amount", Kind.Dec),
        ["toleranceMode"] = new("ToleranceMode", Kind.Enum), ["tolerancePlusPct"] = new("TolerancePlusPct", Kind.Dec), ["toleranceMinusPct"] = new("ToleranceMinusPct", Kind.Dec),
        ["expiryRule"] = new("ExpiryRule", Kind.Enum), ["expiryDate"] = new("ExpiryDate", Kind.Date), ["expiryDaysAfterIssue"] = new("ExpiryDaysAfterIssue", Kind.Int),
        ["expiryPlace"] = new("ExpiryPlace", Kind.Text, Max: 200), ["earliestShipmentDate"] = new("EarliestShipmentDate", Kind.Date),
        ["latestShipmentRule"] = new("LatestShipmentRule", Kind.Enum), ["latestShipmentDate"] = new("LatestShipmentDate", Kind.Date),
        ["latestShipmentDaysAfterIssue"] = new("LatestShipmentDaysAfterIssue", Kind.Int), ["presentationDays"] = new("PresentationDays", Kind.Int),
        ["presentationBasis"] = new("PresentationBasis", Kind.Enum), ["expectedIssueDate"] = new("ExpectedIssueDate", Kind.Date),
        ["partialShipments"] = new("PartialShipments", Kind.Enum), ["installmentShipments"] = new("InstallmentShipments", Kind.Text, Max: 300),
        ["transhipment"] = new("Transhipment", Kind.Enum), ["transportMode"] = new("TransportMode", Kind.Enum),
        ["placeOfDispatch"] = new("PlaceOfDispatch", Kind.Text, Max: 150), ["placeOfFinalDestination"] = new("PlaceOfFinalDestination", Kind.Text, Max: 150),
        ["portOfLoading"] = new("PortOfLoading", Kind.Text, Max: 150), ["portOfDischarge"] = new("PortOfDischarge", Kind.Text, Max: 150),
        ["airportOfDeparture"] = new("AirportOfDeparture", Kind.Text, Max: 150), ["airportOfDestination"] = new("AirportOfDestination", Kind.Text, Max: 150),
        ["incotermId"] = new("IncotermId", Kind.Incoterm), ["incotermPlace"] = new("IncotermPlace", Kind.Text, Max: 150), ["goodsCategory"] = new("GoodsCategory", Kind.Text, Max: 80),
        ["goodsDescription"] = new("GoodsDescription", Kind.Text, Max: 2000), ["supplierProformaNo"] = new("SupplierProformaNo", Kind.Text, Max: 60),
        ["supplierProformaDate"] = new("SupplierProformaDate", Kind.Date), ["insuranceResponsibility"] = new("InsuranceResponsibility", Kind.Enum),
        ["insuranceMinPct"] = new("InsuranceMinPct", Kind.Dec), ["insurancePctStated"] = new("InsurancePctStated", Kind.Bool),
        ["insuranceClauses"] = new("InsuranceClauses", Kind.Text, Max: 300), ["bankMayArrangeInsurance"] = new("BankMayArrangeInsurance", Kind.Bool),
        ["additionalConditions"] = new("AdditionalConditions", Kind.Text, Max: 2000), ["lcTextLanguage"] = new("LcTextLanguage", Kind.Enum),
        ["prevLcNumber"] = new("PrevLcNumber", Kind.Text, Max: 60), ["prevLcAmount"] = new("PrevLcAmount", Kind.Dec), ["prevLcCurrencyId"] = new("PrevLcCurrencyId", Kind.Currency),
        ["prevLcUtilizedAmount"] = new("PrevLcUtilizedAmount", Kind.Dec), ["prevLcOpenedBy"] = new("PrevLcOpenedBy", Kind.Text, Max: 200),
        // The treasury's fields (FR-LCT-021, FR-LCI-007): not shown to the requester, changed by lc.terms.treasury.edit, also after the lock.
        ["marginPct"] = new("MarginPct", Kind.Dec, true), ["debitAuthorization"] = new("DebitAuthorization", Kind.Enum, true),
        ["marginHeldCurrency"] = new("MarginHeldCurrency", Kind.Enum, true), ["facilityAccountId"] = new("FacilityAccountId", Kind.Account, true),
        ["marginSettlementAccountId"] = new("MarginSettlementAccountId", Kind.Account, true), ["chargesAccountId"] = new("ChargesAccountId", Kind.Account, true),
        ["postDeferralFinancingDays"] = new("PostDeferralFinancingDays", Kind.Int, true), ["bankSpecificClauses"] = new("BankSpecificClauses", Kind.Text, true, 4000),
    };

    public sealed class TermsRow
    {
        public long LcTermsId { get; init; }
        public Guid PublicId { get; init; }
        public int VersionNo { get; init; }
        public string Status { get; init; } = "";
        public string LcClass { get; init; } = "";
        public string Scope { get; init; } = "";
        public string Purpose { get; init; } = "";
        public decimal? Amount { get; init; }
        public int? CurrencyId { get; init; }
        public decimal TolerancePlusPct { get; init; }
        public byte[]? SnapshotHash { get; init; }
        public byte[]? TreasuryHash { get; init; }
    }

    /// <summary>The current (not superseded) application terms of a request, if any.</summary>
    public static async Task<TermsRow?> CurrentAsync(SqlConnection c, SqlTransaction? tx, long requestId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<TermsRow>(new CommandDefinition(
            """
            SELECT LcTermsId, PublicId, VersionNo, Status, LcClass, Scope, Purpose, Amount, CurrencyId, TolerancePlusPct, SnapshotHash, TreasuryHash
              FROM lc.LcTerms WHERE OwnerType = 'REQUEST' AND OwnerId = @r AND Purpose = 'APPLICATION' AND Status <> 'SUPERSEDED';
            """, new { r = requestId }, tx, cancellationToken: ct)).ConfigureAwait(false);

    /// <summary>The draft terms of a purchase request, written once with the company as applicant and the charges of the OWN_BANK preset (14m section 5.5).</summary>
    public static async Task<TermsRow> EnsureAsync(SqlConnection c, SqlTransaction tx, long requestId, long companyId, CancellationToken ct)
    {
        if (await CurrentAsync(c, tx, requestId, ct).ConfigureAwait(false) is { } t) return t;
        var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LcTerms (TenantId, OwnerType, OwnerId, Purpose, VersionNo, Status, LcClass, Scope, ApplicantCompanyId, PresentationDays, CreatedBy)
            OUTPUT inserted.LcTermsId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'REQUEST', @r, 'APPLICATION', 1, 'DRAFT', 'PURCHASE', 'INTERNATIONAL', @co, 21,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { r = requestId, co = companyId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await ChargesPresetAsync(c, tx, id, "OWN_BANK", ct).ConfigureAwait(false);
        return (await CurrentAsync(c, tx, requestId, ct).ConfigureAwait(false))!;
    }

    /// <summary>The presets of the charges matrix (14m section 5.5): OWN_BANK puts the issuing bank's and the amendment charges on the applicant and the rest on the beneficiary.</summary>
    public static async Task ChargesPresetAsync(SqlConnection c, SqlTransaction tx, long termsId, string preset, CancellationToken ct)
    {
        string Payer(string cat) => preset switch
        {
            "ALL_APPLICANT" => "APPLICANT",
            "ALL_BENEFICIARY" => "BENEFICIARY",
            "SPLIT_50" => "SHARED",
            _ => cat is "ISSUING_BANK_LOCAL" or "AMENDMENT" ? "APPLICANT" : "BENEFICIARY",
        };
        // The matrix keeps one row per category; a preset rewrites the rows in place (the table takes no delete).
        foreach (var cat in TermsRules.ChargeCategories)
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE lc.LcChargesMatrix SET Payer = @payer, ApplicantSharePct = @share, PresetCode = @preset, UpdatedAt = SYSUTCDATETIME(),
                       UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE LcTermsId = @t AND ChargeCategory = @cat;
                IF @@ROWCOUNT = 0
                    INSERT lc.LcChargesMatrix (TenantId, LcTermsId, ChargeCategory, Payer, ApplicantSharePct, PresetCode, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, @cat, @payer, @share, @preset, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new { t = termsId, cat, payer = Payer(cat), share = Payer(cat) == "SHARED" ? 50m : (decimal?)null, preset }, tx, cancellationToken: ct)).ConfigureAwait(false);
    }

    /// <summary>
    /// Writes the given fields (key → value; null clears). Requester fields only while the version is a draft: after a
    /// return, the locked version is superseded by a draft copy first. Treasury fields need the treasury permission
    /// and change also on a locked version until its TreasuryHash.
    /// </summary>
    public static async Task<TermsRow> UpdateAsync(SqlConnection c, SqlTransaction tx, long requestId, long companyId, JsonElement values, bool treasury, bool mayEditRequester,
        CancellationToken ct)
    {
        var t = await EnsureAsync(c, tx, requestId, companyId, ct).ConfigureAwait(false);
        var sets = new List<string>();
        var p = new DynamicParameters();
        var requesterChange = false;
        foreach (var prop in values.EnumerateObject())
        {
            if (!Map.TryGetValue(prop.Name, out var col)) throw WorkflowRefusalException.Missing("V-LCT-FIELD", $"The terms have no field {prop.Name} that may be set.");
            if (col.Treasury && !treasury) throw WorkflowRefusalException.Forbidden("Only the treasury sets its own fields of the terms.");
            if (!col.Treasury)
            {
                if (!mayEditRequester) throw WorkflowRefusalException.State("The requester's terms change only while the request is a draft or returned.");
                requesterChange = true;
            }
            var name = "@v" + sets.Count.ToString(CultureInfo.InvariantCulture);
            p.Add(name, await ValueAsync(c, tx, col, prop.Name, prop.Value, ct).ConfigureAwait(false));
            sets.Add($"[{col.Column}] = {name}");
        }
        if (sets.Count == 0) return t;
        if (requesterChange && t.Status == "LOCKED") t = await NewVersionAsync(c, tx, t, requestId, ct).ConfigureAwait(false);
        if (!requesterChange && t.TreasuryHash is not null) throw WorkflowRefusalException.State("The treasury's terms are locked.");
        p.Add("@t", t.LcTermsId);
        await c.ExecuteAsync(new CommandDefinition(
            $"UPDATE lc.LcTerms SET {string.Join(", ", sets)}, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE LcTermsId = @t;",
            p, tx, cancellationToken: ct)).ConfigureAwait(false);
        return (await CurrentAsync(c, tx, requestId, ct).ConfigureAwait(false))!;
    }

    private static async Task<object?> ValueAsync(SqlConnection c, SqlTransaction tx, Col col, string key, JsonElement v, CancellationToken ct)
    {
        if (v.ValueKind == JsonValueKind.Null) return null;
        WorkflowRefusalException Bad() => WorkflowRefusalException.Missing("V-LCT-FIELD", $"The value of {key} is not valid.");
        switch (col.Kind)
        {
            case Kind.Text:
            case Kind.Enum:
                var s = v.ValueKind == JsonValueKind.String ? v.GetString()!.Trim() : throw Bad();
                if (col.Max > 0 && s.Length > col.Max) throw WorkflowRefusalException.Missing("V-LCT-FIELD", $"{key} is up to {col.Max} characters.");
                return s.Length == 0 ? null : col.Kind == Kind.Enum ? s.ToUpperInvariant() : s;
            case Kind.Int: return v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : throw Bad();
            case Kind.Dec: return v.ValueKind == JsonValueKind.Number ? v.GetDecimal() : throw Bad();
            case Kind.Bool: return v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : throw Bad();
            case Kind.Date: return v.ValueKind == JsonValueKind.String && DateOnly.TryParse(v.GetString(), CultureInfo.InvariantCulture, out var d) ? d.ToDateTime(TimeOnly.MinValue) : throw Bad();
            case Kind.Currency:
                return await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @x AND IsActive = 1;", new { x = v.GetString() }, tx,
                    cancellationToken: ct)).ConfigureAwait(false) ?? throw Bad();
            case Kind.Incoterm:
                return await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT IncotermId FROM ref.Incoterm WHERE Code = @x AND Status = 'ACTIVE';", new { x = v.GetString() }, tx,
                    cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.Missing("V-LCT-09", "The Incoterm is not an active one.");
            case Kind.Counterparty:
                return Guid.TryParse(v.GetString(), out var cp) ? await c.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT CounterpartyId FROM lc.Counterparty WHERE PublicId = @cp AND IsActive = 1;", new { cp }, tx, cancellationToken: ct)).ConfigureAwait(false) ?? throw Bad() : throw Bad();
            case Kind.Account:
                return Guid.TryParse(v.GetString(), out var acc) ? await c.ExecuteScalarAsync<long?>(new CommandDefinition(
                    "SELECT BankAccountId FROM acc.BankAccount WHERE PublicId = @acc;", new { acc }, tx, cancellationToken: ct)).ConfigureAwait(false) ?? throw Bad() : throw Bad();
            default: throw Bad();
        }
    }

    /// <summary>FR-LCT-002: a new draft version copies the locked one (its fields, clauses and charges) and supersedes it.</summary>
    private static async Task<TermsRow> NewVersionAsync(SqlConnection c, SqlTransaction tx, TermsRow t, long requestId, CancellationToken ct)
    {
        var cols = (await c.QueryAsync<string>(new CommandDefinition(
            """
            SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'lc.LcTerms') AND is_computed = 0 AND system_type_id <> 189
               AND name NOT IN ('LcTermsId', 'PublicId', 'VersionNo', 'Status', 'SnapshotHash', 'TreasuryHash', 'LockedAt', 'LockedBy', 'SupersedesTermsId', 'CreatedAt',
                                'CreatedBy', 'UpdatedAt', 'UpdatedBy', 'AmountInWordsAr', 'AmountInWordsEn', 'ChangeReason');
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).Select(n => $"[{n}]").ToList();
        await c.ExecuteAsync(new CommandDefinition("UPDATE lc.LcTerms SET Status = 'SUPERSEDED' WHERE LcTermsId = @t AND Status = 'LOCKED';", new { t = t.LcTermsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            $"""
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LcTerms ({string.Join(", ", cols)}, VersionNo, Status, SupersedesTermsId, CreatedBy)
            OUTPUT inserted.LcTermsId INTO @o
            SELECT {string.Join(", ", cols)}, VersionNo + 1, 'DRAFT', LcTermsId, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) FROM lc.LcTerms WHERE LcTermsId = @t;
            DECLARE @n BIGINT = (SELECT Id FROM @o);
            INSERT lc.LcTermsDocument (TenantId, LcTermsId, SeqNo, ClauseId, ClauseVersion, Originals, Copies, ParamsJson, IsFreeText, [FreeText], CreatedBy)
            SELECT TenantId, @n, SeqNo, ClauseId, ClauseVersion, Originals, Copies, ParamsJson, IsFreeText, [FreeText], CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM lc.LcTermsDocument WHERE LcTermsId = @t;
            INSERT lc.LcChargesMatrix (TenantId, LcTermsId, ChargeCategory, Payer, ApplicantSharePct, PresetCode, Note, CreatedBy)
            SELECT TenantId, @n, ChargeCategory, Payer, ApplicantSharePct, PresetCode, Note, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM lc.LcChargesMatrix WHERE LcTermsId = @t;
            SELECT @n;
            """, new { t = t.LcTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        _ = id;
        return (await CurrentAsync(c, tx, requestId, ct).ConfigureAwait(false))!;
    }

    /// <summary>The document clauses of a draft version: replaced as a list of (clause code, originals, copies, parameters) or free texts (FR-LCT-018).</summary>
    public static async Task SetDocumentsAsync(SqlConnection c, SqlTransaction tx, TermsRow t, JsonElement items, CancellationToken ct)
    {
        if (t.Status != "DRAFT") throw WorkflowRefusalException.State("The documents of locked terms do not change.");
        await c.ExecuteAsync(new CommandDefinition("DELETE FROM lc.LcTermsDocument WHERE LcTermsId = @t;", new { t = t.LcTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var seq = 0;
        foreach (var it in items.EnumerateArray())
        {
            seq++;
            var code = it.TryGetProperty("clause", out var cl) ? cl.GetString() : null;
            var free = it.TryGetProperty("freeText", out var ft) ? ft.GetString()?.Trim() : null;
            var clause = await c.QuerySingleOrDefaultAsync<(long Id, int Version)?>(new CommandDefinition(
                """
                SELECT TOP (1) LcDocumentClauseId, VersionNo FROM lc.LcDocumentClause
                 WHERE Code = @code AND Status = 'ACTIVE' ORDER BY VersionNo DESC;
                """, new { code = code ?? "OTHER_FREE_TEXT" }, tx, cancellationToken: ct)).ConfigureAwait(false)
                ?? throw WorkflowRefusalException.Missing("V-LCT-CLAUSE", $"The clause {code} is not in the library.");
            int? Int(string k) => it.TryGetProperty(k, out var x) && x.ValueKind == JsonValueKind.Number ? x.GetInt32() : null;
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT lc.LcTermsDocument (TenantId, LcTermsId, SeqNo, ClauseId, ClauseVersion, Originals, Copies, ParamsJson, IsFreeText, [FreeText], CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @t, @seq, @clause, @ver, @orig, @copies, @params, @isFree, @free, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """,
                new
                {
                    t = t.LcTermsId, seq, clause = clause.Id, ver = clause.Version, orig = Int("originals"), copies = Int("copies"),
                    @params = it.TryGetProperty("params", out var pj) && pj.ValueKind == JsonValueKind.Object ? pj.GetRawText() : null,
                    isFree = free is { Length: > 0 }, free = free is { Length: > 0 } ? free : null,
                }, tx, cancellationToken: ct)).ConfigureAwait(false);
        }
    }

    /// <summary>The fields of a version as keys and values, the requester's or all of them.</summary>
    public static async Task<Dictionary<string, object?>> ReadAsync(SqlConnection c, SqlTransaction? tx, long termsId, bool treasury, CancellationToken ct)
    {
        var row = (IDictionary<string, object?>)await c.QuerySingleAsync(new CommandDefinition(
            """
            SELECT t.*, cur.Code AS CurrencyCode, inc.Code AS IncotermCode, pc.Code AS PrevLcCurrencyCode, cp.PublicId AS BeneficiaryRef, cp.NameEn AS BeneficiaryNameEn,
                   fa.PublicId AS FacilityAccountRef, ma.PublicId AS MarginSettlementAccountRef, ca.PublicId AS ChargesAccountRef
              FROM lc.LcTerms AS t
              LEFT JOIN ref.Currency AS cur ON cur.CurrencyId = t.CurrencyId LEFT JOIN ref.Incoterm AS inc ON inc.IncotermId = t.IncotermId
              LEFT JOIN ref.Currency AS pc ON pc.CurrencyId = t.PrevLcCurrencyId LEFT JOIN lc.Counterparty AS cp ON cp.CounterpartyId = t.BeneficiaryCounterpartyId
              LEFT JOIN acc.BankAccount AS fa ON fa.BankAccountId = t.FacilityAccountId LEFT JOIN acc.BankAccount AS ma ON ma.BankAccountId = t.MarginSettlementAccountId
              LEFT JOIN acc.BankAccount AS ca ON ca.BankAccountId = t.ChargesAccountId
             WHERE t.LcTermsId = @t;
            """, new { t = termsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var r = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var (key, col) in Map)
        {
            if (col.Treasury && !treasury) continue;
            var v = col.Kind switch
            {
                Kind.Currency => row[col.Column == "CurrencyId" ? "CurrencyCode" : "PrevLcCurrencyCode"],
                Kind.Incoterm => row["IncotermCode"],
                Kind.Counterparty => row["BeneficiaryRef"],
                Kind.Account => row[col.Column.Replace("Id", "Ref", StringComparison.Ordinal)],
                Kind.Date => row[col.Column] is DateTime d ? DateOnly.FromDateTime(d).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : null,
                _ => row[col.Column],
            };
            r[key] = v;
        }
        r["lcClass"] = row["LcClass"];
        r["amountInWordsAr"] = row["AmountInWordsAr"];
        r["amountInWordsEn"] = row["AmountInWordsEn"];
        r["beneficiaryName"] = row["BeneficiaryNameEn"];
        return r;
    }

    // ---------- lc.validate_terms ----------

    /// <summary>The required fields of the dictionary for the class, scope and purpose (BR-LCT-002), without the computed ones and those checked on their own.</summary>
    private static async Task<List<(string Key, string Label)>> RequiredAsync(SqlConnection c, SqlTransaction tx, TermsRow t, CancellationToken ct)
    {
        var defs = await c.QueryAsync<(string FieldKey, string LabelEn, string ApplicabilityJson, string DataType)>(new CommandDefinition(
            "SELECT FieldKey, LabelEn, ApplicabilityJson, DataType FROM lc.LcFieldDefinition WHERE IsActive = 1;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false);
        var list = new List<(string, string)>();
        foreach (var d in defs)
        {
            if (d.DataType == "COMPUTED" || d.FieldKey is "documents" or "charges" or "applicant" or "lcClass" or "ucpVersion") continue;
            using var doc = JsonDocument.Parse(d.ApplicabilityJson);
            if (doc.RootElement.TryGetProperty(t.LcClass, out var k) && k.TryGetProperty(t.Scope, out var s) && s.TryGetProperty(t.Purpose, out var p) && p.GetString() == "REQUIRED")
                list.Add((d.FieldKey, d.LabelEn));
        }
        return list;
    }

    /// <summary>The findings of a version (V-LCT); errors block the lock.</summary>
    public static async Task<IReadOnlyList<TermsFinding>> CheckAsync(SqlConnection c, SqlTransaction tx, TermsRow t, DateOnly today, CancellationToken ct)
    {
        var v = await ReadAsync(c, tx, t.LcTermsId, true, ct).ConfigureAwait(false);
        var settings = (await c.QueryAsync<(string Key, string? Value)>(new CommandDefinition(
            """
            SELECT d.[Key], ISNULL(s.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS s ON s.[Key] = d.[Key]
             WHERE d.[Key] IN ('lc.warn.tolerance_pct', 'lc.presentation.default_days');
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false)).ToDictionary(x => x.Key, x => x.Value);
        var warn = decimal.TryParse(settings.GetValueOrDefault("lc.warn.tolerance_pct"), NumberStyles.Number, CultureInfo.InvariantCulture, out var w) ? w : 10m;
        var pres = int.TryParse(settings.GetValueOrDefault("lc.presentation.default_days"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var pd) ? pd : 21;
        var docs = await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM lc.LcTermsDocument WHERE LcTermsId = @t;", new { t = t.LcTermsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        var cats = (await c.QueryAsync<string>(new CommandDefinition("SELECT ChargeCategory FROM lc.LcChargesMatrix WHERE LcTermsId = @t;", new { t = t.LcTermsId }, tx,
            cancellationToken: ct)).ConfigureAwait(false)).ToHashSet(StringComparer.Ordinal);
        static DateOnly? D(object? o) => o is string s && DateOnly.TryParse(s, CultureInfo.InvariantCulture, out var d) ? d : null;
        static string? S(object? o) => o as string;
        static int? I(object? o) => o is int i ? i : null;
        static decimal? M(object? o) => o is decimal m ? m : null;
        var facts = new TermsFacts
        {
            LcClass = t.LcClass, Scope = t.Scope, LcType = S(v["lcType"]), DeferralDays = I(v["deferralDays"]), MaturityBasis = S(v["maturityBasis"]),
            MixedPaymentText = S(v["mixedPaymentText"]), DraftRequired = v["draftRequired"] as bool?, DraftDrawee = S(v["draftDrawee"]),
            ConfirmingBankBic = S(v["confirmingBankBic"]), AdvisingBankBic = S(v["advisingBankBic"]), Amount = M(v["amount"]), ToleranceMode = S(v["toleranceMode"]) ?? "NONE",
            TolerancePlusPct = M(v["tolerancePlusPct"]) ?? 0, ToleranceMinusPct = M(v["toleranceMinusPct"]) ?? 0, ExpiryRule = S(v["expiryRule"]), ExpiryDate = D(v["expiryDate"]),
            ExpiryDaysAfterIssue = I(v["expiryDaysAfterIssue"]), EarliestShipmentDate = D(v["earliestShipmentDate"]), LatestShipmentRule = S(v["latestShipmentRule"]),
            LatestShipmentDate = D(v["latestShipmentDate"]), LatestShipmentDaysAfterIssue = I(v["latestShipmentDaysAfterIssue"]), PresentationDays = I(v["presentationDays"]),
            HasIncoterm = v["incotermId"] is not null, IncotermPlace = S(v["incotermPlace"]), DocumentCount = docs, ChargeCategories = cats,
            DebitAuthorization = S(v["debitAuthorization"]), MarginPct = M(v["marginPct"]), PrevLcAmount = M(v["prevLcAmount"]), PrevLcUtilizedAmount = M(v["prevLcUtilizedAmount"]),
            Filled = v.Where(kv => kv.Value is not null && !(kv.Value is string s && s.Length == 0)).Select(kv => kv.Key).ToHashSet(StringComparer.Ordinal),
        };
        return TermsRules.Check(facts, await RequiredAsync(c, tx, t, ct).ConfigureAwait(false), today, warn, pres);
    }

    /// <summary>
    /// lc.validate_terms (14m FR-LCT-023, BR-LCT-019): on SUBMIT and RESUBMIT the draft terms are checked; an error refuses
    /// the action with its findings; otherwise the version is locked with its amount in words, its hash, time and user,
    /// and the request takes the terms' amount and currency. Terms already locked pass unchanged.
    /// </summary>
    public static async Task<object?> ValidateHookAsync(RequestEngine.HookContext h)
    {
        var t = await CurrentAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "The terms of the letter of credit are required.");
        if (t.Status == "LOCKED") return new { termsId = t.LcTermsId, version = t.VersionNo, locked = true };
        var findings = await CheckAsync(h.C, h.Tx, t, DateOnly.FromDateTime(h.Now.UtcDateTime), h.Ct).ConfigureAwait(false);
        var errors = findings.Where(f => f.IsError).ToList();
        if (errors.Count > 0)
            throw new WorkflowRefusalException(422, errors[0].Code, string.Join(" ", errors.Select(e => e.Message)));
        var cur = await h.C.QuerySingleAsync<(string NameAr, string NameEn, int Decimals)>(new CommandDefinition(
            "SELECT NameAr, NameEn, Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = t.CurrencyId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var amount = Math.Round(t.Amount!.Value, cur.Decimals, MidpointRounding.AwayFromZero);
        var fields = await ReadAsync(h.C, h.Tx, t.LcTermsId, false, h.Ct).ConfigureAwait(false);
        var docs = await h.C.QueryAsync<string>(new CommandDefinition(
            "SELECT CONCAT(SeqNo, ':', ClauseId, ':', ClauseVersion, ':', Originals, ':', Copies, ':', ParamsJson, ':', [FreeText]) FROM lc.LcTermsDocument WHERE LcTermsId = @t ORDER BY SeqNo;",
            new { t = t.LcTermsId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var charges = await h.C.QueryAsync<string>(new CommandDefinition(
            "SELECT CONCAT(ChargeCategory, ':', Payer, ':', ApplicantSharePct) FROM lc.LcChargesMatrix WHERE LcTermsId = @t ORDER BY ChargeCategory;",
            new { t = t.LcTermsId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var b = new StringBuilder();
        using (var json = JsonDocument.Parse(JsonSerializer.Serialize(new { fields, docs, charges }))) Snapshot.Canonical(json.RootElement, b);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(b.ToString()));
        var n = await h.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcTerms SET AmountInWordsAr = @ar, AmountInWordsEn = @en, SnapshotHash = @hash, LockedAt = SYSUTCDATETIME(), LockedBy = @u, Status = 'LOCKED'
             WHERE LcTermsId = @t AND Status = 'DRAFT';
            UPDATE wfl.Request SET Amount = @amount, CurrencyId = @c WHERE RequestId = @r;
            """,
            new
            {
                ar = AmountInWords.Arabic(amount, cur.NameAr, cur.Decimals), en = AmountInWords.English(amount, cur.NameEn, cur.Decimals), hash, u = h.Actor.UserId,
                t = t.LcTermsId, amount, c = t.CurrencyId, r = h.Request.RequestId,
            }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        if (n < 2) throw WorkflowRefusalException.Conflict();
        await Outbox.EmitAsync(h.C, h.Tx, "lc.terms.locked", "lc.LcTerms", t.LcTermsId, new { termsId = t.LcTermsId }, h.Ct).ConfigureAwait(false);
        return new { termsId = t.LcTermsId, version = t.VersionNo, warnings = findings.Where(f => !f.IsError).Select(f => f.Code) };
    }
}
