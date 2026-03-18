using Azure.Core;
using GetAvailability.Models;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>
/// Queries Azure Resource Health availability status history via REST API to verify
/// metric gaps (null and 0% datapoints). Uses direct HTTP calls (no SDK dependency)
/// for AOT compatibility. Null gaps outside faults are healthy; 0% gaps are only
/// excused during Unknown health windows (Azure Monitor issue).
/// </summary>
public static class ResourceHealthService
{
    /// <summary>
    /// For resources with metric gaps, queries Resource Health history and classifies each
    /// gap minute. Returns a dictionary keyed by lowercase resource ID with fault/trustedZero/healthy counts.
    /// </summary>
    public static async Task<ConcurrentDictionary<string, GapClassification>> CheckGapsAsync(
        TokenCredential credential,
        IReadOnlyList<(TrackedResource Res, long[] AllGapTicks, HashSet<long>? ZeroTicks)> candidates,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int parallelism)
    {
        Console.WriteLine($"Checking Resource Health for {candidates.Count} resource(s) with metric gaps...");

        var token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://management.azure.com/.default"]), default);

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        var results = new ConcurrentDictionary<string, GapClassification>(StringComparer.OrdinalIgnoreCase);
        int done = 0;
        int total = candidates.Count;

        await Parallel.ForEachAsync(candidates,
            new ParallelOptions { MaxDegreeOfParallelism = parallelism },
            async (candidate, ct) =>
            {
                var (res, allGapTicks, zeroTicks) = candidate;
                var classification = await ClassifyGapsAsync(http, res, allGapTicks, zeroTicks, periodStart, periodEnd, ct);
                results[res.ResourceId.ToLowerInvariant()] = classification;

                int current = Interlocked.Increment(ref done);
                if (current % 10 == 0 || current == total)
                    Console.Write($"\r  [{current} / {total}] {res.Name,-50}");
            });

        Console.WriteLine();
        return results;
    }

    /// <summary>
    /// Fetches health history for a single resource and classifies each gap-tick minute.
    /// Classification rules differ by gap type:
    ///   - Null metric in fault interval (Unavailable/Degraded) → downtime
    ///   - Null metric outside fault interval → healthy gap (VM off, telemetry gap, etc.)
    ///   - 0% metric in fault interval → downtime (confirmed outage)
    ///   - 0% metric in Unknown window → healthy gap (Azure Monitor issue)
    ///   - 0% metric outside fault/Unknown → downtime (requests failed, no health explanation)
    /// </summary>
    private static async Task<GapClassification> ClassifyGapsAsync(
        HttpClient http,
        TrackedResource resource,
        long[] allGapTicks,
        HashSet<long>? zeroTicks,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        CancellationToken ct)
    {
        List<HealthTransition> transitions;
        try
        {
            transitions = await FetchHealthHistoryAsync(http, resource.ResourceId, ct);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"  WARNING: Resource Health query failed for '{resource.Name}': {ex.Message}");
            // On failure, conservatively treat all gaps as faults (don't hide potential downtime)
            return new GapClassification(allGapTicks.Length, 0, 0);
        }

        var faultIntervals = BuildFaultIntervals(transitions, periodStart, periodEnd);
        var unknownIntervals = BuildUnknownIntervals(transitions, periodStart, periodEnd);

        int faultMin = 0;
        int trustedZeroMin = 0;
        int healthyGapMin = 0;

        foreach (long tick in allGapTicks)
        {
            bool inFault = IsInInterval(tick, faultIntervals);
            bool isZero = zeroTicks is not null && zeroTicks.Contains(tick);

            if (inFault)
            {
                // Confirmed outage (Unavailable/Degraded) — counts as downtime
                faultMin++;
            }
            else if (isZero)
            {
                // 0% metric: only excuse during Unknown windows (Azure Monitor issue).
                // Outside Unknown, 0% with transactions is real downtime.
                if (IsInInterval(tick, unknownIntervals))
                    healthyGapMin++;
                else
                    trustedZeroMin++;
            }
            else
            {
                // Null metric outside fault interval — healthy gap
                healthyGapMin++;
            }
        }

