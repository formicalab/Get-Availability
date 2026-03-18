// Get-Availability — rolling 30-day Azure resource availability reporter (C# / Native AOT)
//
// Pipeline: resolve subscriptions → inventory (Resource Graph)
//         → fetch metrics (Azure Monitor, parallel) → verify gaps (Resource Health)
//         → assemble results → print table + summaries
//
// Metric gaps (null datapoints) are verified against Resource Health:
//   – fault confirmed (Unavailable/Degraded) → counts as downtime
//   – no fault → subtracted from eligible minutes
// Zero-percent metric values (0% with active transactions) get nuanced handling:
//   – during Unknown health windows (Azure Monitor issue) → subtracted from eligible
//   – during confirmed faults or with no health explanation → counts as downtime
//
// The reporting window is a rolling 30-day period (now − 30 days → now) to match
// Resource Health API retention (~30 days).

using System.Collections.Concurrent;
using System.Diagnostics;
using Azure.Identity;
using Azure.Monitor.Query;
using Azure.ResourceManager;
using GetAvailability.Models;
using GetAvailability.Output;
using GetAvailability.Services;

// ── CLI argument parsing ─────────────────────────────────────────────────────
// Supports: --subscriptions (required), --kinds, --resource, --parallelism, --help

string[] subscriptionNames = [];
string[] kinds = ["vm", "sql", "storage"];
string? resourceName = null;
int parallelism = Math.Max(4, Math.Min(16, Environment.ProcessorCount)); // auto-scale to CPU cores

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
        case "--parallelism" or "-p":
            parallelism = int.Parse(args[++i]);
            break;
        case "--help" or "-h":
            Console.WriteLine("Usage: GetAvailability --subscriptions <name1> [name2 ...] [options]");
            Console.WriteLine("  --subscriptions, -s  Required. One or more Azure subscription display names.");
            Console.WriteLine("  --kinds, -k          Resource kinds: vm, sql, storage (default: all).");
            Console.WriteLine("  --resource, -r       Filter to a single resource name.");
            Console.WriteLine("  --parallelism, -p    Max concurrent metric calls (default: auto).");
            return 0;
    }
}

if (subscriptionNames.Length == 0)
{
    Console.Error.WriteLine("Error: --subscriptions is required. Use --help for usage.");
    return 1;
}

await RunAsync(subscriptionNames, kinds, resourceName, parallelism);
return 0;

// ── Main orchestration ───────────────────────────────────────────────────────

