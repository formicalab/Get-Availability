namespace GetAvailability.Models;

/// <summary>Per-resource availability result. Eligible minutes start at the observation-window
/// total and are reduced by suspect minutes that are later classified as lifecycle activity,
/// metric issues, customer-initiated transitions, or zero-transaction storage minutes.</summary>
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

    /// <summary>Suspect minutes confirmed as platform issues by Resource Health fault intervals.</summary>
    public int ConfirmedDowntimeMinutes { get; set; }

    /// <summary>Suspect minutes that remain unexplained after Activity Log, Resource Health,
    /// and fallback classification have been applied.</summary>
    public int UnexplainedSuspectMinutes { get; set; }

    /// <summary>Availability percentage (5 decimal places), or "N/A" if fully excluded.</summary>
    public string AvailabilityPct => EligibleMinutes > 0
            ? Math.Round(AvailableMinutes / EligibleMinutes * 100, 5).ToString("F5")
            : "N/A";
}
