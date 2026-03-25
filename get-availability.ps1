#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Reports month-scoped availability for VMs, Azure SQL databases, and Storage Accounts.

.DESCRIPTION
    Mirrors the C# Get-Availability pipeline:
      1. Resolve subscriptions
      2. Inventory via Resource Graph
      3. Fetch metrics (Azure Monitor, parallel)
      4. Investigate suspect gaps (Activity Log + Resource Health)
      5. Assemble results
      6. Print table + summaries

    A suspect minute is any metric datapoint that is null or below 100%.
    Contiguous suspect minutes form "suspect gaps" for narration.

    For supported resource types, suspect minutes are first checked against
    Activity Log lifecycle operations:
      - Virtual Machines: start/deallocate/power off/restart
      - Azure SQL Databases: pause/resume
    Resource Health is then applied to classify remaining suspects:
      - platform fault confirmed (Unavailable/Degraded) -> counts as downtime
      - Unknown / customer-initiated -> valid explanation, excluded from eligibility
    Remaining null minutes become metric issues (excluded from eligibility),
    while remaining 0% minutes are trusted as downtime.

    When -Workspace is specified, Activity Log and Resource Health data are
    fetched in a single bulk KQL query from a Log Analytics workspace instead
    of per-resource REST API calls. This is faster for large estates and
    extends Resource Health coverage beyond the 30-day API retention limit
    (uses workspace retention, typically 365 days). Without -Workspace, the
    REST APIs are used directly (30-day Resource Health retention applies).

    The observation window is a UTC calendar month selected via -Month YYYYMM.
    Current month runs month-to-date; past months run full-month.

.PARAMETER Subscriptions
    One or more Azure subscription display names.

.PARAMETER Month
    Observation month in UTC, format YYYYMM.

.PARAMETER Kinds
    Resource kinds: vm, sql, storage (default: all).

.PARAMETER Resource
    Optional single resource name filter.

.PARAMETER Parallelism
    Max concurrent metric/investigation calls (default: auto-scaled to CPU cores).

.PARAMETER ActivityGraceMinutes
    Post-operation grace window for Activity Log lifecycle events (default: 10).

.PARAMETER Batch
    Use the regional Metrics Batch API instead of per-resource metric calls.

.PARAMETER BatchSize
    Max resources per batch call (default: 10, max 50). Implies -Batch.

.PARAMETER Workspace
    Log Analytics workspace ID (GUID). When provided, Activity Log and Resource
    Health data are fetched from the AzureActivity table in this workspace via a
    single bulk KQL query instead of per-resource REST API calls. This is faster
    for large estates and extends Resource Health retention beyond the 30-day API
    limit (uses workspace retention, typically 365 days). Requires the workspace
    to receive Activity Log diagnostic settings from the target subscriptions.

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySubscription' -Month 202506

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'Sub1','Sub2' -Month 202505 -Kinds vm,sql

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySub' -Month 202506 -Batch -BatchSize 20

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySub' -Month 202506 -Workspace 'b233a4b7-3c43-433c-ac60-1f6ff217ddd4'
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Subscriptions,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidatePattern('^\d{6}$')]
    [string]$Month,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateSet('vm','sql','storage')]
    [string[]]$Kinds = @('vm','sql','storage'),

    [Parameter(ParameterSetName = 'Run')]
    [string]$Resource,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 64)]
    [int]$Parallelism = [math]::Max(4, [math]::Min(16, [Environment]::ProcessorCount)),

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(0, 120)]
    [int]$ActivityGraceMinutes = 10,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$Batch,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 50)]
    [int]$BatchSize = 10,

    [Parameter(ParameterSetName = 'Run')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$Workspace,

    [Parameter(Mandatory, ParameterSetName = 'ShowVersion')]
    [switch]$Version
)

$ScriptVersion = '0.0.0-dev'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version) {
    Write-Host "get-availability $ScriptVersion"
    return
}

# ── Observation window ────────────────────────────────────────────────────────

function Resolve-ObservationWindow([string]$MonthParam) {
    $parsed = [datetime]::new(1, 1, 1)
    if (-not [datetime]::TryParseExact($MonthParam, 'yyyyMM',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw '-Month must use format YYYYMM.'
    }
    $now = [DateTimeOffset]::UtcNow
    $currentMinute = [DateTimeOffset]::new($now.Year, $now.Month, $now.Day,
        $now.Hour, $now.Minute, 0, [TimeSpan]::Zero)
    $start = [DateTimeOffset]::new($parsed.Year, $parsed.Month, 1, 0, 0, 0, [TimeSpan]::Zero)

    if ($start -ge $currentMinute) { throw '-Month must not be in the future.' }
    if ($start -lt $currentMinute.AddDays(-90)) { throw '-Month cannot start more than 90 days before now.' }

    $nextMonth = $start.AddMonths(1)
    $end = if ($nextMonth -lt $currentMinute) { $nextMonth } else { $currentMinute }
    if ($end -le $start) { throw '-Month produced an empty observation period.' }

    [PSCustomObject]@{
        Start           = $start
        End             = $end
        NormalizedMonth = $start.ToString('yyyyMM', [System.Globalization.CultureInfo]::InvariantCulture)
        IsMonthToDate   = $end -lt $nextMonth
        TotalMinutes    = [int]($end - $start).TotalMinutes
    }
}

# ── Resource inventory via Azure Resource Graph ───────────────────────────────

function Get-ResourceInventory {
    param(
        [string[]]$SubscriptionIds,
        [hashtable]$SubIdToName,
        [string[]]$Kinds,
        [string]$ResourceNameFilter
    )
    $kindToType = @{
        'vm'      = 'microsoft.compute/virtualmachines'
        'sql'     = 'microsoft.sql/servers/databases'
        'storage' = 'microsoft.storage/storageaccounts'
    }
    $unsupported = @($Kinds | Where-Object { -not $kindToType.ContainsKey($_) })
    if ($unsupported.Count -gt 0) {
        throw "Unsupported kind(s): $($unsupported -join ', '). Allowed values: vm, sql, storage."
    }

    $types = @($Kinds | ForEach-Object { $kindToType[$_] })
    $typeFilter = if ($types.Count -eq 1) { "type =~ '$($types[0])'" }
                  else { ($types | ForEach-Object { "type =~ '$_'" }) -join ' or ' }

    $nameFilter = ''
    if ($ResourceNameFilter) {
        $escaped = $ResourceNameFilter.Replace("'", "''")
        $nameFilter = "| where displayName =~ '$escaped' or name =~ '$escaped'`n"
    }

    $query = @"
resources
| where $typeFilter
| extend idParts = split(id, '/')
| extend sqlServerName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[8]), '')
| extend databaseName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[10]), '')
| where not(type =~ 'microsoft.sql/servers/databases' and databaseName =~ 'master')
| extend displayName = iff(type =~ 'microsoft.sql/servers/databases', strcat(sqlServerName, '/', databaseName), name)
${nameFilter}| extend resourceKind = case(
    type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
    type =~ 'microsoft.sql/servers/databases', 'AzureSqlDatabase',
    type =~ 'microsoft.storage/storageaccounts', 'StorageAccount',
    'Other'
)
| project id, name, displayName, type, subscriptionId, resourceGroup, location, resourceKind,
          sqlServerName, databaseName
"@

    $resources = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $params = @{ Query = $query; First = 1000; Subscription = $SubscriptionIds }
        if ($skipToken) { $params.SkipToken = $skipToken }
        $response = Search-AzGraph @params

        foreach ($row in $response.Data) {
            $kind = [string]$row.resourceKind
            $subId = [string]$row.subscriptionId
            $name = if ($row.displayName) { [string]$row.displayName } else { [string]$row.name }
            $resources.Add([PSCustomObject]@{
                Name              = $name
                Kind              = $kind
                ResourceId        = [string]$row.id
                SubscriptionId    = $subId
                SubscriptionName  = $SubIdToName.ContainsKey($subId) ? $SubIdToName[$subId] : $subId
                ResourceGroupName = [string]$row.resourceGroup
                Location          = [string]$row.location
            })
        }
        $skipToken = [string]::IsNullOrWhiteSpace($response.SkipToken) ? $null : $response.SkipToken
    } while ($skipToken)

    @($resources | Sort-Object SubscriptionName, Kind, Name)
}

# ── Helpers ───────────────────────────────────────────────────────────────────

## Abbreviates a resource kind for compact table/summary display.
function Get-ShortKind([string]$Kind) {
    switch ($Kind) {
        'VirtualMachine'   { 'VM' }
        'AzureSqlDatabase' { 'SQL' }
        'StorageAccount'   { 'Storage' }
        default            { $Kind }
    }
}

## Returns the effective start of the Resource Health 30-day retention window,
## clamped to PeriodStart if Health History covers the full observation period.
## When using Log Analytics (-Workspace), retention is workspace-defined (typically
## 365 days), so we return PeriodStart directly.
function Get-HealthCoverageStart([DateTimeOffset]$PeriodStart, [switch]$UseLogAnalytics) {
    if ($UseLogAnalytics) { return $PeriodStart }
    $now = [DateTimeOffset]::UtcNow
    $cm = [DateTimeOffset]::new($now.Year, $now.Month, $now.Day,
        $now.Hour, $now.Minute, 0, [TimeSpan]::Zero)
    $ret = $cm.AddDays(-30)
    $ret -gt $PeriodStart ? $ret : $PeriodStart
}

# ── Log Analytics bulk data fetch ─────────────────────────────────────────────

