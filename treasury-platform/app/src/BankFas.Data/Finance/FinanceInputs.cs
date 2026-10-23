using BankFas.Core.Finance;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Finance;

/// <summary>A statement as an input: its id, company, basis, period and the amounts of its lines by code.</summary>
public sealed record StatementInput(long Id, Guid PublicId, int VersionNo, long CompanyId, string Basis, string Assurance, string PeriodType, DateTime PeriodEnd, int CurrencyId,
    IReadOnlyDictionary<string, decimal?> Lines);

/// <summary>
/// What a formula reads from the database (BR-FIN-003, BR-FIN-009): the line amounts of a statement as the database
/// reads them (the entered amount, else the computed one), the approved statement of the same series k periods
/// before (PRIOR), and the tenant's known codes. Shared by the preview, the analysis measures and the covenant engine.
/// </summary>
public static class FinanceInputs
{
    /// <summary>The codes a formula may name: the tenant's statement lines.</summary>
    public static async Task<HashSet<string>> CodesAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct) =>
        [.. await c.QueryAsync<string>(new CommandDefinition("SELECT Code FROM fin.LineCatalogItem;", transaction: tx, cancellationToken: ct)).ConfigureAwait(false)];

    private sealed record Head(long Id, Guid PublicId, int VersionNo, long CompanyId, string Basis, string Assurance, string PeriodType, DateTime PeriodEnd, int CurrencyId);

    public static async Task<StatementInput?> StatementAsync(SqlConnection c, SqlTransaction? tx, long statementId, CancellationToken ct)
    {
        var h = await c.QuerySingleOrDefaultAsync<Head>(new CommandDefinition(
            "SELECT FinancialStatementId AS Id, PublicId, VersionNo, CompanyId, Basis, Assurance, PeriodType, PeriodEnd, CurrencyId FROM fin.FinancialStatement WHERE FinancialStatementId = @s;",
            new { s = statementId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (h is null) return null;
        var lines = (await c.QueryAsync<(string Code, decimal? Amount)>(new CommandDefinition(
            """
            SELECT li.Code, COALESCE(l.EnteredAmount, l.ComputedAmount)
              FROM fin.StatementLine AS l JOIN fin.LineCatalogItem AS li ON li.LineCatalogItemId = l.LineCatalogItemId
             WHERE l.StatementId = @s;
            """, new { s = statementId }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToDictionary(x => x.Code, x => x.Amount, StringComparer.Ordinal);
        return new StatementInput(h.Id, h.PublicId, h.VersionNo, h.CompanyId, h.Basis, h.Assurance, h.PeriodType, h.PeriodEnd, h.CurrencyId, lines);
    }

    /// <summary>The months of a period type.</summary>
    public static int Months(string periodType) => periodType switch { "ANNUAL" => 12, "SEMIANNUAL" => 6, "QUARTERLY" => 3, _ => 1 };

    /// <summary>The approved statement of the same company, basis and period type k periods before, audited first (BR-FIN-003).</summary>
    public static async Task<StatementInput?> PriorAsync(SqlConnection c, SqlTransaction? tx, StatementInput s, int k, CancellationToken ct)
    {
        var start = new DateTime(s.PeriodEnd.Year, s.PeriodEnd.Month, 1).AddMonths(-Months(s.PeriodType) * k);
        var end = start.AddMonths(1).AddDays(-1);
        var id = await c.ExecuteScalarAsync<long?>(new CommandDefinition(
            """
            SELECT TOP (1) FinancialStatementId FROM fin.FinancialStatement
             WHERE CompanyId = @c AND Basis = @b AND PeriodType = @p AND PeriodEnd = @e AND Status = 'APPROVED' AND Nature = 'ACTUAL'
             ORDER BY CASE Assurance WHEN 'AUDITED' THEN 0 WHEN 'REVIEWED' THEN 1 ELSE 2 END;
            """, new { c = s.CompanyId, b = s.Basis, p = s.PeriodType, e = end }, tx, cancellationToken: ct)).ConfigureAwait(false);
        return id is { } x ? await StatementAsync(c, tx, x, ct).ConfigureAwait(false) : null;
    }

    /// <summary>The statement inputs of a formula on a statement, with the earlier statements PRIOR, SUM and the like read.</summary>
    public static async Task<(DictionaryInputs Inputs, List<StatementInput> Read)> ForStatementAsync(SqlConnection c, SqlTransaction? tx, StatementInput s, FormulaNode tree,
        IReadOnlyDictionary<string, decimal?>? extra, CancellationToken ct)
    {
        var current = new Dictionary<string, decimal?>(s.Lines, StringComparer.Ordinal);
        if (extra is not null) foreach (var (k, v) in extra) current[k] = v;
        var read = new List<StatementInput> { s };
        var earlier = new List<IReadOnlyDictionary<string, decimal?>>();
        for (var k = 1; k <= Formula.Lookback(tree); k++)
        {
            var prior = await PriorAsync(c, tx, s, k, ct).ConfigureAwait(false);
            if (prior is not null) read.Add(prior);
            earlier.Add(prior?.Lines ?? new Dictionary<string, decimal?>());
        }
        return (new DictionaryInputs(current, earlier), read);
    }
}
