using Azure.Core;
using GetAvailability.Models;
using System.Collections.Concurrent;
using System.Net.Http.Headers;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>
/// Investigates suspect availability minutes using Azure Activity Log and Resource Health.
/// Suspect minutes are any metric datapoints that are null or below 100%.
///
/// Classification precedence is:
///   1. Platform fault from Resource Health wins over any other explanation.
///   2. Customer/admin lifecycle activity from Activity Log or customer-initiated
///      health states excludes the minute from eligibility.
///   3. Unknown health states excuse null/0% suspect minutes as monitoring artifacts.
///   4. Remaining null minutes are treated as metric issues and excluded from eligibility.
///   5. Remaining 0% minutes are treated as downtime.
///   6. Remaining positive degraded datapoints stay as degraded availability.
///
/// Resource Health is only available for the overlap with the current 30-day retention
/// window. This service is structured so older observation periods can later skip the
/// health-history step while still using Activity Log and metric-based fallbacks.
/// </summary>
public static class ResourceHealthService
{
    /// <summary>
    /// For resources with suspect metric minutes, investigates null/0% suspect minutes plus
    /// positive degraded datapoints. Activity Log is gathered first for supported kinds, then
    /// Resource Health is consulted for the portion of the observation window still within the
    /// current 30-day retention window.
    /// Returns a dictionary keyed by lowercase resource ID.
    /// </summary>
    public static async Task<ConcurrentDictionary<string, SuspectGapClassification>> InvestigateSuspectGapsAsync(
        TokenCredential credential,
        IReadOnlyList<(TrackedResource Res, long[] AllGapTicks, HashSet<long>? ZeroTicks, MetricValueSample[]? DegradedSamples)> candidates,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int parallelism,
        int activityGraceMinutes)
    {
        Console.WriteLine($"Investigating suspect gaps for {candidates.Count} resource(s)...");

        var token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://management.azure.com/.default"]), default);

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        var results = new ConcurrentDictionary<string, SuspectGapClassification>(StringComparer.OrdinalIgnoreCase);
        int done = 0;
        int total = candidates.Count;

        await Parallel.ForEachAsync(candidates,
            new ParallelOptions { MaxDegreeOfParallelism = parallelism },
            async (candidate, ct) =>
            {
                var (res, allGapTicks, zeroTicks, degradedSamples) = candidate;
                var classification = await ClassifySuspectGapsAsync(
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
    /// Fetches lifecycle activity and health history for a single resource, then classifies
    /// each suspect minute using the precedence documented on the class.
    /// </summary>
    private static async Task<SuspectGapClassification> ClassifySuspectGapsAsync(
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
        var activityIntervals = new List<(DateTimeOffset From, DateTimeOffset To)>();
        if (ActivityLogService.SupportsKind(resource.Kind) &&
            (allGapTicks.Length > 0 || (degradedSamples?.Length ?? 0) > 0))
        {
            try
            {
                activityIntervals = await ActivityLogService.BuildLifecycleIntervalsAsync(
                    http,
                    resource,
                    periodStart,
                    periodEnd,
                    activityGraceMinutes,
                    ct);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  WARNING: Activity Log query failed for '{resource.Name}': {ex.Message}");
            }
        }

        var healthCoverageStart = GetHealthCoverageStart(periodStart);
        bool healthHistoryApplied = healthCoverageStart < periodEnd;

        List<HealthTransition> transitions = [];
        if (healthHistoryApplied)
        {
            try
            {
                transitions = await FetchHealthHistoryAsync(http, resource.ResourceId, ct);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"  WARNING: Resource Health query failed for '{resource.Name}': {ex.Message}");
                // Conservative fallback: keep Activity Log results, but do not excuse any
                // remaining suspect minutes via Resource Health when the query fails.
                transitions = [];
            }
        }

        var faultIntervals = healthHistoryApplied
            ? BuildFaultIntervals(transitions, healthCoverageStart, periodEnd)
            : [];
        var unknownIntervals = healthHistoryApplied
            ? BuildUnknownIntervals(transitions, healthCoverageStart, periodEnd)
            : [];
        var customerIntervals = healthHistoryApplied
            ? BuildCustomerIntervals(transitions, healthCoverageStart, periodEnd)
            : [];

        int platformFaultGapMin = 0;
        int unresolvedZeroDowntimeMin = 0;
        int healthExplainedGapMin = 0;
        int metricIssueNullMin = 0;
        int activityLogExcludedGapMin = 0;
        int customerExcusedDegradedMin = 0;
        double customerExcusedDegradedAvail = 0;
        int activityLogDegradedMin = 0;
        int healthConfirmedDegradedMin = 0;

        foreach (long tick in allGapTicks)
        {
            bool isZero = zeroTicks is not null && zeroTicks.Contains(tick);
            bool inActivity = IsInInterval(tick, activityIntervals);
            bool inHealthCoverage = healthHistoryApplied && tick >= healthCoverageStart.UtcTicks;
            bool inFault = inHealthCoverage && IsInInterval(tick, faultIntervals);
            bool inUnknown = inHealthCoverage && IsInInterval(tick, unknownIntervals);
            bool inCustomer = inHealthCoverage && IsInInterval(tick, customerIntervals);

            if (inFault)
            {
                platformFaultGapMin++;
            }
            else if (inActivity)
            {
                activityLogExcludedGapMin++;
            }
            else if (inCustomer || inUnknown)
            {
                healthExplainedGapMin++;
            }
            else if (isZero)
            {
                unresolvedZeroDowntimeMin++;
            }
            else
            {
                metricIssueNullMin++;
            }
        }

        if (degradedSamples is not null)
        {
            foreach (var sample in degradedSamples)
            {
                bool inActivity = IsInInterval(sample.Tick, activityIntervals);
                bool inHealthCoverage = healthHistoryApplied && sample.Tick >= healthCoverageStart.UtcTicks;
                bool inFault = inHealthCoverage && IsInInterval(sample.Tick, faultIntervals);
                bool inCustomer = inHealthCoverage && IsInInterval(sample.Tick, customerIntervals);

                if (inFault)
                {
                    healthConfirmedDegradedMin++;
                    continue;
                }

                if (inActivity || inCustomer)
                {
                    customerExcusedDegradedMin++;
                    customerExcusedDegradedAvail += sample.Value;
                    if (inActivity)
                        activityLogDegradedMin++;
                }
            }
        }

        return new SuspectGapClassification(
            healthHistoryApplied,
            activityLogExcludedGapMin,
            healthExplainedGapMin,
            metricIssueNullMin,
            platformFaultGapMin,
            unresolvedZeroDowntimeMin,
            customerExcusedDegradedMin,
            customerExcusedDegradedAvail,
            activityLogDegradedMin,
            healthConfirmedDegradedMin);
    }

    public static DateTimeOffset GetHealthCoverageStart(DateTimeOffset periodStart)
    {
        var now = DateTimeOffset.UtcNow;
        var currentMinute = new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, now.Minute, 0, TimeSpan.Zero);
        var retentionStart = currentMinute.AddDays(-30);
        return retentionStart > periodStart ? retentionStart : periodStart;
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

/// <summary>Result of investigating suspect metric minutes for a resource.</summary>
/// <param name="HealthHistoryApplied">Whether Resource Health was available for any part of the observation window.</param>
/// <param name="ActivityLogExcludedGapMinutes">Null/0% suspect minutes excused by supported lifecycle operations in Activity Log.</param>
/// <param name="HealthExplainedGapMinutes">Null/0% suspect minutes excused by Resource Health Unknown or customer-initiated windows.</param>
/// <param name="MetricIssueNullMinutes">Remaining null suspect minutes treated as metric issues and removed from eligibility.</param>
/// <param name="PlatformFaultGapMinutes">Null/0% suspect minutes confirmed as platform issues by Resource Health fault intervals.</param>
/// <param name="UnresolvedZeroDowntimeMinutes">Remaining 0% suspect minutes trusted as downtime because no valid explanation was found.</param>
/// <param name="CustomerExcusedDegradedMinutes">Positive degraded datapoints excused by lifecycle activity or customer-initiated health windows.</param>
/// <param name="CustomerExcusedDegradedAvailableSum">Fractional available minutes contributed by customer-excused degraded datapoints and removed from AvailableMinutes.</param>
/// <param name="ActivityLogDegradedMinutes">Subset of CustomerExcusedDegradedMinutes explained specifically by supported Activity Log lifecycle operations.</param>
/// <param name="HealthConfirmedDegradedMinutes">Positive degraded datapoints confirmed as platform issues by Resource Health fault intervals.</param>
public readonly record struct SuspectGapClassification(
    bool HealthHistoryApplied,
    int ActivityLogExcludedGapMinutes,
    int HealthExplainedGapMinutes,
    int MetricIssueNullMinutes,
    int PlatformFaultGapMinutes,
    int UnresolvedZeroDowntimeMinutes,
    int CustomerExcusedDegradedMinutes,
    double CustomerExcusedDegradedAvailableSum,
    int ActivityLogDegradedMinutes,
    int HealthConfirmedDegradedMinutes);