## Fetches all Activity Log lifecycle events and Resource Health transitions for
## the given subscriptions and resource types from a Log Analytics workspace in a
## single KQL query.  Returns a hashtable keyed by lowercase resource ID, each
## value containing ActivityEvents and HealthTransitions arrays.
function Get-LogAnalyticsData {
    param(
        [string]$WorkspaceId,
        [string[]]$SubscriptionIds,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [string]$ArmToken
    )

    $startIso = $PeriodStart.ToString('O')
    $endIso   = $PeriodEnd.ToString('O')
    $subList  = ($SubscriptionIds | ForEach-Object { "'$_'" }) -join ', '

    # Single KQL query that fetches both Activity Log operations and Resource
    # Health transitions, tagged with a Source column to distinguish them.
    $kql = @"
let subs = dynamic([$subList]);
let actOps = dynamic([
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/START/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/DEALLOCATE/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/POWEROFF/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/RESTART/ACTION',
  'MICROSOFT.SQL/SERVERS/DATABASES/PAUSE/ACTION',
  'MICROSOFT.SQL/SERVERS/DATABASES/RESUME/ACTION'
]);
let actData = AzureActivity
    | where SubscriptionId in (subs)
    | where CategoryValue == 'Administrative'
    | where OperationNameValue in~ (actOps)
    | where ActivityStatusValue == 'Success'
    | where TimeGenerated >= datetime($startIso) and TimeGenerated <= datetime($endIso)
    | project TimeGenerated, ResourceId=tolower(_ResourceId),
              OperationName=OperationNameValue, CorrelationId,
              Source='Activity';
let healthData = AzureActivity
    | where SubscriptionId in (subs)
    | where CategoryValue == 'ResourceHealth'
    | where ResourceProviderValue in ('MICROSOFT.COMPUTE', 'MICROSOFT.SQL', 'MICROSOFT.STORAGE')
    | project TimeGenerated, ResourceId=tolower(_ResourceId),
              Source='Health', OperationName=OperationNameValue,
              Properties=todynamic(Properties);
actData | union healthData
"@

    # Call the Log Analytics REST API
    $laUrl = "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query"
    $body = @{ query = $kql } | ConvertTo-Json -Depth 4

    $httpClient = [System.Net.Http.HttpClient]::new()
    $httpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $httpClient.Timeout = [TimeSpan]::FromMinutes(5)

    try {
        $content = [System.Net.Http.StringContent]::new(
            $body, [System.Text.Encoding]::UTF8, 'application/json')
        $response = $httpClient.PostAsync($laUrl, $content).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $jsonStr = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally {
        $httpClient.Dispose()
    }

    $result = $jsonStr | ConvertFrom-Json
    $table = $result.tables[0]
    $columns = @($table.columns | ForEach-Object { $_.name })
    $rows = @($table.rows)

    # Index columns
    $iTime     = [array]::IndexOf($columns, 'TimeGenerated')
    $iResId    = [array]::IndexOf($columns, 'ResourceId')
    $iOp       = [array]::IndexOf($columns, 'OperationName')
    $iCorr     = [array]::IndexOf($columns, 'CorrelationId')
    $iSource   = [array]::IndexOf($columns, 'Source')
    $iProps    = [array]::IndexOf($columns, 'Properties')

    # Build per-resource data
    $dataByRes = @{}
    $rawHealthEvents = @{}

    foreach ($row in $rows) {
        $resId = [string]$row[$iResId]
        if (-not $dataByRes.ContainsKey($resId)) {
            $dataByRes[$resId] = [PSCustomObject]@{
                ActivityEvents    = [System.Collections.Generic.List[object]]::new()
                HealthTransitions = [System.Collections.Generic.List[object]]::new()
            }
        }
        $entry = $dataByRes[$resId]

        $ts = [DateTimeOffset]::Parse([string]$row[$iTime],
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $source = [string]$row[$iSource]

        if ($source -eq 'Activity') {
            $entry.ActivityEvents.Add([PSCustomObject]@{
                Timestamp     = $ts
                OperationName = [string]$row[$iOp]
                CorrelationId = [string]$row[$iCorr]
            })
        }
        elseif ($source -eq 'Health') {
            $propsRaw = $row[$iProps]
            $props = if ($propsRaw -is [string] -and $propsRaw) {
                $propsRaw | ConvertFrom-Json
            } elseif ($propsRaw -is [PSCustomObject]) {
                $propsRaw
            } else { $null }

            if ($props) {
                $state = ''
                if ($props.PSObject.Properties['currentHealthStatus']) {
                    $state = [string]$props.currentHealthStatus
                } elseif ($props.PSObject.Properties['availabilityState']) {
                    $state = [string]$props.availabilityState
                }

                $rawCause = ''
                if ($props.PSObject.Properties['cause']) {
                    $rawCause = [string]$props.cause
                }

                if ($state) {
                    # Determine operation type from OperationNameValue
                    $opName = [string]$row[$iOp]
                    $opType = if ($opName -match '/Activated/') { 'Activated' }
                              elseif ($opName -match '/Resolved/')  { 'Resolved' }
                              elseif ($opName -match '/InProgress/') { 'InProgress' }
                              else { 'Updated' }

                    if (-not $rawHealthEvents.ContainsKey($resId)) {
                        $rawHealthEvents[$resId] = [System.Collections.Generic.List[object]]::new()
                    }
                    $rawHealthEvents[$resId].Add([PSCustomObject]@{
                        Timestamp     = $ts
                        State         = $state
                        RawCause      = $rawCause
                        OperationType = $opType
                    })
                }
            }
        }
    }

    # ── Post-process health events into clean, incident-based transitions ──
    # AzureActivity ResourceHealth events include lifecycle events (Activated,
    # Updated, InProgress, Resolved) for each health incident.  Multiple events
    # per incident create spurious transitions and the initial Activated event
    # always has cause=Unknown (cause is determined later via Updated events).
    # The REST API retroactively applies the final cause to the entire incident.
    # This post-processing replicates that behaviour:
    # 1. Only create transitions when the health state actually changes.
    # 2. Track incidents (Activated/InProgress → Resolved) and collect the
    #    latest non-Unknown cause within each incident.
    # 3. On Resolved, retroactively apply the final cause to all transitions
    #    in that incident.
    # 4. Skip orphan Updated events outside any incident (stale events).
    foreach ($resId in $rawHealthEvents.Keys) {
        if (-not $dataByRes.ContainsKey($resId)) { continue }
        $entry = $dataByRes[$resId]
        $sorted = $rawHealthEvents[$resId] | Sort-Object Timestamp

        $trackedState = 'Available'
        $lastTransition = $null
        $inIncident = $false
        $incidentTransitions = [System.Collections.Generic.List[object]]::new()
        $incidentCause = ''

        foreach ($evt in $sorted) {
            $st   = $evt.State
            $rc   = $evt.RawCause
            $op   = $evt.OperationType

            # Open incident on Activated or InProgress
            if (($op -eq 'Activated' -or $op -eq 'InProgress') -and -not $inIncident) {
                $inIncident = $true
                $incidentTransitions = [System.Collections.Generic.List[object]]::new()
                $incidentCause = ''
            }

            # Track the latest non-Unknown cause within the incident
            if ($inIncident -and $rc -and $rc -ne 'Unknown') {
                $incidentCause = $rc
            }

            # Skip orphan Updated events (stale / out-of-incident)
            if ($op -ne 'Activated' -and $op -ne 'InProgress' -and
                $op -ne 'Resolved' -and -not $inIncident) {
                continue
            }

            # Only create a transition when the state actually changes
            if ($st -ne $trackedState) {
                $mapped = switch ($rc) {
                    'UserInitiated'     { 'Customer Initiated' }
                    'PlatformInitiated' { 'Platform Initiated' }
                    default { '' }
                }
                $transition = [PSCustomObject]@{
                    OccurredOn       = $evt.Timestamp
                    State            = $st
                    ReasonType       = $mapped
                    Context          = if ($rc -eq 'UserInitiated') { 'Customer Initiated' } else { '' }
                    HealthEventCause = if ($rc -eq 'UserInitiated') { 'UserInitiated' } else { '' }
                }
                $entry.HealthTransitions.Add($transition)
                $trackedState = $st
                $lastTransition = $transition

                if ($inIncident -and $st -ne 'Available') {
                    $incidentTransitions.Add($transition)
                }
            }
            else {
                # Same state — update cause on last transition if more specific
                if ($lastTransition -and $rc -and $rc -ne 'Unknown' -and
                    $lastTransition.ReasonType -in @('', 'Unknown')) {
                    $mapped = switch ($rc) {
                        'UserInitiated'     { 'Customer Initiated' }
                        'PlatformInitiated' { 'Platform Initiated' }
                        default { $rc }
                    }
                    $lastTransition.ReasonType       = $mapped
                    $lastTransition.Context          = if ($rc -eq 'UserInitiated') { 'Customer Initiated' } else { '' }
                    $lastTransition.HealthEventCause = if ($rc -eq 'UserInitiated') { 'UserInitiated' } else { '' }
                }
            }

            # Close incident on Resolved — retroactively apply final cause
            if ($op -eq 'Resolved') {
                if ($incidentCause -and $incidentCause -ne 'Unknown' -and
                    $incidentTransitions.Count -gt 0) {
                    $mapped = switch ($incidentCause) {
                        'UserInitiated'     { 'Customer Initiated' }
                        'PlatformInitiated' { 'Platform Initiated' }
                        default { $incidentCause }
                    }
                    foreach ($t in $incidentTransitions) {
                        $t.ReasonType       = $mapped
                        $t.Context          = if ($incidentCause -eq 'UserInitiated') { 'Customer Initiated' } else { '' }
                        $t.HealthEventCause = if ($incidentCause -eq 'UserInitiated') { 'UserInitiated' } else { '' }
                    }
                }
                $inIncident = $false
                $incidentTransitions = [System.Collections.Generic.List[object]]::new()
                $incidentCause = ''
            }
        }

        # Handle open incident at end of event stream
        if ($inIncident -and $incidentTransitions.Count -gt 0 -and
            $incidentCause -and $incidentCause -ne 'Unknown') {
            $mapped = switch ($incidentCause) {
                'UserInitiated'     { 'Customer Initiated' }
                'PlatformInitiated' { 'Platform Initiated' }
                default { $incidentCause }
            }
            foreach ($t in $incidentTransitions) {
                $t.ReasonType       = $mapped
                $t.Context          = if ($incidentCause -eq 'UserInitiated') { 'Customer Initiated' } else { '' }
                $t.HealthEventCause = if ($incidentCause -eq 'UserInitiated') { 'UserInitiated' } else { '' }
            }
        }
    }

    Write-Host "Log Analytics: fetched $($rows.Count) events for $($dataByRes.Count) resource(s)"
    $dataByRes
}

## Truncates a string to max length with '...' suffix.
function Get-TruncatedString([string]$s, [int]$max) {
    $s.Length -le $max ? $s : ($s.Substring(0, $max - 3) + '...')
}

# ── Compiled metric processor ─────────────────────────────────────────────────
# The JSON processing loop iterates ~44 K data-points per resource (PT1M × 1
# month).  In interpreted PowerShell that is the dominant bottleneck; compiling
# the identical logic as C# via Add-Type makes it run at native .NET speed.

if (-not ([System.Management.Automation.PSTypeName]'MetricProcessor').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text.Json;

public sealed class MetricProcessorResult
{
    public double AvailableSum;
    public int    NumericPoints;
    public int    ZeroTxMin;
    public long[]   NullTicks     = Array.Empty<long>();
    public long[]   ZeroTicks     = Array.Empty<long>();
    public long[]   DegradedTicks = Array.Empty<long>();
    public double[] DegradedValues = Array.Empty<double>();

    public int  GapMinutes              => NullTicks.Length + ZeroTicks.Length;
    public int  DegradedMinutes         => DegradedTicks.Length;
    public bool ExcludeFromAvailability => NumericPoints == 0 && NullTicks.Length == 0
                                           && ZeroTicks.Length == 0 && DegradedTicks.Length == 0;
    public int  SuspectMinutes          => GapMinutes + DegradedMinutes;
}

public sealed class BatchResourceResult
{
    public string ResourceId      = "";
    public string ResourceIdLower = "";
    public MetricProcessorResult Metrics = new();
}

public static class MetricProcessor
{
    /// <summary>Per-resource response: root has "value" array.</summary>
    public static MetricProcessorResult ProcessSingle(JsonDocument doc, bool isVm, bool isStorage)
        => ProcessMetricArray(doc.RootElement.GetProperty("value"), isVm, isStorage);

    /// <summary>Batch response: root has "values" array, each with "resourceid" + "value".</summary>
    public static BatchResourceResult[] ProcessBatch(JsonDocument doc, bool isVm, bool isStorage)
    {
        var results = new List<BatchResourceResult>();
        foreach (var entry in doc.RootElement.GetProperty("values").EnumerateArray())
        {
            string resId = entry.GetProperty("resourceid").GetString() ?? "";
            results.Add(new BatchResourceResult
            {
                ResourceId      = resId,
                ResourceIdLower = resId.ToLowerInvariant(),
                Metrics         = ProcessMetricArray(entry.GetProperty("value"), isVm, isStorage)
            });
        }
        return results.ToArray();
    }

    // ── shared inner loop ────────────────────────────────────────────────────
    private static MetricProcessorResult ProcessMetricArray(
        JsonElement valueArr, bool isVm, bool isStorage)
    {
        var r = new MetricProcessorResult();
        var nullTicks      = new List<long>();
        var zeroTicks      = new List<long>();
        var degradedTicks  = new List<long>();
        var degradedValues = new List<double>();

        if (isStorage)
        {
            var txByTicks = new Dictionary<long, double>();
            foreach (var metricEl in valueArr.EnumerateArray())
            {
                if (!string.Equals(metricEl.GetProperty("name").GetProperty("value").GetString(), "Transactions", StringComparison.OrdinalIgnoreCase))
                    continue;
                foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
                foreach (var dp  in tsEl.GetProperty("data").EnumerateArray())
                {
                    long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!)
                                         .ToUniversalTime().Ticks;
                    if (dp.TryGetProperty("total", out var tot) && tot.ValueKind == JsonValueKind.Number)
                        txByTicks[ticks] = tot.GetDouble();
                }
            }
            foreach (var metricEl in valueArr.EnumerateArray())
            {
                if (!string.Equals(metricEl.GetProperty("name").GetProperty("value").GetString(), "Availability", StringComparison.OrdinalIgnoreCase))
                    continue;
                foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
                foreach (var dp  in tsEl.GetProperty("data").EnumerateArray())
                {
                    long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!)
                                         .ToUniversalTime().Ticks;
                    bool hasTx = txByTicks.TryGetValue(ticks, out double txVal) && txVal > 0;
                    double? minVal = null;
                    if (dp.TryGetProperty("minimum", out var minEl) && minEl.ValueKind == JsonValueKind.Number)
                        minVal = minEl.GetDouble();

                    if (hasTx && minVal.HasValue)
                    {
                        double norm = minVal.Value / 100.0;
                        r.NumericPoints++;
                        if (norm == 0.0)      zeroTicks.Add(ticks);
                        else { r.AvailableSum += norm;
                               if (norm < 1.0) { degradedTicks.Add(ticks); degradedValues.Add(norm); } }
                    }
                    else if (hasTx)  nullTicks.Add(ticks);
                    else             r.ZeroTxMin++;
                }
            }
        }
        else
        {
            foreach (var metricEl in valueArr.EnumerateArray())
            {
                string mName = metricEl.GetProperty("name").GetProperty("value").GetString() ?? "";
                if (!string.Equals(mName, "VmAvailabilityMetric", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(mName, "Availability", StringComparison.OrdinalIgnoreCase)) continue;

                foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
                foreach (var dp  in tsEl.GetProperty("data").EnumerateArray())
                {
                    long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!)
                                         .ToUniversalTime().Ticks;
                    double? minVal = null;
                    if (dp.TryGetProperty("minimum", out var minEl) && minEl.ValueKind == JsonValueKind.Number)
                        minVal = minEl.GetDouble();

                    if (minVal.HasValue)
                    {
                        r.NumericPoints++;
                        double v = isVm ? minVal.Value : minVal.Value / 100.0;
                        if (v == 0.0)      zeroTicks.Add(ticks);
                        else { r.AvailableSum += v;
                               if (v < 1.0) { degradedTicks.Add(ticks); degradedValues.Add(v); } }
                    }
                    else nullTicks.Add(ticks);
                }
            }
        }

        r.NullTicks      = nullTicks.ToArray();
        r.ZeroTicks      = zeroTicks.ToArray();
        r.DegradedTicks  = degradedTicks.ToArray();
        r.DegradedValues = degradedValues.ToArray();
        return r;
    }
}
'@
}

