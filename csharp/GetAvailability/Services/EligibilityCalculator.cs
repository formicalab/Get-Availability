using GetAvailability.Helpers;
using GetAvailability.Models;
using System.Text;

namespace GetAvailability.Services;

/// <summary>
/// Computes eligible minutes for a resource by building exclusion windows from lifecycle events.
/// Phase 1: non-existence (Delete→Create). Phase 2: purposeful stops. Phase 3: ±tolerance zones.
/// </summary>
public static class EligibilityCalculator
{
    // Power states that indicate a resource is intentionally stopped/deallocated
    private static readonly HashSet<string> StoppedStates =
        ["deallocated", "deallocating", "stopped", "stopping", "Paused", "Pausing", "Resuming"];

    /// <summary>
    /// Builds exclusion windows from lifecycle events and computes how many of the total minutes
    /// the resource was expected to be available (eligible). Works in three phases:
    ///   Phase 1: Non-existence windows (Delete→Create gaps, pre-creation time).
    ///   Phase 2: Purposeful-stop windows (Stop→Start gaps, currently-stopped with no events).
    ///   Phase 3: Symmetric ±N minute tolerance zones around each Start/Stop event.
    /// Windows are merged, snapped to whole-minute boundaries, and subtracted from totalMinutes.
    /// </summary>
    public static EligibilityResult Compute(
        TrackedResource resource,
        IReadOnlyList<LifecycleEvent> events,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int totalMinutes,
        int toleranceMinutes)
    {
        var sorted = events.OrderBy(e => e.EventTimestamp).ToArray();
        var nonExistWindows = new List<ExclusionWindow>();
        var stoppedWindows = new List<ExclusionWindow>();

        // Phase 1: Non-existence windows
        // If the resource was created during the window (no prior delete), exclude [periodStart, createdAt).
        // For each Delete→Create pair, exclude the gap between them.
        // A trailing Delete with no subsequent Create excludes through periodEnd.
        var deletes = sorted.Where(e => e.EventKind == "Delete").ToArray();

        if (resource.CreatedAt is { } created && created > periodStart && created < periodEnd)
        {
            if (!deletes.Any(d => d.EventTimestamp < created))
                ExclusionWindowHelper.Add(nonExistWindows, periodStart, created, periodStart, periodEnd);
        }

        DateTimeOffset? pendingDelete = null;
        foreach (var evt in sorted)
        {
            if (evt.EventKind == "Delete") { pendingDelete = evt.EventTimestamp; continue; }
            if (evt.EventKind == "Create" && pendingDelete.HasValue)
            {
                ExclusionWindowHelper.Add(nonExistWindows, pendingDelete.Value, evt.EventTimestamp, periodStart, periodEnd);
                pendingDelete = null;
            }
        }
        if (pendingDelete.HasValue)
            ExclusionWindowHelper.Add(nonExistWindows, pendingDelete.Value, periodEnd, periodStart, periodEnd);

        // Phase 2: Purposeful-stop windows
        // Extract Start/Stop events in chronological order.
        // If first event is Start → resource was stopped before the window, exclude [periodStart, firstStart).
        // If no events and current state is stopped → exclude entire period.
        // For each Stop→Start pair, exclude the gap between them.
        // A trailing Stop with no subsequent Start excludes through periodEnd.
        var powerEvents = new List<(string Kind, DateTimeOffset Time)>();
        foreach (var evt in sorted)
        {
            if (evt.EventKind == "Stop") powerEvents.Add(("Stop", evt.EventTimestamp));
            if (evt.EventKind == "Start") powerEvents.Add(("Start", evt.EventTimestamp));
        }

        if (powerEvents.Count > 0 && powerEvents[0].Kind == "Start")
            ExclusionWindowHelper.Add(stoppedWindows, periodStart, powerEvents[0].Time, periodStart, periodEnd);
        else if (powerEvents.Count == 0 && StoppedStates.Contains(resource.CurrentPowerState))
            ExclusionWindowHelper.Add(stoppedWindows, periodStart, periodEnd, periodStart, periodEnd);

        DateTimeOffset? pendingStop = null;
        foreach (var pe in powerEvents)
        {
            if (pe.Kind == "Stop") { pendingStop ??= pe.Time; continue; }
            if (pe.Kind == "Start" && pendingStop.HasValue)
            {
                ExclusionWindowHelper.Add(stoppedWindows, pendingStop.Value, pe.Time, periodStart, periodEnd);
                pendingStop = null;
            }
        }
        if (pendingStop.HasValue)
            ExclusionWindowHelper.Add(stoppedWindows, pendingStop.Value, periodEnd, periodStart, periodEnd);

        // Symmetric ±N tolerance around every power event.
        // This covers the ramp-down before shutdown and ramp-up after boot where metrics
        // may be degraded. Consecutive events naturally merge: events at 18:00 and 18:02
        // with N=5 produce a single merged window [17:55, 18:07].
        var buf = TimeSpan.FromMinutes(toleranceMinutes);
        foreach (var pe in powerEvents)
            ExclusionWindowHelper.Add(stoppedWindows, pe.Time - buf, pe.Time + buf, periodStart, periodEnd);

        // Phase 3: Merge all windows, snap to whole-minute boundaries, compute eligible minutes.
        // Snapping: floor(from) and ceil(to) ensures discrete metric data points (one per minute)
        // align perfectly with eligible minute counts.
        var mergedNonExist = ExclusionWindowHelper.Merge(nonExistWindows);
        var mergedStopped = ExclusionWindowHelper.Merge(stoppedWindows);

        var allWindows = new List<ExclusionWindow>(mergedNonExist.Length + mergedStopped.Length);
        allWindows.AddRange(mergedNonExist);
        allWindows.AddRange(mergedStopped);
        var mergedExcluded = ExclusionWindowHelper.Merge(allWindows);

        long psTicks = periodStart.UtcTicks, peTicks = periodEnd.UtcTicks;
        ExclusionWindowHelper.Snap(mergedNonExist, psTicks, peTicks);
        ExclusionWindowHelper.Snap(mergedStopped, psTicks, peTicks);
        ExclusionWindowHelper.Snap(mergedExcluded, psTicks, peTicks);

        double nonExistMin = ExclusionWindowHelper.GetMinutes(mergedNonExist);
        double stoppedMin = ExclusionWindowHelper.GetMinutes(mergedStopped);
        double excludedMin = ExclusionWindowHelper.GetMinutes(mergedExcluded);
        int eligibleMin = Math.Max(0, (int)(totalMinutes - excludedMin));

        // Build human-readable explanation of what was excluded and why
        var sb = new StringBuilder();
        if (eligibleMin == totalMinutes)
        {
            sb.Append("Fully eligible for the entire period");
        }
        else if (eligibleMin == 0)
        {
            if (nonExistMin >= totalMinutes) sb.Append("Did not exist during the period");
            else if (stoppedMin >= totalMinutes) sb.Append($"Stopped/deallocated for the entire period (current state: {resource.CurrentPowerState})");
            else sb.Append("Excluded for the entire period");
        }
        else
        {
            if (nonExistMin > 0)
            {
                sb.Append($"Non-existent for {nonExistMin} min");
                foreach (var w in mergedNonExist)
                {
                    var f = new DateTimeOffset(w.FromTicks, TimeSpan.Zero);
                    var t = new DateTimeOffset(w.ToTicks, TimeSpan.Zero);
                    sb.Append($";   non-exist: {f:MM/dd HH:mm}-{t:MM/dd HH:mm}");
                }
            }
            if (stoppedMin > 0)
            {
                if (sb.Length > 0) sb.Append("; ");
                sb.Append($"Stopped/deallocated for {stoppedMin} min");
                foreach (var w in mergedStopped)
                {
                    var f = new DateTimeOffset(w.FromTicks, TimeSpan.Zero);
                    var t = new DateTimeOffset(w.ToTicks, TimeSpan.Zero);
                    sb.Append($";   stopped: {f:MM/dd HH:mm}-{t:MM/dd HH:mm}");
                }
            }
        }

        return new EligibilityResult
        {
            Name = resource.Name,
            Kind = resource.Kind,
            ResourceId = resource.ResourceId,
            ResourceGroupName = resource.ResourceGroupName,
            Location = resource.Location,
            SubscriptionName = resource.SubscriptionName,
            CreatedAt = resource.CreatedAt,
            EligibleMinutes = eligibleMin,
            TotalMinutes = totalMinutes,
            Explanation = sb.ToString(),
            ExclusionWindows = mergedExcluded
        };
    }
}
