using System.Text.Json;
using GetAvailability.Models;

namespace GetAvailability.Services;

/// <summary>
/// Queries Azure Activity Log for lifecycle operations and resource creation/deletion
/// events that can explain suspect availability minutes before Health History and
/// fallback rules are applied.
///
/// Lifecycle rules are kind-specific (VM, SQL, WebApp). Kinds with no known lifecycle
/// operations (e.g. Storage) still get creation/deletion detection.
///
/// For Web Apps, paired stop→start intervals cover the full stopped window because
/// Resource Health does not track stopped web app state (unlike VMs where deallocation
/// creates "Unavailable – Customer Initiated").
/// </summary>
public static class ActivityLogService
{
    // All VM lifecycle operations apply grace (trailing metrics during state transitions).
    private static readonly ActivityOperationRule[] VmActivityRules =
    [
        new(true,
        [
            "microsoft.compute/virtualmachines/start/action",
            "start virtual machine",
        ]),
        new(true,
        [
            "microsoft.compute/virtualmachines/deallocate/action",
            "deallocate virtual machine",
        ]),
        new(true,
        [
            "microsoft.compute/virtualmachines/poweroff/action",
            "power off virtual machine",
        ]),
        new(true,
        [
            "microsoft.compute/virtualmachines/restart/action",
            "restart virtual machine",
        ]),
    ];

    private static readonly ActivityOperationRule[] SqlDatabaseActivityRules =
    [
        new(true,
        [
            "microsoft.sql/servers/databases/pause",
            "pause sql database",
            "pause database",
        ]),
        new(true,
        [
            "microsoft.sql/servers/databases/resume",
            "resume sql database",
            "resume database",
        ]),
    ];

    // Web App lifecycle: stop/start/restart all apply grace for trailing zero metrics
    // during process shutdown/startup.
    private static readonly ActivityOperationRule[] WebAppActivityRules =
    [
        new(true,
        [
            "microsoft.web/sites/stop/action",
            "stop web app",
            "stopwebsite",
        ]),
        new(true,
        [
            "microsoft.web/sites/start/action",
            "start web app",
            "startwebsite",
        ]),
        new(true,
        [
            "microsoft.web/sites/restart/action",
            "restart web app",
            "restartwebsite",
        ]),
    ];

    /// <summary>Maps resource kind to its ARM namespace for creation/deletion token matching.</summary>
    private static readonly Dictionary<string, string> KindNamespace = new(StringComparer.OrdinalIgnoreCase)
    {
        ["VirtualMachine"] = "microsoft.compute/virtualmachines",
        ["AzureSqlDatabase"] = "microsoft.sql/servers/databases",
        ["StorageAccount"] = "microsoft.storage/storageaccounts",
        ["WebApp"] = "microsoft.web/sites",
    };

