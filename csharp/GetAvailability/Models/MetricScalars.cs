namespace GetAvailability.Models;

/// <summary>Compact result from per-resource metric computation (no arrays, minimal GC pressure).</summary>
public readonly record struct MetricScalars(double AvailableSum, int Recovered, int ZeroTxMin);
