using Azure.ResourceManager;
using Azure.ResourceManager.ResourceGraph;
using Azure.ResourceManager.ResourceGraph.Models;
using GetAvailability.Models;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>Queries Resource Graph resources table for VMs, SQL DBs, and Storage Accounts.</summary>
public static class ResourceInventoryService
{
    // KQL query against the Resource Graph 'resources' table.
    // Returns all VMs, SQL DBs (excluding system 'master'), and Storage Accounts
    // with their current power state and creation date inline — no per-resource REST calls needed.
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

    /// <summary>
    /// Executes the inventory KQL query with pagination (skipToken) across all subscriptions.
    /// Parses the JSON response into TrackedResource objects, normalizing SQL DB names to
    /// "server/database" format and stripping the "PowerState/" prefix from VM power states.
    /// Returns resources sorted by subscription → kind → name.
    /// </summary>
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

            // Parse JSON response using System.Text.Json (AOT-safe, no reflection)
            using var doc = JsonDocument.Parse(result.Data);
            var data = doc.RootElement;
            if (data.ValueKind == JsonValueKind.Array)
            {
                foreach (var row in data.EnumerateArray())
                {
                    var kind = row.GetProperty("resourceKind").GetString()!;
                    var rawPower = row.GetProperty("currentPowerState").GetString() ?? "";
                    var subId = row.GetProperty("subscriptionId").GetString()!;

                    // SQL DB names are shown as "server/database" for clarity
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

                    // Strip "PowerState/" prefix if present
                    string powerState = kind == "VirtualMachine" && rawPower.StartsWith("PowerState/", StringComparison.Ordinal)
                        ? rawPower["PowerState/".Length..]
                        : rawPower;

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