    /// <summary>
    /// Builds merged lifecycle + existence intervals from pre-fetched Log Analytics
    /// activity events. Used when --workspace is specified, replacing REST API calls
    /// with bulk KQL data.
    /// </summary>
    public static List<(DateTimeOffset From, DateTimeOffset To)> BuildLifecycleIntervalsFromEvents(
        IReadOnlyList<LogAnalyticsActivityEvent> laEvents,
        string resourceKind,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes)
    {
        TryGetActivityLogRules(resourceKind, out var activityRules);

        string? createToken = null, deleteToken = null;
        if (KindNamespace.TryGetValue(resourceKind, out var ns))
        {
            createToken = ns + "/write";
            deleteToken = ns + "/delete";
        }

        var lifecycleEvents = new List<ActivityLogEvent>();
        var existenceEvents = new List<(DateTimeOffset Timestamp, string Type)>();

        foreach (var laEvt in laEvents)
        {
            var normalized = laEvt.OperationName.ToLowerInvariant();

            // Check for resource creation/deletion events
            if (createToken is not null && normalized.Contains(createToken, StringComparison.OrdinalIgnoreCase))
                existenceEvents.Add((laEvt.Timestamp.ToUniversalTime(), "Write"));
            else if (deleteToken is not null && normalized.Contains(deleteToken, StringComparison.OrdinalIgnoreCase))
                existenceEvents.Add((laEvt.Timestamp.ToUniversalTime(), "Delete"));

            // Check for lifecycle operations
            if (activityRules is not null &&
                TryMatchActivityOperation(laEvt.OperationName, activityRules, activityGraceMinutes, out int graceMinutes))
            {
                lifecycleEvents.Add(new ActivityLogEvent(
                    laEvt.Timestamp.ToUniversalTime(),
                    laEvt.OperationName,
                    laEvt.CorrelationId,
                    graceMinutes));
            }
        }

        var intervals = lifecycleEvents.Count > 0
            ? BuildIntervalsFromEvents(lifecycleEvents, periodStart, periodEnd)
            : new List<(DateTimeOffset, DateTimeOffset)>();

        // For web apps, build paired stop→start spanning intervals
        if (resourceKind.Equals("WebApp", StringComparison.OrdinalIgnoreCase) && lifecycleEvents.Count > 0)
        {
            var pairedIntervals = BuildPairedStopStartIntervals(lifecycleEvents, periodStart, periodEnd, activityGraceMinutes);
            if (pairedIntervals.Count > 0)
                intervals = MergeIntervals([.. intervals, .. pairedIntervals]);
        }

        // Build non-existence intervals from creation/deletion events
        var nonExistIntervals = BuildNonExistenceIntervals(existenceEvents, periodStart, periodEnd, activityGraceMinutes);
        if (nonExistIntervals.Count > 0)
            intervals = MergeIntervals([.. intervals, .. nonExistIntervals]);

        return intervals;
    }

    /// <summary>
    /// Builds merged lifecycle + existence intervals for a resource from Activity Log
    /// events fetched via the REST API.
    /// </summary>
    public static async Task<List<(DateTimeOffset From, DateTimeOffset To)>> BuildLifecycleIntervalsAsync(
        HttpClient http,
        TrackedResource resource,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes,
        CancellationToken ct)
    {
        TryGetActivityLogRules(resource.Kind, out var activityRules);

        var (lifecycleEvents, existenceEvents) = await FetchActivityEventsAsync(
            http,
            resource,
            periodStart,
            periodEnd,
            activityGraceMinutes,
            activityRules,
            ct);

        var intervals = lifecycleEvents.Count > 0
            ? BuildIntervalsFromEvents(lifecycleEvents, periodStart, periodEnd)
            : new List<(DateTimeOffset, DateTimeOffset)>();

        // For web apps, build paired stop→start spanning intervals
        if (resource.Kind.Equals("WebApp", StringComparison.OrdinalIgnoreCase) && lifecycleEvents.Count > 0)
        {
            var pairedIntervals = BuildPairedStopStartIntervals(lifecycleEvents, periodStart, periodEnd, activityGraceMinutes);
            if (pairedIntervals.Count > 0)
                intervals = MergeIntervals([.. intervals, .. pairedIntervals]);
        }

        // Build non-existence intervals from creation/deletion events
        var nonExistIntervals = BuildNonExistenceIntervals(existenceEvents, periodStart, periodEnd, activityGraceMinutes);
        if (nonExistIntervals.Count > 0)
            intervals = MergeIntervals([.. intervals, .. nonExistIntervals]);

        return intervals;
    }

    /// <summary>
    /// Builds merged lifecycle intervals from a list of parsed activity events.
    /// Groups events by operation+correlationId, computes per-group intervals with
    /// grace windows, clamps to the observation period, and merges overlaps.
    /// </summary>
    private static List<(DateTimeOffset From, DateTimeOffset To)> BuildIntervalsFromEvents(
        List<ActivityLogEvent> events,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd)
    {
        var rawIntervals = new List<(DateTimeOffset From, DateTimeOffset To)>();

        foreach (var group in events.GroupBy(BuildActivityGroupKey, StringComparer.OrdinalIgnoreCase))
        {
            var min = group.Min(e => e.Timestamp);
            var max = group.Max(e => e.Timestamp);
            int graceMinutes = group.Max(e => e.GraceMinutes);

            var from = TruncateToMinute(min);
            var to = TruncateToMinute(max).AddMinutes(1);
            to = ExtendActivityInterval(graceMinutes, to);

            if (from < periodStart) from = periodStart;
            if (to > periodEnd) to = periodEnd;

            if (to > from)
                rawIntervals.Add((from, to));
        }

        return MergeIntervals(rawIntervals);
    }

