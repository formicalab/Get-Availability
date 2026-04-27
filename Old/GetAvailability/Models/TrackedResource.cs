namespace GetAvailability.Models;

/// <summary>An Azure resource discovered via Resource Graph inventory query.</summary>
public sealed record TrackedResource
{
    public required string Name { get; init; }
    public required string Kind { get; init; }  // VirtualMachine | AzureSqlDatabase | StorageAccount | WebApp
    public required string ResourceId { get; init; }
    public required string SubscriptionId { get; init; }
    public required string SubscriptionName { get; init; }
    public required string ResourceGroupName { get; init; }
    public required string Location { get; init; }
}
