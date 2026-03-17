namespace GetAvailability.Models;

/// <summary>A normalized lifecycle transition detected from Resource Graph Changes.</summary>
public readonly record struct LifecycleEvent(
    string ResourceId,
    DateTimeOffset EventTimestamp,
    string EventKind  // Start | Stop | Create | Delete
);
