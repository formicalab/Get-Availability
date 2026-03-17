namespace GetAvailability.Models;

/// <summary>Per-resource eligibility + availability result, populated in two passes (eligibility then metrics).</summary>
public sealed class EligibilityResult
{
    public required string Name { get; init; }
    public required string Kind { get; init; }
    public required string ResourceId { get; init; }
    public required string ResourceGroupName { get; init; }
    public required string Location { get; init; }
    public required string SubscriptionName { get; init; }
    public DateTimeOffset? CreatedAt { get; init; }
    public int EligibleMinutes { get; set; }     // may be reduced later by zero-tx storage minutes
    public int TotalMinutes { get; init; }       // always 20160 (14 days × 24h × 60m)
    public required string Explanation { get; init; }  // human-readable reason for exclusions
    public ExclusionWindow[] ExclusionWindows { get; init; } = [];  // merged+snapped exclusion intervals

    // Set after metric computation in the assembly step
    public double AvailableMinutes { get; set; }

    /// <summary>True when the primary availability metric returned no data at all (broken telemetry pipeline).</summary>
    public bool NoData { get; set; }

    /// <summary>Availability percentage (5 decimal places), "N/A" if fully excluded, or "N/D" if no metric data.</summary>
    public string AvailabilityPct => NoData ? "N/D"
        : EligibleMinutes > 0
            ? Math.Round(AvailableMinutes / EligibleMinutes * 100, 5).ToString("F5")
            : "N/A";
}
