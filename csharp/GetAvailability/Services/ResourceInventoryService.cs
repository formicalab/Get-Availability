using Azure.ResourceManager;
using Azure.ResourceManager.ResourceGraph;
using Azure.ResourceManager.ResourceGraph.Models;
using GetAvailability.Models;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GetAvailability.Services;

public static class ResourceInventoryService
{
    private const string Query = """
        resources
        | where type =~ 'microsoft.compute/virtualmachines'
            or type =~ 'microsoft.sql/servers/databases'
            or type =~ 'microsoft.storage/storageaccounts'
        | extend idParts = split(id, '/')
        | extend sqlServerName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[8]), '')
        | extend databaseName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[10]), '')
        | where not(type =~ 'microsoft.sql/servers/databases' and databaseName =~ 'master')
        | extend resourceKind = case(
            type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
            type =~ 'microsoft.sql/servers/databases', 'AzureSqlDatabase',
            type =~ 'microsoft.storage/storageaccounts', 'StorageAccount',
            'Other'
        )
        | extend createdAt = case(
            type =~ 'microsoft.compute/virtualmachines', todatetime(properties.timeCreated),
            type =~ 'microsoft.sql/servers/databases', todatetime(properties.creationDate),
            type =~ 'microsoft.storage/storageaccounts', todatetime(properties.creationTime),
            datetime(null)
        )
        | extend currentPowerState = case(
            type =~ 'microsoft.compute/virtualmachines', tostring(properties.extended.instanceView.powerState.code),
            type =~ 'microsoft.sql/servers/databases', tostring(properties.status),
            ''
        )
        | project id, name, type, subscriptionId, resourceGroup, location, resourceKind,
                  createdAt, sqlServerName, databaseName, currentPowerState
        """;

    public static async Task<List<TrackedResource>> QueryAsync(
        ArmClient client, string[] subscriptionIds, Dictionary<string, string> subIdToName)
    {
        var resources = new List<TrackedResource>();
        string? skipToken = null;

        do
        {
            var content = new ResourceQueryContent(Query)
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
                    var kind = row.GetProperty("resourceKind").GetString()!;
                    var rawPower = row.GetProperty("currentPowerState").GetString() ?? "";
                    var subId = row.GetProperty("subscriptionId").GetString()!;

                    string name;
                    if (kind == "AzureSqlDatabase")
                    {
                        var server = row.GetProperty("sqlServerName").GetString() ?? "";
                        var db = row.GetProperty("databaseName").GetString() ?? "";
                        name = !string.IsNullOrEmpty(server) && !string.IsNullOrEmpty(db)
                            ? $"{server}/{db}" : row.GetProperty("name").GetString()!;
                    }
                    else
                    {
                        name = row.GetProperty("name").GetString()!;
                    }

                    string powerState;
                    if (kind == "VirtualMachine" && Regex.Match(rawPower, @"PowerState/(.+)") is { Success: true } m)
                        powerState = m.Groups[1].Value;
                    else
                        powerState = rawPower;

                    DateTimeOffset? createdAt = null;
                    var createdStr = row.GetProperty("createdAt").GetString();
                    if (!string.IsNullOrWhiteSpace(createdStr) && DateTimeOffset.TryParse(createdStr, out var parsed))
                        createdAt = parsed.ToUniversalTime();

                    resources.Add(new TrackedResource
                    {
                        Name = name,
                        Kind = kind,
                        ResourceId = row.GetProperty("id").GetString()!,
                        SubscriptionId = subId,
                        SubscriptionName = subIdToName.TryGetValue(subId, out var sn) ? sn : subId,
                        ResourceGroupName = row.GetProperty("resourceGroup").GetString()!,
                        Location = row.GetProperty("location").GetString()!,
                        CreatedAt = createdAt,
                        CurrentPowerState = powerState
                    });
                }
            }

            skipToken = result.SkipToken;
        } while (!string.IsNullOrEmpty(skipToken));

        resources.Sort((a, b) =>
        {
            int c = string.Compare(a.SubscriptionName, b.SubscriptionName, StringComparison.OrdinalIgnoreCase);
            if (c != 0) return c;
            c = string.Compare(a.Kind, b.Kind, StringComparison.OrdinalIgnoreCase);
            return c != 0 ? c : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        });

        return resources;
    }
}
