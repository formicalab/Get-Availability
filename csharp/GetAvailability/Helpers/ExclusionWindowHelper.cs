using GetAvailability.Models;

namespace GetAvailability.Helpers;

/// <summary>Utilities for building, merging, snapping and querying exclusion windows.</summary>
public static class ExclusionWindowHelper
{
    /// <summary>
    /// Adds an exclusion window [from, to) clamped to the analysis period.
    /// Silently discards windows that fall entirely outside the period or are zero-length.
    /// </summary>
    public static void Add(List<ExclusionWindow> windows, DateTimeOffset from, DateTimeOffset to,
        DateTimeOffset periodStart, DateTimeOffset periodEnd)
    {
        if (to <= periodStart || from >= periodEnd) return;  // entirely outside the window
        if (from < periodStart) from = periodStart;          // clamp start
        if (to > periodEnd) to = periodEnd;                  // clamp end
        if (to > from)
            windows.Add(new ExclusionWindow(from.UtcTicks, to.UtcTicks));
    }

    /// <summary>
    /// Sorts windows by start time and merges overlapping/adjacent intervals.
    /// Input: potentially overlapping windows. Output: sorted, non-overlapping array.
    /// </summary>
    public static ExclusionWindow[] Merge(List<ExclusionWindow> windows)
    {
        if (windows.Count == 0) return [];
        windows.Sort((a, b) =>
        {
            int c = a.FromTicks.CompareTo(b.FromTicks);
            return c != 0 ? c : a.ToTicks.CompareTo(b.ToTicks);
        });
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

    /// <summary>Returns the total duration of the given windows in minutes.</summary>
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
        // Estimate capacity to avoid rehashing
        int capacity = 0;
        foreach (var w in windows)
            capacity += (int)((w.ToTicks - w.FromTicks) / ticksPerMin);
        var set = new HashSet<long>(capacity);
        foreach (var w in windows)
        {
            for (long t = w.FromTicks; t < w.ToTicks; t += ticksPerMin)
                set.Add(t);
        }
        return set;
    }
}