    /// <summary>
    /// Fetches Activity Log events via the REST API, collecting both lifecycle events
    /// (matched by kind-specific rules) and creation/deletion events (matched by
    /// namespace write/delete tokens). Returns both lists.
    /// </summary>
    private static async Task<(List<ActivityLogEvent> LifecycleEvents, List<(DateTimeOffset Timestamp, string Type)> ExistenceEvents)> FetchActivityEventsAsync(
        HttpClient http,
        TrackedResource resource,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes,
        ActivityOperationRule[]? activityRules,
        CancellationToken ct)
    {
        var lifecycleEvents = new List<ActivityLogEvent>();
        var existenceEvents = new List<(DateTimeOffset Timestamp, string Type)>();

        string? createToken = null, deleteToken = null;
        if (KindNamespace.TryGetValue(resource.Kind, out var ns))
        {
            createToken = ns + "/write";
            deleteToken = ns + "/delete";
        }

        string filter = $"eventTimestamp ge '{periodStart:O}' and eventTimestamp le '{periodEnd:O}' and resourceUri eq '{resource.ResourceId}'";
        string select = "eventTimestamp,operationName,correlationId,status";

        string? url =
            $"https://management.azure.com/subscriptions/{resource.SubscriptionId}/providers/microsoft.insights/eventtypes/management/values" +
            $"?api-version=2015-04-01&$filter={Uri.EscapeDataString(filter)}&$select={Uri.EscapeDataString(select)}";

        while (url is not null)
        {
            string json = await GetWithRetryAsync(http, url, ct);
            using var doc = JsonDocument.Parse(json);

            if (doc.RootElement.TryGetProperty("value", out var value) && value.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in value.EnumerateArray())
                {
                    string? occurredStr = item.TryGetProperty("eventTimestamp", out var occurredEl)
                        ? occurredEl.GetString()
                        : null;

                    var occurred = ParseAzureTimestamp(occurredStr);
                    if (occurred is null)
                        continue;

                    string operationValue = GetNestedPropString(item, "operationName", "value");
                    string operationLabel = GetNestedPropString(item, "operationName", "localizedValue");
                    string operationKey = string.IsNullOrWhiteSpace(operationValue) ? operationLabel : operationValue;
                    if (string.IsNullOrWhiteSpace(operationKey)) continue;

                    var normalized = operationKey.ToLowerInvariant();
                    var ts = occurred.Value.ToUniversalTime();

                    // Check for resource creation/deletion events
                    if (createToken is not null && normalized.Contains(createToken, StringComparison.OrdinalIgnoreCase))
                        existenceEvents.Add((ts, "Write"));
                    else if (deleteToken is not null && normalized.Contains(deleteToken, StringComparison.OrdinalIgnoreCase))
                        existenceEvents.Add((ts, "Delete"));

                    // Check for lifecycle operations
                    if (activityRules is not null &&
                        TryMatchActivityOperation(operationKey, activityRules, activityGraceMinutes, out int graceMinutes))
                    {
                        string correlationId = GetPropString(item, "correlationId");
                        lifecycleEvents.Add(new ActivityLogEvent(ts, operationKey, correlationId, graceMinutes));
                    }
                }
            }

            url = doc.RootElement.TryGetProperty("nextLink", out var next) &&
                  next.ValueKind == JsonValueKind.String
                ? next.GetString()
                : null;
        }

