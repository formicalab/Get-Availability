// Get-Availability — month-scoped Azure resource availability reporter (C# / Native AOT)
//
// Pipeline: resolve subscriptions → inventory (Resource Graph)
//         → fetch metrics (Azure Monitor, parallel) → investigate suspect gaps
//           (Activity Log first, then Resource Health where retained)
//         → assemble results → print table + summaries
//
// A suspect minute is any metric datapoint that is null or below 100%.
// Contiguous suspect minutes form "suspect gaps" for narration purposes.
// For supported resource types, suspect minutes are first checked against
// Activity Log lifecycle operations:
//   – Virtual Machines: start/deallocate/power off/restart
//   – Azure SQL Databases: pause/resume
// Resource Health is then applied for the overlap with its current retention window:
//   – platform fault confirmed (Unavailable/Degraded) → counts as downtime
//   – Unknown / customer-initiated → valid explanation for null and 0% suspect minutes
// Remaining null minutes become metric issues (excluded from eligibility), while
// remaining 0% minutes are trusted as downtime. Remaining positive degraded datapoints
// stay as degraded availability.
//
// The observation window is a UTC calendar month selected via --month YYYYMM.
// Current month runs month-to-date; past months run full-month. Metrics and
// Activity Log can later support periods beyond 30 days, while Resource Health
// is still applied only for the overlap with its retained history.

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using Azure.Identity;
using Azure.Monitor.Query;
using Azure.ResourceManager;
using GetAvailability.Models;
using GetAvailability.Output;
using GetAvailability.Services;

// ── CLI argument parsing ─────────────────────────────────────────────────────
// Supports: --subscriptions (required), --month (required), --kinds,
//           --resource, --parallelism, --activity-grace-minutes, --help

string[] subscriptionNames = [];
string[] kinds = ["vm", "sql", "storage"];
string? resourceName = null;
string? monthParameter = null;
int parallelism = Math.Max(4, Math.Min(16, Environment.ProcessorCount)); // auto-scale to CPU cores
int activityGraceMinutes = 10;

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--subscriptions" or "-s":
            subscriptionNames = ReadRequiredValues(args, ref i, "--subscriptions");
            break;
        case "--kinds" or "-k":
            kinds = ReadRequiredValues(args, ref i, "--kinds");
            break;
        case "--resource" or "-r":
            resourceName = ReadRequiredValue(args, ref i, "--resource");
            break;
        case "--month" or "-m":
            monthParameter = ReadRequiredValue(args, ref i, "--month");
            break;
        case "--parallelism" or "-p":
            parallelism = ParseIntOption(ReadRequiredValue(args, ref i, "--parallelism"), "--parallelism", minValue: 1);
            break;
        case "--activity-grace-minutes" or "-g":
            activityGraceMinutes = ParseIntOption(ReadRequiredValue(args, ref i, "--activity-grace-minutes"), "--activity-grace-minutes", minValue: 0);
            break;
        case "--help" or "-h":
            Console.WriteLine("Usage: GetAvailability --subscriptions <name1> [name2 ...] [options]");
            Console.WriteLine("  --subscriptions, -s  Required. One or more Azure subscription display names.");
            Console.WriteLine("  --month, -m          Required. Observation month in UTC, format YYYYMM.");
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

if (string.IsNullOrWhiteSpace(monthParameter))
{
    Console.Error.WriteLine("Error: --month is required. Use --help for usage.");
    return 1;
}

try
{
    await RunAsync(subscriptionNames, kinds, resourceName, monthParameter, parallelism, activityGraceMinutes);
    return 0;
}
catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
{
    Console.Error.WriteLine($"Error: {ex.Message}");
    return 1;
}

// ── Main orchestration ───────────────────────────────────────────────────────