# ── Compiled gap investigation helpers ────────────────────────────────────────
# ExpandToTickSet and ClassifyGaps run at native .NET speed, replacing interpreted
# PowerShell loops that iterate over potentially tens of thousands of ticks.

if (-not ([System.Management.Automation.PSTypeName]'GapProcessor').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;

// ── Gap investigation helpers ───────────────────────────────────────────────

public sealed class GapClassificationResult
{
    public int    PlatformFaultGapMin;
    public int    UnresolvedZeroDowntimeMin;
    public int    HealthExplainedGapMin;
    public int    MetricIssueNullMin;
    public int    ActivityLogExcludedGapMin;
    public int    CustomerExcusedDegradedMin;
    public double CustomerExcusedDegradedAvail;
    public int    ActivityLogDegradedMin;
    public int    HealthConfirmedDegradedMin;
}

public static class GapProcessor
{
    private const long OneMinTicks = 600_000_000L;

    /// <summary>Expands interval pairs (fromTicks[i]..toTicks[i]) into a HashSet of minute-aligned ticks.</summary>
    public static HashSet<long> ExpandToTickSet(long[] fromTicks, long[] toTicks)
    {
        var set = new HashSet<long>();
        if (fromTicks == null || fromTicks.Length == 0) return set;
        for (int i = 0; i < fromTicks.Length; i++)
        {
            long t = fromTicks[i] - (fromTicks[i] % OneMinTicks);
            if (t < fromTicks[i]) t += OneMinTicks;
            while (t < toTicks[i])
            {
                set.Add(t);
                t += OneMinTicks;
            }
        }
        return set;
    }

    /// <summary>Classifies each suspect tick into gap/degraded categories using precomputed HashSets.</summary>
    public static GapClassificationResult ClassifyGaps(
        long[] allGapTicks, long[] zeroTicks,
        long[] degradedTicks, double[] degradedValues,
        HashSet<long> activitySet, HashSet<long> faultSet,
        HashSet<long> unknownSet, HashSet<long> customerSet,
        bool healthHistoryApplied, long hcStartTicks)
    {
        var r = new GapClassificationResult();
        var zeroSet = new HashSet<long>(zeroTicks ?? Array.Empty<long>());

        if (allGapTicks != null)
        {
            foreach (long tk in allGapTicks)
            {
                bool isZero     = zeroSet.Contains(tk);
                bool inActivity = activitySet.Contains(tk);
                bool inHCov     = healthHistoryApplied && tk >= hcStartTicks;
                bool inFault    = inHCov && faultSet.Contains(tk);
                bool inUnknown  = inHCov && unknownSet.Contains(tk);
                bool inCustomer = inHCov && customerSet.Contains(tk);

                if      (inFault)                   r.PlatformFaultGapMin++;
                else if (inActivity)                r.ActivityLogExcludedGapMin++;
                else if (inCustomer || inUnknown)   r.HealthExplainedGapMin++;
                else if (isZero)                    r.UnresolvedZeroDowntimeMin++;
                else                                r.MetricIssueNullMin++;
            }
        }

        if (degradedTicks != null)
        {
            for (int i = 0; i < degradedTicks.Length; i++)
            {
                long   tk = degradedTicks[i];
                double dv = degradedValues[i];
                bool inActivity = activitySet.Contains(tk);
                bool inHCov     = healthHistoryApplied && tk >= hcStartTicks;
                bool inFault    = inHCov && faultSet.Contains(tk);
                bool inCustomer = inHCov && customerSet.Contains(tk);

                if (inFault)
                    r.HealthConfirmedDegradedMin++;
                else if (inActivity || inCustomer)
                {
                    r.CustomerExcusedDegradedMin++;
                    r.CustomerExcusedDegradedAvail += dv;
                    if (inActivity) r.ActivityLogDegradedMin++;
                }
            }
        }

        return r;
    }
}
'@
}

# ── Kind configuration ────────────────────────────────────────────────────────
# Maps resource kind → metric namespace, metric names, and aggregation.
# Used by both the per-resource ARM Metrics API and the regional Batch API.

$KindConfig = @{
    'VirtualMachine' = @{
        Namespace   = 'Microsoft.Compute/virtualMachines'
        MetricNames = 'VmAvailabilityMetric'
        Aggregation = 'Minimum'
    }
    'AzureSqlDatabase' = @{
        Namespace   = 'Microsoft.Sql/servers/databases'
        MetricNames = 'Availability'
        Aggregation = 'Minimum'
    }
    'StorageAccount' = @{
        Namespace   = 'Microsoft.Storage/storageAccounts'
        MetricNames = 'Availability,Transactions'
        Aggregation = 'Minimum,Total'
    }
}

# ── Batch endpoint validation ─────────────────────────────────────────────────

## Probes each regional batch endpoint with an empty payload to verify reachability.
## 400/401/403 are expected for the dummy subscription and treated as OK.
function Test-BatchEndpoints {
    param(
        [string]$MetricsToken,
        [string[]]$Regions
    )

    Write-Host "Validating batch endpoint availability for $($Regions.Count) region(s)..."
    $allOk = $true
    foreach ($region in $Regions) {
        $endpoint = "https://$region.metrics.monitor.azure.com"
        $testUri = "$endpoint/subscriptions/00000000-0000-0000-0000-000000000000/metrics:getBatch?api-version=2023-10-01&metricnamespace=Microsoft.Compute/virtualMachines&metricnames=Percentage%20CPU"
        $body = '{"resourceids":[]}'

        try {
            $oldPref = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $testUri -Method POST -Body $body -ContentType 'application/json' `
                    -Headers @{ Authorization = "Bearer $MetricsToken" } -UseBasicParsing -ErrorAction Stop | Out-Null
            }
            finally { $ProgressPreference = $oldPref }
            Write-Host "  $region`: OK"
        }
        catch {
            $statusCode = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($statusCode -in @(400, 401, 403)) {
                Write-Host "  $region`: OK (got expected $statusCode for probe)"
            }
            else {
                Write-Host "  $region`: FAILED (status=$statusCode) - $_" -ForegroundColor Red
                $allOk = $false
            }
        }
    }
    if (-not $allOk) {
        throw 'One or more batch endpoints are unreachable. Aborting.'
    }
    Write-Host 'All batch endpoints validated successfully.'
    Write-Host ''
}

# ── Batch metric processing ───────────────────────────────────────────────────

