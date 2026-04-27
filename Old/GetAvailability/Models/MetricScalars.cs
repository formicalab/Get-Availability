namespace GetAvailability.Models;

/// <summary>Compact result from per-resource metric computation.</summary>
/// <param name="AvailableSum">Sum of metric values above 0% (each 0.0–1.0). Becomes AvailableMinutes after customer-excused degraded contributions are removed.</param>
/// <param name="GapMinutes">Count of null and 0%-valued suspect minutes.</param>
/// <param name="ZeroTxMin">Storage only: minutes with zero transactions — subtracted from eligible.</param>
/// <param name="ExcludeFromAvailability">True when the metric API returned no usable datapoints at all for the window. These resources are excluded from availability calculations.</param>
/// <param name="GapTicks">UTC ticks of null-valued suspect minutes.</param>
/// <param name="ZeroAvailTicks">UTC ticks of 0%-valued suspect minutes.</param>
/// <param name="DegradedMinutes">Minutes where a metric datapoint was present and strictly between 0% and 100%.</param>
/// <param name="DegradedSamples">Normalized availability values for positive degraded datapoints, used to remove customer-excused degraded contributions from eligibility and available minutes.</param>
public readonly record struct MetricScalars(
    double AvailableSum,
    int GapMinutes,
    int ZeroTxMin,
    bool ExcludeFromAvailability = false,
    long[]? GapTicks = null,
    long[]? ZeroAvailTicks = null,
    int DegradedMinutes = 0,
    MetricValueSample[]? DegradedSamples = null)
{
    public int SuspectMinutes => GapMinutes + DegradedMinutes;
}

/// <summary>Minute-level normalized availability value for a degraded datapoint.</summary>
public readonly record struct MetricValueSample(long Tick, double Value);
