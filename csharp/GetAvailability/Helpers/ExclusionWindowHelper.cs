using GetAvailability.Models;

namespace GetAvailability.Helpers;

public static class ExclusionWindowHelper
{
    public static void Add(List<ExclusionWindow> windows, DateTimeOffset from, DateTimeOffset to,
        DateTimeOffset periodStart, DateTimeOffset periodEnd)
    {
        if (to <= periodStart || from >= periodEnd) return;
        if (from < periodStart) from = periodStart;
        if (to > periodEnd) to = periodEnd;
        if (to > from)
            windows.Add(new ExclusionWindow(from.UtcTicks, to.UtcTicks));
    }

    public static ExclusionWindow[] Merge(List<ExclusionWindow> windows)
    {
        if (windows.Count == 0) return [];
        windows.Sort((a, b) => a.FromTicks.CompareTo(b.FromTicks) is var c && c != 0 ? c : a.ToTicks.CompareTo(b.ToTicks));
        var merged = new List<ExclusionWindow>(windows.Count);
        long f = windows[0].FromTicks, t = windows[0].ToTicks;
        for (int i = 1; i < windows.Count; i++)
        {
            if (windows[i].FromTicks <= t)
            {
                if (windows[i].ToTicks > t) t = windows[i].ToTicks;
            }
            else
            {
                merged.Add(new ExclusionWindow(f, t));
                f = windows[i].FromTicks;
                t = windows[i].ToTicks;
            }
        }
        merged.Add(new ExclusionWindow(f, t));
        return [.. merged];
    }

    public static double GetMinutes(ExclusionWindow[] windows)
    {
        double sum = 0;
        foreach (var w in windows)
            sum += (w.ToTicks - w.FromTicks) / (double)TimeSpan.TicksPerMinute;
        return Math.Round(sum, 2);
    }

    /// <summary>Floor(From) and Ceil(To) to whole-minute boundaries, clamped to period.</summary>
    public static void Snap(ExclusionWindow[] windows, long periodStartTicks, long periodEndTicks)
    {
        long ticksPerMin = TimeSpan.TicksPerMinute;
        for (int i = 0; i < windows.Length; i++)
        {
            long from = windows[i].FromTicks / ticksPerMin * ticksPerMin;  // floor
            long toMin = windows[i].ToTicks / ticksPerMin * ticksPerMin;
            long to = windows[i].ToTicks > toMin ? toMin + ticksPerMin : toMin; // ceil
            if (from < periodStartTicks) from = periodStartTicks;
            if (to > periodEndTicks) to = periodEndTicks;
            windows[i] = new ExclusionWindow(from, to);
        }
    }

    /// <summary>Build a HashSet of excluded minute-boundary ticks for O(1) lookup.</summary>
    public static HashSet<long> BuildExcludedTickSet(ExclusionWindow[] windows)
    {
        long ticksPerMin = TimeSpan.TicksPerMinute;
        var set = new HashSet<long>();
        foreach (var w in windows)
        {
            for (long t = w.FromTicks; t < w.ToTicks; t += ticksPerMin)
                set.Add(t);
        }
        return set;
    }
}