static async Task RunAsync(
    string[] subscriptionNames,
    string[] kinds,
    string? resourceName,
    string monthParameter,
    int parallelism,
    int activityGraceMinutes)
{
    var sw = Stopwatch.StartNew();

    var (utcStart, utcEnd, normalizedMonth, isMonthToDate) = ResolveObservationWindow(monthParameter);
    int totalMinutes = (int)(utcEnd - utcStart).TotalMinutes;
    var healthCoverageStart = ResourceHealthService.GetHealthCoverageStart(utcStart);
    int healthCoveredMinutes = healthCoverageStart < utcEnd
        ? (int)(utcEnd - healthCoverageStart).TotalMinutes
        : 0;

    string periodLabel = isMonthToDate ? $"month {normalizedMonth} (month-to-date)" : $"month {normalizedMonth}";
    Console.WriteLine($"Period: {periodLabel} ({utcStart:u} -> {utcEnd:u}, {totalMinutes} min)");
    if (healthCoverageStart > utcStart && healthCoveredMinutes > 0)
    {
        Console.WriteLine(
            $"WARNING: Resource Health history covers only part of this period ({healthCoverageStart:u} -> {utcEnd:u}, {healthCoveredMinutes} of {totalMinutes} min). Earlier minutes will use Activity Log and metric fallback rules.");
    }
    else if (healthCoveredMinutes == 0)
    {
        Console.WriteLine(
            "WARNING: Resource Health history does not cover this period. All suspect minutes will use Activity Log and metric fallback rules.");
    }

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

    // Step 3: Build initial eligibility (all minutes eligible — suspect-minute investigation adjusts it later)
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

    // Step 5: For resources with suspect metric minutes, investigate null/0% suspect minutes and
    // positive degraded datapoints. Activity Log is checked first for supported lifecycle actions,
    // then Resource Health is applied where still retained.
    var suspectCandidates = new List<(TrackedResource Res, long[] AllGapTicks, HashSet<long>? ZeroTicks, MetricValueSample[]? DegradedSamples)>();
    foreach (var res in resources)
    {
        var key = res.ResourceId.ToLowerInvariant();
        if (metricResults.TryGetValue(key, out var mr) && mr.SuspectMinutes > 0)
        {
            var allTicks = new List<long>();
            if (mr.GapTicks is not null) allTicks.AddRange(mr.GapTicks);
            if (mr.ZeroAvailTicks is not null) allTicks.AddRange(mr.ZeroAvailTicks);
            if (allTicks.Count > 0 || (mr.DegradedSamples?.Length ?? 0) > 0)
            {
                var zeroSet = mr.ZeroAvailTicks is not null ? new HashSet<long>(mr.ZeroAvailTicks) : null;
                suspectCandidates.Add((res, allTicks.ToArray(), zeroSet, mr.DegradedSamples));
            }
        }
    }

    ConcurrentDictionary<string, SuspectGapClassification>? suspectResults = null;
    if (suspectCandidates.Count > 0)
        suspectResults = await ResourceHealthService.InvestigateSuspectGapsAsync(
            credential,
            suspectCandidates,
            utcStart,
            utcEnd,
            parallelism,
            activityGraceMinutes);

    // Step 6: Assemble final results — apply suspect-gap investigation outcomes and zero-tx storage exclusions
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

            // Apply suspect-gap investigation results
            int downtimeGapMinutes = 0;
            int activityLogExcludedGapMinutes = 0;
            int healthExplainedGapMinutes = 0;
            int metricIssueNullMinutes = 0;
            int excludedDegradedMinutes = 0;
            if (suspectResults is not null && suspectResults.TryGetValue(key, out var gc))
            {
                int totalSuspectMinutes = mr.SuspectMinutes;
                int suspectGapCount = CountSuspectGaps(mr);

                if (totalSuspectMinutes > 0)
                {
                    Console.WriteLine(
                        $"  [{res.Name}] metric scan found {totalSuspectMinutes} suspect min across {suspectGapCount} suspect gaps (null or <100% availability values)");

                    int activityExplainedSuspectMinutes = gc.ActivityLogExcludedGapMinutes + gc.ActivityLogDegradedMinutes;
                    int remainingAfterActivity = totalSuspectMinutes - activityExplainedSuspectMinutes;
                    if (remainingAfterActivity > 0)
                    {
                        Console.WriteLine(
                            $"  [{res.Name}] checked against Activity Log: {activityExplainedSuspectMinutes} suspect min explained by admin lifecycle events, {remainingAfterActivity} remain for Health History / fallback rules");
                    }
                    else
                    {
                        Console.WriteLine(
                            $"  [{res.Name}] checked against Activity Log: {activityExplainedSuspectMinutes} suspect min explained by admin lifecycle events");
                    }

                    if (remainingAfterActivity > 0 && gc.HealthHistoryApplied)
                    {
                        int healthExplainedSuspectMinutes = gc.HealthExplainedGapMinutes + (gc.CustomerExcusedDegradedMinutes - gc.ActivityLogDegradedMinutes);
                        Console.WriteLine(
                            $"  [{res.Name}] checked remaining suspect min against Health History: {gc.PlatformFaultGapMinutes} gap min confirmed as platform issues, {healthExplainedSuspectMinutes} suspect min explained as Unknown / customer-initiated");
                    }
                    else if (remainingAfterActivity > 0)
                    {
                        Console.WriteLine(
                            $"  [{res.Name}] Health History skipped for remaining suspect min (outside current retention window); applying fallback rules directly");
                    }
                }

                if (gc.ActivityLogExcludedGapMinutes > 0)
                {
                    elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - gc.ActivityLogExcludedGapMinutes);
                    activityLogExcludedGapMinutes = gc.ActivityLogExcludedGapMinutes;
                }
                if (gc.HealthExplainedGapMinutes > 0)
                {
                    elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - gc.HealthExplainedGapMinutes);
                    healthExplainedGapMinutes = gc.HealthExplainedGapMinutes;
                }
                if (gc.MetricIssueNullMinutes > 0)
                {
                    elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - gc.MetricIssueNullMinutes);
                    metricIssueNullMinutes = gc.MetricIssueNullMinutes;
                    Console.WriteLine($"  [{res.Name}] {gc.MetricIssueNullMinutes} unresolved null suspect min treated as metric issues and excluded from eligibility");
                }
                if (gc.CustomerExcusedDegradedMinutes > 0)
                {
                    elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - gc.CustomerExcusedDegradedMinutes);
                    excludedDegradedMinutes = gc.CustomerExcusedDegradedMinutes;
                    int healthExcusedDegradedMinutes = gc.CustomerExcusedDegradedMinutes - gc.ActivityLogDegradedMinutes;
                    var degradedReasons = new List<string>();
                    if (gc.ActivityLogDegradedMinutes > 0)
                        degradedReasons.Add($"{gc.ActivityLogDegradedMinutes} matched in Activity Log");
                    if (healthExcusedDegradedMinutes > 0)
                        degradedReasons.Add($"{healthExcusedDegradedMinutes} matched customer-initiated Health History");
                    Console.WriteLine($"  [{res.Name}] {gc.CustomerExcusedDegradedMinutes} degraded suspect min excluded from eligibility ({string.Join(", ", degradedReasons)})");
                }
                if (gc.PlatformFaultGapMinutes > 0)
                {
                    downtimeGapMinutes += gc.PlatformFaultGapMinutes;
                    Console.WriteLine($"  [{res.Name}] {gc.PlatformFaultGapMinutes} gap min confirmed as downtime (Health History platform issue)");
                }
                if (gc.UnresolvedZeroDowntimeMinutes > 0)
                {
                    downtimeGapMinutes += gc.UnresolvedZeroDowntimeMinutes;
                    Console.WriteLine($"  [{res.Name}] {gc.UnresolvedZeroDowntimeMinutes} unresolved 0% suspect min trusted as downtime");
                }
            }

            // DegradedMinutes = metric-level degraded datapoints that remain eligible
            // + gap minutes counted as downtime.
            elig.DegradedMinutes = Math.Max(0, mr.DegradedMinutes - (suspectResults is not null && suspectResults.TryGetValue(key, out var hc) ? hc.CustomerExcusedDegradedMinutes : 0) + downtimeGapMinutes);

            // For Storage Accounts, subtract zero-transaction minutes from eligibility
            int zeroTxExcludedMinutes = 0;
            if (mr.ZeroTxMin > 0 && res.Kind == "StorageAccount")
            {
                elig.EligibleMinutes = Math.Max(0, elig.EligibleMinutes - mr.ZeroTxMin);
                zeroTxExcludedMinutes = mr.ZeroTxMin;
            }

            if (activityLogExcludedGapMinutes > 0 || healthExplainedGapMinutes > 0 || metricIssueNullMinutes > 0 || excludedDegradedMinutes > 0 || zeroTxExcludedMinutes > 0)
            {
                var eligibilityAdjustments = new List<string>();
                if (activityLogExcludedGapMinutes > 0)
                    eligibilityAdjustments.Add($"{activityLogExcludedGapMinutes} gap min excluded by Activity Log");
                if (healthExplainedGapMinutes > 0)
                    eligibilityAdjustments.Add($"{healthExplainedGapMinutes} gap min excluded by Health History");
                if (metricIssueNullMinutes > 0)
                    eligibilityAdjustments.Add($"{metricIssueNullMinutes} null suspect min treated as metric issues");
                if (excludedDegradedMinutes > 0)
                    eligibilityAdjustments.Add($"{excludedDegradedMinutes} customer-excused degraded min");
                if (zeroTxExcludedMinutes > 0)
                    eligibilityAdjustments.Add($"{zeroTxExcludedMinutes} zero-tx min");

                Console.WriteLine(
                    $"  [{res.Name}] eligible min = {totalMinutes} - {string.Join(" - ", eligibilityAdjustments)} = {elig.EligibleMinutes}");
            }

            double customerExcusedAvail = suspectResults is not null && suspectResults.TryGetValue(key, out var availClass)
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

