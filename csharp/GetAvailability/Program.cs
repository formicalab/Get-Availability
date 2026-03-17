// Get-Availability — monthly calendar Azure resource availability reporter (C# / Native AOT)
//
// Pipeline: resolve subscriptions → inventory (Resource Graph) → lifecycle events (Activity Log)
//         → compute eligibility (exclusion windows) → fetch metrics (Azure Monitor, parallel)
//         → assemble results → print table + summaries
//
// Uses Azure Activity Log (90-day retention) instead of Resource Graph resourcechanges (14-day)
// to support analysis of past calendar months (--month -1, -2, -3, or 0 for current).

using System.Diagnostics;
using Azure.Identity;
using Azure.Monitor.Query;
using Azure.ResourceManager;
using GetAvailability.Models;
using GetAvailability.Output;
using GetAvailability.Services;

// ── CLI argument parsing ─────────────────────────────────────────────────────
// Supports: --subscriptions (required), --kinds, --resource, --tolerance, --parallelism, --help

string[] subscriptionNames = [];
string[] kinds = ["vm", "sql", "storage"];
string? resourceName = null;
int tolerance = 5;  // symmetric ±N minutes around each start/stop event
int parallelism = Math.Max(4, Math.Min(16, Environment.ProcessorCount)); // auto-scale to CPU cores
int monthOffset = -1; // -1 = previous month (default), -2 = two months ago, -3 = three months ago, 0 = current month

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
        case "--month" or "-m":
            monthOffset = int.Parse(args[++i]);
            break;
        case "--help" or "-h":
            Console.WriteLine("Usage: GetAvailability --subscriptions <name1> [name2 ...] [options]");
            Console.WriteLine("  --subscriptions, -s  Required. One or more Azure subscription display names.");
            Console.WriteLine("  --kinds, -k          Resource kinds: vm, sql, storage (default: all).");
            Console.WriteLine("  --resource, -r       Filter to a single resource name.");
            Console.WriteLine("  --tolerance, -t      +/- minute tolerance around events (default: 5).");
            Console.WriteLine("  --parallelism, -p    Max concurrent metric calls (default: auto).");
            Console.WriteLine("  --month, -m          Month offset: -1 (previous, default), -2, -3, 0 (current).");
            return 0;
    }
}

if (subscriptionNames.Length == 0)
{
    Console.Error.WriteLine("Error: --subscriptions is required. Use --help for usage.");
    return 1;
}

await RunAsync(subscriptionNames, kinds, resourceName, tolerance, parallelism, monthOffset);
return 0;

// ── Main orchestration ───────────────────────────────────────────────────────

