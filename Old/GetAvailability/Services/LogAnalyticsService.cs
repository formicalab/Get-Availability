using Azure.Core;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>
/// Fetches Activity Log lifecycle events and Resource Health transitions from a
/// Log Analytics workspace via a single bulk KQL query against the AzureActivity table.
/// Returns per-resource data keyed by lowercase resource ID.
///
/// Activity Log events are used directly for lifecycle classification (VM start/stop, SQL pause/resume).
/// Health transitions undergo incident-based post-processing to replicate the REST API's curated
/// behaviour: multiple lifecycle events per incident (Activated → Updated → InProgress → Resolved)
/// are consolidated into clean state transitions with retroactively corrected cause classification.
/// </summary>
public static class LogAnalyticsService
{
    /// <summary>
    /// Executes a single KQL query that fetches both Activity Log lifecycle events and
    /// Resource Health transitions for all specified subscriptions. Returns a dictionary
    /// keyed by lowercase resource ID, each containing pre-parsed activity events and
    /// consolidated health transitions.
    /// </summary>
    public static async Task<Dictionary<string, LogAnalyticsResourceData>> FetchAsync(
        TokenCredential credential,
        string workspaceId,
        string[] subscriptionIds,
        DateTimeOffset periodStart,
        DateTimeOffset periodEnd)
    {
        var token = await credential.GetTokenAsync(
            new TokenRequestContext(["https://api.loganalytics.io/.default"]), default);

        string startIso = periodStart.ToString("O");
        string endIso = periodEnd.ToString("O");
        string subList = string.Join(", ", subscriptionIds.Select(s => $"'{s}'"));

        string kql = $"""
            let subs = dynamic([{subList}]);
            let actOps = dynamic([
              'MICROSOFT.COMPUTE/VIRTUALMACHINES/START/ACTION',
              'MICROSOFT.COMPUTE/VIRTUALMACHINES/DEALLOCATE/ACTION',
              'MICROSOFT.COMPUTE/VIRTUALMACHINES/POWEROFF/ACTION',
              'MICROSOFT.COMPUTE/VIRTUALMACHINES/RESTART/ACTION',
              'MICROSOFT.SQL/SERVERS/DATABASES/PAUSE/ACTION',
              'MICROSOFT.SQL/SERVERS/DATABASES/RESUME/ACTION',
              'MICROSOFT.WEB/SITES/STOP/ACTION',
              'MICROSOFT.WEB/SITES/START/ACTION',
              'MICROSOFT.WEB/SITES/RESTART/ACTION',
              'MICROSOFT.COMPUTE/VIRTUALMACHINES/WRITE',
              'MICROSOFT.COMPUTE/VIRTUALMACHINES/DELETE',
              'MICROSOFT.SQL/SERVERS/DATABASES/WRITE',
              'MICROSOFT.SQL/SERVERS/DATABASES/DELETE',
              'MICROSOFT.STORAGE/STORAGEACCOUNTS/WRITE',
              'MICROSOFT.STORAGE/STORAGEACCOUNTS/DELETE',
              'MICROSOFT.WEB/SITES/WRITE',
              'MICROSOFT.WEB/SITES/DELETE'
            ]);
            let actData = AzureActivity
                | where SubscriptionId in (subs)
                | where CategoryValue == 'Administrative'
                | where OperationNameValue in~ (actOps)
                | where ActivityStatusValue == 'Success'
                | where TimeGenerated >= datetime({startIso}) and TimeGenerated <= datetime({endIso})
                | project TimeGenerated, ResourceId=tolower(_ResourceId),
                          OperationName=OperationNameValue, CorrelationId,
                          Source='Activity';
            let healthData = AzureActivity
                | where SubscriptionId in (subs)
                | where CategoryValue == 'ResourceHealth'
                | where ResourceProviderValue in ('MICROSOFT.COMPUTE', 'MICROSOFT.SQL', 'MICROSOFT.STORAGE', 'MICROSOFT.WEB')
                | project TimeGenerated, ResourceId=tolower(_ResourceId),
                          Source='Health', OperationName=OperationNameValue,
                          Properties=todynamic(Properties);
            actData | union healthData
            """;

        string laUrl = $"https://api.loganalytics.io/v1/workspaces/{workspaceId}/query";
        string body = BuildQueryJson(kql);

        using var http = new HttpClient();
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        http.Timeout = TimeSpan.FromMinutes(5);

        using var content = new StringContent(body, System.Text.Encoding.UTF8, "application/json");
        using var response = await http.PostAsync(laUrl, content);
        response.EnsureSuccessStatusCode();

        string json = await response.Content.ReadAsStringAsync();

        return ParseResponse(json);
    }

