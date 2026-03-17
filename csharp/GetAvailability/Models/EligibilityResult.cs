namespace GetAvailability.Models;

public sealed class EligibilityResult
{
    public required string Name { get; init; }
    public required string Kind { get; init; }
    public required string ResourceId { get; init; }
    public required string ResourceGroupName { get; init; }
    public required string Location { get; init; }
    public required string SubscriptionName { get; init; }
    public DateTimeOffset? CreatedAt { get; init; }
    public int EligibleMinutes { get; set; }
    public int TotalMinutes { get; init; }
    public required string Explanation { get; init; }
    public ExclusionWindow[] ExclusionWindows { get; init; } = [];

    // Populated after metric computation
    public double AvailableMinutes { get; set; }
    public string AvailabilityPct => EligibleMinutes > 0
        ? Math.Round(AvailableMinutes / EligibleMinutes * 100, 5).ToString("F5")
        : "N/A";
}
