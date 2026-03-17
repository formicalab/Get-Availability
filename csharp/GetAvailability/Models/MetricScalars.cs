namespace GetAvailability.Models;

/// <summary>Compact result from per-resource metric computation (no arrays, minimal GC pressure).</summary>
/// <param name="NoData">True when the primary metric returned null for every data point (broken telemetry).</param>
public readonly record struct MetricScalars(double AvailableSum, int Recovered, int ZeroTxMin, bool NoData = false);
