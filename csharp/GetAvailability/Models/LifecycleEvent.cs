namespace GetAvailability.Models;

/// <summary>A normalized lifecycle transition detected from Activity Log (or synthesized from inventory CreatedAt).</summary>
public readonly record struct LifecycleEvent(
    string ResourceId,
    DateTimeOffset EventTimestamp,
    string EventKind  // Start | Stop | Create | Delete
);