        return new GapClassification(faultMin, trustedZeroMin, healthyGapMin);
    }

    private static bool IsInInterval(long tick, List<(DateTimeOffset From, DateTimeOffset To)> intervals)
    {
        foreach (var (from, to) in intervals)
        {
            if (tick >= from.UtcTicks && tick < to.UtcTicks)
                return true;
        }
        return false;
    }

    /// <summary>
    /// Calls the Resource Health REST API to list availability statuses for a resource.
    /// GET {resourceUri}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2025-05-01
    /// Returns transitions ordered by OccurredOn ascending.
    /// Parses multiple fields for robust customer-vs-platform classification:
    ///   - availabilityState: Available | Unavailable | Degraded | Unknown
    ///   - reasonType: "Customer Initiated", "User Initiated", "Unplanned", "Planned", etc.
    ///   - context: "Customer Initiated" or "Platform Initiated"
    ///   - healthEventCause: "UserInitiated" or "PlatformInitiated"
    /// Retries up to 5 times on 429/5xx with exponential backoff.
    /// </summary>
    private static async Task<List<HealthTransition>> FetchHealthHistoryAsync(
        HttpClient http,
        string resourceId,
        CancellationToken ct)
    {
        var transitions = new List<HealthTransition>();

        string? url = $"https://management.azure.com{resourceId}" +
                      "/providers/Microsoft.ResourceHealth/availabilityStatuses" +
                      "?api-version=2025-05-01";

        while (url != null)
        {
            string json = await GetWithRetryAsync(http, url, ct);
            using var doc = JsonDocument.Parse(json);

            if (doc.RootElement.TryGetProperty("value", out var value) &&
                value.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in value.EnumerateArray())
                {
                    if (!item.TryGetProperty("properties", out var props))
                        continue;

                    string? occurredStr = props.TryGetProperty("occuredTime", out var occurredEl)
                        ? occurredEl.GetString() : null;

                    if (occurredStr is null || !DateTimeOffset.TryParse(occurredStr, out var occurred))
                        continue;

                    transitions.Add(new HealthTransition(
                        occurred.ToUniversalTime(),
                        GetPropString(props, "availabilityState"),
                        GetPropString(props, "reasonType"),
                        GetPropString(props, "context"),
                        GetPropString(props, "healthEventCause")));
                }
            }

            url = doc.RootElement.TryGetProperty("nextLink", out var next) &&
                  next.ValueKind == JsonValueKind.String
                ? next.GetString()
                : null;
        }

        // API returns newest-first; reverse to chronological order
        transitions.Reverse();
        return transitions;
    }

    private static string GetPropString(JsonElement props, string name)
        => props.TryGetProperty(name, out var el) ? el.GetString() ?? "" : "";

    /// <summary>
    /// HTTP GET with retry on 429 and 5xx errors. Uses Retry-After header when available,
    /// otherwise exponential backoff.
    /// </summary>
    private static async Task<string> GetWithRetryAsync(HttpClient http, string url, CancellationToken ct)
    {
        for (int attempt = 0; ; attempt++)
        {
            using var response = await http.GetAsync(url, ct);

            if (response.StatusCode == System.Net.HttpStatusCode.TooManyRequests ||
                (int)response.StatusCode >= 500)
            {
                if (attempt >= 5) response.EnsureSuccessStatusCode();
                var delay = response.Headers.RetryAfter?.Delta
                            ?? TimeSpan.FromSeconds(1 << attempt);
                await Task.Delay(delay, ct);
                continue;
            }

            response.EnsureSuccessStatusCode();
            return await response.Content.ReadAsStringAsync(ct);
        }
    }

    /// <summary>
    /// Builds fault intervals from a chronologically-ordered list of health transitions.
    /// Only Unavailable and Degraded states open a fault interval. Non-fault states that
    /// close any open interval:
    ///   - Available: resource confirmed healthy
    ///   - Unknown: Azure cannot determine health (typically an Azure Monitor issue)
    ///   - Customer-initiated: detected via reasonType, context, or healthEventCause fields
    /// If still faulted at the end, the interval extends to periodEnd.
    /// </summary>
    private static List<(DateTimeOffset From, DateTimeOffset To)> BuildFaultIntervals(
        List<HealthTransition> transitions,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd)
    {
        var intervals = new List<(DateTimeOffset, DateTimeOffset)>();
        DateTimeOffset? faultStart = null;

        foreach (var t in transitions)
        {
            bool isAvailable = t.State.Equals("Available", StringComparison.OrdinalIgnoreCase);
            bool isUnknown = t.State.Equals("Unknown", StringComparison.OrdinalIgnoreCase);
            bool isCustomer = IsCustomerInitiated(t);

            // Non-fault states that close any open fault interval:
            //   - Available: resource confirmed healthy
            //   - Unknown: Azure cannot determine health (typically Azure Monitor issue, not a real fault)
            //   - Customer-initiated: stop/deallocate/restart — gap minutes subtracted from eligible
            // Only Unavailable and Degraded open fault intervals.
            bool isFault = !isAvailable && !isUnknown && !isCustomer;

            if (isFault && faultStart is null)
            {
                faultStart = t.OccurredOn < periodStart ? periodStart : t.OccurredOn;
            }
            else if (!isFault && faultStart is not null)
            {
                var end = t.OccurredOn > periodEnd ? periodEnd : t.OccurredOn;
                if (end > faultStart.Value)
                    intervals.Add((faultStart.Value, end));
                faultStart = null;
            }
        }

        if (faultStart is not null)
            intervals.Add((faultStart.Value, periodEnd));

        return intervals;
    }

    /// <summary>
    /// Builds intervals where the resource was in Unknown state (Azure Monitor issues).
    /// 0% metric values during these intervals are treated as monitoring artifacts, not real faults.
    /// </summary>
    private static List<(DateTimeOffset From, DateTimeOffset To)> BuildUnknownIntervals(
        List<HealthTransition> transitions,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd)
    {
        var intervals = new List<(DateTimeOffset, DateTimeOffset)>();
        DateTimeOffset? unknownStart = null;

        foreach (var t in transitions)
        {
            bool isUnknown = t.State.Equals("Unknown", StringComparison.OrdinalIgnoreCase);

            if (isUnknown && unknownStart is null)
            {
                unknownStart = t.OccurredOn < periodStart ? periodStart : t.OccurredOn;
            }
            else if (!isUnknown && unknownStart is not null)
            {
                var end = t.OccurredOn > periodEnd ? periodEnd : t.OccurredOn;
                if (end > unknownStart.Value)
                    intervals.Add((unknownStart.Value, end));
                unknownStart = null;
            }
        }

        if (unknownStart is not null)
            intervals.Add((unknownStart.Value, periodEnd));

        return intervals;
    }

    /// <summary>
    /// Determines whether a health transition was caused by a customer/user action
    /// using multiple API fields for robust detection. Any positive signal is sufficient.
    /// </summary>
    private static bool IsCustomerInitiated(HealthTransition t)
        => t.ReasonType.Equals("Customer Initiated", StringComparison.OrdinalIgnoreCase)
        || t.ReasonType.Equals("User Initiated", StringComparison.OrdinalIgnoreCase)
        || t.Context.Equals("Customer Initiated", StringComparison.OrdinalIgnoreCase)
        || t.HealthEventCause.Equals("UserInitiated", StringComparison.OrdinalIgnoreCase);
}

/// <summary>Parsed health status transition from the Resource Health API.</summary>
internal readonly record struct HealthTransition(
    DateTimeOffset OccurredOn,
    string State,
    string ReasonType,
    string Context,
    string HealthEventCause);

/// <summary>Result of classifying unexplained metric gap minutes via Resource Health.</summary>
/// <param name="FaultMinutes">Gap minutes inside confirmed fault intervals (Unavailable/Degraded).</param>
/// <param name="TrustedZeroMinutes">0% metric minutes outside fault and Unknown intervals — trusted as real downtime.</param>
/// <param name="HealthyGapMinutes">Null gaps outside faults + 0% in Unknown windows — subtracted from eligible.</param>
public readonly record struct GapClassification(int FaultMinutes, int TrustedZeroMinutes, int HealthyGapMinutes);
