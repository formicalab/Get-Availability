using Azure.Core;
using GetAvailability.Models;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>
/// Fetches Azure Monitor metrics using the regional Batch API (metrics:getBatch) instead of
/// per-resource calls. Groups resources by (subscription, region, kind) and sends batched
/// POST requests to reduce total HTTP calls and throttling risk.
///
/// Batch API constraints:
///   - All resources in a batch must share subscription, region, and resource type.
///   - Max 50 resource IDs per batch call (default 10 for memory safety).
///   - Endpoint: https://{region}.metrics.monitor.azure.com
///   - Auth scope: https://metrics.monitor.azure.com/.default
/// </summary>
public static class BatchMetricsService
{
    private static readonly Dictionary<string, BatchMetricConfig> KindConfigs = new(StringComparer.OrdinalIgnoreCase)
    {
        ["VirtualMachine"] = new("Microsoft.Compute/virtualMachines", "VmAvailabilityMetric", "Minimum"),
        ["AzureSqlDatabase"] = new("Microsoft.Sql/servers/databases", "Availability", "Minimum"),
        ["StorageAccount"] = new("Microsoft.Storage/storageAccounts", "Availability,Transactions", "Minimum,Total"),
    };

    /// <summary>
    /// Queries metrics for all resources using the batch API. Returns a dictionary keyed by
    /// lowercase resource ID, same shape as MetricsService.QueryAsync for drop-in replacement.
    /// </summary>
    public static async Task<ConcurrentDictionary<string, MetricScalars>> QueryAsync(
        TokenCredential credential,
        IReadOnlyList<TrackedResource> resources,
        DateTimeOffset startDate,
        DateTimeOffset endDate,
        int parallelism,
        int batchSize = 10)
    {
        int total = resources.Count;

        // Acquire metrics-scoped token
        var tokenResponse = await credential.GetTokenAsync(
            new TokenRequestContext(["https://metrics.monitor.azure.com/.default"]), default);

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", tokenResponse.Token);
        http.Timeout = TimeSpan.FromMinutes(5);

        // Group resources by (subscriptionId, location, kind)
        var groups = new Dictionary<string, List<TrackedResource>>(StringComparer.OrdinalIgnoreCase);
        foreach (var res in resources)
        {
            string key = $"{res.SubscriptionId}|{res.Location.ToLowerInvariant()}|{res.Kind}";
            if (!groups.TryGetValue(key, out var list))
            {
                list = [];
                groups[key] = list;
            }
            list.Add(res);
        }

        // Build batch work items (chunks of batchSize)
        var workItems = new List<BatchWorkItem>();
        foreach (var (key, resList) in groups)
        {
            var parts = key.Split('|');
            string subId = parts[0], location = parts[1], kind = parts[2];
            if (!KindConfigs.TryGetValue(kind, out var config))
            {
                Console.Error.WriteLine($"  WARNING: No batch config for kind '{kind}', skipping.");
                continue;
            }

            for (int i = 0; i < resList.Count; i += batchSize)
            {
                var chunk = resList.GetRange(i, Math.Min(batchSize, resList.Count - i));
                workItems.Add(new BatchWorkItem(subId, location, kind, config, chunk));
            }
        }

        // Print grouping summary
        int uniqueRegions = groups.Keys
            .Select(k => k.Split('|')[1])
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Count();
        Console.WriteLine($"Grouped {total} resource(s) into {workItems.Count} batch(es) across {uniqueRegions} region(s) (max {batchSize} per batch).");

        foreach (var (key, resList) in groups.OrderBy(g => g.Key))
        {
            var parts = key.Split('|');
            string subName = resList[0].SubscriptionName;
            string kind = ShortKind(parts[2]);
            string location = parts[1];
            int chunks = (int)Math.Ceiling((double)resList.Count / batchSize);
            Console.WriteLine($"  {location} / {kind} / {Truncate(subName, 30)} : {resList.Count} resource(s) -> {chunks} batch(es)");
        }
        Console.WriteLine();

        string startIso = startDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ");
        string endIso = endDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ");

        var results = new ConcurrentDictionary<string, MetricScalars>(StringComparer.OrdinalIgnoreCase);
        int done = 0;
        int totalBatches = workItems.Count;

        await Parallel.ForEachAsync(workItems,
            new ParallelOptions { MaxDegreeOfParallelism = parallelism },
            async (workItem, ct) =>
            {
                await ProcessBatchWorkItemAsync(http, workItem, startIso, endIso, results, ct);

                int current = Interlocked.Increment(ref done);
                if (current % 5 == 0 || current == totalBatches)
                    Console.Write($"\r  Fetching batch metrics: {current}/{totalBatches} batches done");
            });

        Console.WriteLine($"\r  Batch queries completed. Received results for {results.Count} / {total} resource(s).          ");
        return results;
    }