## Fetches Azure Monitor metrics using the regional Batch API instead of per-resource
## ARM calls. Resources are grouped by (subscription, region, kind), chunked by
## BatchSize, and processed in parallel waves with GC between waves to bound memory.
## Uses HttpClient with ResponseHeadersRead for streaming JSON parsing.
function Get-BatchAvailabilityMetrics {
    param(
        [object[]]$Resources,
        [DateTimeOffset]$StartDate,
        [DateTimeOffset]$EndDate,
        [int]$ThrottleLimit,
        [int]$BatchSize,
        [string]$MetricsToken
    )

    $startIso = $StartDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $endIso   = $EndDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Group resources by (subscriptionId, location, kind)
    $groups = @{}
    foreach ($res in $Resources) {
        $groupKey = "$($res.SubscriptionId)|$($res.Location.ToLowerInvariant())|$($res.Kind)"
        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$groupKey].Add($res)
    }

    # Split each group into chunks of BatchSize to form individual batch API calls
    $batchWorkItems = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $groups.GetEnumerator()) {
        $parts = $entry.Key -split '\|'
        $subId    = $parts[0]
        $location = $parts[1]
        $kind     = $parts[2]

        $config = $KindConfig[$kind]
        if (-not $config) {
            Write-Warning "No batch config for kind '$kind', skipping."
            continue
        }

        $chunk = [System.Collections.Generic.List[object]]::new()
        foreach ($res in $entry.Value) {
            $chunk.Add($res)
            if ($chunk.Count -ge $BatchSize) {
                $batchWorkItems.Add([PSCustomObject]@{
                    SubscriptionId = $subId
                    Location       = $location
                    Kind           = $kind
                    Config         = $config
                    Resources      = @($chunk)
                })
                $chunk = [System.Collections.Generic.List[object]]::new()
            }
        }
        if ($chunk.Count -gt 0) {
            $batchWorkItems.Add([PSCustomObject]@{
                SubscriptionId = $subId
                Location       = $location
                Kind           = $kind
                Config         = $config
                Resources      = @($chunk)
            })
        }
    }

    $totalResources = $Resources.Count
    $totalBatches   = $batchWorkItems.Count
    $uniqueRegions  = @($groups.Keys | ForEach-Object { ($_ -split '\|')[1] } | Select-Object -Unique | Sort-Object)
    Write-Host "Grouped $totalResources resource(s) into $totalBatches batch(es) across $($uniqueRegions.Count) region(s) (max $BatchSize per batch)."
    $sortedEntries = @($groups.GetEnumerator() | Sort-Object { ($_.Key -split '\|')[1] }, { ($_.Key -split '\|')[2] }, { ($_.Key -split '\|')[0] })
    foreach ($entry in $sortedEntries) {
        $parts = $entry.Key -split '\|'
        $subName  = $entry.Value[0].SubscriptionName
        $kind     = Get-ShortKind $parts[2]
        $location = $parts[1]
        $count    = $entry.Value.Count
        $chunks   = [math]::Ceiling($count / $BatchSize)
        Write-Host "  $location / $kind / $(Get-TruncatedString $subName 30) : $count resource(s) -> $chunks batch(es)"
    }
    Write-Host ''

    $resultByRes = @{}
    $batchesDone = 0

    $batchHttpClient = [System.Net.Http.HttpClient]::new()
    $batchHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $MetricsToken")
    $batchHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    $waveSize = $ThrottleLimit
    for ($waveStart = 0; $waveStart -lt $batchWorkItems.Count; $waveStart += $waveSize) {
        $waveEnd   = [math]::Min($waveStart + $waveSize, $batchWorkItems.Count)
        $waveItems = @($batchWorkItems[$waveStart..($waveEnd - 1)])
        $waveNum   = [math]::Floor($waveStart / $waveSize) + 1
        $totalWaves = [math]::Ceiling($batchWorkItems.Count / $waveSize)

        $waveProgress = [hashtable]::Synchronized(@{ Done = 0; Total = $waveItems.Count; Base = $batchesDone; Grand = $totalBatches; Waves = $totalWaves; Wave = $waveNum })
        [Console]::Write("`r  Fetching batch metrics: wave $waveNum/$totalWaves, batch $batchesDone/$totalBatches done")

        $waveResults = @($waveItems | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $workItem     = $_
        $client       = $using:batchHttpClient
        $startIso     = $using:startIso
        $endIso       = $using:endIso
        $wp           = $using:waveProgress

        $subId    = $workItem.SubscriptionId
        $location = $workItem.Location
        $kind     = $workItem.Kind
        $config   = $workItem.Config
        $resources = $workItem.Resources

        $isVm      = $kind -eq 'VirtualMachine'
        $isStorage = $kind -eq 'StorageAccount'

        $resourceIds = @($resources | ForEach-Object { $_.ResourceId })

        $endpoint = "https://$location.metrics.monitor.azure.com"

        $uri = "$endpoint/subscriptions/$subId/metrics:getBatch" +
               "?starttime=$([uri]::EscapeDataString($startIso))" +
               "&endtime=$([uri]::EscapeDataString($endIso))" +
               "&interval=PT1M" +
               "&metricnamespace=$([uri]::EscapeDataString($config.Namespace))" +
               "&metricnames=$([uri]::EscapeDataString($config.MetricNames))" +
               "&aggregation=$([uri]::EscapeDataString($config.Aggregation))" +
               "&api-version=2023-10-01"

        $bodyObj = @{ resourceids = $resourceIds }
        $bodyJson = $bodyObj | ConvertTo-Json -Compress -Depth 3

        $doc = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $httpReq = [System.Net.Http.HttpRequestMessage]::new(
                [System.Net.Http.HttpMethod]::Post, $uri)
            $httpReq.Content = [System.Net.Http.StringContent]::new(
                $bodyJson, [System.Text.Encoding]::UTF8, 'application/json')
            try {
                $httpResp = $client.SendAsync($httpReq,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()
                $sc = [int]$httpResp.StatusCode
                if ($sc -ge 200 -and $sc -lt 300) {
                    $respStream = $httpResp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    try { $doc = [System.Text.Json.JsonDocument]::ParseAsync($respStream).GetAwaiter().GetResult() }
                    finally { $respStream.Dispose() }
                    $httpResp.Dispose(); $httpReq.Dispose()
                    break
                }
                $httpResp.Dispose(); $httpReq.Dispose()
                if (($sc -in @(401, 429) -or $sc -ge 500) -and $attempt -lt 5) {
                    Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt)))
                    continue
                }
                $names = ($resources | ForEach-Object { $_.Name }) -join ', '
                Write-Warning "Batch metric query failed for [$names]: HTTP $sc"
                break
            }
            catch {
                try { $httpReq.Dispose() } catch {}
                $retryable = $_.ToString() -match 'transport|connection.*closed|reset by peer|timed?\s*out'
                if ($retryable -and $attempt -lt 5) {
                    Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt)))
                    continue
                }
                $names = ($resources | ForEach-Object { $_.Name }) -join ', '
                Write-Warning "Batch metric query failed for [$names]: $_"
                break
            }
        }
        $bodyJson = $null

        if (-not $doc) {
            foreach ($resource in $resources) {
                [PSCustomObject]@{
                    ResourceId              = $resource.ResourceId
                    ResourceIdLower         = $resource.ResourceId.ToLowerInvariant()
                    Name                    = $resource.Name
                    AvailableSum            = 0.0
                    GapMinutes              = 0
                    ZeroTxMin               = 0
                    ExcludeFromAvailability = $true
                    GapTicks                = @()
                    ZeroAvailTicks          = @()
                    DegradedMinutes         = 0
                    DegradedTicks           = @()
                    DegradedValues          = @()
                    SuspectMinutes          = 0
                }
            }
        $wp.Done++
        [Console]::Write("`r  Fetching batch metrics: wave $($wp.Wave)/$($wp.Waves), batch $($wp.Base + $wp.Done)/$($wp.Grand) done")
            return
        }

        $resById = @{}
        foreach ($r in $resources) { $resById[$r.ResourceId.ToLowerInvariant()] = $r }

        try {
            $batchResults = [MetricProcessor]::ProcessBatch($doc, $isVm, $isStorage)
            foreach ($br in $batchResults) {
                $resObj  = if ($resById.ContainsKey($br.ResourceIdLower)) { $resById[$br.ResourceIdLower] } else { $null }
                $resName = if ($resObj) { $resObj.Name } else { $br.ResourceId }
                $m = $br.Metrics

                [PSCustomObject]@{
                    ResourceId              = $br.ResourceId
                    ResourceIdLower         = $br.ResourceIdLower
                    Name                    = $resName
                    AvailableSum            = $m.AvailableSum
                    GapMinutes              = $m.GapMinutes
                    ZeroTxMin               = $m.ZeroTxMin
                    ExcludeFromAvailability = $m.ExcludeFromAvailability
                    GapTicks                = $m.NullTicks
                    ZeroAvailTicks          = $m.ZeroTicks
                    DegradedMinutes         = $m.DegradedMinutes
                    DegradedTicks           = $m.DegradedTicks
                    DegradedValues          = $m.DegradedValues
                    SuspectMinutes          = $m.SuspectMinutes
                }
            }
        }
        finally {
            if ($doc) { $doc.Dispose() }
        }

        $wp.Done++
        [Console]::Write("`r  Fetching batch metrics: wave $($wp.Wave)/$($wp.Waves), batch $($wp.Base + $wp.Done)/$($wp.Grand) done")
    })

        # Collect this wave's results into the main hashtable
        [Console]::Write("`r" + (' ' * 60) + "`r")
        foreach ($item in $waveResults) {
            $key = if ($item.ResourceIdLower) { $item.ResourceIdLower } else { $item.ResourceId.ToLowerInvariant() }
            $resultByRes[$key] = $item
        }
        $batchesDone += $waveItems.Count
        $waveResults = $null

        if ($waveStart + $waveSize -lt $batchWorkItems.Count) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
        }
    }

    $batchHttpClient.Dispose()

    [Console]::Write("`r" + (' ' * 80) + "`r")
    Write-Host "Batch queries completed. Received results for $($resultByRes.Count) / $totalResources resource(s)."

    $resultByRes
}

# ── Per-resource metrics (parallel) ───────────────────────────────────────────

## Fetches Azure Monitor metrics one resource at a time via the ARM Metrics API.
## Uses ForEach-Object -Parallel with a shared HttpClient for connection pooling
## and System.Text.Json for streaming JSON parsing. Retries on 429/5xx.
function Get-AvailabilityMetrics {
    param(
        [object[]]$Resources,
        [DateTimeOffset]$StartDate,
        [DateTimeOffset]$EndDate,
        [int]$ThrottleLimit,
        [string]$ArmToken
    )
    $total = $Resources.Count
    Write-Host "Querying metrics for $total resource(s) with parallelism $ThrottleLimit..."

    $armHttpClient = [System.Net.Http.HttpClient]::new()
    $armHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $armHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    $done = 0
    $resultByRes = @{}

    $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $resource = $_
        $client   = $using:armHttpClient
        $startIso = ($using:StartDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endIso   = ($using:EndDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $isVm      = $resource.Kind -eq 'VirtualMachine'
        $isStorage  = $resource.Kind -eq 'StorageAccount'

        $kindCfg = ($using:KindConfig)[$resource.Kind]
        $metricNames = $kindCfg.MetricNames
        $agg         = $kindCfg.Aggregation
        $ns          = $kindCfg.Namespace

        $uri = "https://management.azure.com$($resource.ResourceId)/providers/Microsoft.Insights/metrics?" +
               "api-version=2024-02-01&metricnamespace=$([uri]::EscapeDataString($ns))" +
               "&metricnames=$([uri]::EscapeDataString($metricNames))" +
               "&timespan=$startIso/$endIso&interval=PT1M&aggregation=$agg"

        $doc = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            $httpReq = [System.Net.Http.HttpRequestMessage]::new(
                [System.Net.Http.HttpMethod]::Get, $uri)
            try {
                $httpResp = $client.SendAsync($httpReq,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()
                $sc = [int]$httpResp.StatusCode
                if ($sc -ge 200 -and $sc -lt 300) {
                    $respStream = $httpResp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                    try { $doc = [System.Text.Json.JsonDocument]::ParseAsync($respStream).GetAwaiter().GetResult() }
                    finally { $respStream.Dispose() }
                    $httpResp.Dispose(); $httpReq.Dispose()
                    break
                }
                $httpResp.Dispose(); $httpReq.Dispose()
                if (($sc -eq 429 -or $sc -ge 500) -and $attempt -lt 5) {
                    Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt)))
                    continue
                }
                Write-Warning "Metric query failed for '$($resource.Name)': HTTP $sc"
                break
            }
            catch {
                try { $httpReq.Dispose() } catch {}
                $retryable = $_.ToString() -match 'transport|connection.*closed|reset by peer|timed?\s*out'
                if ($retryable -and $attempt -lt 5) {
                    Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt)))
                    continue
                }
                Write-Warning "Metric query failed for '$($resource.Name)': $_"
                break
            }
        }

        $m = $null
        if ($doc) {
            try   { $m = [MetricProcessor]::ProcessSingle($doc, $isVm, $isStorage) }
            catch { Write-Warning "Metric processing failed for '$($resource.Name)': $_" }
            finally { $doc.Dispose() }
        }

        if ($m) {
            [PSCustomObject]@{
                ResourceId              = $resource.ResourceId
                Name                    = $resource.Name
                AvailableSum            = $m.AvailableSum
                GapMinutes              = $m.GapMinutes
                ZeroTxMin               = $m.ZeroTxMin
                ExcludeFromAvailability = $m.ExcludeFromAvailability
                GapTicks                = $m.NullTicks
                ZeroAvailTicks          = $m.ZeroTicks
                DegradedMinutes         = $m.DegradedMinutes
                DegradedTicks           = $m.DegradedTicks
                DegradedValues          = $m.DegradedValues
                SuspectMinutes          = $m.SuspectMinutes
            }
        } else {
            [PSCustomObject]@{
                ResourceId              = $resource.ResourceId
                Name                    = $resource.Name
                AvailableSum            = 0.0
                GapMinutes              = 0
                ZeroTxMin               = 0
                ExcludeFromAvailability = $true
                GapTicks                = @()
                ZeroAvailTicks          = @()
                DegradedMinutes         = 0
                DegradedTicks           = @()
                DegradedValues          = @()
                SuspectMinutes          = 0
            }
        }
    } | ForEach-Object {
        $done++
        $key = $_.ResourceId.ToLowerInvariant()
        $resultByRes[$key] = $_
        if ($done % 10 -eq 0 -or $done -eq $total) {
            Write-Progress -Activity 'Querying metrics' `
                -Status "[$done / $total] $($_.Name)" `
                -PercentComplete ([math]::Min(100, $done / $total * 100))
        }
    }
    Write-Progress -Activity 'Querying metrics' -Completed
    $armHttpClient.Dispose()
    $resultByRes
}

