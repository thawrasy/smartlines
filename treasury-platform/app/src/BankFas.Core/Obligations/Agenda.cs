namespace BankFas.Core.Obligations;

/// <summary>A reporting rule as the agenda reads it (obl.ReportingObligation with its obligation's dates).</summary>
public sealed record ReportingRule(string Frequency, string AnchorKind, int? OffsetValue, string OffsetUnit, DateTime? FixedDueDate, DateTime? FirstPeriodEnd,
    int HorizonMonths, DateTime ValidFrom, DateTime? ValidTo);

/// <summary>One item of the agenda: the period it reports (none for a fixed date or an event) and its due date.</summary>
public sealed record AgendaItem(DateTime? PeriodStart, DateTime? PeriodEnd, DateTime? EventDate, DateTime DueDate);

/// <summary>
/// BR-OBL-002 and BR-OBL-004: the due dates of a reporting rule. A periodic rule reports each period of its frequency,
/// aligned on the company's fiscal year end (a semi-annual period of a December year ends in June and December); its
/// due date is the period end plus the offset in calendar days, working days or months. AFTER_FISCAL_YEAR_END reports
/// each fiscal year. A fixed date is one item; an event-based rule has no item until its event is logged, and a notice
/// before an event is due N working days before it (the last day it is still in time). Items run from the period
/// that ends before the rule starts (its report falls due inside the rule) to the horizon; a period that ends after the
/// rule (or the facility) ends is not reported.
/// </summary>
public static class Agenda
{
    private static int Months(string frequency) => frequency switch
    {
        "ANNUAL" => 12,
        "SEMIANNUAL" => 6,
        "QUARTERLY" => 3,
        "MONTHLY" => 1,
        _ => 0,
    };

    private static DateTime MonthEnd(int year, int month) => new(year, month, DateTime.DaysInMonth(year, month));

    /// <summary>The due date of an offset from an anchor date; a negative count moves back (a notice before an event).</summary>
    public static DateTime Offset(DateTime anchor, int value, string unit, Func<DateTime, int, DateTime> addWorkingDays) => unit switch
    {
        "BUSINESS_DAYS" => addWorkingDays(anchor, value),
        "MONTHS" => anchor.AddMonths(value),
        _ => anchor.AddDays(value),
    };

    public static IReadOnlyList<AgendaItem> Generate(ReportingRule rule, int fiscalYearEndMonth, DateTime today, Func<DateTime, int, DateTime> addWorkingDays)
    {
        var horizon = today.Date.AddMonths(rule.HorizonMonths <= 0 ? 24 : rule.HorizonMonths);
        if (rule.AnchorKind == "FIXED_DATE")
            return rule.FixedDueDate is { } fixedDate && fixedDate <= horizon ? [new AgendaItem(null, null, null, fixedDate.Date)] : [];
        if (rule.AnchorKind is not ("AFTER_PERIOD_END" or "AFTER_FISCAL_YEAR_END")) return [];
        var months = rule.AnchorKind == "AFTER_FISCAL_YEAR_END" ? 12 : Months(rule.Frequency);
        if (months == 0) return [];
        var items = new List<AgendaItem>();
        // The first candidate period end: a year before the start, aligned on the fiscal year end month.
        var start = rule.ValidFrom.Date.AddMonths(-12);
        var m = start.Month;
        while ((m - fiscalYearEndMonth + 12) % months != 0) m = m % 12 + 1;
        var end = MonthEnd(m < start.Month ? start.Year + 1 : start.Year, m);
        for (; end <= horizon; end = MonthEnd(end.AddMonths(months).Year, end.AddMonths(months).Month))
        {
            if (rule.FirstPeriodEnd is { } first && end < first.Date) continue;
            if (rule.ValidTo is { } to && end > to.Date) break;
            var due = Offset(end, rule.OffsetValue ?? 0, rule.OffsetUnit, addWorkingDays);
            if (due < rule.ValidFrom.Date || due > horizon) continue;
            items.Add(new AgendaItem(end.AddMonths(-months).AddDays(1), end, null, due));
        }
        return items;
    }

    /// <summary>BR-OBL-004: an event-based rule's item for a logged event: N units before (BEFORE_EVENT) or after it.</summary>
    public static AgendaItem ForEvent(ReportingRule rule, DateTime eventDate, Func<DateTime, int, DateTime> addWorkingDays)
    {
        var n = rule.OffsetValue ?? 0;
        var due = Offset(eventDate.Date, rule.AnchorKind == "BEFORE_EVENT" ? -n : n, rule.OffsetUnit, addWorkingDays);
        return new AgendaItem(null, null, eventDate.Date, due);
    }
}
