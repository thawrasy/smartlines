namespace BankFas.Core.Lc;

/// <summary>A line of a proforma as entered: its quantity, unit and unit price (FR-LCE-003).</summary>
public sealed record ProformaLineInput(string Description, decimal Qty, string UnitCode, decimal UnitPrice, string? Notes = null);

/// <summary>A line with its total, as stored in lc.ProformaLine.</summary>
public sealed record ProformaLineTotal(int LineNo, string Description, decimal Qty, string UnitCode, decimal UnitPrice, decimal LineTotal, string? Notes);

/// <summary>The totals of a proforma (BR-LCE-001) and the amount of the credit asked of the customer (BR-LCE-006).</summary>
public sealed record ProformaTotals(IReadOnlyList<ProformaLineTotal> Lines, decimal Subtotal, decimal VatRatePct, decimal VatAmount, decimal Total, decimal LcAmount);

/// <summary>The balance of a received credit (BR-LCE-009): its amount, what its sales orders still earmark, what is drawn, and the rest.</summary>
public sealed record SalesBalance(decimal LcAmount, decimal EarmarkedRemaining, decimal Drawn)
{
    public decimal Available => LcAmount - EarmarkedRemaining - Drawn;
}

/// <summary>An earmark a drawing converts: the sales order and the part of the drawing taken from it (BR-LCE-011).</summary>
public sealed record ConversionPart(long SalesOrderId, decimal Amount, decimal OrderRemaining);

/// <summary>
/// The arithmetic of the sales side of spec 14 (section 5.3), without the database: the proforma's totals, the balance
/// of a received credit, and the checks of an earmark, a conversion and an amendment. Amounts are decimals rounded away
/// from zero to the currency's decimals, never floating points (BR-LCE-001).
/// </summary>
public static class SalesRules
{
    /// <summary>
    /// BR-LCE-001: each line total is round(Qty × UnitPrice, d), the subtotal their sum, the VAT round(Subtotal × Rate / 100, d)
    /// and the total their sum. The credit asked of the customer is round(Total × LcPaymentPct / 100, d) (BR-LCE-006).
    /// A line needs a description, a quantity above zero and a price not below zero (V-LCE-03).
    /// </summary>
    public static ProformaTotals Totals(IReadOnlyList<ProformaLineInput> lines, decimal vatRatePct, decimal lcPaymentPct, int decimals)
    {
        ArgumentNullException.ThrowIfNull(lines);
        if (lines.Count == 0) throw new ArgumentException("V-LCE-03: a proforma has at least one line.", nameof(lines));
        if (vatRatePct is < 0 or > 100) throw new ArgumentOutOfRangeException(nameof(vatRatePct), "The VAT rate is 0 to 100.");
        if (lcPaymentPct is <= 0 or > 100) throw new ArgumentOutOfRangeException(nameof(lcPaymentPct), "The part paid by the credit is above 0 and at most 100.");
        var totals = new List<ProformaLineTotal>(lines.Count);
        var no = 0;
        foreach (var l in lines)
        {
            no++;
            if (string.IsNullOrWhiteSpace(l.Description) || l.Qty <= 0 || l.UnitPrice < 0 || string.IsNullOrWhiteSpace(l.UnitCode))
                throw new ArgumentException($"V-LCE-03: line {no} needs a description, a unit, a quantity above zero and a price not below zero.", nameof(lines));
            totals.Add(new ProformaLineTotal(no, l.Description.Trim(), l.Qty, l.UnitCode.Trim(), l.UnitPrice, Round(l.Qty * l.UnitPrice, decimals), l.Notes?.Trim()));
        }
        var subtotal = totals.Sum(t => t.LineTotal);
        var vat = Round(subtotal * vatRatePct / 100m, decimals);
        var total = subtotal + vat;
        return new ProformaTotals(totals, subtotal, vatRatePct, vat, total, Round(total * lcPaymentPct / 100m, decimals));
    }

    public static decimal Round(decimal value, int decimals) => Math.Round(value, decimals, MidpointRounding.AwayFromZero);

    /// <summary>The cap of the earmarks (BR-LCE-010): the amount, or the amount with its plus tolerance when lc.earmark.cap_includes_tolerance holds.</summary>
    public static decimal EarmarkCap(decimal amount, decimal tolerancePlusPct, bool includeTolerance, int decimals) =>
        includeTolerance ? Round(amount * (1 + tolerancePlusPct / 100m), decimals) : amount;

    /// <summary>The refusal of an earmark, or null (BR-LCE-010; V-LCE-05 to 07): an active credit not expired, the same currency, an amount within what is available.</summary>
    public static string? EarmarkProblem(string status, DateOnly expiry, DateOnly today, bool sameCurrency, decimal amount, decimal available)
    {
        if (status != "ACTIVE" || expiry < today) return "V-LCE-07";
        if (!sameCurrency) return "V-LCE-06";
        if (amount <= 0 || amount > available) return "V-LCE-05";
        return null;
    }

    /// <summary>
    /// BR-LCE-011: a drawing D converts parts aᵢ of its orders; each part is within its order's remaining earmark, their
    /// sum within D (V-LCE-09), and the part of D earmarked to no order is within what is available (V-LCE-10). Returns the
    /// code of the refusal, or null.
    /// </summary>
    public static string? ConversionProblem(decimal drawing, IReadOnlyList<ConversionPart> parts, decimal available)
    {
        ArgumentNullException.ThrowIfNull(parts);
        if (drawing <= 0) return "V-LCE-09";
        if (parts.Any(p => p.Amount <= 0 || p.Amount > p.OrderRemaining) || parts.GroupBy(p => p.SalesOrderId).Any(g => g.Count() > 1)) return "V-LCE-09";
        var allocated = parts.Sum(p => p.Amount);
        if (allocated > drawing) return "V-LCE-09";
        return drawing - allocated > available ? "V-LCE-10" : null;
    }

    /// <summary>BR-LCE-014: an amendment's new amount covers what is earmarked and drawn; returns the shortfall, zero when it does.</summary>
    public static decimal AmendmentShortfall(decimal newAmount, decimal earmarkedRemaining, decimal drawn) =>
        Math.Max(0, earmarkedRemaining + drawn - newAmount);

    /// <summary>The number of a proforma (BR-LCE-002): {seq:000}-{erp}-{yy}, the sequence widened past 999, the ERP code trimmed, upper case and without spaces.</summary>
    public static string ProformaNumber(int seq, string erpCode, int year) =>
        $"{seq.ToString("000", System.Globalization.CultureInfo.InvariantCulture)}-{NormaliseErp(erpCode)}-{(year % 100).ToString("00", System.Globalization.CultureInfo.InvariantCulture)}";

    public static string NormaliseErp(string erpCode)
    {
        ArgumentNullException.ThrowIfNull(erpCode);
        return erpCode.Replace(" ", "", StringComparison.Ordinal).Trim().ToUpperInvariant();
    }
}
