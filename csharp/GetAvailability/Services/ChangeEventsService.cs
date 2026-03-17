using Azure.ResourceManager;
using Azure.ResourceManager.ResourceGraph;
using Azure.ResourceManager.ResourceGraph.Models;
using GetAvailability.Models;
using System.Text.Json;

namespace GetAvailability.Services;

public static class ChangeEventsService
{
    public static async Task<List<LifecycleEvent>> QueryAsync(
        ArmClient client, string[] subscriptionIds,
        DateTimeOffset startDate, DateTimeOffset endDate)
    {
        string startIso = startDate.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ");
        string endIso = endDate.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ");

        string vmQuery = $"""
            resourcechanges
            | extend changeTime  = todatetime(properties.changeAttributes.timestamp),
                     changeType   = tostring(properties.changeType),
                     targetId     = tostring(properties.targetResourceId),
                     targetType   = tostring(properties.targetResourceType),
                     changes      = properties.changes
            | where targetType =~ 'microsoft.compute/virtualmachines'
            | where changeTime >= datetime('{startIso}') and changeTime <= datetime('{endIso}')
            | where changeType in ('Create', 'Delete') or isnotempty(changes['properties.extended.instanceView.powerState.code'])
            | extend powerStateChange = changes['properties.extended.instanceView.powerState.code']
            | project changeTime, changeType, targetId,
                      newPowerState = tostring(powerStateChange.newValue)
            """;

        string sqlQuery = $"""
            resourcechanges
            | extend changeTime  = todatetime(properties.changeAttributes.timestamp),
                     changeType   = tostring(properties.changeType),
                     targetId     = tostring(properties.targetResourceId),
                     targetType   = tostring(properties.targetResourceType),
                     changes      = properties.changes
            | where targetType =~ 'microsoft.sql/servers/databases'
            | where changeTime >= datetime('{startIso}') and changeTime <= datetime('{endIso}')
            | where changeType in ('Create', 'Delete') or isnotempty(changes['properties.status'])
            | extend statusChange = changes['properties.status']
            | project changeTime, changeType, targetId,
                      newStatus = tostring(statusChange.newValue)
            """;

        string storageQuery = $"""
            resourcechanges
            | extend changeTime  = todatetime(properties.changeAttributes.timestamp),
                     changeType   = tostring(properties.changeType),
                     targetId     = tostring(properties.targetResourceId),
                     targetType   = tostring(properties.targetResourceType)
            | where targetType =~ 'microsoft.storage/storageaccounts'
            | where changeTime >= datetime('{startIso}') and changeTime <= datetime('{endIso}')
            | where changeType in ('Create', 'Delete')
            | project changeTime, changeType, targetId
            """;

        var allEvents = new List<LifecycleEvent>();
        var queries = new (string Query, string Kind)[]
        {
            (vmQuery, "VM"), (sqlQuery, "SQL"), (storageQuery, "Storage")
        };

        foreach (var (query, kind) in queries)
        {
            string? skipToken = null;
            do
            {
                var content = new ResourceQueryContent(query)
                {
                    Options = new ResourceQueryRequestOptions { ResultFormat = ResultFormat.ObjectArray }
                };
                if (skipToken != null) content.Options.SkipToken = skipToken;
                foreach (var id in subscriptionIds) content.Subscriptions.Add(id);

                var tenant = client.GetTenants().First();
                var response = await tenant.GetResourcesAsync(content);
                var result = response.Value;

                using var doc = JsonDocument.Parse(result.Data);
                var data = doc.RootElement;
                if (data.ValueKind == JsonValueKind.Array)
                {
                    foreach (var row in data.EnumerateArray())
                    {
                        var changeType = row.GetProperty("changeType").GetString()!;
                        var targetId = row.GetProperty("targetId").GetString()!;
                        var changeTime = DateTimeOffset.Parse(row.GetProperty("changeTime").GetString()!).ToUniversalTime();

                        string? eventKind = changeType switch
                        {
                            "Create" => "Create",
                            "Delete" => "Delete",
                            _ => kind switch
                            {
                                "VM" => (row.GetProperty("newPowerState").GetString() ?? "") switch
                                {
                                    "PowerState/running" => "Start",
                                    var ps when ps.StartsWith("PowerState/deallocat") => "Stop",
                                    var ps when ps.StartsWith("PowerState/stop") => "Stop",
                                    _ => null
                                },
                                "SQL" => (row.GetProperty("newStatus").GetString() ?? "") switch
                                {
                                    "Online" => "Start",
                                    "Paused" or "Pausing" => "Stop",
                                    _ => null
                                },
                                _ => null
                            }
                        };

                        if (eventKind != null)
                        {
                            allEvents.Add(new LifecycleEvent(targetId, changeTime, eventKind));
                        }
                    }
                }

                skipToken = result.SkipToken;
            } while (!string.IsNullOrEmpty(skipToken));
        }

        return allEvents;
    }
}