    private static string BuildQueryJson(string kql)
    {
        using var ms = new System.IO.MemoryStream();
        using (var writer = new Utf8JsonWriter(ms))
        {
            writer.WriteStartObject();
            writer.WriteString("query", kql);
            writer.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(ms.ToArray());
    }

    private static Dictionary<string, LogAnalyticsResourceData> ParseResponse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var table = doc.RootElement.GetProperty("tables")[0];

        var columns = table.GetProperty("columns").EnumerateArray()
            .Select(c => c.GetProperty("name").GetString()!)
            .ToArray();

        int iTime = Array.IndexOf(columns, "TimeGenerated");
        int iResId = Array.IndexOf(columns, "ResourceId");
        int iOp = Array.IndexOf(columns, "OperationName");
        int iCorr = Array.IndexOf(columns, "CorrelationId");
        int iSource = Array.IndexOf(columns, "Source");
        int iProps = Array.IndexOf(columns, "Properties");

        var dataByRes = new Dictionary<string, LogAnalyticsResourceData>(StringComparer.OrdinalIgnoreCase);
        var rawHealthEvents = new Dictionary<string, List<RawHealthEvent>>(StringComparer.OrdinalIgnoreCase);
        int rowCount = 0;

        foreach (var row in table.GetProperty("rows").EnumerateArray())
        {
            rowCount++;
            string resId = row[iResId].GetString() ?? "";
            if (string.IsNullOrEmpty(resId)) continue;

            if (!dataByRes.TryGetValue(resId, out var entry))
            {
                entry = new LogAnalyticsResourceData();
                dataByRes[resId] = entry;
            }

            string timeStr = row[iTime].GetString() ?? "";
            if (!DateTimeOffset.TryParse(timeStr, CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal, out var ts))
                continue;
            ts = ts.ToUniversalTime();

            string source = row[iSource].GetString() ?? "";

            if (source == "Activity")
            {
                entry.ActivityEvents.Add(new LogAnalyticsActivityEvent(
                    ts,
                    row[iOp].GetString() ?? "",
                    iCorr >= 0 ? (row[iCorr].GetString() ?? "") : ""));
            }
            else if (source == "Health")
            {
                ParseHealthEvent(row, iOp, iProps, resId, ts, rawHealthEvents);
            }
        }

        // Post-process raw health events into clean incident-based transitions
        PostProcessHealthEvents(dataByRes, rawHealthEvents);

        Console.WriteLine($"Log Analytics: fetched {rowCount} events for {dataByRes.Count} resource(s)");
        return dataByRes;
    }

    private static void ParseHealthEvent(
        JsonElement row,
        int iOp,
        int iProps,
        string resId,
        DateTimeOffset ts,
        Dictionary<string, List<RawHealthEvent>> rawHealthEvents)
    {
        var propsEl = row[iProps];

        // Properties may arrive as a JSON string or as an already-parsed object
        JsonElement props;
        JsonDocument? propsDoc = null;
        try
        {
            if (propsEl.ValueKind == JsonValueKind.String)
            {
                var propsStr = propsEl.GetString();
                if (string.IsNullOrEmpty(propsStr)) return;
                propsDoc = JsonDocument.Parse(propsStr);
                props = propsDoc.RootElement;
            }
            else if (propsEl.ValueKind == JsonValueKind.Object)
            {
                props = propsEl;
            }
            else return;

            // Extract health state — newer events use 'currentHealthStatus',
            // older ones use 'availabilityState'
            string state = GetPropString(props, "currentHealthStatus");
            if (string.IsNullOrEmpty(state))
                state = GetPropString(props, "availabilityState");

            string rawCause = GetPropString(props, "cause");

            if (!string.IsNullOrEmpty(state))
            {
                // Determine incident lifecycle phase from OperationNameValue
                string opName = row[iOp].GetString() ?? "";
                string opType =
                    opName.Contains("/Activated/", StringComparison.OrdinalIgnoreCase) ? "Activated" :
                    opName.Contains("/Resolved/", StringComparison.OrdinalIgnoreCase) ? "Resolved" :
                    opName.Contains("/InProgress/", StringComparison.OrdinalIgnoreCase) ? "InProgress" :
                    "Updated";

                if (!rawHealthEvents.TryGetValue(resId, out var evtList))
                {
                    evtList = [];
                    rawHealthEvents[resId] = evtList;
                }
                evtList.Add(new RawHealthEvent(ts, state, rawCause, opType));
            }
        }
        finally
        {
            propsDoc?.Dispose();
        }
    }

