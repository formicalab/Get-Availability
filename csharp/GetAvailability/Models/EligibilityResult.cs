namespace GetAvailability.Models;

/// <summary>Per-resource availability result. Eligible minutes start at the rolling
/// 30-day total and are reduced by healthy gaps, customer-excused degraded minutes,
/// and zero-tx storage minutes during assembly.</summary>
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

    /// <summary>Minutes of confirmed degradation: metric datapoints below 100% that were not
    /// excused by customer-initiated activity, plus gap minutes counted as downtime
    /// (health-confirmed faults and trusted 0% metrics).</summary>
    public int DegradedMinutes { get; set; }

    /// <summary>Availability percentage (5 decimal places), or "N/A" if fully excluded.</summary>
    public string AvailabilityPct => EligibleMinutes > 0
            ? Math.Round(AvailableMinutes / EligibleMinutes * 100, 5).ToString("F5")
            : "N/A";
}
