using System.Text.Json;
using GetAvailability.Models;

namespace GetAvailability.Services;

/// <summary>
/// Queries Azure Activity Log for lifecycle operations that can explain suspect availability
/// minutes before Health History and fallback rules are applied.
/// </summary>
public static class ActivityLogService
{
    private static readonly ActivityOperationRule[] VmActivityRules =
    [
        new(false,
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
        new(false,
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

    public static bool SupportsKind(string resourceKind)
        => TryGetActivityLogRules(resourceKind, out _);

    /// <summary>
    /// Builds merged lifecycle intervals for a supported resource kind from Activity Log events.
    /// </summary>
    public static async Task<List<(DateTimeOffset From, DateTimeOffset To)>> BuildLifecycleIntervalsAsync(
        HttpClient http,
        TrackedResource resource,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes,
        CancellationToken ct)
    {
        if (!TryGetActivityLogRules(resource.Kind, out var activityRules))
            return [];

        var events = await FetchLifecycleEventsAsync(
            http,
            resource,
            periodStart,
            periodEnd,
            activityGraceMinutes,
            activityRules,
            ct);
        if (events.Count == 0)
            return [];

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

    private static async Task<List<ActivityLogEvent>> FetchLifecycleEventsAsync(
        HttpClient http,
        TrackedResource resource,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd,
        int activityGraceMinutes,
        IReadOnlyList<ActivityOperationRule> activityRules,
        CancellationToken ct)
    {
        var events = new List<ActivityLogEvent>();
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
                    if (!TryMatchActivityOperation(operationKey, activityRules, activityGraceMinutes, out int graceMinutes))
                        continue;

                    string correlationId = GetPropString(item, "correlationId");

                    events.Add(new ActivityLogEvent(
                        occurred.Value.ToUniversalTime(),
                        operationKey,
                        correlationId,
                        graceMinutes));
                }
            }

            url = doc.RootElement.TryGetProperty("nextLink", out var next) &&
                  next.ValueKind == JsonValueKind.String
                ? next.GetString()
                : null;
        }

        return events;
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

    private static bool TryGetActivityLogRules(string resourceKind, out ActivityOperationRule[] rules)
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

        rules = [];
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