# ── Suspect gap investigation (parallel) ──────────────────────────────────────

## For each resource with suspect minutes, queries Activity Log (for supported
## lifecycle operations) and Resource Health to classify every suspect minute.
## When Log Analytics data is provided, uses pre-fetched events; otherwise falls
## back to per-resource REST API calls (30-day Resource Health retention applies).
## Classification precedence:
##   1. Platform fault (Resource Health)       → stays eligible, counts as downtime
##   2. Lifecycle activity (Activity Log)       → excluded from eligibility
##   3. Unknown / customer-initiated (Health)  → excluded from eligibility
##   4. Remaining null                          → metric issue, excluded
##   5. Remaining 0%                            → trusted as downtime
##   6. Remaining degraded (0% < v < 100%)     → trusted as degraded availability
function Invoke-SuspectGapInvestigation {
    param(
        [object[]]$Candidates,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$ThrottleLimit,
        [int]$GraceMinutes,
        [string]$ArmToken,
        [DateTimeOffset]$HealthCoverageStart,
        [hashtable]$LogAnalyticsData
    )
    Write-Host "Investigating suspect gaps for $($Candidates.Count) resource(s)..."

    $done = 0
    $total = $Candidates.Count
    $resultByRes = @{}

    # Shared HttpClient for Activity Log and Resource Health API calls within
    # the parallel block — only needed when NOT using Log Analytics.
    $gapHttpClient = $null
    if (-not $LogAnalyticsData) {
        $gapHttpClient = [System.Net.Http.HttpClient]::new()
        $gapHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
        $gapHttpClient.Timeout = [TimeSpan]::FromMinutes(5)
    }

    $Candidates | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $c         = $_
        $client    = $using:gapHttpClient
        $pStart    = $using:PeriodStart
        $pEnd      = $using:PeriodEnd
        $graceMin  = $using:GraceMinutes
        $hcStart   = $using:HealthCoverageStart
        $laData    = $using:LogAnalyticsData

        # Pre-fetched Log Analytics data for this resource (if available)
        $resLaData = $null
        if ($laData) {
            $resKey = $c.ResourceId.ToLowerInvariant()
            if ($laData.ContainsKey($resKey)) {
                $resLaData = $laData[$resKey]
            }
        }

        # ── Local helpers ─────────────────────────────────────────────
        ## ARM GET with retry on 429/5xx and exponential backoff (shared HttpClient).
        function script:ArmGet([string]$uri, [System.Net.Http.HttpClient]$httpClient) {
            for ($a = 0; $a -lt 6; $a++) {
                $httpReq = [System.Net.Http.HttpRequestMessage]::new(
                    [System.Net.Http.HttpMethod]::Get, $uri)
                try {
                    $httpResp = $httpClient.SendAsync($httpReq,
                        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                    ).GetAwaiter().GetResult()
                    $sc = [int]$httpResp.StatusCode
                    if ($sc -ge 200 -and $sc -lt 300) {
                        return $httpResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    }
                    if (($sc -eq 429 -or $sc -ge 500) -and $a -lt 5) {
                        $httpResp.Dispose()
                        Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $a)))
                        continue
                    }
                    $httpResp.EnsureSuccessStatusCode() | Out-Null
                } catch {
                    if ($a -lt 5) {
                        $code = try { [int]$_.Exception.InnerException.StatusCode } catch { 0 }
                        if ($code -eq 429 -or $code -ge 500) {
                            Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $a)))
                            continue
                        }
                    }
                    throw
                } finally {
                    $httpReq.Dispose()
                }
            }
        }

        ## Truncates a DateTimeOffset to the minute boundary (seconds = 0).
        function script:TruncMin([DateTimeOffset]$v) {
            [DateTimeOffset]::new($v.Year, $v.Month, $v.Day, $v.Hour, $v.Minute, 0, [TimeSpan]::Zero)
        }

        ## Safely reads a string property from a JsonElement, returning '' if absent.
        function script:GetJsonStr([System.Text.Json.JsonElement]$el, [string]$name) {
            $v = [System.Text.Json.JsonElement]::new()
            if ($el.TryGetProperty($name, [ref]$v) -and
                $v.ValueKind -ne [System.Text.Json.JsonValueKind]::Null) {
                return $v.GetString()
            }
            ''
        }

        ## Parses a timestamp string from Azure APIs (multiple formats) into a UTC DateTime.
        function script:ParseTimestamp([string]$s) {
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            $dto = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($s,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal,
                    [ref]$dto)) {
                return $dto.UtcDateTime
            }
            $null
        }

        # ── Activity Log ──────────────────────────────────────────────
        # Query Activity Log for supported lifecycle operations (VM: start/deallocate/
        # powerOff/restart; SQL: pause/resume) and build intervals that explain metric gaps.
        # When Log Analytics data is available, use pre-fetched events; otherwise call
        # the Activity Log REST API per-resource.
        $activityIntervals = @()
        $supportsActivity = $c.Kind -eq 'VirtualMachine' -or $c.Kind -eq 'AzureSqlDatabase'

        if ($supportsActivity -and ($c.AllGapTicks.Count -gt 0 -or $c.DegradedTicks.Count -gt 0)) {
            try {
                $vmRules = @(
                    @{ ApplyGrace = $false; Tokens = @('microsoft.compute/virtualmachines/start/action', 'start virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/deallocate/action', 'deallocate virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/poweroff/action', 'power off virtual machine') }
                    @{ ApplyGrace = $false; Tokens = @('microsoft.compute/virtualmachines/restart/action', 'restart virtual machine') }
                )
                $sqlRules = @(
                    @{ ApplyGrace = $true; Tokens = @('microsoft.sql/servers/databases/pause', 'pause sql database', 'pause database') }
                    @{ ApplyGrace = $true; Tokens = @('microsoft.sql/servers/databases/resume', 'resume sql database', 'resume database') }
                )
                $rules = if ($c.Kind -eq 'VirtualMachine') { $vmRules } else { $sqlRules }

                $events = [System.Collections.Generic.List[object]]::new()

                if ($resLaData -and $resLaData.ActivityEvents.Count -gt 0) {
                    # ── Log Analytics path: use pre-fetched events ────
                    foreach ($laEvt in $resLaData.ActivityEvents) {
                        $opKey = [string]$laEvt.OperationName
                        if (-not $opKey) { continue }

                        $matched = $false; $eventGrace = 0
                        $normalized = $opKey.ToLowerInvariant()
                        foreach ($rule in $rules) {
                            foreach ($t in $rule.Tokens) {
                                if ($normalized.Contains($t)) {
                                    $matched = $true
                                    $eventGrace = if ($rule.ApplyGrace) { $graceMin } else { 0 }
                                    break
                                }
                            }
                            if ($matched) { break }
                        }
                        if (-not $matched) { continue }

                        $events.Add([PSCustomObject]@{
                            Timestamp     = $laEvt.Timestamp
                            OperationKey  = $opKey
                            CorrelationId = [string]$laEvt.CorrelationId
                            GraceMinutes  = $eventGrace
                        })
                    }
                } elseif (-not $laData) {
                    # ── REST API path (original) ──────────────────────
                    $filter = "eventTimestamp ge '$($pStart.ToString('O'))' and eventTimestamp le '$($pEnd.ToString('O'))' and resourceUri eq '$($c.ResourceId)'"
                    $select = 'eventTimestamp,operationName,correlationId,status'
                    $url = "https://management.azure.com/subscriptions/$($c.SubscriptionId)" +
                           "/providers/microsoft.insights/eventtypes/management/values" +
                           "?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))" +
                           "&`$select=$([uri]::EscapeDataString($select))"

                    while ($url) {
                        $json = ArmGet $url $client
                        $doc = [System.Text.Json.JsonDocument]::Parse($json)
                        try {
                            $valEl = [System.Text.Json.JsonElement]::new()
                            if ($doc.RootElement.TryGetProperty('value', [ref]$valEl) -and
                                $valEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                                foreach ($item in $valEl.EnumerateArray()) {
                                    $tsStr = GetJsonStr $item 'eventTimestamp'
                                    $ts = ParseTimestamp $tsStr
                                    if ($null -eq $ts) { continue }

                                    $opValue = ''; $opLabel = ''
                                    $opEl = [System.Text.Json.JsonElement]::new()
                                    if ($item.TryGetProperty('operationName', [ref]$opEl) -and
                                        $opEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                                        $opValue = GetJsonStr $opEl 'value'
                                        $opLabel = GetJsonStr $opEl 'localizedValue'
                                    }
                                    $opKey = if ($opValue) { $opValue } else { $opLabel }
                                    if (-not $opKey) { continue }

                                    $matched = $false; $eventGrace = 0
                                    $normalized = $opKey.ToLowerInvariant()
                                    foreach ($rule in $rules) {
                                        foreach ($t in $rule.Tokens) {
                                            if ($normalized.Contains($t)) {
                                                $matched = $true
                                                $eventGrace = if ($rule.ApplyGrace) { $graceMin } else { 0 }
                                                break
                                            }
                                        }
                                        if ($matched) { break }
                                    }
                                    if (-not $matched) { continue }

                                    $corrId = GetJsonStr $item 'correlationId'
                                    $events.Add([PSCustomObject]@{
                                        Timestamp    = [DateTimeOffset]$ts
                                        OperationKey = $opKey
                                        CorrelationId = $corrId
                                        GraceMinutes = $eventGrace
                                    })
                                }
                            }

                            $nextEl = [System.Text.Json.JsonElement]::new()
                            $url = if ($doc.RootElement.TryGetProperty('nextLink', [ref]$nextEl) -and
                                       $nextEl.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                                $nextEl.GetString()
                            } else { $null }
                        }
                        finally { $doc.Dispose() }
                    }
                }

                # Build intervals from events: group by operation+correlationId,
                # compute from/to per group, apply grace window, then merge overlaps.
                if ($events.Count -gt 0) {
                    $groups = @{}
                    foreach ($evt in $events) {
                        $corrPart = if ($evt.CorrelationId) { $evt.CorrelationId }
                                    else { (TruncMin $evt.Timestamp).ToString('O') }
                        $gk = "$($evt.OperationKey)|$corrPart"
                        if (-not $groups.ContainsKey($gk)) { $groups[$gk] = [System.Collections.Generic.List[object]]::new() }
                        $groups[$gk].Add($evt)
                    }

                    $rawIntervals = [System.Collections.Generic.List[object]]::new()
                    foreach ($group in $groups.Values) {
                        $minTs = ($group | ForEach-Object { $_.Timestamp } | Measure-Object -Minimum).Minimum
                        $maxTs = ($group | ForEach-Object { $_.Timestamp } | Measure-Object -Maximum).Maximum
                        $maxGr = ($group | ForEach-Object { $_.GraceMinutes } | Measure-Object -Maximum).Maximum

                        $from = TruncMin $minTs
                        $to   = (TruncMin $maxTs).AddMinutes(1)
                        if ($maxGr -gt 0) { $to = $to.AddMinutes($maxGr) }
                        if ($from -lt $pStart) { $from = $pStart }
                        if ($to -gt $pEnd)     { $to = $pEnd }

                        if ($to -gt $from) {
                            $rawIntervals.Add([PSCustomObject]@{
                                From = $from; To = $to
                                FromTicks = $from.UtcTicks; ToTicks = $to.UtcTicks
                            })
                        }
                    }

                    # Merge overlapping intervals into a minimal set
                    if ($rawIntervals.Count -gt 1) {
                        $sorted = @($rawIntervals | Sort-Object FromTicks)
                        $merged = [System.Collections.Generic.List[object]]::new()
                        $merged.Add($sorted[0])
                        for ($i = 1; $i -lt $sorted.Count; $i++) {
                            $last = $merged[$merged.Count - 1]
                            if ($sorted[$i].FromTicks -le $last.ToTicks) {
                                if ($sorted[$i].ToTicks -gt $last.ToTicks) {
                                    $last.ToTicks = $sorted[$i].ToTicks
                                    $last.To = $sorted[$i].To
                                }
                            } else { $merged.Add($sorted[$i]) }
                        }
                        $activityIntervals = @($merged)
                    } elseif ($rawIntervals.Count -eq 1) {
                        $activityIntervals = @($rawIntervals[0])
                    }
                }
            }
            catch {
                Write-Warning "Activity Log query failed for '$($c.Name)': $_"
            }
        }

        # ── Resource Health ───────────────────────────────────────────
        # Query Resource Health transitions to classify platform faults,
        # unknown states, and customer-initiated events.  When Log Analytics
        # data is available, use pre-fetched transitions; otherwise call the
        # Resource Health REST API (limited to 30-day retention).
        $healthHistoryApplied = [DateTimeOffset]$hcStart -lt [DateTimeOffset]$pEnd
        $faultIntervals    = @()
        $unknownIntervals  = @()
        $customerIntervals = @()

        if ($healthHistoryApplied) {
            try {
                $transitions = [System.Collections.Generic.List[object]]::new()

                if ($resLaData -and $resLaData.HealthTransitions.Count -gt 0) {
                    # ── Log Analytics path: use pre-fetched transitions ──
                    foreach ($ht in $resLaData.HealthTransitions) {
                        $transitions.Add($ht)
                    }
                } elseif (-not $laData) {
                    # ── REST API path (original) ─────────────────────────
                    $url = "https://management.azure.com$($c.ResourceId)" +
                           "/providers/Microsoft.ResourceHealth/availabilityStatuses" +
                           "?api-version=2025-05-01"

                    while ($url) {
                        $json = ArmGet $url $client
                        $doc = [System.Text.Json.JsonDocument]::Parse($json)
                        try {
                            $valEl = [System.Text.Json.JsonElement]::new()
                            if ($doc.RootElement.TryGetProperty('value', [ref]$valEl) -and
                                $valEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                                foreach ($item in $valEl.EnumerateArray()) {
                                    $propsEl = [System.Text.Json.JsonElement]::new()
                                    if (-not $item.TryGetProperty('properties', [ref]$propsEl)) { continue }

                                    $occurredStr = GetJsonStr $propsEl 'occuredTime'
                                    $occurred = ParseTimestamp $occurredStr
                                    if ($null -eq $occurred) { continue }

                                    $transitions.Add([PSCustomObject]@{
                                        OccurredOn       = [DateTimeOffset]$occurred
                                        State            = GetJsonStr $propsEl 'availabilityState'
                                        ReasonType       = GetJsonStr $propsEl 'reasonType'
                                        Context          = GetJsonStr $propsEl 'context'
                                        HealthEventCause = GetJsonStr $propsEl 'healthEventCause'
                                    })
                                }
                            }

                            $nextEl = [System.Text.Json.JsonElement]::new()
                            $url = if ($doc.RootElement.TryGetProperty('nextLink', [ref]$nextEl) -and
                                       $nextEl.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                                $nextEl.GetString()
                            } else { $null }
                        }
                        finally { $doc.Dispose() }
                    }
                }

                # Sort transitions chronologically (REST API returns newest-
                # first; LA data arrives in query order — sort to be safe)
                $transArr = @($transitions | Sort-Object { $_.OccurredOn })

                # Helper: IsCustomerInitiated
                $isCust = {
                    param($t)
                    $t.ReasonType -eq 'Customer Initiated' -or
                    $t.ReasonType -eq 'User Initiated' -or
                    $t.Context -eq 'Customer Initiated' -or
                    $t.HealthEventCause -eq 'UserInitiated'
                }

                # Build fault intervals
                $fStart = $null
                foreach ($t in $transArr) {
                    $isAvail   = $t.State -eq 'Available'
                    $isUnknown = $t.State -eq 'Unknown'
                    $isC       = & $isCust $t
                    $isFault   = -not $isAvail -and -not $isUnknown -and -not $isC

                    if ($isFault -and $null -eq $fStart) {
                        $fStart = if ($t.OccurredOn -lt $hcStart) { [DateTimeOffset]$hcStart } else { $t.OccurredOn }
                    } elseif (-not $isFault -and $null -ne $fStart) {
                        $fE = if ($t.OccurredOn -gt $pEnd) { [DateTimeOffset]$pEnd } else { $t.OccurredOn }
                        if ($fE -gt $fStart) {
                            $faultIntervals += [PSCustomObject]@{
                                From = $fStart; To = $fE
                                FromTicks = $fStart.UtcTicks; ToTicks = $fE.UtcTicks
                            }
                        }
                        $fStart = $null
                    }
                }
                if ($null -ne $fStart) {
                    $faultIntervals += [PSCustomObject]@{
                        From = $fStart; To = [DateTimeOffset]$pEnd
                        FromTicks = $fStart.UtcTicks; ToTicks = ([DateTimeOffset]$pEnd).UtcTicks
                    }
                }

                # Build unknown intervals
                $uStart = $null
                foreach ($t in $transArr) {
                    $isUnknown = $t.State -eq 'Unknown'
                    if ($isUnknown -and $null -eq $uStart) {
                        $uStart = if ($t.OccurredOn -lt $hcStart) { [DateTimeOffset]$hcStart } else { $t.OccurredOn }
                    } elseif (-not $isUnknown -and $null -ne $uStart) {
                        $uE = if ($t.OccurredOn -gt $pEnd) { [DateTimeOffset]$pEnd } else { $t.OccurredOn }
                        if ($uE -gt $uStart) {
                            $unknownIntervals += [PSCustomObject]@{
                                From = $uStart; To = $uE
                                FromTicks = $uStart.UtcTicks; ToTicks = $uE.UtcTicks
                            }
                        }
                        $uStart = $null
                    }
                }
                if ($null -ne $uStart) {
                    $unknownIntervals += [PSCustomObject]@{
                        From = $uStart; To = [DateTimeOffset]$pEnd
                        FromTicks = $uStart.UtcTicks; ToTicks = ([DateTimeOffset]$pEnd).UtcTicks
                    }
                }

                # Build customer intervals
                $cStart = $null
                foreach ($t in $transArr) {
                    $isC = & $isCust $t
                    if ($isC -and $null -eq $cStart) {
                        $cStart = if ($t.OccurredOn -lt $hcStart) { [DateTimeOffset]$hcStart } else { $t.OccurredOn }
                    } elseif (-not $isC -and $null -ne $cStart) {
                        $cE = if ($t.OccurredOn -gt $pEnd) { [DateTimeOffset]$pEnd } else { $t.OccurredOn }
                        if ($cE -gt $cStart) {
                            $customerIntervals += [PSCustomObject]@{
                                From = $cStart; To = $cE
                                FromTicks = $cStart.UtcTicks; ToTicks = $cE.UtcTicks
                            }
                        }
                        $cStart = $null
                    }
                }
                if ($null -ne $cStart) {
                    $customerIntervals += [PSCustomObject]@{
                        From = $cStart; To = [DateTimeOffset]$pEnd
                        FromTicks = $cStart.UtcTicks; ToTicks = ([DateTimeOffset]$pEnd).UtcTicks
                    }
                }
            }
            catch {
                Write-Warning "Resource Health query failed for '$($c.Name)': $_"
            }
        }

        # ── Classify each suspect tick ────────────────────────────────
        # Expands intervals into HashSets of minute-aligned ticks and classifies
        # every suspect minute via compiled C# (GapProcessor). Precedence:
        #   1. Platform fault (Resource Health)       → stays eligible, 0 available
        #   2. Lifecycle activity (Activity Log)       → excluded from eligibility
        #   3. Unknown / customer-initiated (Health)  → excluded from eligibility
        #   4. Remaining null                          → metric issue, excluded
        #   5. Remaining 0%                            → downtime, stays eligible
        #   6. Remaining degraded (0% < v < 100%)     → trusted, stays eligible
        $aFrom = [long[]]@($activityIntervals | ForEach-Object { $_.FromTicks })
        $aTo   = [long[]]@($activityIntervals | ForEach-Object { $_.ToTicks })
        $fFrom = [long[]]@($faultIntervals    | ForEach-Object { $_.FromTicks })
        $fTo   = [long[]]@($faultIntervals    | ForEach-Object { $_.ToTicks })
        $uFrom = [long[]]@($unknownIntervals  | ForEach-Object { $_.FromTicks })
        $uTo   = [long[]]@($unknownIntervals  | ForEach-Object { $_.ToTicks })
        $cFrom = [long[]]@($customerIntervals | ForEach-Object { $_.FromTicks })
        $cTo   = [long[]]@($customerIntervals | ForEach-Object { $_.ToTicks })

        $activityTickSet = [GapProcessor]::ExpandToTickSet($aFrom, $aTo)
        $faultTickSet    = [GapProcessor]::ExpandToTickSet($fFrom, $fTo)
        $unknownTickSet  = [GapProcessor]::ExpandToTickSet($uFrom, $uTo)
        $customerTickSet = [GapProcessor]::ExpandToTickSet($cFrom, $cTo)

        $hcStartTicks = ([DateTimeOffset]$hcStart).UtcTicks

        $cr = [GapProcessor]::ClassifyGaps(
            [long[]]@($c.AllGapTicks),
            [long[]]@($c.ZeroTicksArray),
            [long[]]@($c.DegradedTicks),
            [double[]]@($c.DegradedValues),
            $activityTickSet, $faultTickSet, $unknownTickSet, $customerTickSet,
            $healthHistoryApplied, $hcStartTicks)

        [PSCustomObject]@{
            ResourceId                        = $c.ResourceId
            HealthHistoryApplied              = $healthHistoryApplied
            ActivityLogExcludedGapMinutes     = $cr.ActivityLogExcludedGapMin
            HealthExplainedGapMinutes         = $cr.HealthExplainedGapMin
            MetricIssueNullMinutes            = $cr.MetricIssueNullMin
            PlatformFaultGapMinutes           = $cr.PlatformFaultGapMin
            UnresolvedZeroDowntimeMinutes     = $cr.UnresolvedZeroDowntimeMin
            CustomerExcusedDegradedMinutes    = $cr.CustomerExcusedDegradedMin
            CustomerExcusedDegradedAvailableSum = $cr.CustomerExcusedDegradedAvail
            ActivityLogDegradedMinutes        = $cr.ActivityLogDegradedMin
            HealthConfirmedDegradedMinutes    = $cr.HealthConfirmedDegradedMin
        }
    } | ForEach-Object {
        $done++
        $resultByRes[$_.ResourceId.ToLowerInvariant()] = $_
        if ($done % 10 -eq 0 -or $done -eq $total) {
            Write-Progress -Activity 'Investigating suspect gaps' `
                -Status "[$done / $total]" `
                -PercentComplete ([math]::Min(100, $done / $total * 100))
        }
    }
    Write-Progress -Activity 'Investigating suspect gaps' -Completed
    if ($gapHttpClient) { $gapHttpClient.Dispose() }
    $resultByRes
}