static async Task RunAsync(string[] subscriptionNames, string[] kinds, string? resourceName,
    int parallelism)
{
    var sw = Stopwatch.StartNew();

    // Rolling 30-day window: aligned to Resource Health API retention (~30 days)
    var now = DateTimeOffset.UtcNow;
    var utcEnd = new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, now.Minute, 0, TimeSpan.Zero);
    var utcStart = utcEnd.AddDays(-30);
    int totalMinutes = (int)(utcEnd - utcStart).TotalMinutes;

    Console.WriteLine($"Period: rolling 30 days ({utcStart:u} -> {utcEnd:u}, {totalMinutes} min)");

    // Authenticate using DefaultAzureCredential (az login, managed identity, etc.)
    var credential = new DefaultAzureCredential();
    var armClient = new ArmClient(credential);
    var metricsClient = new MetricsQueryClient(credential);

    // Step 1: Resolve subscription display names → subscription IDs
    var resolved = await SubscriptionResolver.ResolveAsync(armClient, subscriptionNames);
    var subIds = resolved.Select(r => r.Id).ToArray();
    var subIdToName = resolved.ToDictionary(r => r.Id, r => r.Name);
    Console.WriteLine($"Processing {resolved.Count} subscription(s): {string.Join(", ", resolved.Select(r => r.Name))}");

    // Step 2: Query Resource Graph for all VMs, SQL DBs, and Storage Accounts
    Console.Write("Querying resource inventory... ");
    var resources = await ResourceInventoryService.QueryAsync(armClient, subIds, subIdToName, kinds, resourceName);
    Console.WriteLine($"Found {resources.Count} resource(s) across {resolved.Count} subscription(s) (kinds: {string.Join(", ", kinds)}).");

    if (resources.Count == 0) { Console.WriteLine("No resources found."); return; }

    // Step 3: Build initial eligibility (all minutes eligible — gaps handled via Resource Health)
    var eligByRes = new Dictionary<string, EligibilityResult>(StringComparer.OrdinalIgnoreCase);
    foreach (var res in resources)
    {
        eligByRes[res.ResourceId.ToLowerInvariant()] = new EligibilityResult
        {
            Name = res.Name,
            Kind = res.Kind,
            ResourceId = res.ResourceId,
            ResourceGroupName = res.ResourceGroupName,
            Location = res.Location,
            SubscriptionName = res.SubscriptionName,
            EligibleMinutes = totalMinutes,
        };
    }

    // Step 4: Fetch Azure Monitor metrics per resource in parallel
    var metricResults = await MetricsService.QueryAsync(metricsClient, resources, utcStart, utcEnd, parallelism);

    // Step 5: For resources with metric gaps (null or 0% datapoints), check Resource Health.
    // Null gaps outside fault intervals → subtract from eligible (telemetry absence, VM off, etc.).
    // 0% gaps only excused during Unknown health windows (Azure Monitor issue).
    // All gaps inside fault intervals (Unavailable/Degraded) → stay in eligible, count as downtime.
    var gapCandidates = new List<(TrackedResource Res, long[] AllGapTicks, HashSet<long>? ZeroTicks)>();
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        if (metricResults.TryGetValue(key, out var mr) && mr.GapMinutes > 0)
        {
            var allTicks = new List<long>();
            if (mr.GapTicks is not null) allTicks.AddRange(mr.GapTicks);
            if (mr.ZeroAvailTicks is not null) allTicks.AddRange(mr.ZeroAvailTicks);
            if (allTicks.Count > 0)
            {
                var zeroSet = mr.ZeroAvailTicks is not null ? new HashSet<long>(mr.ZeroAvailTicks) : null;
                gapCandidates.Add((res, allTicks.ToArray(), zeroSet));
            }
        }
    }

    ConcurrentDictionary<string, GapClassification>? healthResults = null;
    if (gapCandidates.Count > 0)
        healthResults = await ResourceHealthService.CheckGapsAsync(credential, gapCandidates, utcStart, utcEnd, parallelism);

    // Step 6: Assemble final results — apply health-verified gap adjustments and zero-tx storage exclusions
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        var elig = eligByRes[key];

        if (metricResults.TryGetValue(key, out var mr))
        {
            // Apply Resource Health gap classification
            int healthFaults = 0;
            if (healthResults is not null && healthResults.TryGetValue(key, out var gc))
            {
                if (gc.HealthyGapMinutes > 0)
                {
                    elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - gc.HealthyGapMinutes);
                    Console.WriteLine($"  [{res.Name}] {gc.HealthyGapMinutes} gap min ignored (no fault in Resource Health)");
                }
                if (gc.FaultMinutes > 0)
                {
                    healthFaults += gc.FaultMinutes;
                    Console.WriteLine($"  [{res.Name}] {gc.FaultMinutes} gap min confirmed as downtime (Resource Health fault)");
                }
                if (gc.TrustedZeroMinutes > 0)
                {
                    healthFaults += gc.TrustedZeroMinutes;
                    Console.WriteLine($"  [{res.Name}] {gc.TrustedZeroMinutes} gap min counted as downtime (0% metric, no health explanation)");
                }
            }

            // DegradedMinutes = metric-level degraded (avail < 100%) + health-confirmed faults + trusted 0% downtimes
            elig.DegradedMinutes = mr.DegradedMinutes + healthFaults;

            // Flag resources where the primary metric returned 100% null (broken telemetry)
            if (mr.NoData && elig.EligibleMinutes > 0)
            {
                elig.NoData = true;
                Console.WriteLine($"  [{res.Name}] No metric data (telemetry not emitting)");
            }

            // For Storage Accounts, subtract zero-transaction minutes from eligibility
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