    private static async Task ProcessBatchWorkItemAsync(
        HttpClient http,
        BatchWorkItem workItem,
        string startIso,
        string endIso,
        ConcurrentDictionary<string, MetricScalars> results,
        CancellationToken ct)
    {
        bool isVm = workItem.Kind == "VirtualMachine";
        bool isStorage = workItem.Kind == "StorageAccount";

        var resourceIds = workItem.Resources.Select(r => r.ResourceId).ToArray();

        string uri = $"https://{workItem.Location}.metrics.monitor.azure.com" +
                     $"/subscriptions/{workItem.SubscriptionId}/metrics:getBatch" +
                     $"?starttime={Uri.EscapeDataString(startIso)}" +
                     $"&endtime={Uri.EscapeDataString(endIso)}" +
                     $"&interval=PT1M" +
                     $"&metricnamespace={Uri.EscapeDataString(workItem.Config.Namespace)}" +
                     $"&metricnames={Uri.EscapeDataString(workItem.Config.MetricNames)}" +
                     $"&aggregation={Uri.EscapeDataString(workItem.Config.Aggregation)}" +
                     $"&api-version=2023-10-01";

        string bodyJson = BuildResourceIdsJson(resourceIds);

        // Build resource lookup
        var resById = new Dictionary<string, TrackedResource>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in workItem.Resources)
            resById[r.ResourceId.ToLowerInvariant()] = r;

        JsonDocument? doc = null;

