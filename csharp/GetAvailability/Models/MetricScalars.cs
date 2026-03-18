namespace GetAvailability.Models;

/// <summary>Compact result from per-resource metric computation.</summary>
/// <param name="AvailableSum">Sum of metric values above 0% (each 0.0–1.0). Null and 0% are excluded (routed as gaps). Becomes AvailableMinutes.</param>
/// <param name="GapMinutes">Total count of null-metric and 0%-metric minutes to verify via Resource Health.</param>
/// <param name="ZeroTxMin">Storage only: minutes with zero transactions — subtracted from eligible.</param>
/// <param name="NoData">True when the primary metric returned no data points at all (broken telemetry).</param>
/// <param name="GapTicks">UTC ticks of null-metric minutes, for Resource Health gap classification.</param>
/// <param name="ZeroAvailTicks">UTC ticks of 0%-metric minutes — only excused during Unknown health windows.</param>
/// <param name="DegradedMinutes">Minutes where a metric datapoint was present but below 100% (and above 0%).</param>
public readonly record struct MetricScalars(
    double AvailableSum,
    int GapMinutes,
    int ZeroTxMin,
    bool NoData = false,
    long[]? GapTicks = null,
    long[]? ZeroAvailTicks = null,
    int DegradedMinutes = 0);
