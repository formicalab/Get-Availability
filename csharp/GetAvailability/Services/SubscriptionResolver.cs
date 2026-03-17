using Azure.ResourceManager;
using Azure.ResourceManager.Resources;

namespace GetAvailability.Services;

public static class SubscriptionResolver
{
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
                throw new InvalidOperationException($"Subscription '{name}' not found.");
            if (matches.Count > 1)
                throw new InvalidOperationException($"Multiple subscriptions named '{name}'.");

            var sub = matches[0];
            resolved.Add((sub.Data.SubscriptionId!, sub.Data.DisplayName!));
        }
        return resolved;
    }
}
