namespace GetAvailability.Models;

/// <summary>A time interval (in UTC ticks) that should be excluded from availability calculations.</summary>
public readonly record struct ExclusionWindow(long FromTicks, long ToTicks);
