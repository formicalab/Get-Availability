namespace GetAvailability.Models;

/// <summary>Per-resource availability result. Eligible minutes start at the rolling
/// 30-day total and are reduced by healthy gaps and zero-tx storage minutes during assembly.</summary>
public sealed class EligibilityResult
{
    public required string Name { get; init; }
    public required string Kind { get; init; }
    public required string ResourceId { get; init; }
    public required string ResourceGroupName { get; init; }
    public required string Location { get; init; }
    public required string SubscriptionName { get; init; }
    public int EligibleMinutes { get; set; }

    // Set after metric computation in the assembly step
    public double AvailableMinutes { get; set; }

    /// <summary>Minutes of confirmed degradation: metric datapoints below 100% (non-zero),
    /// plus gap minutes counted as downtime (health-confirmed faults and trusted 0% metrics).</summary>
    public int DegradedMinutes { get; set; }

    /// <summary>True when the primary availability metric returned no data at all (broken telemetry pipeline).</summary>
    public bool NoData { get; set; }

    /// <summary>Availability percentage (5 decimal places), "N/A" if fully excluded, or "N/D" if no metric data.</summary>
    public string AvailabilityPct => NoData ? "N/D"
        : EligibleMinutes > 0
            ? Math.Round(AvailableMinutes / EligibleMinutes * 100, 5).ToString("F5")
            : "N/A";
}
