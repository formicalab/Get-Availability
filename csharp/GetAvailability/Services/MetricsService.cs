using Azure.Monitor.Query;
using Azure.Monitor.Query.Models;
using GetAvailability.Helpers;
using GetAvailability.Models;
using System.Collections.Concurrent;

namespace GetAvailability.Services;

public static class MetricsService
{
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
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt))), ct);
            }
            catch (Exception ex) when (attempt < 5 &&
                (ex.Message.Contains("transport", StringComparison.OrdinalIgnoreCase) ||
                 ex.Message.Contains("connection", StringComparison.OrdinalIgnoreCase) ||
                 ex.Message.Contains("timed out", StringComparison.OrdinalIgnoreCase)))
            {
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt))), ct);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  WARNING: Metric query failed for '{resource.Name}': {ex.Message}");
                return default;
            }
        }

        // Build excluded ticks set
        var excluded = ExclusionWindowHelper.BuildExcludedTickSet(
            resource.ExclFromTicks.Zip(resource.ExclToTicks, (f, t) => new ExclusionWindow(f, t)).ToArray());

        double availSum = 0.0;
        int recovered = 0;
        int zeroTxMin = 0;

        if (isStorage)
            ProcessStorage(response, excluded, ref availSum, ref zeroTxMin);
        else
            ProcessVmOrSql(response, excluded, isVm, ref availSum, ref recovered);

        return new MetricScalars(availSum, recovered, zeroTxMin);
    }

    private static void ProcessStorage(MetricsQueryResult response, HashSet<long> excluded,
        ref double availSum, ref int zeroTxMin)
    {
        // Build Transactions lookup
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

        // Process Availability
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

    private static void ProcessVmOrSql(MetricsQueryResult response, HashSet<long> excluded,
        bool isVm, ref double availSum, ref int recovered)
    {
        var suppByMinute = new Dictionary<string, int>();
        var nullTicks = new List<long>();

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
                        if (!isVm) v /= 100.0;
                        if (!excluded.Contains(ticks))
                            availSum += v;
                    }
                    else
                    {
                        nullTicks.Add(ticks);
                    }
                }
                else if (isVm && val.Average.HasValue)
                {
                    string key = val.TimeStamp.UtcDateTime.ToString("yyyy-MM-dd HH:mm");
                    suppByMinute[key] = suppByMinute.GetValueOrDefault(key) + 1;
                }
            }
        }

        // Inline gap recovery (VMs only, require both CPU + Network)
        if (isVm && nullTicks.Count > 0)
        {
            foreach (long nt in nullTicks)
            {
                if (!excluded.Contains(nt))
                {
                    var dt = new DateTimeOffset(nt, TimeSpan.Zero);
                    string key = dt.UtcDateTime.ToString("yyyy-MM-dd HH:mm");
                    if (suppByMinute.GetValueOrDefault(key) >= 2)
                    {
                        recovered++;
                        availSum += 1.0;
                    }
                }
            }
        }
    }
}
