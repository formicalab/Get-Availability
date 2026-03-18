using Azure.ResourceManager;
using Azure.ResourceManager.Resources;

namespace GetAvailability.Services;

/// <summary>Resolves Azure subscription display names to subscription IDs.</summary>
public static class SubscriptionResolver
{
    /// <summary>
    /// Lists all subscriptions visible to the authenticated identity, then matches each
    /// requested display name. Throws if a name isn't found or matches more than one.
    /// </summary>
    public static async Task<List<(string Id, string Name)>> ResolveAsync(
        ArmClient client, string[] subscriptionNames)
    {
        var allSubs = new List<SubscriptionResource>();
        await foreach (var sub in client.GetSubscriptions().GetAllAsync())
            allSubs.Add(sub);

        var resolved = new List<(string Id, string Name)>();
        foreach (var name in subscriptionNames)
        {
            var matches = allSubs.Where(s =>
                string.Equals(s.Data.DisplayName, name, StringComparison.OrdinalIgnoreCase)).ToList();

            if (matches.Count == 0)
                throw new ArgumentException($"Subscription '{name}' not found.");
            if (matches.Count > 1)
                throw new ArgumentException($"Multiple subscriptions named '{name}'.");

            var sub = matches[0];
            resolved.Add((sub.Data.SubscriptionId!, sub.Data.DisplayName!));
        }
        return resolved;
    }
}
