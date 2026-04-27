using Azure.ResourceManager;
using Azure.ResourceManager.ResourceGraph;
using Azure.ResourceManager.ResourceGraph.Models;
using GetAvailability.Models;
using System.Text.Json;

namespace GetAvailability.Services;

/// <summary>
/// Queries the Resource Graph resources table for VMs, SQL DBs, Storage Accounts,
/// and Web Apps (excluding Function Apps which share the microsoft.web/sites type).
/// </summary>
public static class ResourceInventoryService
{
    /// <summary>Maps CLI kind abbreviations to Azure Resource Graph type identifiers.</summary>
    private static readonly Dictionary<string, string> KindToType = new(StringComparer.OrdinalIgnoreCase)
    {
        ["vm"] = "microsoft.compute/virtualmachines",
        ["sql"] = "microsoft.sql/servers/databases",
        ["storage"] = "microsoft.storage/storageaccounts",
        ["webapp"] = "microsoft.web/sites",
    };

    /// <summary>
    /// Builds and executes the inventory KQL query with server-side kind and resource name filters.
    /// </summary>
    public static async Task<List<TrackedResource>> QueryAsync(
        ArmClient client, string[] subscriptionIds, Dictionary<string, string> subIdToName,
        string[] kinds, string? resourceName)
    {
        var unsupportedKinds = kinds
            .Where(k => !KindToType.ContainsKey(k))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(k => k, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (unsupportedKinds.Length > 0)
            throw new ArgumentException($"Unsupported kind(s): {string.Join(", ", unsupportedKinds)}. Allowed values: vm, sql, storage, webapp.");

        // Build the type filter clause from selected kinds
        var types = kinds
            .Select(k => KindToType.TryGetValue(k, out var t) ? t : null)
            .Where(t => t != null)
            .ToArray();
        if (types.Length == 0)
            throw new ArgumentException("At least one supported kind must be specified.");

        string typeFilter = types.Length == 1
            ? $"type =~ '{types[0]}'"
            : string.Join(" or ", types.Select(t => $"type =~ '{t}'"));

        string escapedResourceName = resourceName?.Replace("'", "''", StringComparison.Ordinal) ?? "";
        string nameFilter = resourceName != null
            ? $"| where displayName =~ '{escapedResourceName}' or name =~ '{escapedResourceName}'\n"
            : "";

        string query = $"""
            resources
            | where {typeFilter}
            | where not(type =~ 'microsoft.web/sites' and kind contains 'functionapp')
            | extend idParts = split(id, '/')
            | extend sqlServerName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[8]), '')
            | extend databaseName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[10]), '')
            | where not(type =~ 'microsoft.sql/servers/databases' and databaseName =~ 'master')
            | extend displayName = iff(type =~ 'microsoft.sql/servers/databases', strcat(sqlServerName, '/', databaseName), name)
            {nameFilter}
            | extend resourceKind = case(
                type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
                type =~ 'microsoft.sql/servers/databases', 'AzureSqlDatabase',
                type =~ 'microsoft.storage/storageaccounts', 'StorageAccount',
                type =~ 'microsoft.web/sites', 'WebApp',
                'Other'
            )
            | project id, name, displayName, type, subscriptionId, resourceGroup, location, resourceKind,
                      sqlServerName, databaseName
            """;

        var resources = new List<TrackedResource>();
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

            // Parse JSON response using System.Text.Json (AOT-safe, no reflection)
            using var doc = JsonDocument.Parse(result.Data);
            var data = doc.RootElement;
            if (data.ValueKind == JsonValueKind.Array)
            {
                foreach (var row in data.EnumerateArray())
                {
                    var kind = row.GetProperty("resourceKind").GetString()!;
                    var subId = row.GetProperty("subscriptionId").GetString()!;

                    string name = row.GetProperty("displayName").GetString() ?? row.GetProperty("name").GetString()!;

                    resources.Add(new TrackedResource
                    {
                        Name = name,
                        Kind = kind,
                        ResourceId = row.GetProperty("id").GetString()!,
                        SubscriptionId = subId,
                        SubscriptionName = subIdToName.TryGetValue(subId, out var sn) ? sn : subId,
                        ResourceGroupName = row.GetProperty("resourceGroup").GetString()!,
                        Location = row.GetProperty("location").GetString()!,
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
