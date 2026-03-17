namespace GetAvailability.Models;

public readonly record struct LifecycleEvent(
    string ResourceId,
    DateTimeOffset EventTimestamp,
    string EventKind            // Start, Stop, Create, Delete
);
