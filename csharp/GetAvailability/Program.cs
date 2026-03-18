// Get-Availability — rolling 30-day Azure resource availability reporter (C# / Native AOT)
//
// Pipeline: resolve subscriptions → inventory (Resource Graph)
//         → fetch metrics (Azure Monitor, parallel) → verify gaps (Resource Health)
//         → assemble results → print table + summaries
//
// Metric gaps (null datapoints) are verified against Resource Health first.
// For supported resource types, unresolved non-perfect minutes are then cross-checked
// against Activity Log lifecycle operations:
//   – Virtual Machines: start/deallocate/power off/restart
//   – Azure SQL Databases: pause/resume
//   – fault confirmed (Unavailable/Degraded) → counts as downtime
//   – no fault / customer-admin lifecycle explanation → subtracted from eligible minutes
// Zero-percent metric values (0% with active transactions) get nuanced handling:
//   – during Unknown health windows (Azure Monitor issue) → subtracted from eligible
//   – during confirmed faults or with no health/activity explanation → counts as downtime
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
// Supports: --subscriptions (required), --kinds, --resource, --parallelism,
//           --activity-grace-minutes, --help

string[] subscriptionNames = [];
string[] kinds = ["vm", "sql", "storage"];
string? resourceName = null;
int parallelism = Math.Max(4, Math.Min(16, Environment.ProcessorCount)); // auto-scale to CPU cores
int activityGraceMinutes = 10;

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
        case "--activity-grace-minutes" or "-g":
            activityGraceMinutes = int.Parse(args[++i]);
            break;
        case "--help" or "-h":
            Console.WriteLine("Usage: GetAvailability --subscriptions <name1> [name2 ...] [options]");
            Console.WriteLine("  --subscriptions, -s  Required. One or more Azure subscription display names.");
            Console.WriteLine("  --kinds, -k          Resource kinds: vm, sql, storage (default: all).");
            Console.WriteLine("  --resource, -r       Filter to a single resource name.");
            Console.WriteLine("  --parallelism, -p    Max concurrent metric calls (default: auto).");
            Console.WriteLine("  --activity-grace-minutes, -g  Post-operation grace window for supported Activity Log lifecycle events (default: 10).");
            return 0;
    }
}

if (subscriptionNames.Length == 0)
{
    Console.Error.WriteLine("Error: --subscriptions is required. Use --help for usage.");
    return 1;
}

if (activityGraceMinutes < 0)
{
    Console.Error.WriteLine("Error: --activity-grace-minutes must be >= 0.");
    return 1;
}

await RunAsync(subscriptionNames, kinds, resourceName, parallelism, activityGraceMinutes);
return 0;

// ── Main orchestration ───────────────────────────────────────────────────────