# ── Output ────────────────────────────────────────────────────────────────────

## Prints a fixed-width table with one row per resource showing availability metrics.
function Write-ResultsTable([object[]]$Sorted) {
    $fmt = '{0,-24} {1,-30} {2,-7} {3,-12} {4,7} {5,6} {6,7} {7,10} {8,10} {9,8} {10,10}'
    Write-Host ''
    Write-Host ($fmt -f 'Subscription', 'Name', 'Kind', 'Location',
        'Suspect', 'Faults', 'Excused', 'Unresolved', 'AvailMin', 'EligMin', 'Avail%')
    Write-Host ([string]::new([char]0x2500, 141))

    foreach ($r in $Sorted) {
        Write-Host ($fmt -f
            (Get-TruncatedString $r.SubscriptionName 24),
            (Get-TruncatedString $r.Name 30),
            (Get-ShortKind $r.Kind),
            $r.Location,
            $(if ($r.SuspectMinutes -gt 0) { "$($r.SuspectMinutes)" } else { '' }),
            $(if ($r.ConfirmedDowntimeMinutes -gt 0) { "$($r.ConfirmedDowntimeMinutes)" } else { '' }),
            $(if ($r.ExcusedMinutes -gt 0) { "$($r.ExcusedMinutes)" } else { '' }),
            $(if ($r.UnexplainedSuspectMinutes -gt 0) { "$($r.UnexplainedSuspectMinutes)" } else { '' }),
            [math]::Round($r.AvailableMinutes, 2),
            $r.EligibleMinutes,
            $r.AvailabilityPct)
    }
    Write-Host ''
}

