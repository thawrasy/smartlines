using BankFas.Core.Calendar;
using BankFas.Core.Obligations;

namespace BankFas.Core.Tests.Obligations;

public sealed class AgendaTests
{
    // Saudi Arabia: Friday and Saturday are the weekend; no holiday in the window.
    private static readonly WorkingDays Sa = new(WorkingDays.Weekend("FRI,SAT"), new HashSet<DateOnly>());
    private static DateTime Add(DateTime d, int n) => Sa.AddWorkingDays(DateOnly.FromDateTime(d), n).ToDateTime(TimeOnly.MinValue);
    private static readonly DateTime Today = new(2026, 1, 1);

    [Fact]
    public void AC_FAC_6_audited_210_days_interim_45_days_and_a_notice_30_working_days_before()
    {
        var audited = new ReportingRule("ANNUAL", "AFTER_FISCAL_YEAR_END", 210, "CALENDAR_DAYS", null, null, 24, new DateTime(2026, 1, 1), new DateTime(2027, 12, 31));
        var a = Agenda.Generate(audited, 12, Today, Add);
        Assert.Equal([new DateTime(2026, 7, 29), new DateTime(2027, 7, 29)], a.Select(i => i.DueDate));
        Assert.Equal((new DateTime(2025, 1, 1), new DateTime(2025, 12, 31)), (a[0].PeriodStart!.Value, a[0].PeriodEnd!.Value));

        var interim = new ReportingRule("SEMIANNUAL", "AFTER_PERIOD_END", 45, "CALENDAR_DAYS", null, null, 24, new DateTime(2026, 1, 1), new DateTime(2027, 12, 31));
        var i = Agenda.Generate(interim, 12, Today, Add);
        Assert.Contains(new DateTime(2026, 8, 14), i.Select(x => x.DueDate));
        Assert.All(i, x => Assert.True(x.PeriodEnd!.Value.Month is 6 or 12));
        Assert.DoesNotContain(i, x => x.PeriodEnd > new DateTime(2027, 12, 31));

        var notice = new ReportingRule("EVENT_BASED", "BEFORE_EVENT", 30, "BUSINESS_DAYS", null, null, 24, new DateTime(2026, 1, 1), null);
        Assert.Empty(Agenda.Generate(notice, 12, Today, Add));
        Assert.Equal(new DateTime(2026, 11, 8), Agenda.ForEvent(notice, new DateTime(2026, 12, 20), Add).DueDate);
    }

    [Fact]
    public void A_fiscal_year_ending_in_june_aligns_the_quarters_and_a_fixed_date_is_one_item()
    {
        var quarterly = new ReportingRule("QUARTERLY", "AFTER_PERIOD_END", 1, "MONTHS", null, new DateTime(2026, 3, 31), 12, new DateTime(2026, 1, 1), null);
        var q = Agenda.Generate(quarterly, 6, Today, Add);
        Assert.Equal([new DateTime(2026, 3, 31), new DateTime(2026, 6, 30), new DateTime(2026, 9, 30)], q.Select(x => x.PeriodEnd!.Value));
        Assert.Equal(new DateTime(2026, 4, 30), q[0].DueDate);
        var once = new ReportingRule("ONE_TIME", "FIXED_DATE", null, "CALENDAR_DAYS", new DateTime(2026, 5, 1), null, 24, new DateTime(2026, 1, 1), null);
        Assert.Equal([new DateTime(2026, 5, 1)], Agenda.Generate(once, 12, Today, Add).Select(x => x.DueDate));
    }
}