    /// <summary>
    /// Consolidates raw LA health events into clean incident-based transitions.
    /// AzureActivity ResourceHealth events include lifecycle phases (Activated, Updated,
    /// InProgress, Resolved) for each health incident. This post-processing replicates the
    /// REST API's curated behaviour:
    ///   1. Only create transitions when the health state actually changes.
    ///   2. Track incidents (Activated/InProgress → Resolved) and collect the latest
    ///      non-Unknown cause within each incident.
    ///   3. On Resolved, retroactively apply the final cause to all transitions in the incident.
    ///   4. Skip orphan Updated events outside any incident.
    /// </summary>
    private static void PostProcessHealthEvents(
        Dictionary<string, LogAnalyticsResourceData> dataByRes,
        Dictionary<string, List<RawHealthEvent>> rawHealthEvents)
    {
        foreach (var (resId, events) in rawHealthEvents)
        {
            if (!dataByRes.TryGetValue(resId, out var entry))
                continue;

            var sorted = events.OrderBy(e => e.Timestamp).ToList();
            string trackedState = "Available";
            int lastTransitionIdx = -1;
            bool inIncident = false;
            var incidentTransitionIndices = new List<int>();
            string incidentCause = "";

            foreach (var evt in sorted)
            {
                // Open incident on Activated or InProgress
                if (evt.OperationType is "Activated" or "InProgress" && !inIncident)
                {
                    inIncident = true;
                    incidentTransitionIndices = [];
                    incidentCause = "";
                }

                // Track the latest non-Unknown cause within the incident
                if (inIncident && !string.IsNullOrEmpty(evt.RawCause) && evt.RawCause != "Unknown")
                    incidentCause = evt.RawCause;

                // Skip orphan Updated events (stale / out-of-incident)
                if (evt.OperationType is not ("Activated" or "InProgress" or "Resolved") && !inIncident)
                    continue;

                // Only create a transition when the state actually changes
                if (!evt.State.Equals(trackedState, StringComparison.OrdinalIgnoreCase))
                {
                    var (reasonType, context, healthEventCause) = MapCause(evt.RawCause);
                    entry.HealthTransitions.Add(new HealthTransition(
                        evt.Timestamp, evt.State, reasonType, context, healthEventCause));
                    trackedState = evt.State;
                    lastTransitionIdx = entry.HealthTransitions.Count - 1;

                    // Track non-Available transitions for retroactive cause fix on Resolved
                    if (inIncident && !evt.State.Equals("Available", StringComparison.OrdinalIgnoreCase))
                        incidentTransitionIndices.Add(lastTransitionIdx);
                }
                else
                {
                    // Same state — update cause on last transition if a more specific
                    // cause arrived (e.g. Updated event reveals 'UserInitiated')
                    if (lastTransitionIdx >= 0 && !string.IsNullOrEmpty(evt.RawCause) && evt.RawCause != "Unknown")
                    {
                        var last = entry.HealthTransitions[lastTransitionIdx];
                        if (string.IsNullOrEmpty(last.ReasonType) || last.ReasonType == "Unknown")
                        {
                            var (reasonType, context, healthEventCause) = MapCause(evt.RawCause);
                            entry.HealthTransitions[lastTransitionIdx] = new HealthTransition(
                                last.OccurredOn, last.State, reasonType, context, healthEventCause);
                        }
                    }
                }

                // Close incident on Resolved — retroactively apply the final determined
                // cause to ALL transitions in this incident
                if (evt.OperationType == "Resolved")
                {
                    if (!string.IsNullOrEmpty(incidentCause) && incidentCause != "Unknown"
                        && incidentTransitionIndices.Count > 0)
                    {
                        var (reasonType, context, healthEventCause) = MapCause(incidentCause);
                        foreach (int idx in incidentTransitionIndices)
                        {
                            var t = entry.HealthTransitions[idx];
                            entry.HealthTransitions[idx] = new HealthTransition(
                                t.OccurredOn, t.State, reasonType, context, healthEventCause);
                        }
                    }
                    inIncident = false;
                    incidentTransitionIndices = [];
                    incidentCause = "";
                }
            }

            // Handle open incident at end of event stream — apply best known cause
            if (inIncident && incidentTransitionIndices.Count > 0
                && !string.IsNullOrEmpty(incidentCause) && incidentCause != "Unknown")
            {
                var (reasonType, context, healthEventCause) = MapCause(incidentCause);
                foreach (int idx in incidentTransitionIndices)
                {
                    var t = entry.HealthTransitions[idx];
                    entry.HealthTransitions[idx] = new HealthTransition(
                        t.OccurredOn, t.State, reasonType, context, healthEventCause);
                }
            }
        }
    }

    /// <summary>Maps LA raw cause names to the REST API's multi-field format.</summary>
    private static (string ReasonType, string Context, string HealthEventCause) MapCause(string rawCause)
        => rawCause switch
        {
            "UserInitiated" => ("Customer Initiated", "Customer Initiated", "UserInitiated"),
            "PlatformInitiated" => ("Platform Initiated", "", ""),
            _ => ("", "", "")
        };

    private static string GetPropString(JsonElement props, string name)
        => props.TryGetProperty(name, out var el) ? el.GetString() ?? "" : "";

    private readonly record struct RawHealthEvent(
        DateTimeOffset Timestamp,
        string State,
        string RawCause,
        string OperationType);
}

/// <summary>Per-resource data fetched from Log Analytics.</summary>
public sealed class LogAnalyticsResourceData
{
    public List<LogAnalyticsActivityEvent> ActivityEvents { get; } = [];
    public List<HealthTransition> HealthTransitions { get; } = [];
}

/// <summary>A parsed Activity Log lifecycle event from Log Analytics.</summary>
public sealed record LogAnalyticsActivityEvent(
    DateTimeOffset Timestamp,
    string OperationName,
    string CorrelationId);