## Prints per-subscription summaries grouped by Kind + Location, plus a cross-
## subscription overall summary when multiple subscriptions are present.
function Write-SubscriptionSummaries([object[]]$Sorted) {
    $eligible = @($Sorted | Where-Object { $_.AvailabilityPct -ne 'N/A' })

    foreach ($subGroup in ($eligible | Group-Object SubscriptionName | Sort-Object Name)) {
        Write-Host "--- $($subGroup.Name) Summary ---"
        foreach ($g in ($subGroup.Group | Group-Object { "$($_.Kind)|$($_.Location)" } | Sort-Object Name)) {
            $items = @($g.Group)
            $n = $items.Count
            $a = ($items | Measure-Object AvailableMinutes -Sum).Sum
            $e = ($items | Measure-Object EligibleMinutes  -Sum).Sum
            $pct = if ($e -gt 0) { [math]::Round($a / $e * 100, 5) } else { 0 }
            $kind = Get-ShortKind $items[0].Kind
            $loc  = $items[0].Location
            Write-Host "  $kind, $loc [$n res]: $pct% ($([math]::Round($a, 2)) / $([math]::Round($e, 2)) eligible min)"
        }
        $tn = $subGroup.Count
        $ta = ($subGroup.Group | Measure-Object AvailableMinutes -Sum).Sum
        $te = ($subGroup.Group | Measure-Object EligibleMinutes  -Sum).Sum
        $tpct = if ($te -gt 0) { [math]::Round($ta / $te * 100, 5) } else { 0 }
        Write-Host "  TOTAL [$tn res]: $tpct% ($([math]::Round($ta, 2)) / $([math]::Round($te, 2)) eligible min)"
        Write-Host ''
    }

    # Cross-subscription summary
    $subs = @($eligible | ForEach-Object { $_.SubscriptionName } | Select-Object -Unique)
    if ($subs.Count -gt 1 -and $eligible.Count -gt 0) {
        Write-Host ([string]::new([char]0x2550, 62))
        Write-Host '               OVERALL (all subscriptions)'
        Write-Host ([string]::new([char]0x2550, 62))
        foreach ($g in ($eligible | Group-Object { "$($_.Kind)|$($_.Location)" } | Sort-Object Name)) {
            $items = @($g.Group)
            $n = $items.Count
            $a = ($items | Measure-Object AvailableMinutes -Sum).Sum
            $e = ($items | Measure-Object EligibleMinutes  -Sum).Sum
            $pct = if ($e -gt 0) { [math]::Round($a / $e * 100, 5) } else { 0 }
            $kind = Get-ShortKind $items[0].Kind
            $loc  = $items[0].Location
            Write-Host "  $kind, $loc [$n res]: $pct% ($([math]::Round($a, 2)) / $([math]::Round($e, 2)) eligible min)"
        }
        $on = $eligible.Count
        $oa = ($eligible | Measure-Object AvailableMinutes -Sum).Sum
        $oe = ($eligible | Measure-Object EligibleMinutes  -Sum).Sum
        $opct = if ($oe -gt 0) { [math]::Round($oa / $oe * 100, 5) } else { 0 }
        Write-Host "  OVERALL [$on res]: $opct% ($([math]::Round($oa, 2)) / $([math]::Round($oe, 2)) eligible min)"
        Write-Host ''
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Step 1: Resolve observation window
$window = Resolve-ObservationWindow $Month
$utcStart     = $window.Start
$utcEnd       = $window.End
$totalMinutes = $window.TotalMinutes

$healthCoverageStart = if ($Workspace) {
    Get-HealthCoverageStart $utcStart -UseLogAnalytics
} else {
    Get-HealthCoverageStart $utcStart
}
$healthCoveredMinutes = $healthCoverageStart -lt $utcEnd ? [int]($utcEnd - $healthCoverageStart).TotalMinutes : 0

$periodLabel = $window.IsMonthToDate ? "month $($window.NormalizedMonth) (month-to-date)" : "month $($window.NormalizedMonth)"
Write-Host "Period: $periodLabel ($($utcStart.ToString('u')) -> $($utcEnd.ToString('u')), $totalMinutes min)"

if ($Workspace) {
    Write-Host "Log Analytics workspace: $Workspace (Activity Log + Resource Health via KQL)"
} elseif ($healthCoverageStart -gt $utcStart -and $healthCoveredMinutes -gt 0) {
    Write-Host "WARNING: Resource Health history covers only part of this period ($($healthCoverageStart.ToString('u')) -> $($utcEnd.ToString('u')), $healthCoveredMinutes of $totalMinutes min). Earlier minutes will use Activity Log and metric fallback rules."
} elseif ($healthCoveredMinutes -eq 0) {
    Write-Host 'WARNING: Resource Health history does not cover this period. All suspect minutes will use Activity Log and metric fallback rules.'
}

# Step 2: Authenticate and resolve subscriptions
# -BatchSize explicitly set implies -Batch
if ($PSBoundParameters.ContainsKey('BatchSize') -and -not $Batch) { $Batch = [switch]::new($true) }

Write-Host -NoNewline 'Authenticating... '
$allAzSubs = @(Get-AzSubscription)
$resolvedSubs = @(foreach ($name in $Subscriptions) {
    $found = @($allAzSubs | Where-Object Name -eq $name)
    if ($found.Count -eq 0) { throw "Subscription '$name' not found." }
    if ($found.Count -gt 1) { throw "Multiple subscriptions named '$name'." }
    $found[0]
})
$subIds      = @($resolvedSubs.Id)
$subIdToName = @{}; foreach ($s in $resolvedSubs) { $subIdToName[$s.Id] = $s.Name }

$rawToken = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
$armToken = ($rawToken -is [securestring]) ? ($rawToken | ConvertFrom-SecureString -AsPlainText) : [string]$rawToken
$rawToken = $null

Write-Host 'OK'
Write-Host "Processing $($resolvedSubs.Count) subscription(s): $($resolvedSubs.Name -join ', ')"
Write-Host "Kinds: $($Kinds -join ', ')"

# Step 3: Query Resource Graph inventory
Write-Host -NoNewline 'Querying resource inventory... '
$resources = Get-ResourceInventory -SubscriptionIds $subIds -SubIdToName $subIdToName `
    -Kinds $Kinds -ResourceNameFilter $Resource

$regionCount = @($resources | ForEach-Object { $_.Location } | Select-Object -Unique).Count
Write-Host "Found $($resources.Count) resource(s) across $($resolvedSubs.Count) subscription(s), $regionCount region(s)."

if ($resources.Count -eq 0) { Write-Host 'No resources found.'; return }

if ($Batch) {
    $rawMetrics = (Get-AzAccessToken -ResourceUrl 'https://metrics.monitor.azure.com').Token
    $metricsToken = ($rawMetrics -is [securestring]) ? ($rawMetrics | ConvertFrom-SecureString -AsPlainText) : [string]$rawMetrics
    $rawMetrics = $null
    Write-Host "Mode: Batch (batch-size=$BatchSize)"
}

# Step 4: Build initial eligibility records (all minutes start as eligible)
$eligByRes = @{}
foreach ($res in $resources) {
    $eligByRes[$res.ResourceId.ToLowerInvariant()] = [PSCustomObject]@{
        Name                     = $res.Name
        Kind                     = $res.Kind
        ResourceId               = $res.ResourceId
        ResourceGroupName        = $res.ResourceGroupName
        Location                 = $res.Location
        SubscriptionName         = $res.SubscriptionName
        EligibleMinutes          = $totalMinutes
        AvailableMinutes         = [double]0
        SuspectMinutes           = 0
        ConfirmedDowntimeMinutes = 0
        ExcusedMinutes           = 0
        UnexplainedSuspectMinutes = 0
        AvailabilityPct          = 'N/A'
    }
}

# Step 5: Fetch Azure Monitor metrics
if ($Batch) {
    $uniqueRegions = @($resources | ForEach-Object { $_.Location.ToLowerInvariant() } | Select-Object -Unique | Sort-Object)
    Test-BatchEndpoints -MetricsToken $metricsToken -Regions $uniqueRegions
    $metricResults = Get-BatchAvailabilityMetrics -Resources $resources -StartDate $utcStart `
        -EndDate $utcEnd -ThrottleLimit $Parallelism -BatchSize $BatchSize -MetricsToken $metricsToken
    $metricsToken = $null
} else {
    $metricResults = Get-AvailabilityMetrics -Resources $resources -StartDate $utcStart `
        -EndDate $utcEnd -ThrottleLimit $Parallelism -ArmToken $armToken
}

# Step 6: Build suspect candidates and investigate via Activity Log + Resource Health
$suspectCandidates = [System.Collections.Generic.List[object]]::new()
foreach ($res in $resources) {
    $key = $res.ResourceId.ToLowerInvariant()
    $mr = $metricResults[$key]
    if ($mr -and $mr.SuspectMinutes -gt 0) {
        $allTicks = [System.Collections.Generic.List[long]]::new()
        if ($mr.GapTicks.Count -gt 0)       { foreach ($t in $mr.GapTicks)       { $allTicks.Add([long]$t) } }
        if ($mr.ZeroAvailTicks.Count -gt 0)  { foreach ($t in $mr.ZeroAvailTicks)  { $allTicks.Add([long]$t) } }
        if ($allTicks.Count -gt 0 -or $mr.DegradedTicks.Count -gt 0) {
            $suspectCandidates.Add([PSCustomObject]@{
                Name           = $res.Name
                Kind           = $res.Kind
                ResourceId     = $res.ResourceId
                SubscriptionId = $res.SubscriptionId
                AllGapTicks    = @($allTicks)
                ZeroTicksArray = @($mr.ZeroAvailTicks)
                DegradedTicks  = @($mr.DegradedTicks)
                DegradedValues = @($mr.DegradedValues)
            })
        }
    }
}

# Step 6b: If using Log Analytics, bulk-fetch Activity Log + Resource Health data
$logAnalyticsData = $null
if ($Workspace -and $suspectCandidates.Count -gt 0) {
    Write-Host -NoNewline 'Fetching Activity Log + Resource Health from Log Analytics... '
    $laToken = (Get-AzAccessToken -ResourceUrl 'https://api.loganalytics.io').Token
    $laTokenStr = ($laToken -is [securestring]) ? ($laToken | ConvertFrom-SecureString -AsPlainText) : [string]$laToken
    $laToken = $null
    $logAnalyticsData = Get-LogAnalyticsData -WorkspaceId $Workspace `
        -SubscriptionIds $subIds -PeriodStart $utcStart -PeriodEnd $utcEnd `
        -ArmToken $laTokenStr
    $laTokenStr = $null
}

$suspectResults = $null
if ($suspectCandidates.Count -gt 0) {
    $suspectResults = Invoke-SuspectGapInvestigation -Candidates @($suspectCandidates) `
        -PeriodStart $utcStart -PeriodEnd $utcEnd -ThrottleLimit $Parallelism `
        -GraceMinutes $ActivityGraceMinutes -ArmToken $armToken `
        -HealthCoverageStart $healthCoverageStart `
        -LogAnalyticsData $logAnalyticsData
}

# Step 7: Assemble final results
# Wires investigation outcomes into each resource's eligibility record:
#   - Subtracts excused minutes from EligibleMinutes
#   - Computes AvailableMinutes, ConfirmedDowntimeMinutes, UnexplainedSuspectMinutes
#   - Excludes zero-transaction storage minutes from eligibility
#   - Prints per-resource classification narration
foreach ($res in $resources) {
    $key  = $res.ResourceId.ToLowerInvariant()
    $elig = $eligByRes[$key]
    $mr   = $metricResults[$key]

    if (-not $mr) { continue }

    if ($mr.ExcludeFromAvailability) {
        $elig.EligibleMinutes = 0
        $elig.AvailableMinutes = 0
        $elig.SuspectMinutes = 0
        $elig.ConfirmedDowntimeMinutes = 0
        $elig.ExcusedMinutes = 0
        $elig.UnexplainedSuspectMinutes = 0
        Write-Host "  [$($res.Name)] excluded from availability (no numeric availability datapoints in period)"
        continue
    }

    $activityLogExcludedGapMinutes = 0
    $healthExplainedGapMinutes = 0
    $metricIssueNullMinutes = 0
    $excludedDegradedMinutes = 0

    $gc = if ($suspectResults) { $suspectResults[$key] } else { $null }

    if ($gc) {
        $totalSuspectMinutes = $mr.SuspectMinutes

        # Count contiguous suspect gaps for narration by sorting all suspect
        # ticks and counting boundaries where consecutive ticks are >1 min apart.
        $allSuspectTicks = [System.Collections.Generic.List[long]]::new()
        foreach ($t in @($mr.GapTicks))       { $allSuspectTicks.Add([long]$t) }
        foreach ($t in @($mr.ZeroAvailTicks))  { $allSuspectTicks.Add([long]$t) }
        foreach ($t in @($mr.DegradedTicks))   { $allSuspectTicks.Add([long]$t) }
        $suspectGapCount = 0
        if ($allSuspectTicks.Count -gt 0) {
            $allSuspectTicks.Sort()
            $suspectGapCount = 1
            $oneMin = [TimeSpan]::FromMinutes(1).Ticks
            for ($i = 1; $i -lt $allSuspectTicks.Count; $i++) {
                if ($allSuspectTicks[$i] -ne $allSuspectTicks[$i - 1] -and
                    ($allSuspectTicks[$i] - $allSuspectTicks[$i - 1]) -gt $oneMin) {
                    $suspectGapCount++
                }
            }
        }

        if ($totalSuspectMinutes -gt 0) {
            Write-Host "  [$($res.Name)] metric scan found $totalSuspectMinutes suspect min across $suspectGapCount suspect gaps (null or <100% availability values)"

            $activityExplainedSuspectMinutes = $gc.ActivityLogExcludedGapMinutes + $gc.ActivityLogDegradedMinutes
            $remainingAfterActivity = $totalSuspectMinutes - $activityExplainedSuspectMinutes
            if ($remainingAfterActivity -gt 0) {
                Write-Host "  [$($res.Name)] checked against Activity Log: $activityExplainedSuspectMinutes suspect min explained by admin lifecycle events, $remainingAfterActivity remain for Health History / fallback rules"
            } else {
                Write-Host "  [$($res.Name)] checked against Activity Log: $activityExplainedSuspectMinutes suspect min explained by admin lifecycle events"
            }

            if ($remainingAfterActivity -gt 0 -and $gc.HealthHistoryApplied) {
                $healthExplainedSuspectMinutes = $gc.HealthExplainedGapMinutes + ($gc.CustomerExcusedDegradedMinutes - $gc.ActivityLogDegradedMinutes)
                Write-Host "  [$($res.Name)] checked remaining suspect min against Health History: $($gc.PlatformFaultGapMinutes) gap min confirmed as platform issues, $healthExplainedSuspectMinutes suspect min explained as Unknown / customer-initiated"
            } elseif ($remainingAfterActivity -gt 0) {
                Write-Host "  [$($res.Name)] Health History skipped for remaining suspect min (outside current retention window); applying fallback rules directly"
            }
        }

        if ($gc.ActivityLogExcludedGapMinutes -gt 0) {
            $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes - $gc.ActivityLogExcludedGapMinutes)
            $activityLogExcludedGapMinutes = $gc.ActivityLogExcludedGapMinutes
        }
        if ($gc.HealthExplainedGapMinutes -gt 0) {
            $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes - $gc.HealthExplainedGapMinutes)
            $healthExplainedGapMinutes = $gc.HealthExplainedGapMinutes
        }
        if ($gc.MetricIssueNullMinutes -gt 0) {
            $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes - $gc.MetricIssueNullMinutes)
            $metricIssueNullMinutes = $gc.MetricIssueNullMinutes
            Write-Host "  [$($res.Name)] $($gc.MetricIssueNullMinutes) unresolved null suspect min treated as metric issues and excluded from eligibility"
        }
        if ($gc.CustomerExcusedDegradedMinutes -gt 0) {
            $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes - $gc.CustomerExcusedDegradedMinutes)
            $excludedDegradedMinutes = $gc.CustomerExcusedDegradedMinutes
            $healthExcusedDegradedMinutes = $gc.CustomerExcusedDegradedMinutes - $gc.ActivityLogDegradedMinutes
            $degradedReasons = [System.Collections.Generic.List[string]]::new()
            if ($gc.ActivityLogDegradedMinutes -gt 0) {
                $degradedReasons.Add("$($gc.ActivityLogDegradedMinutes) matched in Activity Log")
            }
            if ($healthExcusedDegradedMinutes -gt 0) {
                $degradedReasons.Add("$healthExcusedDegradedMinutes matched customer-initiated Health History")
            }
            Write-Host "  [$($res.Name)] $($gc.CustomerExcusedDegradedMinutes) degraded suspect min excluded from eligibility ($($degradedReasons -join ', '))"
        }
        if ($gc.PlatformFaultGapMinutes -gt 0) {
            Write-Host "  [$($res.Name)] $($gc.PlatformFaultGapMinutes) gap min confirmed as downtime (Health History platform issue)"
        }
        if ($gc.HealthConfirmedDegradedMinutes -gt 0) {
            Write-Host "  [$($res.Name)] $($gc.HealthConfirmedDegradedMinutes) degraded suspect min confirmed as downtime (Health History platform issue)"
        }
        if ($gc.UnresolvedZeroDowntimeMinutes -gt 0) {
            Write-Host "  [$($res.Name)] $($gc.UnresolvedZeroDowntimeMinutes) unresolved 0% suspect min trusted as downtime"
        }
    }

    $confirmedHealthDowntimeMinutes = if ($gc) { $gc.PlatformFaultGapMinutes + $gc.HealthConfirmedDegradedMinutes } else { 0 }

    $unexplainedPositiveDegradedMinutes = if ($gc) {
        [math]::Max(0, $mr.DegradedMinutes - $gc.CustomerExcusedDegradedMinutes - $gc.HealthConfirmedDegradedMinutes)
    } else { $mr.DegradedMinutes }

    $unexplainedSuspectMinutes = if ($gc) {
        $gc.UnresolvedZeroDowntimeMinutes + $unexplainedPositiveDegradedMinutes
    } else { $mr.SuspectMinutes }

    # Zero-tx storage exclusion
    $zeroTxExcludedMinutes = 0
    if ($mr.ZeroTxMin -gt 0 -and $res.Kind -eq 'StorageAccount') {
        $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes - $mr.ZeroTxMin)
        $zeroTxExcludedMinutes = $mr.ZeroTxMin
    }

    $elig.SuspectMinutes = $mr.SuspectMinutes + $zeroTxExcludedMinutes
    $elig.ConfirmedDowntimeMinutes = $confirmedHealthDowntimeMinutes
    $elig.ExcusedMinutes = $activityLogExcludedGapMinutes + $healthExplainedGapMinutes +
        $metricIssueNullMinutes + $excludedDegradedMinutes + $zeroTxExcludedMinutes
    $elig.UnexplainedSuspectMinutes = $unexplainedSuspectMinutes

    if ($activityLogExcludedGapMinutes -gt 0 -or $healthExplainedGapMinutes -gt 0 -or
        $metricIssueNullMinutes -gt 0 -or $excludedDegradedMinutes -gt 0 -or $zeroTxExcludedMinutes -gt 0) {
        $adjustments = [System.Collections.Generic.List[string]]::new()
        if ($activityLogExcludedGapMinutes -gt 0) { $adjustments.Add("$activityLogExcludedGapMinutes gap min excluded by Activity Log") }
        if ($healthExplainedGapMinutes -gt 0)     { $adjustments.Add("$healthExplainedGapMinutes gap min excluded by Health History") }
        if ($metricIssueNullMinutes -gt 0)        { $adjustments.Add("$metricIssueNullMinutes null suspect min treated as metric issues") }
        if ($excludedDegradedMinutes -gt 0)       { $adjustments.Add("$excludedDegradedMinutes customer-excused degraded min") }
        if ($zeroTxExcludedMinutes -gt 0)         { $adjustments.Add("$zeroTxExcludedMinutes zero-tx min") }
        Write-Host "  [$($res.Name)] eligible min = $totalMinutes - $($adjustments -join ' - ') = $($elig.EligibleMinutes)"
    }

    $customerExcusedAvail = if ($gc) { $gc.CustomerExcusedDegradedAvailableSum } else { 0 }
    $elig.AvailableMinutes = [math]::Round([math]::Max(0, $mr.AvailableSum - $customerExcusedAvail), 2)
    $elig.AvailabilityPct = if ($elig.EligibleMinutes -gt 0) {
        [math]::Round($elig.AvailableMinutes / $elig.EligibleMinutes * 100, 5).ToString('F5')
    } else { 'N/A' }
}

# Step 8: Output
$sorted = @($eligByRes.Values |
    Sort-Object SubscriptionName, Kind, Name)

Write-ResultsTable $sorted
Write-SubscriptionSummaries $sorted

$sw.Stop()
Write-Host "Completed in $($sw.Elapsed.ToString('hh\:mm\:ss\.ff'))"
