namespace GetAvailability.Models;

/// <summary>Compact result from per-resource metric computation.</summary>
/// <param name="AvailableSum">Sum of metric values above 0% (each 0.0–1.0). Null and 0% are excluded (routed as gaps). Becomes AvailableMinutes.</param>
/// <param name="GapMinutes">Total count of null-metric and 0%-metric minutes to verify via Resource Health.</param>
/// <param name="ZeroTxMin">Storage only: minutes with zero transactions — subtracted from eligible.</param>
/// <param name="ExcludeFromAvailability">True when the resource produced no numeric availability datapoints across the full window. These resources are excluded from availability calculations.</param>
/// <param name="GapTicks">UTC ticks of null-metric minutes, for Resource Health gap classification.</param>
/// <param name="ZeroAvailTicks">UTC ticks of 0%-metric minutes — excused during Unknown or customer-initiated health windows.</param>
/// <param name="DegradedMinutes">Minutes where a metric datapoint was present but below 100% (and above 0%). These can later be excused if Resource Health shows customer-initiated activity.</param>
/// <param name="DegradedSamples">Normalized availability values for positive degraded datapoints, used to exclude customer-initiated degraded minutes from eligibility and available minutes.</param>
public readonly record struct MetricScalars(
    double AvailableSum,
    int GapMinutes,
    int ZeroTxMin,
    bool ExcludeFromAvailability = false,
    long[]? GapTicks = null,
    long[]? ZeroAvailTicks = null,
    int DegradedMinutes = 0,
    MetricValueSample[]? DegradedSamples = null);

/// <summary>Minute-level normalized availability value for a degraded datapoint.</summary>
public readonly record struct MetricValueSample(long Tick, double Value);
