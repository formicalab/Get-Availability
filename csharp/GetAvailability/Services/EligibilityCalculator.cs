using GetAvailability.Helpers;
using GetAvailability.Models;
using System.Text;

namespace GetAvailability.Services;

public static class EligibilityCalculator
{
    private static readonly HashSet<string> StoppedStates =
        ["deallocated", "deallocating", "stopped", "stopping", "Paused", "Pausing", "Resuming"];

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

        // Symmetric ±N tolerance around every power event
        var buf = TimeSpan.FromMinutes(toleranceMinutes);
        foreach (var pe in powerEvents)
            ExclusionWindowHelper.Add(stoppedWindows, pe.Time - buf, pe.Time + buf, periodStart, periodEnd);

        // Phase 3: Merge, snap, compute eligible minutes
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

        // Build explanation
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
