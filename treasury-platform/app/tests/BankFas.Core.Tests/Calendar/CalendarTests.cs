using BankFas.Core.Calendar;

namespace BankFas.Core.Tests.Calendar;

public sealed class CalendarTests
{
    private static readonly WorkingDays Saudi = new(WorkingDays.Weekend("FRI,SAT"), new HashSet<DateOnly>());

    [Fact]
    public void Three_working_days_after_a_Thursday_skip_the_weekend()   // FR-PLT-035 acceptance
    {
        Assert.Equal(new DateOnly(2026, 10, 13), Saudi.AddWorkingDays(new DateOnly(2026, 10, 8), 3));
        Assert.Equal(new DateOnly(2026, 10, 8), Saudi.AddWorkingDays(new DateOnly(2026, 10, 8), 0));
    }

    [Fact]
    public void Thirty_working_days_before_an_event_is_the_last_day_of_a_notice()   // FR-OBL-005, BR-OBL-004
    {
        Assert.Equal(new DateOnly(2026, 11, 8), Saudi.AddWorkingDays(new DateOnly(2026, 12, 20), -30));
    }

    [Fact]
    public void A_holiday_is_not_a_working_day()
    {
        var withHoliday = new WorkingDays(WorkingDays.Weekend("FRI,SAT"), new HashSet<DateOnly> { new(2026, 10, 11) });
        Assert.Equal(new DateOnly(2026, 10, 14), withHoliday.AddWorkingDays(new DateOnly(2026, 10, 8), 3));
        Assert.Empty(WorkingDays.Weekend(null));
    }

    [Fact]
    public void Business_hours_carry_over_working_days()   // BR-PLT-014 acceptance
    {
        var at = Saudi.AddBusinessHours(new DateTime(2026, 10, 12, 9, 0, 0), 24, new TimeOnly(8, 0), new TimeOnly(17, 0));
        Assert.Equal(new DateTime(2026, 10, 14, 15, 0, 0), at);
        // From a Friday evening the clock starts on Sunday morning.
        Assert.Equal(new DateTime(2026, 10, 11, 10, 0, 0), Saudi.AddBusinessHours(new DateTime(2026, 10, 9, 20, 0, 0), 2, new TimeOnly(8, 0), new TimeOnly(17, 0)));
    }

    [Fact]
    public void The_SLA_and_reminder_times_of_spec_13_follow_from_the_business_hours()   // BR-WFL-012, BR-NTF-006, AC-WFL-5, AC-WFL-10
    {
        TimeOnly s = new(8, 0), e = new(17, 0);
        var entered = new DateTime(2026, 10, 8, 15, 0, 0);
        Assert.Equal(new DateTime(2026, 10, 11, 14, 0, 0), Saudi.AddBusinessHours(entered, 8, s, e));
        Assert.Equal(new DateTime(2026, 10, 11, 12, 24, 0), Saudi.AddBusinessHours(entered, 8 * 0.8, s, e));
        var created = new DateTime(2026, 10, 12, 9, 0, 0);
        Assert.Equal(new DateTime(2026, 10, 19, 12, 0, 0), Saudi.AddBusinessHours(created, 48, s, e));
        Assert.Equal(new DateTime(2026, 10, 22, 9, 0, 0), Saudi.AddBusinessHours(created, 72, s, e));
        // The inverse, which carries a pause of the SLA.
        Assert.Equal(8, Saudi.BusinessHoursBetween(entered, new DateTime(2026, 10, 11, 14, 0, 0), s, e), 6);
        Assert.Equal(24, Saudi.BusinessHoursBetween(created, new DateTime(2026, 10, 14, 15, 0, 0), s, e), 6);
        Assert.Equal(0, Saudi.BusinessHoursBetween(new DateTime(2026, 10, 9, 9, 0, 0), new DateTime(2026, 10, 10, 18, 0, 0), s, e));
    }

    [Fact]
    public void Hijri_dates_convert_both_ways_and_a_date_that_does_not_exist_is_refused()   // FR-PLT-033
    {
        var g = new DateOnly(2026, 10, 22);
        var h = HijriDates.FromGregorian(g);
        Assert.Equal(g, HijriDates.ToGregorian(h));
        Assert.Equal(g, HijriDates.ToGregorian(h.Replace('-', '/')));
        var arabicDigits = new string([.. h.Select(ch => char.IsAsciiDigit(ch) ? (char)('٠' + (ch - '0')) : ch)]);
        Assert.Equal(g, HijriDates.ToGregorian(arabicDigits));
        Assert.Null(HijriDates.ToGregorian("1448-13-01"));
        Assert.Null(HijriDates.ToGregorian("1448-02-31"));
        Assert.Null(HijriDates.ToGregorian("not a date"));
        // A month of 29 days has no 30th.
        var cal = new System.Globalization.UmAlQuraCalendar();
        var shortMonth = Enumerable.Range(1, 12).First(m => cal.GetDaysInMonth(1448, m) == 29);
        Assert.Null(HijriDates.ToGregorian($"1448-{shortMonth:00}-30"));
    }
}