static int CountSuspectGaps(MetricScalars metrics)
{
    var ticks = new List<long>();
    if (metrics.GapTicks is not null)
        ticks.AddRange(metrics.GapTicks);
    if (metrics.ZeroAvailTicks is not null)
        ticks.AddRange(metrics.ZeroAvailTicks);
    if (metrics.DegradedSamples is not null)
        ticks.AddRange(metrics.DegradedSamples.Select(sample => sample.Tick));

    if (ticks.Count == 0)
        return 0;

    ticks.Sort();
    int gapCount = 1;
    long previous = ticks[0];
    long oneMinute = TimeSpan.FromMinutes(1).Ticks;

    for (int i = 1; i < ticks.Count; i++)
    {
        long current = ticks[i];
        if (current != previous && current - previous > oneMinute)
            gapCount++;
        previous = current;
    }

    return gapCount;
}

static (DateTimeOffset Start, DateTimeOffset End, string NormalizedMonth, bool IsMonthToDate) ResolveObservationWindow(string monthParameter)
{
    if (!DateTime.TryParseExact(
            monthParameter,
            "yyyyMM",
            CultureInfo.InvariantCulture,
            DateTimeStyles.None,
            out var monthDate))
    {
        throw new ArgumentException("--month must use format YYYYMM.");
    }

    var now = DateTimeOffset.UtcNow;
    var currentMinute = new DateTimeOffset(now.Year, now.Month, now.Day, now.Hour, now.Minute, 0, TimeSpan.Zero);
    var start = new DateTimeOffset(monthDate.Year, monthDate.Month, 1, 0, 0, 0, TimeSpan.Zero);
    if (start >= currentMinute)
        throw new ArgumentException("--month must not be in the future.");

    if (start < currentMinute.AddDays(-90))
        throw new ArgumentException("--month cannot start more than 90 days before now.");

    var nextMonth = start.AddMonths(1);
    var end = nextMonth < currentMinute ? nextMonth : currentMinute;
    if (end <= start)
        throw new ArgumentException("--month produced an empty observation period.");

    string normalizedMonth = start.ToString("yyyyMM", CultureInfo.InvariantCulture);
    bool isMonthToDate = end < nextMonth;
    return (start, end, normalizedMonth, isMonthToDate);
}

static string ReadRequiredValue(string[] args, ref int index, string optionName)
{
    if (index + 1 >= args.Length || args[index + 1].StartsWith("-", StringComparison.Ordinal))
        throw new ArgumentException($"{optionName} requires a value.");

    return args[++index];
}

static string[] ReadRequiredValues(string[] args, ref int index, string optionName)
{
    var values = new List<string>();
    while (index + 1 < args.Length && !args[index + 1].StartsWith("-", StringComparison.Ordinal))
        values.Add(args[++index]);

    return values.Count > 0
        ? values.ToArray()
        : throw new ArgumentException($"{optionName} requires at least one value.");
}

static int ParseIntOption(string rawValue, string optionName, int minValue)
{
    if (!int.TryParse(rawValue, NumberStyles.Integer, CultureInfo.InvariantCulture, out int value))
        throw new ArgumentException($"{optionName} must be an integer.");

    if (value < minValue)
        throw new ArgumentException($"{optionName} must be >= {minValue}.");

    return value;
}
