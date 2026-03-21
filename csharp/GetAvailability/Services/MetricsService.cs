using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using GetAvailability.Models;
using System.Collections.Concurrent;

namespace GetAvailability.Services;

/// <summary>
/// Fetches Azure Monitor metrics per resource in parallel and computes available minutes inline.
/// Uses Parallel.ForEachAsync for concurrent metric API calls with configurable parallelism.
/// Each resource's metrics are processed entirely within the parallel task — only scalar results
/// (AvailableSum, GapMinutes, ZeroTxMin, DegradedMinutes) are returned, minimising cross-thread
/// data and GC pressure. Suspect minutes are collected in three forms:
///   - null datapoints (GapTicks)
///   - exactly 0%-valued datapoints (ZeroAvailTicks)
///   - positive datapoints below 100% (DegradedSamples)
/// Resources are only flagged for N/A exclusion when the metric API returns no usable datapoints
/// at all for the full window.
/// </summary>
public static class MetricsService
{
    /// <summary>
    /// Queries metrics for all resources in parallel. Returns a dictionary keyed by lowercase resource ID.
    /// Progress is reported via console overwrite (\r) every 10 resources.
    /// </summary>
    public static async Task<ConcurrentDictionary<string, MetricScalars>> QueryAsync(
        MetricsQueryClient metricsClient,
        IReadOnlyList<TrackedResource> resources,
        DateTimeOffset startDate,
        DateTimeOffset endDate,
        int parallelism)
    {
        int total = resources.Count;
        Console.WriteLine($"Querying metrics for {total} resource(s) with parallelism {parallelism}...");

        var results = new ConcurrentDictionary<string, MetricScalars>(StringComparer.OrdinalIgnoreCase);
        int done = 0;

        await Parallel.ForEachAsync(resources,
            new ParallelOptions { MaxDegreeOfParallelism = parallelism },
            async (resource, ct) =>
            {
                var scalars = await QuerySingleResourceAsync(metricsClient, resource, startDate, endDate, ct);
                results[resource.ResourceId.ToLowerInvariant()] = scalars;

                int current = Interlocked.Increment(ref done);
                if (current % 10 == 0 || current == total)
                    Console.Write($"\r  [{current} / {total}] {resource.Name,-50}");
            });

        Console.WriteLine();
        return results;
    }

