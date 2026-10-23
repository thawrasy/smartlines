using BankFas.Core.Finance;

namespace BankFas.Core.Tests.Finance;

public sealed class FormulaTests
{
    private static readonly HashSet<string> Codes = new(StringComparer.Ordinal)
    {
        "TOTAL_CA", "TOTAL_CL", "INVENTORY", "AR", "REVENUE", "COGS", "AP", "EBITDA", "FINANCE_COSTS", "CASH", "ST_LOANS", "BANK_ACCEPTANCES", "CURRENT_PORTION_LTD",
        "LT_LOANS", "LEASE_LIABS", "TOTAL_EQUITY", "PRINCIPAL_REPAID", "INTEREST_PAID", "INTANGIBLES", "DUE_FROM_RELATED", "GROSS_PROFIT", "NET_PROFIT",
    };

    private static readonly Dictionary<string, decimal?> Fixture = new()
    {
        ["TOTAL_CA"] = 25_000_000, ["TOTAL_CL"] = 12_000_000, ["INVENTORY"] = 5_000_000, ["AR"] = 8_000_000, ["REVENUE"] = 100_000_000, ["COGS"] = 70_000_000,
        ["AP"] = 4_000_000, ["EBITDA"] = 18_000_000, ["FINANCE_COSTS"] = 2_000_000, ["CASH"] = 12_000_000, ["ST_LOANS"] = 6_000_000, ["BANK_ACCEPTANCES"] = 0,
        ["CURRENT_PORTION_LTD"] = 2_000_000, ["LT_LOANS"] = 10_000_000, ["LEASE_LIABS"] = 3_000_000, ["TOTAL_EQUITY"] = 25_000_000, ["PRINCIPAL_REPAID"] = 4_000_000,
        ["INTEREST_PAID"] = 2_000_000, ["INTANGIBLES"] = 1_000_000, ["DUE_FROM_RELATED"] = 500_000, ["GROSS_PROFIT"] = 30_000_000, ["NET_PROFIT"] = 12_500_000,
        ["FLOW_TO_BANK"] = 15_900_000,
    };

    [Theory]
    [InlineData("TOTAL_CA / TOTAL_CL", "2.0833")]
    [InlineData("(TOTAL_CA - INVENTORY) / TOTAL_CL", "1.6667")]
    [InlineData("(ST_LOANS + BANK_ACCEPTANCES + CURRENT_PORTION_LTD + LT_LOANS + LEASE_LIABS) / TOTAL_EQUITY", "0.8400")]
    [InlineData("(ST_LOANS + BANK_ACCEPTANCES + CURRENT_PORTION_LTD + LT_LOANS + LEASE_LIABS - CASH) / EBITDA", "0.5000")]
    [InlineData("EBITDA / (PRINCIPAL_REPAID + INTEREST_PAID)", "3.0000")]
    [InlineData("TOTAL_EQUITY - INTANGIBLES - DUE_FROM_RELATED", "23500000.0000")]
    [InlineData("FLOW_TO_BANK / REVENUE * 100", "15.9000")]
    [InlineData("AR / REVENUE * 365", "29.2000")]
    [InlineData("INVENTORY / COGS * 365", "26.0714")]
    [InlineData("AP ÷ COGS × 365", "20.8571")]
    [InlineData("EBITDA / FINANCE_COSTS", "9.0000")]
    [InlineData("-ABS(CASH - TOTAL_CA) + 1", "-12999999.0000")]
    public void Templates_parse_and_evaluate_on_a_fixture(string expression, string expected)
    {
        var parsed = Formula.Parse(expression, Codes);
        Assert.True(parsed.IsValid, string.Join("; ", parsed.Errors.Select(e => e.Message)));
        var v = Formula.Evaluate(parsed.Tree!, new DictionaryInputs(Fixture));
        Assert.Equal(decimal.Parse(expected, System.Globalization.CultureInfo.InvariantCulture), Math.Round(v.Value!.Value, 4));
    }

    [Theory]
    [InlineData("TOTAL_CA ; TOTAL_CL", "CHARACTER")]
    [InlineData("TOTAL_CA / NOT_A_LINE", "UNKNOWN_CODE")]
    [InlineData("TOTAL_CA / 0", "DIVIDE_BY_ZERO")]
    [InlineData("TOTAL_CA / (2 - 2)", "DIVIDE_BY_ZERO")]
    [InlineData("((((((((((TOTAL_CA))))))))))", "DEPTH")]
    [InlineData("TOTAL_CA /", "SYNTAX")]
    [InlineData("EXEC(TOTAL_CA)", "FUNCTION")]
    [InlineData("PRIOR(TOTAL_CA, 0)", "PERIODS")]
    [InlineData("SUM(AVG_BAL)", "ARGUMENTS")]
    public void Refused_at_save(string expression, string code)
    {
        var parsed = Formula.Parse(expression, Codes);
        Assert.False(parsed.IsValid);
        Assert.Contains(parsed.Errors, e => e.Code == code);
    }

    [Fact]
    public void Depth_counts_the_levels_of_brackets_and_functions()
    {
        Assert.Equal(1, Formula.Parse("TOTAL_CA + TOTAL_CL + CASH + AR + INVENTORY + REVENUE + COGS + AP + EBITDA + CASH + AR + REVENUE", Codes).Depth);
        Assert.True(Formula.Parse("(((((((((TOTAL_CA)))))))))", Codes).IsValid);
    }

    [Fact]
    public void Division_by_zero_and_missing_inputs_are_undefined_with_a_reason()
    {
        var parsed = Formula.Parse("EBITDA / FINANCE_COSTS", Codes);
        var zero = Formula.Evaluate(parsed.Tree!, new DictionaryInputs(new Dictionary<string, decimal?> { ["EBITDA"] = 5, ["FINANCE_COSTS"] = 0 }));
        Assert.Null(zero.Value);
        Assert.Contains("division by zero", zero.Undefined);
        var missing = Formula.Evaluate(parsed.Tree!, new DictionaryInputs(new Dictionary<string, decimal?> { ["EBITDA"] = 5 }));
        Assert.Equal("FINANCE_COSTS has no value", missing.Undefined);
    }

    [Fact]
    public void Periods_functions_read_earlier_periods_and_input_kinds_are_known()
    {
        var parsed = Formula.Parse("MIN(AVG_BAL, 3) + PRIOR(REVENUE, 1) - SUM(FLOW_TO_BANK, 2)", Codes);
        Assert.True(parsed.IsValid);
        Assert.Equal(["ACCOUNT_STATS", "BANK_FLOWS", "STATEMENT"], parsed.InputKinds.Order());
        Assert.Equal(2, Formula.Lookback(parsed.Tree!));
        var inputs = new DictionaryInputs(
            new Dictionary<string, decimal?> { ["AVG_BAL"] = 620, ["REVENUE"] = 1, ["FLOW_TO_BANK"] = 10 },
            [new Dictionary<string, decimal?> { ["AVG_BAL"] = 480, ["REVENUE"] = 90, ["FLOW_TO_BANK"] = 5 }, new Dictionary<string, decimal?> { ["AVG_BAL"] = 700 }]);
        Assert.Equal(480m + 90m - 15m, Formula.Evaluate(parsed.Tree!, inputs).Value);
    }
}