static async Task RunAsync(
    string[] subscriptionNames,
    string[] kinds,
    string? resourceName,
    int parallelism,
    int activityGraceMinutes)
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

    // Step 5: For resources with non-perfect metric minutes, check Resource Health.
    // Null gaps outside fault intervals → subtract from eligible (telemetry absence, VM off, etc.).
    // 0% gaps are excused during Unknown or customer-initiated health windows.
    // For supported resource kinds, unresolved non-perfect minutes after Resource Health
    // are cross-checked against Activity Log lifecycle operations.
    // Positive degraded datapoints are also excused when they align with customer/admin-initiated activity.
    // All non-perfect minutes inside fault intervals (Unavailable/Degraded) stay in eligible and count as downtime.
    var gapCandidates = new List<(TrackedResource Res, long[] AllGapTicks, HashSet<long>? ZeroTicks, MetricValueSample[]? DegradedSamples)>();
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        if (metricResults.TryGetValue(key, out var mr) && (mr.GapMinutes > 0 || (mr.DegradedSamples?.Length ?? 0) > 0))
        {
            var allTicks = new List<long>();
            if (mr.GapTicks is not null) allTicks.AddRange(mr.GapTicks);
            if (mr.ZeroAvailTicks is not null) allTicks.AddRange(mr.ZeroAvailTicks);
            if (allTicks.Count > 0 || (mr.DegradedSamples?.Length ?? 0) > 0)
            {
                var zeroSet = mr.ZeroAvailTicks is not null ? new HashSet<long>(mr.ZeroAvailTicks) : null;
                gapCandidates.Add((res, allTicks.ToArray(), zeroSet, mr.DegradedSamples));
            }
        }
    }

    ConcurrentDictionary<string, HealthClassification>? healthResults = null;
    if (gapCandidates.Count > 0)
        healthResults = await ResourceHealthService.CheckGapsAsync(
            credential,
            gapCandidates,
            utcStart,
            utcEnd,
            parallelism,
            activityGraceMinutes);

    // Step 6: Assemble final results — apply health-verified gap adjustments and zero-tx storage exclusions
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        var elig = eligByRes[key];

        if (metricResults.TryGetValue(key, out var mr))
        {
            if (mr.ExcludeFromAvailability)
            {
                elig.EligibleMinutes = 0;
                elig.AvailableMinutes = 0;
                elig.DegradedMinutes = 0;
                Console.WriteLine($"  [{res.Name}] excluded from availability (no numeric availability datapoints in period)");
                continue;
            }

            // Apply Resource Health gap classification
            int healthFaults = 0;
            int resourceHealthExcludedGapMinutes = 0;
            int activityLogExcludedGapMinutes = 0;
            int excludedDegradedMinutes = 0;
            if (healthResults is not null && healthResults.TryGetValue(key, out var gc))
            {
                if (mr.GapMinutes > 0)
                {
                    int healthExplainedGapMinutes = gc.HealthyGapMinutes - gc.ActivityLogGapMinutes;
                    int activityLogCheckedGapMinutes = gc.ActivityLogGapMinutes + gc.TrustedZeroMinutes;
                    Console.WriteLine($"  [{res.Name}] metric scan found {mr.GapMinutes} gap min (null/0% availability values)");

                    if (activityLogCheckedGapMinutes > 0)
                    {
                        Console.WriteLine(
                            $"  [{res.Name}] checked against Resource Health: {healthExplainedGapMinutes} gap min explained as no-fault / Unknown / customer-initiated, {gc.FaultMinutes} confirmed as downtime");

                        string activityOutcome = gc.TrustedZeroMinutes > 0
                            ? $", {gc.TrustedZeroMinutes} remain downtime"
                            : "";
                        Console.WriteLine(
                            $"  [{res.Name}] checked {activityLogCheckedGapMinutes} still-unexplained gap min against Activity Log: {gc.ActivityLogGapMinutes} explained by admin lifecycle events{activityOutcome}");
                    }
                    else
                    {
                        string resourceHealthOutcome = gc.TrustedZeroMinutes > 0
                            ? $", {gc.TrustedZeroMinutes} counted as downtime with no health explanation"
                            : "";
                        Console.WriteLine(
                            $"  [{res.Name}] checked against Resource Health: {healthExplainedGapMinutes} gap min explained as no-fault / Unknown / customer-initiated, {gc.FaultMinutes} confirmed as downtime{resourceHealthOutcome}");
                    }
                }

                if (gc.HealthyGapMinutes > 0)
                {
                    elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - gc.HealthyGapMinutes);
                    activityLogExcludedGapMinutes = gc.ActivityLogGapMinutes;
                    resourceHealthExcludedGapMinutes = gc.HealthyGapMinutes - gc.ActivityLogGapMinutes;
                }
                if (gc.CustomerExcusedDegradedMinutes > 0)
                {
                    elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - gc.CustomerExcusedDegradedMinutes);
                    excludedDegradedMinutes = gc.CustomerExcusedDegradedMinutes;
                    string reason = gc.ActivityLogDegradedMinutes > 0
                        ? $"customer-admin lifecycle explanation ({gc.ActivityLogDegradedMinutes} matched in Activity Log)"
                        : "customer-initiated activity";
                    Console.WriteLine($"  [{res.Name}] {gc.CustomerExcusedDegradedMinutes} degraded metric min excluded from eligibility ({reason})");
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

            // DegradedMinutes = metric-level degraded (avail < 100%) minus customer-excused degraded datapoints
            // + health-confirmed faults + trusted 0% downtimes.
            elig.DegradedMinutes = Math.Max(0, mr.DegradedMinutes - (healthResults is not null && healthResults.TryGetValue(key, out var hc) ? hc.CustomerExcusedDegradedMinutes : 0) + healthFaults);

            // For Storage Accounts, subtract zero-transaction minutes from eligibility
            int zeroTxExcludedMinutes = 0;
            if (mr.ZeroTxMin > 0 && res.Kind == "StorageAccount")
            {
                elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - mr.ZeroTxMin);
                zeroTxExcludedMinutes = mr.ZeroTxMin;
            }

                if (resourceHealthExcludedGapMinutes > 0 || activityLogExcludedGapMinutes > 0 || excludedDegradedMinutes > 0 || zeroTxExcludedMinutes > 0)
                {
                    var eligibilityAdjustments = new List<string>();
                    if (resourceHealthExcludedGapMinutes > 0)
                        eligibilityAdjustments.Add($"{resourceHealthExcludedGapMinutes} gap min excluded by Resource Health");
                    if (activityLogExcludedGapMinutes > 0)
                        eligibilityAdjustments.Add($"{activityLogExcludedGapMinutes} gap min excluded by Activity Log");
                    if (excludedDegradedMinutes > 0)
                        eligibilityAdjustments.Add($"{excludedDegradedMinutes} customer-excused degraded min");
                    if (zeroTxExcludedMinutes > 0)
                        eligibilityAdjustments.Add($"{zeroTxExcludedMinutes} zero-tx min");

                    Console.WriteLine(
                        $"  [{res.Name}] eligible min = {totalMinutes} - {string.Join(" - ", eligibilityAdjustments)} = {elig.EligibleMinutes}");
                }

            double customerExcusedAvail = healthResults is not null && healthResults.TryGetValue(key, out var availClass)
                ? availClass.CustomerExcusedDegradedAvailableSum
                : 0;
            elig.AvailableMinutes = Math.Round(Math.Max(0, mr.AvailableSum - customerExcusedAvail), 2);
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
