using System.Diagnostics;
using Azure.Identity;
using Azure.Monitor.Query;
using Azure.ResourceManager;
using GetAvailability.Models;
using GetAvailability.Output;
using GetAvailability.Services;

// Parse CLI arguments
string[] subscriptionNames = [];
string[] kinds = ["vm", "sql", "storage"];
string? resourceName = null;
int tolerance = 5;
int parallelism = Math.Max(4, Math.Min(16, Environment.ProcessorCount));

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--subscriptions" or "-s":
            var subs = new List<string>();
            while (i + 1 < args.Length && !args[i + 1].StartsWith('-'))
                subs.Add(args[++i]);
            subscriptionNames = subs.ToArray();
            break;
        case "--kinds" or "-k":
            var k = new List<string>();
            while (i + 1 < args.Length && !args[i + 1].StartsWith('-'))
                k.Add(args[++i]);
            kinds = k.ToArray();
            break;
        case "--resource" or "-r":
            resourceName = args[++i];
            break;
        case "--tolerance" or "-t":
            tolerance = int.Parse(args[++i]);
            break;
        case "--parallelism" or "-p":
            parallelism = int.Parse(args[++i]);
            break;
        case "--help" or "-h":
            Console.WriteLine("Usage: GetAvailability --subscriptions <name1> [name2 ...] [options]");
            Console.WriteLine("  --subscriptions, -s  Required. One or more Azure subscription display names.");
            Console.WriteLine("  --kinds, -k          Resource kinds: vm, sql, storage (default: all).");
            Console.WriteLine("  --resource, -r       Filter to a single resource name.");
            Console.WriteLine("  --tolerance, -t      +/- minute tolerance around events (default: 5).");
            Console.WriteLine("  --parallelism, -p    Max concurrent metric calls (default: auto).");
            return 0;
    }
}

if (subscriptionNames.Length == 0)
{
    Console.Error.WriteLine("Error: --subscriptions is required. Use --help for usage.");
    return 1;
}

await RunAsync(subscriptionNames, kinds, resourceName, tolerance, parallelism);
return 0;

static async Task RunAsync(string[] subscriptionNames, string[] kinds, string? resourceName,
    int tolerance, int parallelism)
{
    var sw = Stopwatch.StartNew();

    var now = DateTimeOffset.UtcNow;
    var utcEnd = new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, now.Minute, 0, TimeSpan.Zero);
    var utcStart = utcEnd.AddDays(-14);
    int totalMinutes = (int)(utcEnd - utcStart).TotalMinutes;

    Console.WriteLine($"Window: {utcStart:u} -> {utcEnd:u} ({totalMinutes} min, tolerance: +/-{tolerance} min)");

    // Authenticate
    var credential = new DefaultAzureCredential();
    var armClient = new ArmClient(credential);
    var metricsClient = new MetricsQueryClient(credential);

    // Resolve subscriptions
    var resolved = await SubscriptionResolver.ResolveAsync(armClient, subscriptionNames);
    var subIds = resolved.Select(r => r.Id).ToArray();
    var subIdToName = resolved.ToDictionary(r => r.Id, r => r.Name);
    Console.WriteLine($"Processing {resolved.Count} subscription(s): {string.Join(", ", resolved.Select(r => r.Name))}");

    // Inventory
    Console.Write("Querying resource inventory... ");
    var resources = await ResourceInventoryService.QueryAsync(armClient, subIds, subIdToName);

    // Filter by resource kinds
    var kindMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
        ["vm"] = "VirtualMachine",
        ["sql"] = "AzureSqlDatabase",
        ["storage"] = "StorageAccount"
    };
    var selectedKinds = kinds.Select(k => kindMap.TryGetValue(k, out var v) ? v : k).ToHashSet();
    resources = resources.Where(r => selectedKinds.Contains(r.Kind)).ToList();
    Console.WriteLine($"Found {resources.Count} resource(s) across {resolved.Count} subscription(s) (kinds: {string.Join(", ", kinds)}).");

    if (resourceName != null)
    {
        resources = resources.Where(r => string.Equals(r.Name, resourceName, StringComparison.OrdinalIgnoreCase)).ToList();
        if (resources.Count == 0)
            throw new InvalidOperationException($"Resource '{resourceName}' not found.");
        Console.WriteLine($"  Filtered to {resources.Count} resource(s) matching '{resourceName}'.");
    }
    if (resources.Count == 0) { Console.WriteLine("No resources found."); return; }

    // Change events
    Console.Write("Querying lifecycle events... ");
    var allEvents = await ChangeEventsService.QueryAsync(armClient, subIds, utcStart, utcEnd);
    Console.WriteLine($"{allEvents.Count} lifecycle event(s) found.");

    // Group events by resource
    var eventsByRes = new Dictionary<string, List<LifecycleEvent>>(StringComparer.OrdinalIgnoreCase);
    foreach (var evt in allEvents)
    {
        var key = evt.ResourceId.ToLowerInvariant();
        if (!eventsByRes.TryGetValue(key, out var list))
        {
            list = [];
            eventsByRes[key] = list;
        }
        list.Add(evt);
    }

    // Pre-compute eligibility
    Console.WriteLine("Computing eligibility...");
    var eligByRes = new Dictionary<string, EligibilityResult>(StringComparer.OrdinalIgnoreCase);
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        var events = eventsByRes.TryGetValue(key, out var list) ? (IReadOnlyList<LifecycleEvent>)list : [];
        var elig = EligibilityCalculator.Compute(res, events, utcStart, utcEnd, totalMinutes, tolerance);
        eligByRes[key] = elig;

        // Populate tick arrays for the metric service
        res.ExclFromTicks = elig.ExclusionWindows.Select(w => w.FromTicks).ToArray();
        res.ExclToTicks = elig.ExclusionWindows.Select(w => w.ToTicks).ToArray();
    }

    // Fetch metrics + compute availability inline
    var metricResults = await MetricsService.QueryAsync(metricsClient, resources, utcStart, utcEnd, parallelism);

    // Assemble final results
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        var elig = eligByRes[key];

        if (metricResults.TryGetValue(key, out var mr))
        {
            if (mr.Recovered > 0)
                Console.WriteLine($"  [{res.Name}] Recovered {mr.Recovered} gap min via supplementary metrics");
            if (mr.ZeroTxMin > 0 && res.Kind == "StorageAccount")
                elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - mr.ZeroTxMin);
            elig.AvailableMinutes = Math.Round(mr.AvailableSum, 2);
        }
    }

    var sorted = eligByRes.Values
        .OrderBy(r => r.SubscriptionName)
        .ThenBy(r => r.Kind)
        .ThenBy(r => r.Name)
        .ToArray();

    SummaryWriter.WriteResults(sorted);
    SummaryWriter.WriteSubscriptionSummaries(sorted);

    sw.Stop();
    Console.WriteLine($"Completed in {sw.Elapsed:hh\\:mm\\:ss\\.ff}");
}
