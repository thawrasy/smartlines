namespace BankFas.Core.Calendar;

/// <summary>
/// The one working-day service of every module (FR-PLT-035, BR-PLT-014, BR-OBL-004): the weekend of a country
/// (ref.Country.WeekendDays) and its non-working days (platform holidays and the tenant's own days). Adding N working
/// days moves forward over working days only; counting back N working days before an event gives the last day on
/// which a notice is still in time. Working hours run in the window work.start to work.end of each working day.
/// </summary>
public sealed class WorkingDays(IReadOnlySet<DayOfWeek> weekend, IReadOnlySet<DateOnly> holidays)
{
    private static readonly Dictionary<string, DayOfWeek> Codes = new(StringComparer.Ordinal)
    {
        ["MON"] = DayOfWeek.Monday, ["TUE"] = DayOfWeek.Tuesday, ["WED"] = DayOfWeek.Wednesday, ["THU"] = DayOfWeek.Thursday,
        ["FRI"] = DayOfWeek.Friday, ["SAT"] = DayOfWeek.Saturday, ["SUN"] = DayOfWeek.Sunday,
    };

    /// <summary>The weekend from the set code of ref.Country.WeekendDays ("FRI,SAT"); empty or unknown codes give no weekend day.</summary>
    public static IReadOnlySet<DayOfWeek> Weekend(string? codes) =>
        (codes ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(Codes.ContainsKey).Select(c => Codes[c]).ToHashSet();

    public bool IsWorkingDay(DateOnly d) => !weekend.Contains(d.DayOfWeek) && !holidays.Contains(d);

    /// <summary>N working days after (N &gt; 0) or before (N &lt; 0) the date; 0 gives the date itself.</summary>
    public DateOnly AddWorkingDays(DateOnly from, int n)
    {
        var step = n >= 0 ? 1 : -1;
        var d = from;
        for (var left = Math.Abs(n); left > 0;)
        {
            d = d.AddDays(step);
            if (IsWorkingDay(d)) left--;
        }
        return d;
    }

    /// <summary>
    /// Business hours (BR-PLT-014) within the daily window: a start outside the window moves to the next opening, and the
    /// hours carry over working days only. Example: Monday 09:00 + 24 hours with 08:00-17:00 gives Wednesday 15:00.
    /// </summary>
    public DateTime AddBusinessHours(DateTime from, double hours, TimeOnly start, TimeOnly end)
    {
        if (end <= start) throw new ArgumentException("The working day ends after it starts.", nameof(end));
        var day = DateOnly.FromDateTime(from);
        var at = TimeOnly.FromDateTime(from);
        if (!IsWorkingDay(day) || at >= end) { day = NextWorking(day); at = start; }
        else if (at < start) at = start;
        var left = TimeSpan.FromHours(hours);
        while (true)
        {
            var room = end - at;
            if (left <= room) return day.ToDateTime(at).Add(left);
            left -= room;
            day = NextWorking(day);
            at = start;
        }
    }

    /// <summary>
    /// The business hours between two times (BR-WFL-010, 012): the inverse of <see cref="AddBusinessHours"/>, used to carry
    /// a pause of the SLA. Zero when the end is not after the start. Example: Thursday 15:00 to Sunday 14:00 with
    /// 08:00-17:00 and a Friday-Saturday weekend gives 8 hours.
    /// </summary>
    public double BusinessHoursBetween(DateTime from, DateTime to, TimeOnly start, TimeOnly end)
    {
        if (end <= start) throw new ArgumentException("The working day ends after it starts.", nameof(end));
        if (to <= from) return 0;
        var total = TimeSpan.Zero;
        for (var day = DateOnly.FromDateTime(from); day <= DateOnly.FromDateTime(to); day = day.AddDays(1))
        {
            if (!IsWorkingDay(day)) continue;
            var open = day.ToDateTime(start);
            var close = day.ToDateTime(end);
            var a = from > open ? from : open;
            var b = to < close ? to : close;
            if (b > a) total += b - a;
        }
        return total.TotalHours;
    }

    private DateOnly NextWorking(DateOnly d)
    {
        do d = d.AddDays(1); while (!IsWorkingDay(d));
        return d;
    }
}