        return (lifecycleEvents, existenceEvents);
    }

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

    private static bool TryGetActivityLogRules(string resourceKind, out ActivityOperationRule[]? rules)
    {
        if (resourceKind.Equals("VirtualMachine", StringComparison.OrdinalIgnoreCase))
        {
            rules = VmActivityRules;
            return true;
        }

        if (resourceKind.Equals("AzureSqlDatabase", StringComparison.OrdinalIgnoreCase))
        {
            rules = SqlDatabaseActivityRules;
            return true;
        }

        if (resourceKind.Equals("WebApp", StringComparison.OrdinalIgnoreCase))
        {
            rules = WebAppActivityRules;
            return true;
        }

        rules = null;
        return false;
    }

    private static bool TryMatchActivityOperation(
        string operation,
        IReadOnlyList<ActivityOperationRule> rules,
        int activityGraceMinutes,
        out int graceMinutes)
    {
        graceMinutes = 0;
        if (string.IsNullOrWhiteSpace(operation))
            return false;

        var normalized = operation.ToLowerInvariant();

        foreach (var rule in rules)
        {
            if (rule.MatchTokens.Any(token => normalized.Contains(token, StringComparison.OrdinalIgnoreCase)))
            {
                graceMinutes = rule.ApplyGrace ? activityGraceMinutes : 0;
                return true;
            }
        }

        return false;
    }

    private static string BuildActivityGroupKey(ActivityLogEvent evt)
    {
        string correlationPart = string.IsNullOrWhiteSpace(evt.CorrelationId)
            ? TruncateToMinute(evt.Timestamp).ToString("O")
            : evt.CorrelationId;
        return $"{evt.OperationKey}|{correlationPart}";
    }

    private static List<(DateTimeOffset From, DateTimeOffset To)> MergeIntervals(
        List<(DateTimeOffset From, DateTimeOffset To)> intervals)
    {
        if (intervals.Count == 0)
            return intervals;

        var ordered = intervals.OrderBy(i => i.From).ToList();
        var merged = new List<(DateTimeOffset From, DateTimeOffset To)> { ordered[0] };

        for (int i = 1; i < ordered.Count; i++)
        {
            var current = ordered[i];
            var last = merged[^1];

            if (current.From <= last.To)
            {
                merged[^1] = (last.From, current.To > last.To ? current.To : last.To);
            }
            else
            {
                merged.Add(current);
            }
        }

        return merged;
    }

    /// <summary>
    /// For web apps, builds spanning intervals from stop→start/restart pairs.
    /// Unlike VMs (where Resource Health reports "Unavailable – Customer Initiated"
    /// for the entire deallocated period), stopped web apps show only "Available"
    /// in Resource Health. We infer the full stopped window from Activity Log events.
    /// An unpaired trailing stop extends to periodEnd.
    /// </summary>
    private static List<(DateTimeOffset From, DateTimeOffset To)> BuildPairedStopStartIntervals(
        List<ActivityLogEvent> events,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes)
    {
        var stopTokens = WebAppActivityRules[0].MatchTokens;   // stop
        var startTokens = WebAppActivityRules[1].MatchTokens    // start
            .Concat(WebAppActivityRules[2].MatchTokens)         // restart
            .ToArray();

        var stopTimes = new List<DateTimeOffset>();
        var startTimes = new List<DateTimeOffset>();

        foreach (var evt in events)
        {
            var norm = evt.OperationKey.ToLowerInvariant();
            if (stopTokens.Any(t => norm.Contains(t, StringComparison.OrdinalIgnoreCase)))
                stopTimes.Add(evt.Timestamp);
            else if (startTokens.Any(t => norm.Contains(t, StringComparison.OrdinalIgnoreCase)))
                startTimes.Add(evt.Timestamp);
        }

        if (stopTimes.Count == 0)
            return [];

        stopTimes.Sort();
        startTimes.Sort();

        var intervals = new List<(DateTimeOffset From, DateTimeOffset To)>();
        foreach (var stop in stopTimes)
        {
            var nextStart = startTimes.FirstOrDefault(s => s > stop);
            var from = TruncateToMinute(stop);
            var to = nextStart != default
                ? TruncateToMinute(nextStart).AddMinutes(1 + activityGraceMinutes)
                : periodEnd;
            if (from < periodStart) from = periodStart;
            if (to > periodEnd) to = periodEnd;
            if (to > from)
                intervals.Add((from, to));
        }

        return intervals;
    }

    /// <summary>
    /// Builds non-existence intervals from resource creation/deletion events using a
    /// state machine. Non-existence intervals cover:
    ///   - periodStart → first Write (resource created mid-period)
    ///   - Delete → next Write (destroy/recreate cycle)
    ///   - last Delete → periodEnd (resource deleted, not recreated)
    /// </summary>
    private static List<(DateTimeOffset From, DateTimeOffset To)> BuildNonExistenceIntervals(
        List<(DateTimeOffset Timestamp, string Type)> existenceEvents,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes)
    {
        if (existenceEvents.Count == 0)
            return [];

        var sorted = existenceEvents.OrderBy(e => e.Timestamp).ToList();
        var intervals = new List<(DateTimeOffset From, DateTimeOffset To)>();
        string state = "unknown";     // unknown | exists | not-exists
        DateTimeOffset? nonExistStart = null;

        foreach (var (timestamp, type) in sorted)
        {
            if (type == "Write")
            {
                if (state != "exists")
                {
                    // Resource came into existence — close non-existence interval
                    var from = nonExistStart.HasValue ? TruncateToMinute(nonExistStart.Value) : periodStart;
                    var to = TruncateToMinute(timestamp).AddMinutes(1 + activityGraceMinutes);
                    if (from < periodStart) from = periodStart;
                    if (to > periodEnd) to = periodEnd;
                    if (to > from)
                        intervals.Add((from, to));
                    state = "exists";
                    nonExistStart = null;
                }
            }
            else if (type == "Delete")
            {
                state = "not-exists";
                nonExistStart = timestamp;
            }
        }

        // If resource was deleted and not recreated, non-existence extends to period end
        if (state == "not-exists" && nonExistStart.HasValue)
        {
            var from = TruncateToMinute(nonExistStart.Value);
            if (from < periodStart) from = periodStart;
            if (periodEnd > from)
                intervals.Add((from, periodEnd));
        }

        return intervals;
    }

    private static DateTimeOffset ExtendActivityInterval(int graceMinutes, DateTimeOffset currentEnd)
        => graceMinutes > 0 ? currentEnd.AddMinutes(graceMinutes) : currentEnd;

    /// <summary>
    /// Parses Azure timestamp strings which may use several formats depending on
    /// region and API version. Falls back to DateTimeOffset.TryParse for formats
    /// not in the explicit list.
    /// </summary>
    private static DateTimeOffset? ParseAzureTimestamp(string? timestamp)
    {
        if (string.IsNullOrWhiteSpace(timestamp))
            return null;

        ReadOnlySpan<string> formats =
        [
            "MM/dd/yyyy HH:mm:ss",
            "M/d/yyyy H:mm:ss",
            "dd/MM/yyyy HH:mm:ss",
            "d/M/yyyy H:mm:ss",
            "yyyy-MM-ddTHH:mm:ssZ",
            "yyyy-MM-ddTHH:mm:ss.fffffffZ",
        ];

        foreach (var format in formats)
        {
            if (DateTimeOffset.TryParseExact(
                timestamp,
                format,
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AssumeUniversal,
                out var parsed))
            {
                return parsed;
            }
        }

        return DateTimeOffset.TryParse(
            timestamp,
            System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal,
            out var fallback)
            ? fallback
            : null;
    }

    /// <summary>Truncates to minute boundary for interval grouping.</summary>
    private static DateTimeOffset TruncateToMinute(DateTimeOffset value)
        => new(value.Year, value.Month, value.Day, value.Hour, value.Minute, 0, TimeSpan.Zero);

    /// <summary>Reads a nested string property (e.g. operationName.value) from a JsonElement.</summary>
    private static string GetNestedPropString(JsonElement parent, string propertyName, string nestedName)
    {
        if (!parent.TryGetProperty(propertyName, out var obj) || obj.ValueKind != JsonValueKind.Object)
            return "";
        return GetPropString(obj, nestedName);
    }

    /// <summary>Reads a string property from a JsonElement, returning empty if absent or null.</summary>
    private static string GetPropString(JsonElement props, string name)
        => props.TryGetProperty(name, out var el) ? el.GetString() ?? "" : "";
}

internal readonly record struct ActivityLogEvent(
    DateTimeOffset Timestamp,
    string OperationKey,
    string CorrelationId,
    int GraceMinutes);

internal readonly record struct ActivityOperationRule(
    bool ApplyGrace,
    string[] MatchTokens);