static async Task RunAsync(string[] subscriptionNames, string[] kinds, string? resourceName,
    int tolerance, int parallelism, int monthOffset)
{
    var sw = Stopwatch.StartNew();

    // Compute calendar month boundaries based on --month offset.
    // -1 = previous full month, -2 = two months ago, -3 = three months ago, 0 = current month (partial, to now).
    var now = DateTimeOffset.UtcNow;
    var target = now.AddMonths(monthOffset);
    var utcStart = new DateTimeOffset(target.Year, target.Month, 1, 0, 0, 0, TimeSpan.Zero);
    var utcEnd = monthOffset == 0
        ? new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, now.Minute, 0, TimeSpan.Zero)
        : utcStart.AddMonths(1);
    int totalMinutes = (int)(utcEnd - utcStart).TotalMinutes;

    // Activity Log retains 90 days — validate the requested month is within range
    if ((DateTimeOffset.UtcNow - utcStart).TotalDays > 89)
    {
        Console.Error.WriteLine("Error: Activity Log retains only 90 days. The requested month is too far back.");
        return;
    }

    var monthName = utcStart.ToString("MMMM yyyy");
    Console.WriteLine($"Month: {monthName} ({utcStart:u} -> {utcEnd:u}, {totalMinutes} min, tolerance: +/-{tolerance} min)");

    // Authenticate using DefaultAzureCredential (az login, managed identity, etc.)
    var credential = new DefaultAzureCredential();
    var armClient = new ArmClient(credential);              // ARM operations (inventory, changes)
    var metricsClient = new MetricsQueryClient(credential); // Azure Monitor metric queries

    // Step 1: Resolve subscription display names → subscription IDs
    var resolved = await SubscriptionResolver.ResolveAsync(armClient, subscriptionNames);
    var subIds = resolved.Select(r => r.Id).ToArray();
    var subIdToName = resolved.ToDictionary(r => r.Id, r => r.Name);
    Console.WriteLine($"Processing {resolved.Count} subscription(s): {string.Join(", ", resolved.Select(r => r.Name))}");

    // Step 2: Query Resource Graph for all VMs, SQL DBs, and Storage Accounts
    Console.Write("Querying resource inventory... ");
    var resources = await ResourceInventoryService.QueryAsync(armClient, subIds, subIdToName);

    // Map CLI kind abbreviations (vm/sql/storage) to internal kind names
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

    // Step 3: Query Activity Log for lifecycle events (start/stop/delete)
    // Activity Log retains 90 days (vs 14 for resourcechanges), enabling monthly analysis.
    // The query includes a 30-day lookback before utcStart to capture pre-period power state.
    Console.Write("Querying activity log... ");
    var allEvents = await ActivityLogService.QueryAsync(credential, subIds, utcStart, utcEnd, subIdToName);

    // Synthesize Create events from inventory CreatedAt timestamps.
    // Activity Log write operations can't reliably distinguish creation from updates,
    // so we use the creation time recorded in Resource Graph inventory instead.
    // The 30-day lookback in the query window ensures Delete→Create pairs are matched
    // even when the deletion happened before the analysis period.
    var lookbackStart = utcStart.AddDays(-30);
    foreach (var res in resources)
    {
        if (res.CreatedAt is { } created && created >= lookbackStart && created < utcEnd)
            allEvents.Add(new LifecycleEvent(res.ResourceId, created, "Create"));
    }
    Console.WriteLine($"{allEvents.Count} lifecycle event(s) found.");

    // Group lifecycle events by resource ID for quick lookup
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

    // Step 4: Pre-compute eligibility — build exclusion windows per resource
    // This determines how many minutes each resource was expected to be available.
    // Done BEFORE metric fetch so we can pass exclusion tick arrays into the parallel block.
    Console.WriteLine("Computing eligibility...");
    var eligByRes = new Dictionary<string, EligibilityResult>(StringComparer.OrdinalIgnoreCase);
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        var events = eventsByRes.TryGetValue(key, out var list) ? (IReadOnlyList<LifecycleEvent>)list : [];
        var elig = EligibilityCalculator.Compute(res, events, utcStart, utcEnd, totalMinutes, tolerance);
        eligByRes[key] = elig;

        // Copy exclusion windows as flat tick arrays — these are passed into the parallel
        // metric block so each task can check exclusions without sharing the full object graph
        res.ExclFromTicks = elig.ExclusionWindows.Select(w => w.FromTicks).ToArray();
        res.ExclToTicks = elig.ExclusionWindows.Select(w => w.ToTicks).ToArray();
    }

    // Step 5: Fetch Azure Monitor metrics per resource in parallel + compute available minutes inline
    var metricResults = await MetricsService.QueryAsync(metricsClient, resources, utcStart, utcEnd, parallelism);

    // Step 6: Assemble final results — apply recovered gap minutes and zero-tx storage exclusions
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        var elig = eligByRes[key];

        if (metricResults.TryGetValue(key, out var mr))
        {
            // Log supplementary-metric gap recovery for VMs
            if (mr.Recovered > 0)
                Console.WriteLine($"  [{res.Name}] Recovered {mr.Recovered} gap min via supplementary metrics");

            // Flag resources where the primary metric returned 100% null (broken telemetry)
            if (mr.NoData && elig.EligibleMinutes > 0)
            {
                elig.NoData = true;
                Console.WriteLine($"  [{res.Name}] No metric data (telemetry not emitting)");
            }

            // For Storage Accounts, subtract zero-transaction minutes from eligibility
            // (no transactions = no availability signal, so those minutes shouldn't count)
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