    /// <summary>
    /// Fetches metrics for a single resource with retry logic, then computes available minutes.
    /// Metrics requested per resource type:
    ///   VM:      VmAvailabilityMetric (0–1) — 1 metric
    ///   SQL DB:  Availability (0–100, normalised to 0–1) — 1 metric
    ///   Storage: Availability (0–100) + Transactions — 2 metrics, 1 API call
    /// Retries up to 5 times on 429 (throttle) and 5xx errors with exponential backoff.
    /// </summary>
    private static async Task<MetricScalars> QuerySingleResourceAsync(
        MetricsQueryClient metricsClient,
        TrackedResource resource,
        DateTimeOffset startDate,
        DateTimeOffset endDate,
        CancellationToken ct)
    {
        bool isVm = resource.Kind == "VirtualMachine";
        bool isStorage = resource.Kind == "StorageAccount";

        string[] metricNames;
        if (isVm)
            metricNames = ["VmAvailabilityMetric"];
        else if (isStorage)
            metricNames = ["Availability", "Transactions"];
        else
            metricNames = ["Availability"];

        var options = new MetricsQueryOptions
        {
            Granularity = TimeSpan.FromMinutes(1),
            TimeRange = new QueryTimeRange(startDate, endDate),
        };
        if (isStorage)
        {
            options.Aggregations.Add(MetricAggregationType.Minimum);
            options.Aggregations.Add(MetricAggregationType.Total);
        }
        else
        {
            options.Aggregations.Add(MetricAggregationType.Minimum);
        }

        // Retry loop with exponential backoff for throttling (429) and transient server errors (5xx)
        MetricsQueryResult response;
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                response = await metricsClient.QueryResourceAsync(
                    resource.ResourceId, metricNames, options, ct);
                break;
            }
            catch (Azure.RequestFailedException ex) when (attempt < 5 &&
                (ex.Status == 429 || ex.Status >= 500))
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << attempt)), ct);
            }
            catch (Exception ex) when (attempt < 5 &&
                (ex.Message.Contains("transport", StringComparison.OrdinalIgnoreCase) ||
                 ex.Message.Contains("connection", StringComparison.OrdinalIgnoreCase) ||
                 ex.Message.Contains("timed out", StringComparison.OrdinalIgnoreCase)))
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << attempt)), ct);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  WARNING: Metric query failed for '{resource.Name}': {ex.Message}");
                return default;
            }
        }

        double availSum = 0.0;
        int gapMinutes = 0;
        int zeroTxMin = 0;
        int degradedMinutes = 0;
        bool excludeFromAvailability = false;
        long[]? gapTicks = null;
        long[]? zeroAvailTicks = null;
        MetricValueSample[]? degradedSamples = null;

        if (isStorage)
            ProcessStorage(response, ref availSum, ref zeroTxMin, ref gapMinutes, ref degradedMinutes, out gapTicks, out zeroAvailTicks, out excludeFromAvailability, out degradedSamples);
        else
            ProcessVmOrSql(response, isVm, ref availSum, ref gapMinutes, ref degradedMinutes, out gapTicks, out zeroAvailTicks, out excludeFromAvailability, out degradedSamples);

        return new MetricScalars(availSum, gapMinutes, zeroTxMin, excludeFromAvailability, gapTicks, zeroAvailTicks, degradedMinutes, degradedSamples);
    }

    /// <summary>
    /// Processes Storage Account metrics. A storage minute is only counted toward availability
    /// if there were actual transactions (Transactions > 0). Minutes with zero transactions
    /// have no availability signal and are tracked as zeroTxMin — later subtracted from eligibility.
    /// Availability values are 0–100, normalised to 0.0–1.0.
    /// Null availability with transactions is tracked as a null suspect minute.
    /// Exactly 0% availability with transactions is tracked separately as a 0%-valued suspect minute.
    /// Non-zero values below 100% are tracked as degraded suspect minutes.
    /// </summary>
    private static void ProcessStorage(MetricsQueryResult response,
        ref double availSum, ref int zeroTxMin, ref int gapMinutes, ref int degradedMinutes,
        out long[]? gapTicks, out long[]? zeroAvailTicks, out bool excludeFromAvailability,
        out MetricValueSample[]? degradedSamples)
    {
        var nullTicks = new List<long>();
        var zeroTicks = new List<long>();
        var degraded = new List<MetricValueSample>();
        int numericAvailabilityPoints = 0;

        // Build a lookup of transaction counts by minute (ticks)
        var txByTicks = new Dictionary<long, double>();
        var txMetric = response.Metrics.FirstOrDefault(m =>
            string.Equals(m.Name, "Transactions", StringComparison.OrdinalIgnoreCase));
        if (txMetric != null)
        {
            foreach (var ts in txMetric.TimeSeries)
            foreach (var val in ts.Values)
            {
                if (val.Total.HasValue)
                    txByTicks[val.TimeStamp.UtcTicks] = val.Total.Value;
            }
        }

        var availMetric = response.Metrics.FirstOrDefault(m =>
            string.Equals(m.Name, "Availability", StringComparison.OrdinalIgnoreCase));
        if (availMetric != null)
        {
            foreach (var ts in availMetric.TimeSeries)
            foreach (var val in ts.Values)
            {
                long ticks = val.TimeStamp.UtcTicks;
                bool hasTx = txByTicks.TryGetValue(ticks, out double txVal) && txVal > 0;

                if (hasTx && val.Minimum.HasValue)
                {
                    double norm = val.Minimum.Value / 100.0;
                    numericAvailabilityPoints++;
                    if (norm == 0.0)
                    {
                        // Exactly 0% with transactions — tracked as a distinct suspect minute.
                        zeroTicks.Add(ticks);
                    }
                    else
                    {
                        availSum += norm;
                        if (norm < 1.0)
                        {
                            degradedMinutes++;
                            degraded.Add(new MetricValueSample(ticks, norm));
                        }
                    }
                }
                else if (hasTx && !val.Minimum.HasValue)
                {
                    // Transactions present but availability metric null — suspect minute.
                    nullTicks.Add(ticks);
                }
                else if (!hasTx)
                {
                    zeroTxMin++;
                }
            }
        }

        gapMinutes = nullTicks.Count + zeroTicks.Count;
        gapTicks = nullTicks.Count > 0 ? nullTicks.ToArray() : null;
        zeroAvailTicks = zeroTicks.Count > 0 ? zeroTicks.ToArray() : null;
        excludeFromAvailability = numericAvailabilityPoints == 0 && nullTicks.Count == 0 && zeroTicks.Count == 0 && degraded.Count == 0;
        degradedSamples = degraded.Count > 0 ? degraded.ToArray() : null;
    }

    /// <summary>
    /// Processes VM or SQL DB metrics. Null datapoints are collected as null suspect minutes and
    /// 0%-valued datapoints as zero-valued suspect minutes. Non-zero values below 100% are counted
    /// as degraded suspect minutes and tracked so lifecycle/customer explanations can later exclude
    /// them from eligibility and available-minute math.
    /// VM availability is 0.0–1.0 natively; SQL is 0–100, normalised to 0.0–1.0.
    /// </summary>
    private static void ProcessVmOrSql(MetricsQueryResult response,
        bool isVm, ref double availSum, ref int gapMinutes, ref int degradedMinutes,
        out long[]? gapTicks, out long[]? zeroAvailTicks, out bool excludeFromAvailability,
        out MetricValueSample[]? degradedSamples)
    {
        var nullTicks = new List<long>();
        var zeroTicks = new List<long>();
        var degraded = new List<MetricValueSample>();
        int numericAvailabilityPoints = 0;

        foreach (var metric in response.Metrics)
        {
            bool isPrimary = string.Equals(metric.Name, "VmAvailabilityMetric", StringComparison.OrdinalIgnoreCase)
                          || string.Equals(metric.Name, "Availability", StringComparison.OrdinalIgnoreCase);
            if (!isPrimary) continue;

            foreach (var ts in metric.TimeSeries)
            foreach (var val in ts.Values)
            {
                if (val.Minimum.HasValue)
                {
                    numericAvailabilityPoints++;
                    double v = val.Minimum.Value;
                    if (!isVm) v /= 100.0;  // SQL Availability is 0–100, normalise to 0–1
                    if (v == 0.0)
                    {
                        // Exactly 0 — tracked as a distinct suspect minute.
                        zeroTicks.Add(val.TimeStamp.UtcTicks);
                    }
                    else
                    {
                        availSum += v;
                        if (v < 1.0)
                        {
                            degradedMinutes++;
                            degraded.Add(new MetricValueSample(val.TimeStamp.UtcTicks, v));
                        }
                    }
                }
                else
                {
                    nullTicks.Add(val.TimeStamp.UtcTicks);
                }
            }
        }

        gapMinutes = nullTicks.Count + zeroTicks.Count;
        gapTicks = nullTicks.Count > 0 ? nullTicks.ToArray() : null;
        zeroAvailTicks = zeroTicks.Count > 0 ? zeroTicks.ToArray() : null;
        excludeFromAvailability = numericAvailabilityPoints == 0 && nullTicks.Count == 0 && zeroTicks.Count == 0 && degraded.Count == 0;
        degradedSamples = degraded.Count > 0 ? degraded.ToArray() : null;
    }
}
