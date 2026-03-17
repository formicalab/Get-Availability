using Azure.Core;
using GetAvailability.Models;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>
/// Queries Azure Activity Log REST API for VM, SQL DB, and Storage lifecycle transitions.
/// Activity Log retains events for 90 days, enabling analysis beyond the 14-day
/// resourcechanges limit. Queries include a 30-day lookback before the analysis period
/// to capture initial power state of resources (e.g., a VM stopped 2 weeks before the
/// analysis month that starts during it).
/// </summary>
public static class ActivityLogService
{
    // Maps Activity Log operation names (case-insensitive) to lifecycle event kinds.
    // Only Succeeded events are queried — these represent completed state transitions.
    // Restart is intentionally excluded: it's a transient event (VM running→down→running),
    // and the brief unavailability is captured by the availability metric.
    private static readonly Dictionary<string, string> OperationMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["microsoft.compute/virtualmachines/start/action"] = "Start",
        ["microsoft.compute/virtualmachines/deallocate/action"] = "Stop",
        ["microsoft.compute/virtualmachines/poweroff/action"] = "Stop",
        ["microsoft.compute/virtualmachines/delete"] = "Delete",
        ["microsoft.sql/servers/databases/resume/action"] = "Start",
        ["microsoft.sql/servers/databases/pause/action"] = "Stop",
        ["microsoft.sql/servers/databases/delete"] = "Delete",
        ["microsoft.storage/storageaccounts/delete"] = "Delete",
    };

    private static readonly string[] Providers = ["Microsoft.Compute", "Microsoft.Sql", "Microsoft.Storage"];

    /// <summary>
    /// Queries Activity Log per subscription and resource provider, running all combinations
    /// in parallel (up to 4 concurrent). The provider filter is required server-side to avoid
    /// fetching all Activity Log events (hundreds of thousands of pages without it).
    /// Includes a 30-day lookback before periodStart to determine initial resource state.
    /// Filters server-side to Succeeded events only. Results are paginated via nextLink.
    /// </summary>
    public static async Task<List<LifecycleEvent>> QueryAsync(
        TokenCredential credential, string[] subscriptionIds,
        DateTimeOffset periodStart, DateTimeOffset periodEnd,
        Dictionary<string, string> subIdToName)
    {
        // Extend query window 30 days before periodStart to capture pre-period state changes.
        // This ensures the EligibilityCalculator can correctly determine if a resource was
        // stopped before the analysis period. Pre-period events are clipped to [periodStart, periodEnd]
        // by ExclusionWindowHelper.Add, so they don't distort the eligible minute count.
        var queryStart = periodStart.AddDays(-30);

        // Clamp to Activity Log's 90-day retention
        var maxLookback = DateTimeOffset.UtcNow.AddDays(-89);
        if (queryStart < maxLookback) queryStart = maxLookback;

        var token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://management.azure.com/.default"]), default);

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        string startIso = queryStart.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ");
        string endIso = periodEnd.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ");

        // Build all (sub, provider) combinations to query in parallel
        var queries = new List<(string subId, string subName, string provider)>();
        foreach (var subId in subscriptionIds)
        {
            var subName = subIdToName.TryGetValue(subId, out var n) ? n : subId;
            foreach (var provider in Providers)
                queries.Add((subId, subName, provider));
        }

        var results = new ConcurrentBag<LifecycleEvent>();
        int completed = 0;
        int totalQueries = queries.Count;

        await Parallel.ForEachAsync(queries,
            new ParallelOptions { MaxDegreeOfParallelism = 4 },
            async (q, ct) =>
            {
                string filter = $"eventTimestamp ge '{startIso}' and eventTimestamp le '{endIso}'" +
                                $" and resourceProvider eq '{q.provider}' and status eq 'Succeeded'";

                string? url = $"https://management.azure.com/subscriptions/{q.subId}" +
                              $"/providers/Microsoft.Insights/eventtypes/management/values" +
                              $"?api-version=2015-04-01&$filter={Uri.EscapeDataString(filter)}";

                while (url != null)
                {
                    string json = await GetWithRetryAsync(http, url);
                    using var doc = JsonDocument.Parse(json);

                    if (doc.RootElement.TryGetProperty("value", out var value) &&
                        value.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var evt in value.EnumerateArray())
                        {
                            var opName = evt.TryGetProperty("operationName", out var opObj) &&
                                         opObj.TryGetProperty("value", out var opVal)
                                ? opVal.GetString()
                                : null;

                            if (opName == null || !OperationMap.TryGetValue(opName, out var eventKind))
                                continue;

                            var resourceId = evt.GetProperty("resourceId").GetString()!;
                            var timestamp = DateTimeOffset.Parse(
                                evt.GetProperty("eventTimestamp").GetString()!).ToUniversalTime();

                            results.Add(new LifecycleEvent(resourceId, timestamp, eventKind));
                        }
                    }

                    url = doc.RootElement.TryGetProperty("nextLink", out var next) &&
                          next.ValueKind == JsonValueKind.String
                        ? next.GetString()
                        : null;
                }

                var done = Interlocked.Increment(ref completed);
                Console.Write($"\r  Activity Log: {done}/{totalQueries} queries completed...          ");
            });

        Console.WriteLine();
        return results.ToList();
    }

    /// <summary>
    /// HTTP GET with retry on 429 (Too Many Requests) and 5xx server errors.
    /// Uses Retry-After header when available, otherwise exponential backoff (1s, 2s, 4s, 8s, 16s).
    /// </summary>
    private static async Task<string> GetWithRetryAsync(HttpClient http, string url)
    {
        for (int attempt = 0; ; attempt++)
        {
            using var response = await http.GetAsync(url);

            if (response.StatusCode == System.Net.HttpStatusCode.TooManyRequests ||
                (int)response.StatusCode >= 500)
            {
                if (attempt >= 5) response.EnsureSuccessStatusCode(); // throw after max retries
                var delay = response.Headers.RetryAfter?.Delta
                            ?? TimeSpan.FromSeconds(1 << attempt);
                await Task.Delay(delay);
                continue;
            }

            response.EnsureSuccessStatusCode();
            return await response.Content.ReadAsStringAsync();
        }
    }
}