        for (int attempt = 1; attempt <= 5; attempt++)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, uri)
                {
                    Content = new StringContent(bodyJson, System.Text.Encoding.UTF8, "application/json")
                };

                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                int statusCode = (int)response.StatusCode;

                if (statusCode >= 200 && statusCode < 300)
                {
                    await using var stream = await response.Content.ReadAsStreamAsync(ct);
                    doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);
                    break;
                }

                if ((statusCode == 401 || statusCode == 429 || statusCode >= 500) && attempt < 5)
                {
                    await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << attempt)), ct);
                    continue;
                }

                string names = string.Join(", ", workItem.Resources.Select(r => r.Name));
                Console.Error.WriteLine($"  WARNING: Batch metric query failed for [{names}]: HTTP {statusCode}");
                EmitExcludedResults(workItem.Resources, results);
                return;
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
                string names = string.Join(", ", workItem.Resources.Select(r => r.Name));
                Console.Error.WriteLine($"  WARNING: Batch metric query failed for [{names}]: {ex.Message}");
                EmitExcludedResults(workItem.Resources, results);
                return;
            }
        }

        if (doc is null)
        {
            EmitExcludedResults(workItem.Resources, results);
            return;
        }

        try
        {
            if (!doc.RootElement.TryGetProperty("values", out var valuesArray))
            {
                EmitExcludedResults(workItem.Resources, results);
                return;
            }

            foreach (var resourceEntry in valuesArray.EnumerateArray())
            {
                string resId = resourceEntry.GetProperty("resourceid").GetString()!;
                string resIdLower = resId.ToLowerInvariant();

                if (!resourceEntry.TryGetProperty("value", out var metricValueArr))
                {
                    results[resIdLower] = default;
                    continue;
                }

                if (isStorage)
                    results[resIdLower] = ProcessStorageBatch(metricValueArr);
                else
                    results[resIdLower] = ProcessVmOrSqlBatch(metricValueArr, isVm);
            }
        }
        finally
        {
            doc.Dispose();
        }
    }

    private static MetricScalars ProcessVmOrSqlBatch(JsonElement metricValueArr, bool isVm)
    {
        double availSum = 0;
        int numericPoints = 0;
        var nullTicks = new List<long>();
        var zeroTicks = new List<long>();
        var degraded = new List<MetricValueSample>();

        foreach (var metricEl in metricValueArr.EnumerateArray())
        {
            string mName = metricEl.GetProperty("name").GetProperty("value").GetString()!;
            bool isPrimary = mName.Equals("VmAvailabilityMetric", StringComparison.OrdinalIgnoreCase)
                          || mName.Equals("Availability", StringComparison.OrdinalIgnoreCase);
            if (!isPrimary) continue;

            foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
            foreach (var dp in tsEl.GetProperty("data").EnumerateArray())
            {
                long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!).ToUniversalTime().Ticks;
                double? minVal = TryGetDouble(dp, "minimum");

                if (minVal.HasValue)
                {
                    numericPoints++;
                    double v = isVm ? minVal.Value : minVal.Value / 100.0;
                    if (v == 0.0)
                    {
                        zeroTicks.Add(ticks);
                    }
                    else
                    {
                        availSum += v;
                        if (v < 1.0)
                            degraded.Add(new MetricValueSample(ticks, v));
                    }
                }
                else
                {
                    nullTicks.Add(ticks);
                }
            }
        }

        int gapMinutes = nullTicks.Count + zeroTicks.Count;
        int degradedMinutes = degraded.Count;
        bool exclude = numericPoints == 0 && nullTicks.Count == 0 && zeroTicks.Count == 0 && degradedMinutes == 0;

        return new MetricScalars(
            availSum, gapMinutes, 0, exclude,
            nullTicks.Count > 0 ? nullTicks.ToArray() : null,
            zeroTicks.Count > 0 ? zeroTicks.ToArray() : null,
            degradedMinutes,
            degraded.Count > 0 ? degraded.ToArray() : null);
    }

    private static MetricScalars ProcessStorageBatch(JsonElement metricValueArr)
    {
        double availSum = 0;
        int zeroTxMin = 0;
        int numericPoints = 0;
        var nullTicks = new List<long>();
        var zeroTicks = new List<long>();
        var degraded = new List<MetricValueSample>();

        // Build Transactions lookup
        var txByTicks = new Dictionary<long, double>();
        foreach (var metricEl in metricValueArr.EnumerateArray())
        {
            string mName = metricEl.GetProperty("name").GetProperty("value").GetString()!;
            if (!mName.Equals("Transactions", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
            foreach (var dp in tsEl.GetProperty("data").EnumerateArray())
            {
                long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!).ToUniversalTime().Ticks;
                double? tot = TryGetDouble(dp, "total");
                if (tot.HasValue)
                    txByTicks[ticks] = tot.Value;
            }
        }

        // Process Availability
        foreach (var metricEl in metricValueArr.EnumerateArray())
        {
            string mName = metricEl.GetProperty("name").GetProperty("value").GetString()!;
            if (!mName.Equals("Availability", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
            foreach (var dp in tsEl.GetProperty("data").EnumerateArray())
            {
                long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!).ToUniversalTime().Ticks;
                bool hasTx = txByTicks.TryGetValue(ticks, out double txVal) && txVal > 0;
                double? minVal = TryGetDouble(dp, "minimum");

                if (hasTx && minVal.HasValue)
                {
                    double norm = minVal.Value / 100.0;
                    numericPoints++;
                    if (norm == 0.0)
                    {
                        zeroTicks.Add(ticks);
                    }
                    else
                    {
                        availSum += norm;
                        if (norm < 1.0)
                            degraded.Add(new MetricValueSample(ticks, norm));
                    }
                }
                else if (hasTx && !minVal.HasValue)
                {
                    nullTicks.Add(ticks);
                }
                else if (!hasTx)
                {
                    zeroTxMin++;
                }
            }
        }

        int gapMinutes = nullTicks.Count + zeroTicks.Count;
        int degradedMinutes = degraded.Count;
        bool exclude = numericPoints == 0 && nullTicks.Count == 0 && zeroTicks.Count == 0 && degradedMinutes == 0;

        return new MetricScalars(
            availSum, gapMinutes, zeroTxMin, exclude,
            nullTicks.Count > 0 ? nullTicks.ToArray() : null,
            zeroTicks.Count > 0 ? zeroTicks.ToArray() : null,
            degradedMinutes,
            degraded.Count > 0 ? degraded.ToArray() : null);
    }

    /// <summary>Tries to read a double from a JSON data-point element. Returns null if the property is absent or not a number.</summary>
    private static double? TryGetDouble(JsonElement element, string propertyName)
    {
        if (element.TryGetProperty(propertyName, out var prop) && prop.ValueKind == JsonValueKind.Number)
            return prop.GetDouble();
        return null;
    }

    private static void EmitExcludedResults(
        List<TrackedResource> resources,
        ConcurrentDictionary<string, MetricScalars> results)
    {
        foreach (var r in resources)
            results[r.ResourceId.ToLowerInvariant()] = new MetricScalars(0, 0, 0, ExcludeFromAvailability: true);
    }

    private static string ShortKind(string kind) => kind switch
    {
        "VirtualMachine" => "VM",
        "AzureSqlDatabase" => "SQL",
        "StorageAccount" => "Storage",
        _ => kind,
    };

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : string.Concat(s.AsSpan(0, max - 3), "...");

    /// <summary>
    /// Builds the JSON body for the batch request without reflection (AOT-safe).
    /// Produces: {"resourceids":["id1","id2",...]}
    /// </summary>
    private static string BuildResourceIdsJson(string[] resourceIds)
    {
        using var ms = new System.IO.MemoryStream();
        using (var writer = new Utf8JsonWriter(ms))
        {
            writer.WriteStartObject();
            writer.WriteStartArray("resourceids");
            foreach (var id in resourceIds)
                writer.WriteStringValue(id);
            writer.WriteEndArray();
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(ms.ToArray());
    }

    private readonly record struct BatchMetricConfig(string Namespace, string MetricNames, string Aggregation);
    private readonly record struct BatchWorkItem(string SubscriptionId, string Location, string Kind, BatchMetricConfig Config, List<TrackedResource> Resources);
}
