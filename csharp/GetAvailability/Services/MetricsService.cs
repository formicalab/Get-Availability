using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using GetAvailability.Helpers;
using GetAvailability.Models;
using System.Collections.Concurrent;

namespace GetAvailability.Services;

/// <summary>
/// Fetches Azure Monitor metrics per resource in parallel and computes available minutes inline.
/// Uses Parallel.ForEachAsync for concurrent metric API calls with configurable parallelism.
/// Each resource's metrics are processed entirely within the parallel task — only scalar results
/// (AvailableSum, Recovered, ZeroTxMin) are returned, minimizing cross-thread data and GC pressure.
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
    ///   VM:      VmAvailabilityMetric (0–1) + CPU + Network (for gap recovery) — 3 metrics, 1 API call
    ///   SQL DB:  Availability (0–100, normalized to 0–1) — 1 metric
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

        // VMs fetch 3 metrics in a single API call (~4MB, under Azure's 8MB limit).
        // The supplementary CPU and Network metrics enable inline gap recovery without a second call.
        string[] metricNames;
        if (isVm)
            metricNames = ["VmAvailabilityMetric", "Percentage CPU", "Network In Total"];
        else if (isStorage)
            metricNames = ["Availability", "Transactions"];
        else
            metricNames = ["Availability"];

        var options = new MetricsQueryOptions
        {
            Granularity = TimeSpan.FromMinutes(1),
            TimeRange = new QueryTimeRange(startDate, endDate),
        };
        if (isVm)
        {
            options.Aggregations.Add(MetricAggregationType.Minimum);
            options.Aggregations.Add(MetricAggregationType.Average);
        }
        else if (isStorage)
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

        // Build excluded ticks set from pre-computed tick arrays
        var windows = new ExclusionWindow[resource.ExclFromTicks.Length];
        for (int i = 0; i < windows.Length; i++)
            windows[i] = new ExclusionWindow(resource.ExclFromTicks[i], resource.ExclToTicks[i]);
        var excluded = ExclusionWindowHelper.BuildExcludedTickSet(windows);

        double availSum = 0.0;
        int recovered = 0;
        int zeroTxMin = 0;

        if (isStorage)
            ProcessStorage(response, excluded, ref availSum, ref zeroTxMin);
        else
            ProcessVmOrSql(response, excluded, isVm, ref availSum, ref recovered);

        return new MetricScalars(availSum, recovered, zeroTxMin);
    }

    /// <summary>
    /// Processes Storage Account metrics. A storage minute is only counted toward availability
    /// if there were actual transactions (Transactions > 0). Minutes with zero transactions
    /// have no availability signal and are tracked as zeroTxMin — later subtracted from eligibility.
    /// Availability values are 0–100, normalized to 0.0–1.0.
    /// </summary>
    private static void ProcessStorage(MetricsQueryResult response, HashSet<long> excluded,
        ref double availSum, ref int zeroTxMin)
    {
        // Build a lookup of transaction counts by minute (ticks) for cross-referencing with availability
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

        // For each availability data point, check if there were transactions at that minute.
        // Tx > 0 + avail present → count toward availability (normalized /100).
        // No transactions → count as zero-tx minute (subtracted from eligibility later).
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
                    if (!excluded.Contains(ticks))
                        availSum += val.Minimum.Value / 100.0;
                }
                else if (!hasTx)
                {
                    if (!excluded.Contains(ticks))
                        zeroTxMin++;
                }
            }
        }
    }

    /// <summary>
    /// Processes VM or SQL DB metrics. For VMs, also performs inline gap recovery:
    /// when VmAvailabilityMetric is null but both CPU and Network report data, the minute
    /// is recovered as available (1.0). This compensates for known Azure telemetry gaps.
    /// VM availability is 0.0–1.0 natively; SQL is 0–100, normalized to 0.0–1.0.
    /// </summary>
    private static void ProcessVmOrSql(MetricsQueryResult response, HashSet<long> excluded,
        bool isVm, ref double availSum, ref int recovered)
    {
        // Key supplementary metrics (CPU, Network) by ticks for O(1) gap recovery lookup.
        // Using long ticks avoids DateTime.ToString allocation per datapoint.
        // suppByTicks[minute] = count of supplementary metrics with non-null Average at that minute.
        // Gap recovery requires count >= 2 (both CPU and Network present).
        var suppByTicks = new Dictionary<long, int>();
        var nullTicks = new List<long>();  // primary metric minutes that were null (gaps)

        foreach (var metric in response.Metrics)
        {
            bool isPrimary = string.Equals(metric.Name, "VmAvailabilityMetric", StringComparison.OrdinalIgnoreCase)
                          || string.Equals(metric.Name, "Availability", StringComparison.OrdinalIgnoreCase);

            foreach (var ts in metric.TimeSeries)
            foreach (var val in ts.Values)
            {
                long ticks = val.TimeStamp.UtcTicks;

                if (isPrimary)
                {
                    if (val.Minimum.HasValue)
                    {
                        double v = val.Minimum.Value;
                        if (!isVm) v /= 100.0;  // SQL Availability is 0–100, normalize to 0–1
                        if (!excluded.Contains(ticks))
                            availSum += v;
                    }
                    else
                    {
                        nullTicks.Add(ticks);  // track for gap recovery
                    }
                }
                else if (isVm && val.Average.HasValue)  // supplementary metric (CPU or Network)
                {
                    long key = val.TimeStamp.UtcTicks;
                    suppByTicks[key] = suppByTicks.GetValueOrDefault(key) + 1;
                }
            }
        }

        // Inline gap recovery: require both CPU + Network non-null at the same minute
        if (isVm && nullTicks.Count > 0)
        {
            foreach (long nt in nullTicks)
            {
                if (!excluded.Contains(nt) && suppByTicks.GetValueOrDefault(nt) >= 2)
                {
                    recovered++;
                    availSum += 1.0;
                }
            }
        }
    }
}
