using Azure.Core;
using GetAvailability.Models;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>
/// Queries Azure Resource Health availability status history via REST API to verify
/// metric gaps (null and 0% datapoints). Uses direct HTTP calls (no SDK dependency)
/// for AOT compatibility. Resource Health is the primary classifier; for supported
/// resource kinds, unresolved non-perfect minutes are also cross-checked against
/// Activity Log lifecycle operations. Non-perfect datapoints that align with
/// customer/admin-initiated activity are excluded from eligibility. Null gaps outside
/// faults are healthy; 0% gaps are excused during Unknown or customer/admin-initiated
/// windows.
/// </summary>
public static class ResourceHealthService
{

    /// <summary>
    /// For resources with non-perfect metric minutes, queries Resource Health history and classifies
    /// gap minutes plus degraded datapoints. For supported resource kinds, unresolved minutes
    /// after Resource Health are then cross-checked against Activity Log lifecycle operations.
    /// Returns a dictionary keyed by lowercase resource ID.
    /// </summary>
    public static async Task<ConcurrentDictionary<string, HealthClassification>> CheckGapsAsync(
        TokenCredential credential,
        IReadOnlyList<(TrackedResource Res, long[] AllGapTicks, HashSet<long>? ZeroTicks, MetricValueSample[]? DegradedSamples)> candidates,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int parallelism,
        int activityGraceMinutes)
    {
        Console.WriteLine($"Checking Resource Health for {candidates.Count} resource(s) with metric gaps...");

        var token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://management.azure.com/.default"]), default);

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        var results = new ConcurrentDictionary<string, HealthClassification>(StringComparer.OrdinalIgnoreCase);
        int done = 0;
        int total = candidates.Count;

        await Parallel.ForEachAsync(candidates,
            new ParallelOptions { MaxDegreeOfParallelism = parallelism },
            async (candidate, ct) =>
            {
                var (res, allGapTicks, zeroTicks, degradedSamples) = candidate;
                var classification = await ClassifyGapsAsync(
                    http,
                    res,
                    allGapTicks,
                    zeroTicks,
                    degradedSamples,
                    periodStart,
                    periodEnd,
                    activityGraceMinutes,
                    ct);
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
    ///   - 0% metric in Unknown or customer-initiated window → healthy gap
    ///   - 0% metric outside fault/Unknown → unresolved; for supported kinds it can still be excused by Activity Log
    ///   - Positive degraded metric in customer-initiated window → excluded from eligibility
    ///   - Positive degraded metric with no health explanation → for supported kinds it can still be excused by Activity Log
    /// </summary>
    private static async Task<HealthClassification> ClassifyGapsAsync(
        HttpClient http,
        TrackedResource resource,
        long[] allGapTicks,
        HashSet<long>? zeroTicks,
        MetricValueSample[]? degradedSamples,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes,
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
            // On failure, conservatively treat all gaps as faults and keep degraded datapoints unchanged.
            return new HealthClassification(allGapTicks.Length, 0, 0, 0, 0, 0, 0, 0, 0);
        }

        var faultIntervals = BuildFaultIntervals(transitions, periodStart, periodEnd);
        var unknownIntervals = BuildUnknownIntervals(transitions, periodStart, periodEnd);
        var customerIntervals = BuildCustomerIntervals(transitions, periodStart, periodEnd);

        int faultMin = 0;
        int trustedZeroMin = 0;
        int healthyGapMin = 0;
        int customerExcusedDegradedMin = 0;
        double customerExcusedDegradedAvail = 0;
        int activityLogGapMin = 0;
        int activityLogDegradedMin = 0;
        int activityLogCheckedGapMin = 0;
        int activityLogCheckedDegradedMin = 0;

        var pendingNullTicks = new List<long>();
        var pendingZeroTicks = new List<long>();
        var pendingDegradedSamples = new List<MetricValueSample>();

        foreach (long tick in allGapTicks)
        {
            bool inFault = IsInInterval(tick, faultIntervals);
            bool isZero = zeroTicks is not null && zeroTicks.Contains(tick);
            bool inCustomer = IsInInterval(tick, customerIntervals);

            if (inFault)
            {
                // Confirmed outage (Unavailable/Degraded) — counts as downtime
                faultMin++;
            }
            else if (inCustomer)
            {
                // Customer/user initiated stop/deallocate/restart — exclude from eligibility
                healthyGapMin++;
            }
            else if (isZero)
            {
                // 0% metric: excuse during Unknown windows (Azure Monitor issue).
                // Outside Unknown/customer windows, defer to Activity Log if applicable.
                if (IsInInterval(tick, unknownIntervals))
                    healthyGapMin++;
                else
                    pendingZeroTicks.Add(tick);
            }
            else
            {
                // Null metric outside fault interval — healthy gap. For supported kinds we still
                // try to tie it to an explicit lifecycle action in Activity Log before finalizing.
                pendingNullTicks.Add(tick);
            }
        }

        if (degradedSamples is not null)
        {
            foreach (var sample in degradedSamples)
            {
                if (IsInInterval(sample.Tick, customerIntervals))
                {
                    customerExcusedDegradedMin++;
                    customerExcusedDegradedAvail += sample.Value;
                }
                else
                {
                    pendingDegradedSamples.Add(sample);
                }
            }
        }

        if (ActivityLogService.SupportsKind(resource.Kind) &&
            (pendingNullTicks.Count > 0 || pendingZeroTicks.Count > 0 || pendingDegradedSamples.Count > 0))
        {
            try
            {
                activityLogCheckedGapMin = pendingNullTicks.Count + pendingZeroTicks.Count;
                activityLogCheckedDegradedMin = pendingDegradedSamples.Count;
                var activityIntervals = await ActivityLogService.BuildLifecycleIntervalsAsync(
                    http,
                    resource,
                    periodStart,
                    periodEnd,
                    activityGraceMinutes,
                    ct);

                foreach (long tick in pendingNullTicks)
                {
                    if (IsInInterval(tick, activityIntervals))
                        activityLogGapMin++;
                    healthyGapMin++;
                }

                foreach (long tick in pendingZeroTicks)
                {
                    if (IsInInterval(tick, activityIntervals))
                    {
                        healthyGapMin++;
                        activityLogGapMin++;
                    }
                    else
                    {
                        trustedZeroMin++;
                    }
                }

                foreach (var sample in pendingDegradedSamples)
                {
                    if (IsInInterval(sample.Tick, activityIntervals))
                    {
                        customerExcusedDegradedMin++;
                        customerExcusedDegradedAvail += sample.Value;
                        activityLogDegradedMin++;
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  WARNING: Activity Log query failed for '{resource.Name}': {ex.Message}");
                healthyGapMin += pendingNullTicks.Count;
                trustedZeroMin += pendingZeroTicks.Count;
            }
        }
        else
        {
            healthyGapMin += pendingNullTicks.Count;
            trustedZeroMin += pendingZeroTicks.Count;
        }

        return new HealthClassification(
            faultMin,
            trustedZeroMin,
            healthyGapMin,
            customerExcusedDegradedMin,
            customerExcusedDegradedAvail,
            activityLogGapMin,
            activityLogDegradedMin,
            activityLogCheckedGapMin,
            activityLogCheckedDegradedMin);
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

    private static string GetPropString(System.Text.Json.JsonElement props, string name)
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
    /// Builds intervals caused by customer/user activity. Any non-perfect datapoint inside
    /// these windows is excluded from eligibility because it reflects a deliberate action,
    /// not platform downtime.
    /// </summary>
    private static List<(DateTimeOffset From, DateTimeOffset To)> BuildCustomerIntervals(
        List<HealthTransition> transitions,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd)
    {
        var intervals = new List<(DateTimeOffset, DateTimeOffset)>();
        DateTimeOffset? customerStart = null;

        foreach (var t in transitions)
        {
            bool isCustomer = IsCustomerInitiated(t);

            if (isCustomer && customerStart is null)
            {
                customerStart = t.OccurredOn < periodStart ? periodStart : t.OccurredOn;
            }
            else if (!isCustomer && customerStart is not null)
            {
                var end = t.OccurredOn > periodEnd ? periodEnd : t.OccurredOn;
                if (end > customerStart.Value)
                    intervals.Add((customerStart.Value, end));
                customerStart = null;
            }
        }

        if (customerStart is not null)
            intervals.Add((customerStart.Value, periodEnd));

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
/// <param name="TrustedZeroMinutes">0% metric minutes outside fault, Unknown, and customer-initiated intervals — trusted as real downtime.</param>
/// <param name="HealthyGapMinutes">Null gaps outside faults plus 0%/null minutes excused by Unknown, customer-initiated windows, or supported Activity Log lifecycle matches — subtracted from eligible.</param>
/// <param name="CustomerExcusedDegradedMinutes">Positive degraded datapoints excused by customer/admin-initiated activity and removed from eligibility.</param>
/// <param name="CustomerExcusedDegradedAvailableSum">Fractional available minutes contributed by customer/admin-excused degraded datapoints and removed from AvailableMinutes.</param>
/// <param name="ActivityLogGapMinutes">Subset of HealthyGapMinutes explained specifically by supported Activity Log lifecycle operations.</param>
/// <param name="ActivityLogDegradedMinutes">Subset of CustomerExcusedDegradedMinutes explained specifically by supported Activity Log lifecycle operations.</param>
/// <param name="ActivityLogCheckedGapMinutes">Gap minutes that remained unresolved after Resource Health and were explicitly checked against Activity Log.</param>
/// <param name="ActivityLogCheckedDegradedMinutes">Positive degraded minutes that remained unresolved after Resource Health and were explicitly checked against Activity Log.</param>
public readonly record struct HealthClassification(
    int FaultMinutes,
    int TrustedZeroMinutes,
    int HealthyGapMinutes,
    int CustomerExcusedDegradedMinutes,
    double CustomerExcusedDegradedAvailableSum,
    int ActivityLogGapMinutes,
    int ActivityLogDegradedMinutes,
    int ActivityLogCheckedGapMinutes,
    int ActivityLogCheckedDegradedMinutes);
