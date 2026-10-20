#Requires -Version 7.6
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Reports month-scoped availability for VMs, Azure SQL databases, Storage Accounts, and Web Apps.

.DESCRIPTION
    Availability pipeline:
      1. Resolve subscriptions
      2. Inventory via Resource Graph
      3. Measure every kind with its own signal (Azure Monitor, parallel)
      4. Attribute the suspect minutes (Activity Log + Resource Health)
      5. Assemble results
      6. Print table + summaries

    A suspect minute is a minute that may count against availability. Every resource kind follows
    its own algorithm, described step by step in the README ("Algorithms"):
      - Virtual machines: the VmAvailabilityMetric. Zero minutes are attributed with the metric's
        Context dimension (Platform / User / Unknown), Resource Health notes are classified by what
        they say, platform notes explain minutes only within -FaultWindowMinutes, and a gap stays
        explained by what started it. Activity Log: start/deallocate/power off/restart, creation.
      - Azure SQL databases: the availability metric. A zero minute is excused inside a resume or
        failover window of the Activity Log or a customer or planned-maintenance Resource Health
        window, and the others are matched with Resource Health. The minutes of a paused serverless
        database are not Deployment Minutes.
      - Storage accounts: the Error Rate of each hour over the accounts of a subscription and region,
        as in the SLA, shared among the accounts and attributed to Resource Health.
      - Web Apps (no availability metric): a minute is down when every request failed with a 5xx; the
        down minutes are matched with the stop/start/restart operations of the Activity Log and with
        Resource Health.
    A suspect minute ends as a fault (platform), an excused minute (customer, lifecycle, not yet
    created) or an unresolved minute; only faults and unresolved minutes count against availability.

    Resource Health history is read the same way for every kind: the REST history (about the last
    30 days) and, with -SourceWorkspaceId, the Resource Health events of the Activity Log in a Log
    Analytics workspace are combined for the whole period.

    When -SourceWorkspaceId is specified, Activity Log lifecycle events are fetched from the workspace
    via a single bulk KQL query instead of per-resource REST API calls. This is faster for large
    estates and uses workspace retention (typically 365 days). Without -SourceWorkspaceId, the REST
    APIs are used directly. Note: this is NOT the workspace used for result ingestion (see
    -DceEndpoint / -DcrImmutableId for that).

    The observation window is a UTC calendar month selected via -Month YYYYMM.
    Current month runs month-to-date; past months run full-month.

.PARAMETER Subscriptions
    One or more Azure subscription display names.

.PARAMETER Month
    Observation month in UTC, format YYYYMM.

.PARAMETER Kinds
    Resource kinds: vm, sql, storage, webapp (default: all).

.PARAMETER Resource
    Optional single resource name filter.

.PARAMETER Parallelism
    Max concurrent metric/investigation calls (default: auto-scaled to CPU cores).

.PARAMETER ActivityGraceMinutes
    Post-operation grace window for Activity Log lifecycle events (default: 10). For Web Apps
    it is the time after a stop, start or restart during which down minutes are excused.

.PARAMETER FaultWindowMinutes
    Virtual machines only: how long a platform Resource Health note (for example
    "Redeploying due to host failure") can explain suspect minutes that the metric
    does not attribute itself (default: 30).

.PARAMETER HealthLeadMinutes
    Storage accounts, SQL databases and Web Apps: how many minutes before a platform Resource
    Health event (for example "Degraded") its failures are still attributed to it, because
    Resource Health raises the event after the first failed requests (default: 5).

.PARAMETER Batch
    Use the regional Metrics Batch API instead of per-resource metric calls.

.PARAMETER BatchSize
    Max resources per batch call (default: 10, max 50). Implies -Batch.

.PARAMETER TopImpact
    How many resources the closing "most impact" section lists (default: 10, 0 disables it).
    Resources are ranked by the minutes they lost (eligible minus available), across all
    subscriptions, and each one is listed with its share of the total loss and the reason.

.PARAMETER SourceWorkspaceId
    Log Analytics workspace ID (GUID) used as a source for historical Activity
    Log and Resource Health data. This is NOT the ingestion target — it is
    an existing workspace that receives Activity Log diagnostic settings from
    the target subscriptions. When provided, lifecycle events are fetched via
    a single bulk KQL query (faster for large estates, uses workspace
    retention). Its Resource Health events are combined with the REST
    history for the whole period.

.PARAMETER DceEndpoint
    Data Collection Endpoint ingestion URL. When both -DceEndpoint and
    -DcrImmutableId are provided, results are sent to Log Analytics custom
    tables in addition to the normal console output. Obtain the URL from
    the Bicep deployment output 'dceIngestionEndpoint'. Works in both
    interactive (az login / Connect-AzAccount) and Azure Function
    (managed identity) execution contexts.

.PARAMETER DcrImmutableId
    Data Collection Rule immutable ID. Required together with -DceEndpoint.
    Obtain from the Bicep deployment output 'dataCollectionRuleImmutableId'.

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySubscription' -Month 202506

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'Sub1','Sub2' -Month 202505 -Kinds vm,sql

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySub' -Month 202506 -Batch -BatchSize 20

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySub' -Month 202506 -SourceWorkspaceId 'b233a4b7-3c43-433c-ac60-1f6ff217ddd4'

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySub' -Month 202506 -DceEndpoint 'https://dce-getavail-itn-001.italynorth-1.ingest.monitor.azure.com' -DcrImmutableId 'dcr-00000000000000000000000000000000'
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
    [ValidateSet('vm','sql','storage','webapp')]
    [string[]]$Kinds = @('vm','sql','storage','webapp'),

    [Parameter(ParameterSetName = 'Run')]
    [string]$Resource,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 64)]
    [int]$Parallelism = [math]::Max(4, [math]::Min(16, [Environment]::ProcessorCount)),

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(0, 120)]
    [int]$ActivityGraceMinutes = 10,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 240)]
    [int]$FaultWindowMinutes = 30,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(0, 60)]
    [int]$HealthLeadMinutes = 5,

    [Parameter(ParameterSetName = 'Run')]
    [switch]$Batch,


    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(1, 50)]
    [int]$BatchSize = 10,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateRange(0, 100)]
    [int]$TopImpact = 10,

    [Parameter(ParameterSetName = 'Run')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SourceWorkspaceId,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$DceEndpoint,

    [Parameter(ParameterSetName = 'Run')]
    [ValidateNotNullOrEmpty()]
    [string]$DcrImmutableId,

    [Parameter(Mandatory, ParameterSetName = 'ShowVersion')]
    [switch]$Version
)

#region Script setup
$ScriptVersion = '0.0.0-dev'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Version) {
    Write-Host "get-availability $ScriptVersion"
    return
}

# Ingestion needs both the endpoint and the rule ID; supplying only one is a mistake.
$sendToLogAnalytics = $false
if ($DceEndpoint -and $DcrImmutableId) {
    $sendToLogAnalytics = $true
} elseif ($DceEndpoint -or $DcrImmutableId) {
    throw '-DceEndpoint and -DcrImmutableId must both be provided together.'
}
#endregion

#region Observation window
<#
.SYNOPSIS
    Returns the current UTC time truncated to the minute.

.DESCRIPTION
    Metrics are one-minute data points, so every window boundary is aligned to a whole minute.

.OUTPUTS
    System.DateTimeOffset (UTC, seconds = 0).
#>
function Get-CurrentUtcMinute {
    $now = [DateTimeOffset]::UtcNow
    $now.AddTicks(-($now.Ticks % [TimeSpan]::TicksPerMinute))
}

<#
.SYNOPSIS
    Turns a YYYYMM string into the UTC observation window.

.DESCRIPTION
    Past months cover the whole month; the current month is month-to-date, clamped to the
    current UTC minute. Throws when the month is in the future, started more than 90 days ago
    (the metric retention), or would produce an empty period.

.PARAMETER MonthParam
    Month in YYYYMM format.

.OUTPUTS
    PSCustomObject with Start, End, NormalizedMonth, IsMonthToDate and TotalMinutes.
#>
function Resolve-ObservationWindow([string]$MonthParam) {
    $parsed = [datetime]::new(1, 1, 1)
    if (-not [datetime]::TryParseExact($MonthParam, 'yyyyMM',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw '-Month must use format YYYYMM.'
    }
    $currentMinute = Get-CurrentUtcMinute
    $start = [DateTimeOffset]::new($parsed.Year, $parsed.Month, 1, 0, 0, 0, [TimeSpan]::Zero)

    # Azure Monitor keeps one-minute metrics for 90 days; the current month is cut at "now".
    if ($start -ge $currentMinute) { throw '-Month must not be in the future.' }
    if ($start -lt $currentMinute.AddDays(-90)) { throw '-Month cannot start more than 90 days before now.' }

    $nextMonth = $start.AddMonths(1)
    $end = $nextMonth -lt $currentMinute ? $nextMonth : $currentMinute
    if ($end -le $start) { throw '-Month produced an empty observation period.' }

    # IsMonthToDate tells whether the window was cut at "now" instead of the end of the month.
    [PSCustomObject]@{
        Start           = $start
        End             = $end
        NormalizedMonth = $start.ToString('yyyyMM', [System.Globalization.CultureInfo]::InvariantCulture)
        IsMonthToDate   = $end -lt $nextMonth
        TotalMinutes    = [int]($end - $start).TotalMinutes
    }
}
#endregion

#region Resource Health history sources
<#
.SYNOPSIS
    Returns the ~30-day Resource Health REST retention cutoff.

.DESCRIPTION
    The REST history only reaches back about 30 days. A period that ends before this cutoff can be
    answered from the workspace alone, so the REST history is skipped then (see Get-HealthSources).

.OUTPUTS
    System.DateTimeOffset - the current UTC minute minus 30 days.
#>
function Get-RestHealthCutoff {
    (Get-CurrentUtcMinute).AddDays(-30)
}

<#
.SYNOPSIS
    Prepares the Resource Health history sources shared by every algorithm.

.DESCRIPTION
    All algorithms read Resource Health history the same way (see HealthHistory in the compiled code):
    the REST history and, when a workspace is used, the Activity Log events of the whole period are
    combined. This function converts the workspace rows to notes once, before the parallel work starts,
    and decides whether the REST history is worth reading: it is skipped only when a workspace is
    available and the whole period predates the REST retention.

.PARAMETER LogAnalyticsData
    Optional output of Get-LogAnalyticsData.

.PARAMETER PeriodEnd
    End of the observation window.

.OUTPUTS
    PSCustomObject with UseRest (bool) and WorkspaceNotes (hashtable: lowercase resource ID -> list of HealthNote).
#>
function Get-HealthSources {
    param(
        [hashtable]$LogAnalyticsData,
        [DateTimeOffset]$PeriodEnd
    )
    $workspaceNotes = @{}
    # Convert the workspace rows to HealthNote objects here, once, so the parallel runspaces share them.
    foreach ($entry in ($LogAnalyticsData ?? @{}).GetEnumerator()) {
        $list = [System.Collections.Generic.List[HealthNote]]::new()
        foreach ($raw in $entry.Value.HealthRaw) {
            $list.Add([HealthHistory]::FromWorkspace($raw.Timestamp.UtcTicks, $raw.State, $raw.Title, $raw.Cause, $raw.Details))
        }
        $workspaceNotes[$entry.Key] = $list
    }
    [PSCustomObject]@{
        UseRest        = (-not $LogAnalyticsData) -or $PeriodEnd -gt (Get-RestHealthCutoff)
        WorkspaceNotes = $workspaceNotes
    }
}

<#
.SYNOPSIS
    Returns the start of the period covered by Resource Health history.

.DESCRIPTION
    With -UseLogAnalytics the workspace (older history) and the REST history (last ~30 days) together
    cover the whole period. Without it, coverage is limited to the REST retention.

.PARAMETER PeriodStart
    Start of the observation window; coverage never starts before it.

.PARAMETER UseLogAnalytics
    Set when a source workspace supplies the older history.

.OUTPUTS
    System.DateTimeOffset.
#>
function Get-HealthCoverageStart([DateTimeOffset]$PeriodStart, [switch]$UseLogAnalytics) {
    if ($UseLogAnalytics) { return $PeriodStart }
    $cutoff = Get-RestHealthCutoff
    $cutoff -gt $PeriodStart ? $cutoff : $PeriodStart
}
#endregion

#region Display and token helpers
<#
.SYNOPSIS
    Abbreviates a resource kind for compact table and summary output.

.PARAMETER Kind
    Resource kind (VirtualMachine, AzureSqlDatabase, StorageAccount, WebApp).

.OUTPUTS
    System.String - VM, SQL, Storage or Web; unknown kinds are returned unchanged.
#>
function Get-ShortKind([string]$Kind) {
    $short = @{ VirtualMachine = 'VM'; AzureSqlDatabase = 'SQL'; StorageAccount = 'Storage'; WebApp = 'Web' }
    $short[$Kind] ?? $Kind
}

<#
.SYNOPSIS
    Truncates a string to a maximum length, ending with '...' when shortened.

.PARAMETER s
    Text to truncate.

.PARAMETER max
    Maximum length of the result.

.OUTPUTS
    System.String.
#>
function Get-TruncatedString([string]$s, [int]$max) {
    $s.Length -le $max ? $s : ($s.Substring(0, $max - 3) + '...')
}

<#
.SYNOPSIS
    Acquires a plain-text bearer token through Az.Accounts.

.DESCRIPTION
    Handles both the SecureString returned by Az.Accounts 5.x and the plain string returned
    by older versions.

.PARAMETER ResourceUrl
    Token audience, for example 'https://management.azure.com'.

.OUTPUTS
    System.String - the access token.
#>
function Get-PlainToken([string]$ResourceUrl) {
    $raw = (Get-AzAccessToken -ResourceUrl $ResourceUrl).Token
    ($raw -is [securestring]) ? ($raw | ConvertFrom-SecureString -AsPlainText) : [string]$raw
}
#endregion

#region Report formatting helpers
<#
.SYNOPSIS
    Describes the Resource Health event behind an incident.

.PARAMETER Window
    The Resource Health window that covers the incident, or $null when none does.

.OUTPUTS
    System.String, for example "Resource Health 'Degraded': <summary>" or "no Resource Health event".
#>
function Get-WindowCause($Window) {
    if (-not $Window) { return 'no Resource Health event' }
    "Resource Health '$($Window.Title)'$($Window.Summary ? ': ' + $Window.Summary : '')"
}

<#
.SYNOPSIS
    Creates one entry of the "most impact" report: a cause of lost minutes.

.PARAMETER Lost
    Minutes of availability the cause cost the resource.

.PARAMETER Verdict
    'platform fault' or 'unresolved': the two verdicts that count against availability.

.PARAMETER What
    What happened and the evidence for it (Resource Health event, error codes, request counts).

.PARAMETER When
    Where the cause occurred, already formatted by Format-Occurrence; may be empty.

.PARAMETER WhenLabel
    How the report introduces the occurrences: 'at' (default) or, for a summary of many, 'worst hours:'.

.OUTPUTS
    PSCustomObject with Lost, Verdict, What, When and WhenLabel.
#>
function New-LossCause([double]$Lost, [string]$Verdict, [string]$What, [string[]]$When = @(), [string]$WhenLabel = 'at') {
    [PSCustomObject]@{ Lost = $Lost; Verdict = $Verdict; What = $What; When = $When; WhenLabel = $WhenLabel }
}

<#
.SYNOPSIS
    Formats the start of an occurrence, with its length when it lasted more than one minute.

.PARAMETER Start
    Start of the occurrence, in UTC.

.PARAMETER Minutes
    Length in minutes (0 or 1 leaves the length out).

.OUTPUTS
    System.String, for example "2026-09-20 10:32Z (3 min)".
#>
function Format-Occurrence([datetime]$Start, [int]$Minutes = 0) {
    $text = $Start.ToString('yyyy-MM-dd HH:mm') + 'Z'
    $Minutes -gt 1 ? "$text ($Minutes min)" : $text
}

<#
.SYNOPSIS
    Joins consecutive minutes into runs.

.PARAMETER Ticks
    UTC ticks of whole minutes.

.OUTPUTS
    PSCustomObject[] with Start (UTC ticks of the first minute) and Minutes, in time order.
#>
function Get-MinuteRuns([long[]]$Ticks) {
    $oneMin = [TimeSpan]::FromMinutes(1).Ticks
    $run = $null
    foreach ($t in ($Ticks | Sort-Object)) {
        # A minute that directly follows the run extends it; any other minute opens a new run.
        if ($run -and ($t - ($run.Start + ($run.Minutes - 1) * $oneMin)) -le $oneMin) { $run.Minutes++ }
        else {
            if ($run) { $run }
            $run = [PSCustomObject]@{ Start = $t; Minutes = 1 }
        }
    }
    if ($run) { $run }
}
#endregion

#region Loss cause builders
<#
.SYNOPSIS
    Turns the spans of counted VM minutes into the causes of the "most impact" report.

.DESCRIPTION
    Spans with the same explanation (the metric Context, one Resource Health note, or nothing) become one cause.

.PARAMETER Spans
    VmLossSpan objects returned by the VM algorithm.

.OUTPUTS
    PSCustomObject[] created by New-LossCause.
#>
function Get-VmLossCauses([object[]]$Spans) {
    foreach ($g in ($Spans | Group-Object Outcome, Title)) {
        $first = $g.Group[0]
        $what = switch ($first.Outcome) {
            1 { 'the metric Context says Platform' }
            2 { "Resource Health '$($first.Title)'" }
            default { 'zero availability that nothing explains' }
        }
        $verdict = $first.Outcome -eq 11 ? 'unresolved' : 'platform fault'
        # With one occurrence its length is the lost minutes already shown; otherwise each length tells the occurrences apart.
        $total = ($g.Group | Measure-Object Minutes -Sum).Sum
        $when = @($g.Group | Sort-Object Minutes -Descending | ForEach-Object {
            Format-Occurrence ([DateTime]::new($_.StartTicks, [DateTimeKind]::Utc)) ($g.Count -eq 1 ? 0 : $_.Minutes)
        })
        New-LossCause $total $verdict $what $when
    }
}

<#
.SYNOPSIS
    Turns the counted zero minutes of a SQL database into the causes of the "most impact" report.

.DESCRIPTION
    Minutes with the same verdict (and the same Resource Health event) become one cause, with the failed
    connections of those minutes summed by error code.

.PARAMETER Minutes
    Objects with Ticks, Verdict (Fault or Unresolved), Title, HasDetail, Errors ("code xN" strings) and Ok.

.OUTPUTS
    PSCustomObject[] created by New-LossCause.
#>
function Get-SqlLossCauses([object[]]$Minutes) {
    foreach ($g in ($Minutes | Group-Object Verdict, Title)) {
        $first = $g.Group[0]
        $isFault = $first.Verdict -eq 'Fault'
        # Failed connections by error code and the successful ones, summed over the minutes of the group.
        $codes = @{}
        $ok = 0
        $withDetail = 0
        foreach ($m in $g.Group) {
            if (-not $m.HasDetail) { continue }
            $withDetail++
            $ok += $m.Ok
            foreach ($e in $m.Errors) {
                $code, $n = $e -split ' x'
                $codes[$code] = [int]$codes[$code] + [int]$n
            }
        }
        $what = $isFault ? "Resource Health '$($first.Title)'" : 'no Resource Health event'
        if ($withDetail -gt 0) {
            $failed = ($codes.GetEnumerator() | Sort-Object Name | ForEach-Object { "error $($_.Name) x$($_.Value)" }) -join ', '
            $what += "; failed connections: $failed, $ok successful in those minutes"
        }
        # A single run is as long as the lost minutes already shown, so its length is left out.
        $runs = @(Get-MinuteRuns ([long[]]@($g.Group.Ticks)))
        $when = @($runs | ForEach-Object {
            Format-Occurrence ([DateTime]::new($_.Start, [DateTimeKind]::Utc)) ($runs.Count -eq 1 ? 0 : $_.Minutes)
        })
        New-LossCause $g.Count ($isFault ? 'platform fault' : 'unresolved') $what $when
    }
}
#endregion

#region Compiled helpers (C#)
# Everything that loops over the ~44 K one-minute data points of a month per resource (metric parsing, the
# VM, storage and Web App algorithms, HTTP with retries, Resource Health history) is compiled C#: in
# interpreted PowerShell these loops would dominate the run time. It is one Add-Type because an assembly
# compiled by Add-Type cannot reference another one.

if (-not ([System.Management.Automation.PSTypeName]'MetricProcessor').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;

/// <summary>What the metric processor found in the minutes of one resource's availability metric.</summary>
public sealed class MetricProcessorResult
{
    public int    NumericPoints;     // minutes that carried a value
    public long[] NullTicks = Array.Empty<long>();   // minutes without a value
    public long[] ZeroTicks = Array.Empty<long>();   // minutes at 0%: the only minutes that can be downtime
    public int    DegradedMinutes;   // minutes between 0% and 100%: reported, never counted as downtime

    public int  GapMinutes              => NullTicks.Length + ZeroTicks.Length;
    public bool ExcludeFromAvailability => NumericPoints == 0 && NullTicks.Length == 0;
    public int  SuspectMinutes          => GapMinutes;
}

/// <summary>One resource's metric result inside a Metrics Batch response.</summary>
public sealed class BatchResourceResult
{
    public string ResourceId      = "";
    public string ResourceIdLower = "";
    public MetricProcessorResult Metrics = new();
}

/// <summary>
/// The per-resource metric result consumed by the rest of the pipeline. Both the per-resource
/// and the batch fetchers return this type, and failed queries yield an "excluded" placeholder.
/// </summary>
public sealed class MetricResult
{
    public string   ResourceId      = "";
    public string   ResourceIdLower = "";
    public string   Name            = "";
    public int      GapMinutes;
    public bool     ExcludeFromAvailability;
    public long[]   GapTicks        = Array.Empty<long>();
    public long[]   ZeroAvailTicks  = Array.Empty<long>();
    public int      DegradedMinutes;
    public int      SuspectMinutes;

    /// <summary>Builds the result of a resource whose metric response was processed.</summary>
    public static MetricResult From(string resourceId, string name, MetricProcessorResult m)
    {
        return new MetricResult
        {
            ResourceId = resourceId, ResourceIdLower = resourceId.ToLowerInvariant(), Name = name,
            GapMinutes = m.GapMinutes,
            ExcludeFromAvailability = m.ExcludeFromAvailability,
            GapTicks = m.NullTicks, ZeroAvailTicks = m.ZeroTicks,
            DegradedMinutes = m.DegradedMinutes, SuspectMinutes = m.SuspectMinutes
        };
    }

    /// <summary>Builds the placeholder of a resource whose metric query or processing failed.</summary>
    public static MetricResult Excluded(string resourceId, string name)
    {
        return new MetricResult
        {
            ResourceId = resourceId, ResourceIdLower = resourceId.ToLowerInvariant(), Name = name,
            ExcludeFromAvailability = true
        };
    }
}

/// <summary>Result of an AzHttp call: the parsed JSON body, or the reason it failed.</summary>
public sealed class HttpJsonResult
{
    public JsonDocument Doc;      // null when the call failed
    public int          Status;   // last HTTP status, 0 for transport failures
    public string       Error = "";
}

/// <summary>The one way timestamps of Azure responses are read: invariant culture, always UTC.</summary>
public static class AzTime
{
    /// <summary>Parses an ISO 8601 timestamp (assumed UTC when it carries no offset) into UTC ticks.</summary>
    public static long Ticks(string s)
        => DateTime.Parse(s, System.Globalization.CultureInfo.InvariantCulture,
               System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal).Ticks;
}

/// <summary>
/// HTTP helper for Azure Monitor calls that return JSON. Retries throttling (429), server errors
/// (5xx) and transient transport failures up to five attempts with exponential backoff (max 30 s).
/// </summary>
public static class AzHttp
{
    private const int MaxAttempts = 5;
    private static readonly Regex Transient = new Regex(
        @"transport|connection.*closed|reset by peer|timed?\s*out", RegexOptions.IgnoreCase);

    /// <summary>Waits before the next attempt: 2, 4, 8, 16 s, then 30 s at most.</summary>
    private static void Backoff(int attempt)
    {
        Thread.Sleep(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt))));
    }

    /// <summary>Sends the request built by makeRequest (a request cannot be sent twice), retrying where it makes sense.</summary>
    private static HttpJsonResult Send(HttpClient client, Func<HttpRequestMessage> makeRequest)
    {
        for (int attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            HttpResponseMessage resp = null;
            try
            {
                using (var req = makeRequest())
                {
                    resp = client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
                    int sc = (int)resp.StatusCode;
                    // Success: stream the body straight into the JSON parser (no intermediate string).
                    if (sc >= 200 && sc < 300)
                    {
                        using (var stream = resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
                            return new HttpJsonResult { Doc = JsonDocument.ParseAsync(stream).GetAwaiter().GetResult(), Status = sc };
                    }
                    // Throttling and server errors are worth another attempt; other statuses are final.
                    if ((sc == 429 || sc >= 500) && attempt < MaxAttempts) { Backoff(attempt); continue; }
                    return new HttpJsonResult { Status = sc, Error = "HTTP " + sc };
                }
            }
            catch (Exception ex)
            {
                // Transport failures (resets, timeouts) are retried too.
                string text = ex.Message + " " + ex.GetBaseException().Message;
                if (Transient.IsMatch(text) && attempt < MaxAttempts) { Backoff(attempt); continue; }
                return new HttpJsonResult { Error = text };
            }
            finally { if (resp != null) resp.Dispose(); }
        }
        return new HttpJsonResult { Error = "retries exhausted" };
    }

    /// <summary>GET a URI and parse the JSON response.</summary>
    public static HttpJsonResult Get(HttpClient client, string uri)
    {
        return Send(client, () => new HttpRequestMessage(HttpMethod.Get, uri));
    }

    /// <summary>POST a JSON body to a URI and parse the JSON response.</summary>
    public static HttpJsonResult Post(HttpClient client, string uri, string json)
    {
        return Send(client, () => new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        });
    }
}

/// <summary>
/// Reads a metric over a list of time spans. Azure Monitor refuses a response that would be too large with
/// HTTP 400: such a span is then split in two halves and read again, down to 15 minutes.
/// </summary>
public static class MetricSpans
{
    private const long OneMin = TimeSpan.TicksPerMinute;

    /// <summary>Formats UTC ticks as the timestamp Azure Monitor expects in the timespan parameter.</summary>
    private static string Iso(long ticks)
        => new DateTime(ticks, DateTimeKind.Utc).ToString("yyyy-MM-ddTHH:mm:ssZ", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>
    /// Reads the spans given as UTC tick pairs (start, end, start, end, ...), calling parse with each response.
    /// uri is the full query without the timespan parameter. Returns "" when every span was read, otherwise
    /// the error of the first span that could not be.
    /// </summary>
    public static string Read(HttpClient client, string uri, long[] bounds, Action<JsonDocument> parse)
    {
        var queue = new Queue<long[]>();
        for (int i = 0; i + 1 < bounds.Length; i += 2) queue.Enqueue(new[] { bounds[i], bounds[i + 1] });
        string error = "";
        while (queue.Count > 0)
        {
            var span = queue.Dequeue();
            var http = AzHttp.Get(client, uri + "&timespan=" + Iso(span[0]) + "/" + Iso(span[1]));
            if (http.Doc != null)
            {
                using (http.Doc) parse(http.Doc);
            }
            else if (http.Status == 400 && span[1] - span[0] > 15 * OneMin)
            {
                // Split at the middle, rounded up to a whole minute.
                long mid = span[0] + ((span[1] - span[0]) / OneMin + 1) / 2 * OneMin;
                queue.Enqueue(new[] { span[0], mid });
                queue.Enqueue(new[] { mid, span[1] });
            }
            else if (error.Length == 0) error = http.Error;
        }
        return error;
    }
}

/// <summary>One Resource Health history entry, from the REST API or from the Activity Log in Log Analytics.</summary>
public sealed class HealthNote
{
    public long   Ticks;
    public string State   = "";
    public string Title   = "";
    public string Summary = "";
    public string Reason  = "";   // REST reasonType wording ("Unplanned", "Planned", "Customer Initiated", ...)
    public bool   Customer;       // caused by the customer
}

/// <summary>Resource Health history of one resource as read by HealthHistory.Collect.</summary>
public sealed class HealthFetch
{
    public List<HealthNote> Notes = new List<HealthNote>();
    public string Error = "";     // set when the REST history could not be read; Notes then hold the workspace notes only
}

/// <summary>
/// The one way every algorithm reads Resource Health history: the REST availabilityStatuses history
/// (about the last 30 days) and the Resource Health events of the Activity Log in a Log Analytics
/// workspace are combined. Neither is complete on its own: the REST history can omit short events that
/// the Activity Log still holds, and the workspace lags behind and only reaches back as far as its
/// retention. The notes of both sources are simply returned together; the algorithms tolerate duplicates.
/// </summary>
public static class HealthHistory
{
    /// <summary>Builds a note from an Activity Log row: UserInitiated is the customer, PlatformInitiated maps to "Unplanned".</summary>
    public static HealthNote FromWorkspace(long ticks, string state, string title, string cause, string details = "")
        => new HealthNote
        {
            Ticks = ticks, State = state ?? "", Title = title ?? "", Summary = details ?? "",
            Reason = string.Equals(cause, "PlatformInitiated", StringComparison.Ordinal) ? "Unplanned" : "",
            Customer = string.Equals(cause, "UserInitiated", StringComparison.Ordinal)
        };

    /// <summary>Parses one page of the REST history; returns the next page link, or "".</summary>
    private static string ParsePage(JsonDocument doc, List<HealthNote> notes)
    {
        var root = doc.RootElement;
        string next = root.TryGetProperty("nextLink", out var nl) && nl.ValueKind == JsonValueKind.String ? nl.GetString() ?? "" : "";
        if (!root.TryGetProperty("value", out var value) || value.ValueKind != JsonValueKind.Array) return next;
        foreach (var item in value.EnumerateArray())
        {
            if (!item.TryGetProperty("properties", out var p)) continue;
            string Str(string name) => p.TryGetProperty(name, out var e) && e.ValueKind == JsonValueKind.String ? e.GetString() ?? "" : "";
            string occurred = Str("occuredTime");   // sic: the API spells it this way
            if (occurred.Length == 0) continue;
            string reason = Str("reasonType");
            // The customer is named in several fields depending on the source of the note.
            notes.Add(new HealthNote
            {
                Ticks   = AzTime.Ticks(occurred),
                State   = Str("availabilityState"),
                Title   = Str("title"),
                Summary = Str("summary"),
                Reason  = reason,
                // Customer-caused when any of the four fields says so.
                Customer = reason.Equals("Customer Initiated", StringComparison.OrdinalIgnoreCase) ||
                           reason.Equals("User Initiated", StringComparison.OrdinalIgnoreCase) ||
                           Str("context").Equals("Customer Initiated", StringComparison.OrdinalIgnoreCase) ||
                           Str("healthEventCause").Equals("UserInitiated", StringComparison.OrdinalIgnoreCase)
            });
        }
        return next;
    }

    /// <summary>Returns the workspace notes plus, when useRest is true, every page of the REST history.</summary>
    public static HealthFetch Collect(HttpClient client, string resourceId, List<HealthNote> workspaceNotes, bool useRest)
    {
        var result = new HealthFetch();
        if (workspaceNotes != null) result.Notes.AddRange(workspaceNotes);
        if (!useRest) return result;
        string url = "https://management.azure.com" + resourceId +
                     "/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2025-05-01";
        // Follow the pagination links; after an error the notes read so far are kept and Error says why.
        while (url.Length > 0)
        {
            var http = AzHttp.Get(client, url);
            if (http.Doc == null) { result.Error = http.Error; break; }
            using (http.Doc) url = ParsePage(http.Doc, result.Notes);
        }
        return result;
    }

    /// <summary>Titles that say the resource was hurt, even when the state field is missing or "Available".</summary>
    private static readonly Regex BadTitle = new Regex("Degraded|Throttl|Unavailable", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>
    /// Turns health notes into impact windows. A window opens at a Degraded or Unavailable note (or a note with
    /// no state whose title says so) and closes at the next Available note. Workspace "Updated" rows (Available
    /// state, Degraded title) are progress updates of the open event: neither an opening nor a closing note.
    /// An event that never resolves explains at most openCapTicks. The REST history and the workspace describe
    /// the same events, so windows that touch (within mergeTicks) and have the same cause are merged.
    /// A throttling note is customer-caused whatever its recorded reason; a note whose reason is "Planned" is planned maintenance.
    /// </summary>
    public static List<HealthWindow> BuildWindows(List<HealthNote> notes, long openCapTicks, long mergeTicks)
    {
        var sorted = new List<HealthNote>(notes);
        sorted.Sort((a, b) => a.Ticks.CompareTo(b.Ticks));
        var raw = new List<HealthWindow>();
        HealthNote open = null;
        // Pair each opening note with the next closing note.
        foreach (var n in sorted)
        {
            bool bad = BadTitle.IsMatch(n.Title);
            bool opener = n.State.Equals("Degraded", StringComparison.OrdinalIgnoreCase) ||
                          n.State.Equals("Unavailable", StringComparison.OrdinalIgnoreCase) ||
                          (n.State.Length == 0 && bad);
            bool closer = n.State.Equals("Available", StringComparison.OrdinalIgnoreCase) && !bad;
            // An opener starts a window only when none is open; a closer ends the open one.
            if (opener && open == null) open = n;
            else if (closer && open != null) { raw.Add(Make(open, n.Ticks)); open = null; }
        }
        // An event that never resolves explains at most openCapTicks.
        if (open != null) raw.Add(Make(open, open.Ticks + openCapTicks));

        raw.Sort((a, b) => a.Start.CompareTo(b.Start));
        var windows = new List<HealthWindow>();
        // The two sources repeat the same event: extend the previous window instead of adding a duplicate.
        foreach (var w in raw)
        {
            var last = windows.Count > 0 ? windows[windows.Count - 1] : null;
            if (last != null && w.Start <= last.End + mergeTicks && w.Customer == last.Customer && w.Planned == last.Planned)
            {
                if (w.End > last.End) last.End = w.End;
                if (last.Summary.Length == 0) last.Summary = w.Summary;
            }
            else windows.Add(w);
        }
        return windows;
    }

    /// <summary>Builds the window of an event that opened with the given note and ended at end.</summary>
    private static HealthWindow Make(HealthNote open, long end)
        => new HealthWindow
        {
            Start = open.Ticks, End = end, Title = open.Title, Summary = open.Summary,
            Customer = open.Customer || open.Title.IndexOf("Throttl", StringComparison.OrdinalIgnoreCase) >= 0,
            Planned = open.Reason.Equals("Planned", StringComparison.OrdinalIgnoreCase) || PlannedText.IsMatch(open.Summary)
        };

    /// <summary>The wording of a note that says the event was planned maintenance (and not "unplanned").</summary>
    private static readonly Regex PlannedText = new Regex("(?<!un)planned maintenance", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}

/// <summary>A period during which Resource Health reported the resource degraded or unavailable.</summary>
public sealed class HealthWindow
{
    public long   Start, End;     // UTC ticks
    public bool   Customer;       // caused by the customer
    public bool   Planned;        // planned maintenance (the SLA's Scheduled Downtime)
    public string Title   = "";
    public string Summary = "";
}

/// <summary>Hourly request counts of a storage account: the failed transactions and the Total Storage Transactions.</summary>
public sealed class StorageHourly
{
    public double[] Failed;    // ServerOtherError + ServerTimeoutError per hour
    public double[] Counted;   // every transaction that is not an Excluded Transaction, failed ones included, per hour
}

/// <summary>
/// Parsers for the Azure Storage availability algorithm (README, "Algorithms"). Requests are
/// counted per ResponseType, following the Azure Storage SLA: the Total Storage Transactions are all the
/// transactions except the Excluded Transactions that a ResponseType shows (authentication failures and
/// throttling because a quota was exceeded), and the failed ones are the server errors.
/// </summary>
public static class StorageParser
{
    /// <summary>Server errors: the transactions that the service did not complete.</summary>
    private static readonly HashSet<string> FailedTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "ServerOtherError", "ServerTimeoutError"
    };

    /// <summary>Excluded Transactions that a ResponseType shows: authentication failures and quota throttling.</summary>
    private static readonly HashSet<string> ExcludedTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "AuthenticationError", "AuthorizationError", "ServerBusyError", "ClientThrottlingError",
        "ClientAccountRequestThrottlingError", "ClientAccountBandwidthThrottlingError",
        "ClientShareEgressThrottlingError", "ClientShareIngressThrottlingError", "ClientShareIopsThrottlingError"
    };

    /// <summary>Returns 2 for a failed transaction, 1 for any other counted one, 0 for an Excluded Transaction.</summary>
    private static int Classify(JsonElement series)
    {
        if (!series.TryGetProperty("metadatavalues", out var mv)) return 1;
        // The ResponseType dimension says what kind of transactions the series holds.
        foreach (var m in mv.EnumerateArray())
        {
            if (!string.Equals(m.GetProperty("name").GetProperty("value").GetString(), "responsetype", StringComparison.OrdinalIgnoreCase)) continue;
            string v = m.GetProperty("value").GetString() ?? "";
            if (FailedTypes.Contains(v)) return 2;
            if (ExcludedTypes.Contains(v)) return 0;
        }
        return 1;
    }

    /// <summary>Accumulates a Transactions response split by ResponseType into per-slot arrays.</summary>
    /// <param name="slotTicks">Length of one array slot (one hour or one minute) in ticks.</param>
    private static void Accumulate(JsonDocument doc, long startTicks, long slotTicks, double[] failed, double[] counted)
    {
        if (!doc.RootElement.TryGetProperty("value", out var value) || value.GetArrayLength() == 0) return;
        foreach (var series in value[0].GetProperty("timeseries").EnumerateArray())
        {
            int kind = Classify(series);
            if (kind == 0) continue;
            // Each data point is the total of one slot; points outside the period are ignored.
            foreach (var dp in series.GetProperty("data").EnumerateArray())
            {
                if (!dp.TryGetProperty("total", out var tot) || tot.ValueKind != JsonValueKind.Number) continue;
                double n = tot.GetDouble();
                if (n <= 0) continue;
                long slot = (AzTime.Ticks(dp.GetProperty("timeStamp").GetString()!) - startTicks) / slotTicks;
                if (slot < 0 || slot >= counted.Length) continue;
                counted[slot] += n;
                if (kind == 2) failed[slot] += n;
            }
        }
    }

    /// <summary>Parses an hourly (PT1H) response covering the whole period.</summary>
    public static StorageHourly ParseHourly(JsonDocument doc, long startTicks, int hours)
    {
        var h = new StorageHourly { Failed = new double[hours], Counted = new double[hours] };
        Accumulate(doc, startTicks, TimeSpan.TicksPerHour, h.Failed, h.Counted);
        return h;
    }

    /// <summary>Adds a minute (PT1M) response into the per-minute arrays of the period.</summary>
    public static void AddMinutes(JsonDocument doc, long startTicks, double[] failed, double[] counted)
        => Accumulate(doc, startTicks, TimeSpan.TicksPerMinute, failed, counted);
}

/// <summary>
/// Reads the billed minutes of a serverless SQL database. A paused database bills nothing and the metric has
/// no value for its minutes, so a minute without a value is a minute in which the database was not operational.
/// </summary>
public static class ServerlessParser
{
    /// <summary>Marks every minute (indexed from startTicks) that has an app_cpu_billed value.</summary>
    public static void AddBilledMinutes(JsonDocument doc, long startTicks, bool[] billed)
    {
        foreach (var metric in doc.RootElement.GetProperty("value").EnumerateArray())
        foreach (var series in metric.GetProperty("timeseries").EnumerateArray())
        foreach (var dp in series.GetProperty("data").EnumerateArray())
        {
            if (!dp.TryGetProperty("total", out var total) || total.ValueKind != JsonValueKind.Number) continue;
            long minute = (AzTime.Ticks(dp.GetProperty("timeStamp").GetString()!) - startTicks) / TimeSpan.TicksPerMinute;
            if (minute >= 0 && minute < billed.Length) billed[minute] = true;
        }
    }
}

/// <summary>A start, stop or restart of a Web App, from the Activity Log.</summary>
public sealed class WebEvent
{
    public long   Ticks;
    public string Op;      // "stop", "start" or "restart"
    public WebEvent(long ticks, string op) { Ticks = ticks; Op = op; }
}

/// <summary>Consecutive minutes in which every request of a Web App failed.</summary>
public sealed class WebIncident
{
    public int    StartMinute, EndMinute, Minutes;
    public double Requests;
    public string Class = "";           // Stopped, Recycle, Customer, Fault or Unresolved
    public HealthWindow Window;         // Resource Health window that decided the class, if any
}

/// <summary>What the Web App algorithm found in the minutes of one app.</summary>
public sealed class WebResult
{
    public int    Active;               // minutes with at least one request
    public int    Down;                 // active minutes in which every request failed with a 5xx
    public int    DownFewRequests;      // down minutes with fewer than 5 requests
    public int    Partial;              // active minutes with some, but not all, requests failed
    public int    Stopped, Recycle, Customer, Fault, Unresolved;   // the decision for each down minute
    public int    StoppedMinutes;       // minutes the app was stopped by the customer
    public double Requests, Errors;     // totals of the active minutes
    public double PartialRequests, PartialErrors;
    public List<WebIncident> Incidents = new List<WebIncident>();
}

/// <summary>Parsers for the Web App availability algorithm (README, "Algorithms").</summary>
public static class WebParser
{
    /// <summary>Adds the Requests and Http5xx totals of a response into per-slot arrays (slots are hours or minutes).</summary>
    public static void AddCounts(JsonDocument doc, long startTicks, long slotTicks, double[] requests, double[] errors)
    {
        if (!doc.RootElement.TryGetProperty("value", out var value)) return;
        foreach (var metric in value.EnumerateArray())
        {
            string name = metric.GetProperty("name").GetProperty("value").GetString() ?? "";
            double[] target = name.Equals("Requests", StringComparison.OrdinalIgnoreCase) ? requests
                            : name.Equals("Http5xx", StringComparison.OrdinalIgnoreCase) ? errors : null;
            if (target == null) continue;
            // Requests and Http5xx are separate metrics; each is summed into its own array.
            foreach (var series in metric.GetProperty("timeseries").EnumerateArray())
            foreach (var dp in series.GetProperty("data").EnumerateArray())
            {
                if (!dp.TryGetProperty("total", out var tot) || tot.ValueKind != JsonValueKind.Number) continue;
                long slot = (AzTime.Ticks(dp.GetProperty("timeStamp").GetString()!) - startTicks) / slotTicks;
                if (slot >= 0 && slot < target.Length) target[slot] += tot.GetDouble();
            }
        }
    }

    /// <summary>Maps an Activity Log operation name to "stop", "start" or "restart"; "" for any other operation.</summary>
    public static string LifecycleKind(string operation)
    {
        string o = (operation ?? "").ToLowerInvariant();
        if (o.Contains("/sites/stop/"))    return "stop";
        if (o.Contains("/sites/start/"))   return "start";
        if (o.Contains("/sites/restart/")) return "restart";
        return "";
    }
}

/// <summary>One Activity Log event read from the REST API.</summary>
public sealed class ActivityEvent
{
    public long   Ticks;
    public string Operation     = "";   // operation name (its localized label when the name is missing)
    public string CorrelationId = "";
}

/// <summary>Reader of the Activity Log REST API (management events of one resource).</summary>
public static class ActivityLogParser
{
    /// <summary>Reads a string property; "" when it is absent or not a string.</summary>
    private static string Text(JsonElement parent, string name)
        => parent.TryGetProperty(name, out var e) && e.ValueKind == JsonValueKind.String ? e.GetString() ?? "" : "";

    /// <summary>Reads one page of the response, skipping failed operations; returns the next page link, or "".</summary>
    public static string ReadPage(JsonDocument doc, List<ActivityEvent> events)
    {
        var root = doc.RootElement;
        string next = Text(root, "nextLink");
        if (!root.TryGetProperty("value", out var value) || value.ValueKind != JsonValueKind.Array) return next;
        foreach (var item in value.EnumerateArray())
        {
            // A failed operation changed nothing; the operation name falls back to its localized label.
            string status = item.TryGetProperty("status", out var st) ? Text(st, "value") : "";
            if (status.Equals("Failed", StringComparison.OrdinalIgnoreCase)) continue;
            string op = "";
            if (item.TryGetProperty("operationName", out var on) && on.ValueKind == JsonValueKind.Object)
            {
                op = Text(on, "value");
                if (op.Length == 0) op = Text(on, "localizedValue");
            }
            // An event without an operation or a time cannot be used.
            string time = Text(item, "eventTimestamp");
            if (op.Length == 0 || time.Length == 0) continue;
            events.Add(new ActivityEvent { Ticks = AzTime.Ticks(time), Operation = op, CorrelationId = Text(item, "correlationId") });
        }
        return next;
    }
}

/// <summary>The minute-by-minute part of the Web App algorithm.</summary>
public static class WebClassifier
{
    private const long OneMin = TimeSpan.TicksPerMinute;

    /// <summary>
    /// Builds, from the stop, start and restart operations, the periods the app was stopped by the customer
    /// (a stop up to the next start or restart, or the end of the period) and the recycle windows (each
    /// operation, plus the grace time). Events of one kind that are close together (at most 5 minutes apart,
    /// 15 minutes in all) are one operation: the Activity Log records each operation several times.
    /// </summary>
    public static void BuildLifecycle(List<WebEvent> events, long periodEndTicks, long graceTicks,
                                      List<long[]> stopped, List<long[]> recycle)
    {
        var sorted = new List<WebEvent>(events);
        sorted.Sort((a, b) => a.Ticks.CompareTo(b.Ticks));
        var operations = new List<(long start, long end, string kind)>();
        // Group the events of each kind into operations by proximity.
        foreach (string kind in new[] { "stop", "start", "restart" })
        {
            long first = -1, last = -1;
            foreach (var e in sorted)
            {
                if (e.Op != kind) continue;
                // A gap of more than 5 minutes, or a span of more than 15, starts a new operation.
                if (first >= 0 && (e.Ticks - last > 5 * OneMin || e.Ticks - first > 15 * OneMin))
                { operations.Add((first, last, kind)); first = -1; }
                if (first < 0) first = e.Ticks;
                last = e.Ticks;
            }
            if (first >= 0) operations.Add((first, last, kind));
        }
        operations.Sort((a, b) => a.start.CompareTo(b.start));
        // In time order, a stop opens a stopped period and the next start or restart closes it.
        long stopAt = -1;
        foreach (var op in operations)
        {
            recycle.Add(new[] { op.start, op.end + graceTicks });
            if (op.kind == "stop") { if (stopAt < 0) stopAt = op.start; }
            else if (stopAt >= 0) { stopped.Add(new[] { stopAt, op.end }); stopAt = -1; }
        }
        if (stopAt >= 0) stopped.Add(new[] { stopAt, periodEndTicks });
    }

    /// <summary>
    /// Finds the down minutes (every request failed with a 5xx) from the first minute the app existed and
    /// decides each: stopped by the customer, inside a recycle window, inside a Resource Health window
    /// (customer: excused, platform: Fault; a window starts leadTicks before the event and ends graceTicks
    /// after it), otherwise Unresolved. Minutes without requests are not judged; minutes with only some
    /// requests failed are counted as partial and not scored.
    /// </summary>
    public static WebResult Classify(double[] requests, double[] errors, int firstMinute, long startTicks,
                                     List<long[]> stopped, List<long[]> recycle, List<HealthWindow> health,
                                     long leadTicks, long graceTicks)
    {
        int n = requests.Length;
        // Mark the stopped minutes first; they leave the eligible minutes whether or not they had traffic.
        var isStopped = new bool[n];
        foreach (var w in stopped)
        {
            int a = (int)Math.Max(0, Math.Floor((w[0] - startTicks) / (double)OneMin));
            int b = (int)Math.Min(n, Math.Ceiling((w[1] - startTicks) / (double)OneMin));
            for (int i = a; i < b; i++) isStopped[i] = true;
        }

        var r = new WebResult();
        WebIncident cur = null;
        // Walk the minutes since creation: only a minute with requests can be judged.
        for (int m = firstMinute; m < n; m++)
        {
            if (isStopped[m]) r.StoppedMinutes++;
            double req = requests[m], err = errors[m];
            if (req <= 0) continue;
            r.Active++; r.Requests += req; r.Errors += err;
            if (err <= 0) continue;
            if (err < req) { r.Partial++; r.PartialRequests += req; r.PartialErrors += err; continue; }

            r.Down++;
            if (req < 5) r.DownFewRequests++;
            // Every request failed: decide who is responsible, in order stopped, recycle, Resource Health window.
            long t = startTicks + m * OneMin;
            string cls = "";
            HealthWindow win = null;
            // The first rule that matches wins; the recycle window covers the minute the operation was sent.
            if (isStopped[m]) cls = "Stopped";
            if (cls.Length == 0)
                foreach (var w in recycle)
                    if (t + OneMin > w[0] && t <= w[1]) { cls = "Recycle"; break; }
            if (cls.Length == 0)
                foreach (var w in health)
                    if (t >= w.Start - leadTicks && t <= w.End + graceTicks) { cls = w.Customer ? "Customer" : "Fault"; win = w; break; }
            if (cls.Length == 0) cls = "Unresolved";
            // Count the decision for the summary.
            switch (cls)
            {
                case "Stopped":  r.Stopped++;  break;
                case "Recycle":  r.Recycle++;  break;
                case "Customer": r.Customer++; break;
                case "Fault":    r.Fault++;    break;
                default:         r.Unresolved++; break;
            }

            // Consecutive down minutes (gap of at most 5) form one incident for the evidence.
            if (cur != null && m - cur.EndMinute <= 5)
            {
                cur.EndMinute = m; cur.Minutes++; cur.Requests += req;
                if (cls != "Unresolved") { cur.Class = cls; cur.Window = win; }
            }
            else
            {
                if (cur != null) r.Incidents.Add(cur);
                cur = new WebIncident { StartMinute = m, EndMinute = m, Minutes = 1, Requests = req, Class = cls, Window = win };
            }
        }
        if (cur != null) r.Incidents.Add(cur);
        return r;
    }
}

/// <summary>
/// Reads the one-minute availability metric of a VM (0 or 1) or an Azure SQL database (0 to 100) and sorts
/// its minutes into available, null, zero and degraded: the null, zero and degraded ones are the "suspect" minutes.
/// </summary>
public static class MetricProcessor
{
    /// <summary>Per-resource response: root has "value" array.</summary>
    public static MetricProcessorResult ProcessSingle(JsonDocument doc, bool isVm)
        => ProcessMetricArray(doc.RootElement.GetProperty("value"), isVm);

    /// <summary>Batch response: root has "values" array, each with "resourceid" + "value".</summary>
    public static BatchResourceResult[] ProcessBatch(JsonDocument doc, bool isVm)
    {
        var results = new List<BatchResourceResult>();
        foreach (var entry in doc.RootElement.GetProperty("values").EnumerateArray())
        {
            string resId = entry.GetProperty("resourceid").GetString() ?? "";
            results.Add(new BatchResourceResult
            {
                ResourceId      = resId,
                ResourceIdLower = resId.ToLowerInvariant(),
                Metrics         = ProcessMetricArray(entry.GetProperty("value"), isVm)
            });
        }
        return results.ToArray();
    }

    /// <summary>Walks the Minimum series of the availability metric and sorts every minute (shared by the single and batch paths).</summary>
    private static MetricProcessorResult ProcessMetricArray(JsonElement valueArr, bool isVm)
    {
        var r = new MetricProcessorResult();
        var nullTicks = new List<long>();
        var zeroTicks = new List<long>();

        foreach (var metricEl in valueArr.EnumerateArray())
        {
            // Only the availability metric is read (the VM one or the SQL one).
            string mName = metricEl.GetProperty("name").GetProperty("value").GetString() ?? "";
            if (!string.Equals(mName, "VmAvailabilityMetric", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(mName, "Availability", StringComparison.OrdinalIgnoreCase)) continue;

            // Each data point is one minute; the Minimum aggregation is the worst value inside it.
            foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
            foreach (var dp  in tsEl.GetProperty("data").EnumerateArray())
            {
                long ticks = AzTime.Ticks(dp.GetProperty("timeStamp").GetString()!);
                double? minVal = null;
                if (dp.TryGetProperty("minimum", out var minEl) && minEl.ValueKind == JsonValueKind.Number)
                    minVal = minEl.GetDouble();

                if (minVal.HasValue)
                {
                    // A VM reports 0 or 1, SQL reports a percentage: scale to 0..1. Only a zero can be downtime
                    // (the SLA counts a minute as down when there is no connectivity); a fraction is counted
                    // and reported as a degraded minute.
                    r.NumericPoints++;
                    double v = isVm ? minVal.Value : minVal.Value / 100.0;
                    if (v == 0.0)      zeroTicks.Add(ticks);
                    else if (v < 1.0)  r.DegradedMinutes++;
                }
                else nullTicks.Add(ticks);
            }
        }

        // Hand the collected minutes to the caller as arrays.
        r.NullTicks = nullTicks.ToArray();
        r.ZeroTicks = zeroTicks.ToArray();
        return r;
    }
}

// ───────────────────────────────────────────────────────────────────────────
// The VM algorithm (README, "Algorithms > Virtual machines") classifies every suspect minute with
// the evidence available for it; a month holds ~44 K minutes per VM.
// ───────────────────────────────────────────────────────────────────────────

/// <summary>A run of consecutive minutes of a VM that count against availability, with one explanation.</summary>
public sealed class VmLossSpan
{
    public long   StartTicks;   // first minute of the run (UTC ticks)
    public int    Minutes;      // number of minutes in the run (each one is a minute of downtime)
    public int    Outcome;      // outcome code: 1 or 2 platform fault, 11 unresolved
    public string Title;        // the Resource Health note behind a health-note fault, otherwise empty
}

/// <summary>Outcome counts of the VM algorithm for one VM.</summary>
public sealed class VmClassifyResult
{
    public int[]  GapCounts = new int[13];   // null + zero minutes, indexed by outcome code
    public List<VmLossSpan> LossSpans = new List<VmLossSpan>();   // the minutes that count against availability, in time order
}

/// <summary>Classifies Resource Health notes of a VM by what they say (customer, platform, planned, recovery, ...).</summary>
public static class VmHealthClassifier
{
    // Health note classes.
    public const int Other = 0, Customer = 1, PlatformUnplanned = 2, PlatformDegraded = 3,
                     PlatformPlanned = 4, SpotEviction = 5, Unknown = 6, Recovery = 7,
                     DownDetected = 8, Rca = 9;

    private const RegexOptions Opt = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
    private static readonly Regex Recov    = new Regex("^Available$|Live Migration Succeeded", Opt);
    private static readonly Regex Spot     = new Regex("preempt|evict", Opt);
    private static readonly Regex Down     = new Regex("^Down:", Opt);
    private static readonly Regex Degraded = new Regex("Accelerated Networking|Degraded performance|Degraded Hardware", Opt);
    private static readonly Regex Outage   = new Regex("host failure|dataplane down|^Unavailable$|Redeploy", Opt);

    /// <summary>
    /// Classifies a Resource Health note by what it says, not by whether its state changed.
    /// Order matters: RCA and customer notes first, then recovery/unknown, then platform classes.
    /// </summary>
    public static int Classify(string title, string state, bool customer, string reasonType)
    {
        title = title ?? ""; state = state ?? ""; reasonType = reasonType ?? "";
        if (title.StartsWith("Root Cause Analysis", StringComparison.OrdinalIgnoreCase)) return Rca;
        if (customer) return Customer;
        if (state.Equals("Available", StringComparison.OrdinalIgnoreCase) || Recov.IsMatch(title)) return Recovery;
        if (state.Equals("Unknown", StringComparison.OrdinalIgnoreCase) ||
            title.StartsWith("Unknown", StringComparison.OrdinalIgnoreCase)) return Unknown;
        if (Spot.IsMatch(title)) return SpotEviction;
        // "Down: ... unavailable for 15 minutes" is a detection note raised after the VM went down;
        // it never starts or supersedes a state.
        if (Down.IsMatch(title)) return DownDetected;
        if (Degraded.IsMatch(title)) return PlatformDegraded;
        if (Outage.IsMatch(title)) return PlatformUnplanned;
        if (reasonType.Equals("Planned", StringComparison.OrdinalIgnoreCase)) return PlatformPlanned;
        if (reasonType.Equals("Unplanned", StringComparison.OrdinalIgnoreCase) ||
            reasonType.Equals("Platform Initiated", StringComparison.OrdinalIgnoreCase)) return PlatformUnplanned;
        return Other;
    }
}

/// <summary>The VM algorithm: decides every suspect minute of a VM (README, "Algorithms > Virtual machines").</summary>
public static class VmGapClassifier
{
    private const long OneMin = 600_000_000L;

    // Outcome codes (index into GapCounts)
    //  1 FaultPlatformContext   2 FaultPlatformHealth   3 ExcusedNotExists     4 ExcusedCustomerContext
    //  5 ExcusedActivityLog     6 ExcusedCustomerHealth 7 ExcusedPlanned       8 ExcusedSpotEviction
    //  9 ExcusedHealthUnknown  10 ExcusedMetricGap     11 Unresolved          12 ExcusedInheritedCustomer
    // Context mask bits: 2 Platform, 4 User, 8 Unknown.

    /// <summary>
    /// Reads a VmAvailabilityMetric response split by Context and returns, for each zero minute,
    /// the mask of contexts reporting zero. Zeros with no Context information are Unknown (8).
    /// </summary>
    public static int[] GetZeroMasks(JsonDocument split, long[] zeroTicks)
    {
        var zeroMask = new Dictionary<long, int>();
        // One series per Context value; a minute can appear in several (the masks are OR-ed together).
        foreach (var metric in split.RootElement.GetProperty("value").EnumerateArray())
        foreach (var ts in metric.GetProperty("timeseries").EnumerateArray())
        {
            // The Context dimension says who caused the zeros of the series: Platform 2, User 4, Unknown 8.
            int ctxBit = 8;
            if (ts.TryGetProperty("metadatavalues", out var mvs))
            {
                foreach (var mv in mvs.EnumerateArray())
                {
                    // Find the Context dimension of the series; its value tells who caused the zeros.
                    string n = mv.GetProperty("name").GetProperty("value").GetString() ?? "";
                    if (n.IndexOf("context", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    string v = mv.GetProperty("value").GetString() ?? "";
                    if (v.Equals("Platform", StringComparison.OrdinalIgnoreCase)) ctxBit = 2;
                    else if (v.Equals("User", StringComparison.OrdinalIgnoreCase) ||
                             v.Equals("Customer", StringComparison.OrdinalIgnoreCase)) ctxBit = 4;
                }
            }
            // Only the zero minutes matter here; OR the context into the mask of each.
            foreach (var dp in ts.GetProperty("data").EnumerateArray())
            {
                if (!dp.TryGetProperty("minimum", out var mn) ||
                    mn.ValueKind != JsonValueKind.Number || mn.GetDouble() != 0.0) continue;
                long ticks = AzTime.Ticks(dp.GetProperty("timeStamp").GetString()!);
                zeroMask.TryGetValue(ticks, out int cur);
                zeroMask[ticks] = cur | ctxBit;
            }
        }
        // Zeros that no Context series reports stay Unknown (8).
        var masks = new int[zeroTicks.Length];
        for (int i = 0; i < zeroTicks.Length; i++)
            masks[i] = zeroMask.TryGetValue(zeroTicks[i], out int m) ? m : 8;
        return masks;
    }

    /// <summary>Expands interval pairs (from[i] to to[i]) into the set of whole minutes they cover.</summary>
    private static HashSet<long> Expand(long[] from, long[] to)
    {
        var set = new HashSet<long>();
        for (int i = 0; i < from.Length; i++)
        {
            long t = from[i] - (from[i] % OneMin);
            if (t < from[i]) t += OneMin;
            for (; t < to[i]; t += OneMin) set.Add(t);
        }
        return set;
    }

    // Index of the latest anchor starting at or before the tick (+2 min of clock skew).
    private static int Lookup(long[] start, long tick)
    {
        int lo = 0, hi = start.Length - 1, best = -1;
        long limit = tick + 2 * OneMin;
        while (lo <= hi)
        {
            int mid = (lo + hi) >> 1;
            if (start[mid] <= limit) { best = mid; lo = mid + 1; } else hi = mid - 1;
        }
        return best;
    }

    // A platform-unplanned note stays the explanation for a minute within the window unless a
    // customer action followed it. Notes logged seconds later (Resolved, Unknown) do not hide it.
    private static int FindFaultAnchorUnlessCustomer(long[] start, int[] cls, long tick, long windowTicks)
    {
        for (int i = Lookup(start, tick); i >= 0; i--)
        {
            if (tick - start[i] > windowTicks) return -1;
            if (cls[i] == VmHealthClassifier.Customer) return -1;
            if (cls[i] == VmHealthClassifier.PlatformUnplanned) return i;
        }
        return -1;
    }

    /// <summary>
    /// Classifies every suspect minute (null or zero) of one VM. Rules are applied in
    /// order and the first match wins; see README, "Algorithms". The minutes that count against
    /// availability (platform faults and unresolved zeros) are also returned as spans for the report.
    /// </summary>
    public static VmClassifyResult Classify(
        long[] nullTicks, long[] zeroTicks, int[] zeroMasks,
        long[] actFrom, long[] actTo, long[] nxFrom, long[] nxTo,
        long[] entryTicks, int[] entryClasses, string[] entryTitles, long faultWindowTicks)
    {
        var act = Expand(actFrom, actTo);
        var nx  = Expand(nxFrom, nxTo);

        // Only some note classes carry a state forward in time; the rest are evidence only.
        var aStart = new List<long>(); var aClass = new List<int>(); var aTitle = new List<string>();
        for (int i = 0; i < entryTicks.Length; i++)
        {
            int c = entryClasses[i];
            if (c == VmHealthClassifier.Customer || c == VmHealthClassifier.PlatformUnplanned ||
                c == VmHealthClassifier.PlatformPlanned || c == VmHealthClassifier.SpotEviction ||
                c == VmHealthClassifier.Unknown || c == VmHealthClassifier.Recovery)
            { aStart.Add(entryTicks[i]); aClass.Add(c); aTitle.Add(entryTitles[i] ?? ""); }
        }
        long[] anchorStart = aStart.ToArray(); int[] anchorClass = aClass.ToArray();

        // kind: 0 null, 1 zero
        var items = new List<(long tick, int kind, int mask)>(nullTicks.Length + zeroTicks.Length);
        foreach (long t in nullTicks) items.Add((t, 0, 0));
        for (int i = 0; i < zeroTicks.Length; i++) items.Add((zeroTicks[i], 1, zeroMasks[i]));
        items.Sort((a, b) => a.tick.CompareTo(b.tick));

        // Decide the suspect minutes in time order: a null run takes the explanation of the minute before it.
        var res = new VmClassifyResult();
        long prevTick = -1; int prevOutcome = 0;

        foreach (var it in items)
        {
            int outcome = 0;
            long t = it.tick;

            // The VM did not exist yet.
            if (nx.Contains(t)) outcome = 3;

            // A measured zero tells who caused it, when the metric says so.
            if (outcome == 0 && it.kind == 1)
            {
                if ((it.mask & 2) != 0) outcome = 1;
                else if ((it.mask & 4) != 0 && (it.mask & 8) == 0) outcome = 4;
            }

            // A lifecycle operation of the Activity Log (start, deallocate, power off, restart).
            if (outcome == 0 && act.Contains(t)) outcome = 5;

            // A gap is explained by what started it: a null run that continues straight after a
            // customer-explained minute stays customer-explained.
            if (outcome == 0 && it.kind == 0 && prevTick >= 0 && t - prevTick <= OneMin &&
                (prevOutcome == 3 || prevOutcome == 4 || prevOutcome == 5 || prevOutcome == 6 || prevOutcome == 12))
                outcome = 12;

            // A platform note explains the minute within the fault window, unless a customer action followed it.
            string noteTitle = "";
            if (outcome == 0)
            {
                int fa = FindFaultAnchorUnlessCustomer(anchorStart, anchorClass, t, faultWindowTicks);
                if (fa >= 0) { outcome = 2; noteTitle = aTitle[fa]; }
            }

            // Otherwise the latest state-carrying note decides: customer, planned maintenance, spot eviction,
            // or unknown health (null minutes only).
            if (outcome == 0)
            {
                int a = Lookup(anchorStart, t);
                int c = a >= 0 ? anchorClass[a] : 0;
                if (c == VmHealthClassifier.Customer) outcome = 6;
                else if (c == VmHealthClassifier.PlatformPlanned) outcome = 7;
                else if (c == VmHealthClassifier.SpotEviction) outcome = 8;
                else if (c == VmHealthClassifier.Unknown && it.kind == 0) outcome = 9;
            }

            // Nothing explains it: a missing sample is a metric gap, a measured zero is downtime.
            if (outcome == 0) outcome = it.kind == 0 ? 10 : 11;

            res.GapCounts[outcome]++;

            // A minute that counts against availability (platform fault or unresolved) extends the current
            // span when it follows it directly with the same explanation, otherwise it opens a new one.
            if (outcome == 1 || outcome == 2 || outcome == 11)
            {
                var last = res.LossSpans.Count > 0 ? res.LossSpans[res.LossSpans.Count - 1] : null;
                if (last != null && last.Outcome == outcome && last.Title == noteTitle &&
                    t - (last.StartTicks + (last.Minutes - 1) * OneMin) <= OneMin)
                    last.Minutes++;
                else
                    res.LossSpans.Add(new VmLossSpan { StartTicks = t, Minutes = 1, Outcome = outcome, Title = noteTitle });
            }
            prevTick = t; prevOutcome = outcome;
        }
        return res;
    }
}
'@
}
#endregion

#region Get-ResourceInventory
<#
.SYNOPSIS
    Lists the resources to measure through Azure Resource Graph.

.DESCRIPTION
    Queries Resource Graph for the requested resource kinds across the supplied subscriptions,
    optionally filtered by name, and returns lightweight descriptors for the metrics pipeline.
    SQL system databases (master) and Function Apps are excluded. The creation time is included for
    virtual machines, SQL databases, storage accounts and Web Apps, because it marks when the resource
    started to exist; Web Apps also carry the pricing tier of their App Service plan.

.PARAMETER SubscriptionIds
    Subscription IDs to query.

.PARAMETER SubIdToName
    Map of subscription ID to display name.

.PARAMETER Kinds
    Resource kinds: vm, sql, storage, webapp.

.PARAMETER ResourceNameFilter
    Optional resource name (or SQL 'server/database' name) to restrict the inventory to.

.OUTPUTS
    PSCustomObject[] with Name, Kind, ResourceId, SubscriptionId, SubscriptionName,
    ResourceGroupName, Location, CreationTime, Tier (the App Service plan tier, Web Apps only) and
    SkuName (SQL databases only), sorted by subscription, kind and name.
#>
function Get-ResourceInventory {
    param(
        [string[]]$SubscriptionIds,
        [hashtable]$SubIdToName,
        [string[]]$Kinds,
        [string]$ResourceNameFilter
    )
    # Validate the requested kinds and map them to Resource Graph resource types.
    $kindToType = @{
        'vm'      = 'microsoft.compute/virtualmachines'
        'sql'     = 'microsoft.sql/servers/databases'
        'storage' = 'microsoft.storage/storageaccounts'
        'webapp'  = 'microsoft.web/sites'
    }
    $unsupported = @($Kinds | Where-Object { -not $kindToType.ContainsKey($_) })
    if ($unsupported.Count -gt 0) {
        throw "Unsupported kind(s): $($unsupported -join ', '). Allowed values: vm, sql, storage, webapp."
    }

    $types = @($Kinds | ForEach-Object { $kindToType[$_] })
    # One 'type =~' clause per requested kind.
    $typeFilter = if ($types.Count -eq 1) { "type =~ '$($types[0])'" }
                  else { ($types | ForEach-Object { "type =~ '$_'" }) -join ' or ' }

    $nameFilter = ''
    if ($ResourceNameFilter) {
        $escaped = $ResourceNameFilter.Replace("'", "''")
        $nameFilter = "| where displayName =~ '$escaped' or name =~ '$escaped'`n"
    }

    # The query drops the SQL system database and dedicated SQL pools (not Azure SQL Databases in the SLA) and Function Apps, names SQL databases 'server/database',
    # joins Web Apps to their App Service plan (for the tier) and picks the creation time of each kind.
    $query = @"
resources
| where $typeFilter
| extend idParts = split(id, '/')
| extend sqlServerName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[8]), '')
| extend databaseName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[10]), '')
| where not(type =~ 'microsoft.sql/servers/databases' and (databaseName =~ 'master' or tostring(sku.tier) =~ 'DataWarehouse'))
| extend displayName = iff(type =~ 'microsoft.sql/servers/databases', strcat(sqlServerName, '/', databaseName), name)
${nameFilter}| where not(type =~ 'microsoft.web/sites' and kind contains 'functionapp')
| extend planId = tolower(tostring(properties.serverFarmId))
| join kind=leftouter (resources | where type =~ 'microsoft.web/serverfarms' | project planId = tolower(id), planTier = tostring(sku.tier)) on planId
| extend resourceKind = case(
    type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
    type =~ 'microsoft.sql/servers/databases', 'AzureSqlDatabase',
    type =~ 'microsoft.storage/storageaccounts', 'StorageAccount',
    type =~ 'microsoft.web/sites', 'WebApp',
    'Other'
)
| project id, name, displayName, type, subscriptionId, resourceGroup, location, resourceKind,
          sqlServerName, databaseName, planTier, skuName = tostring(sku.name),
          creationTime=case(
              type =~ 'microsoft.compute/virtualmachines', tostring(properties.timeCreated),
              type =~ 'microsoft.storage/storageaccounts', tostring(properties.creationTime),
              type =~ 'microsoft.sql/servers/databases', tostring(properties.creationDate),
              type =~ 'microsoft.web/sites', tostring(properties.createdTimeUtc),
              '')
"@

    $resources = [System.Collections.Generic.List[object]]::new()
    # Page through the Resource Graph results (1,000 rows per call) using the skip token.
    $skipToken = $null
    do {
        $params = @{ Query = $query; First = 1000; Subscription = $SubscriptionIds }
        if ($skipToken) { $params.SkipToken = $skipToken }
        $response = Search-AzGraph @params

        foreach ($row in $response.Data) {
            # Normalise each row into the descriptor used by the rest of the pipeline.
            $kind = [string]$row.resourceKind
            $subId = [string]$row.subscriptionId
            $name = if ($row.displayName) { [string]$row.displayName } else { [string]$row.name }
            # Resource Graph returns the creation time either as a DateTime or as an
            # ISO string, depending on the Az.ResourceGraph version; normalise to UTC.
            $creationTime = $null
            # Only the kinds that carry a creation time are read; an empty value is skipped.
            if ($kind -in 'VirtualMachine', 'StorageAccount', 'AzureSqlDatabase', 'WebApp' -and $row.creationTime) {
                if ($row.creationTime -is [datetime]) {
                    $creationTime = ([DateTimeOffset][datetime]$row.creationTime).ToUniversalTime()
                } else {
                    # A string without an offset is taken as UTC.
                    $parsedCreationTime = [DateTimeOffset]::MinValue
                    if ([DateTimeOffset]::TryParse(
                            [string]$row.creationTime,
                            [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::AssumeUniversal,
                            [ref]$parsedCreationTime)) {
                        $creationTime = $parsedCreationTime.ToUniversalTime()
                    }
                }
            }
            # Tier is only filled for Web Apps (it comes from their App Service plan).
            $resources.Add([PSCustomObject]@{
                Name              = $name
                Kind              = $kind
                ResourceId        = [string]$row.id
                SubscriptionId    = $subId
                SubscriptionName  = $SubIdToName[$subId] ?? $subId
                ResourceGroupName = [string]$row.resourceGroup
                Location          = [string]$row.location
                CreationTime      = $creationTime
                Tier              = [string]$row.planTier
                # The SKU name tells a serverless SQL database (GP_S_Gen5, HS_S_Gen5, ...) from a provisioned one.
                SkuName           = [string]$row.skuName
            })
        }
        $skipToken = [string]::IsNullOrWhiteSpace($response.SkipToken) ? $null : $response.SkipToken
    } while ($skipToken)

    @($resources | Sort-Object SubscriptionName, Kind, Name)
}
#endregion

#region Get-LogAnalyticsData
<#
.SYNOPSIS
    Bulk-fetches Activity Log events and Resource Health history from a Log Analytics workspace.

.DESCRIPTION
    Runs a single KQL query that returns Activity Log events (lifecycle operations plus
    creation/deletion) and Resource Health events for the given subscriptions and
    resources. All non-failed Activity Log statuses are kept: a lifecycle operation is
    logged as Start, Accept and Success, and the Start event marks when the minutes it
    affects begin, so filtering on Success alone leaves those first minutes unexplained.

    ActivityEvents drive lifecycle classification and existence tracking. HealthRaw keeps every
    Resource Health event (state, cause, title); the algorithms turn it into notes and windows
    (see Get-HealthSources and HealthHistory).

.PARAMETER WorkspaceId
    Log Analytics workspace ID (GUID) that receives the Activity Log of the subscriptions.

.PARAMETER SubscriptionIds
    Subscription IDs to query.

.PARAMETER ResourceIds
    Resource IDs of the resources under investigation.

.PARAMETER PeriodStart
    Start of the observation window.

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER ArmToken
    Bearer token for the Log Analytics API.

.OUTPUTS
    Hashtable keyed by lowercase resource ID; each value has ActivityEvents and HealthRaw lists.
#>
function Get-LogAnalyticsData {
    param(
        [string]$WorkspaceId,
        [string[]]$SubscriptionIds,
        [string[]]$ResourceIds,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [string]$ArmToken
    )

    # Period bounds as ISO 8601 text for the KQL datetime() literals.
    $startIso = $PeriodStart.ToString('O')
    $endIso   = $PeriodEnd.ToString('O')
    # Quote the subscription and resource lists as KQL string literals (resource IDs are compared in lower case).
    $subList  = ($SubscriptionIds | ForEach-Object { "'$_'" }) -join ', '
    $normalizedResourceIds = @($ResourceIds |
        ForEach-Object { $_.ToLowerInvariant() } |
        Sort-Object -Unique)
    $resourceList = ($normalizedResourceIds | ForEach-Object {
        "'$($_.Replace("'", "''"))'"
    }) -join ', '

    # Single KQL query that fetches both Activity Log operations and Resource
    # Health events, tagged with a Source column to distinguish them.
    $kql = @"
let subs = dynamic([$subList]);
let resourceIds = dynamic([$resourceList]);
let actOps = dynamic([
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/START/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/DEALLOCATE/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/POWEROFF/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/RESTART/ACTION',
  'MICROSOFT.SQL/SERVERS/DATABASES/RESUME',
  'MICROSOFT.SQL/SERVERS/DATABASES/RESUME/ACTION',
  'MICROSOFT.SQL/SERVERS/DATABASES/FAILOVER/ACTION',
  'MICROSOFT.WEB/SITES/STOP/ACTION',
  'MICROSOFT.WEB/SITES/START/ACTION',
  'MICROSOFT.WEB/SITES/RESTART/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/WRITE',
  'MICROSOFT.SQL/SERVERS/DATABASES/WRITE',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/DELETE',
  'MICROSOFT.SQL/SERVERS/DATABASES/DELETE'
]);
let actData = AzureActivity
    | where SubscriptionId in (subs)
    | where CategoryValue == 'Administrative'
    | where OperationNameValue in~ (actOps)
    // Keep Start/Accept as well as Success: the first event marks when the affected minutes begin.
    | where ActivityStatusValue in~ ('Start', 'Started', 'Accept', 'Accepted', 'Success', 'Succeeded')
    | where TimeGenerated >= datetime($startIso) and TimeGenerated <= datetime($endIso)
    | where tolower(_ResourceId) in (resourceIds)
    | project TimeGenerated, ResourceId=tolower(_ResourceId),
              OperationName=OperationNameValue, CorrelationId,
              Source='Activity';
let healthData = AzureActivity
    | where SubscriptionId in (subs)
    | where CategoryValue == 'ResourceHealth'
    | where ResourceProviderValue in ('MICROSOFT.COMPUTE', 'MICROSOFT.SQL', 'MICROSOFT.STORAGE', 'MICROSOFT.WEB')
    | where tolower(_ResourceId) in (resourceIds)
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

    $content = $null
    $response = $null
    try {
        # A failed query must stop the run: without it the evidence would silently be missing.
        $content = [System.Net.Http.StringContent]::new(
            $body, [System.Text.Encoding]::UTF8, 'application/json')
        $response = $httpClient.PostAsync($laUrl, $content).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null
        $jsonStr = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally {
        if ($response) { $response.Dispose() }
        if ($content) { $content.Dispose() }
        $httpClient.Dispose()
    }

    # The response is one table; columns are looked up by name because their order is not guaranteed.
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

    foreach ($row in $rows) {
        $resId = [string]$row[$iResId]
        if (-not $dataByRes.ContainsKey($resId)) {
            $dataByRes[$resId] = [PSCustomObject]@{
                ActivityEvents = [System.Collections.Generic.List[object]]::new()
                HealthRaw      = [System.Collections.Generic.List[object]]::new()
            }
        }
        $entry = $dataByRes[$resId]

        # ConvertFrom-Json may convert ISO 8601 strings to DateTime objects,
        # and [string]$datetime uses locale formatting which loses sub-second
        # precision.  Handle both types to preserve tick-accurate timestamps.
        $tsRaw = $row[$iTime]
        $ts = if ($tsRaw -is [datetime]) {
            [DateTimeOffset]([datetime]$tsRaw)
        } else {
            [DateTimeOffset]::Parse([string]$tsRaw,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal)
        }
        # 'Activity' rows are lifecycle operations; 'Health' rows are Resource Health events.
        $source = [string]$row[$iSource]

        if ($source -eq 'Activity') {
            $entry.ActivityEvents.Add([PSCustomObject]@{
                Timestamp     = $ts
                OperationName = [string]$row[$iOp]
                CorrelationId = [string]$row[$iCorr]
            })
        }
        elseif ($source -eq 'Health') {
            # Resource Health rows carry the event as a JSON string (or object) in Properties.
            $propsRaw = $row[$iProps]
            $props = if ($propsRaw -is [string] -and $propsRaw) {
                $propsRaw | ConvertFrom-Json
            } elseif ($propsRaw -is [PSCustomObject]) {
                $propsRaw
            } else { $null }

            if ($props) {
                # Extract health state — newer events use 'currentHealthStatus',
                # older ones use 'availabilityState'
                $state = ''
                if ($props.PSObject.Properties['currentHealthStatus']) {
                    $state = [string]$props.currentHealthStatus
                } elseif ($props.PSObject.Properties['availabilityState']) {
                    $state = [string]$props.availabilityState
                }

                # Extract cause (e.g. 'UserInitiated', 'PlatformInitiated', 'Unknown')
                $rawCause = ''
                if ($props.PSObject.Properties['cause']) {
                    $rawCause = [string]$props.cause
                }

                # Extract the health note title (e.g. 'Redeploying due to host failure').
                $rawTitle = ''
                if ($props.PSObject.Properties['title']) {
                    $rawTitle = [string]$props.title
                }

                # The details say, for example, that the database was unavailable due to planned maintenance.
                $rawDetails = ''
                if ($props.PSObject.Properties['details']) {
                    $rawDetails = [string]$props.details
                }

                if ($state) {
                    $entry.HealthRaw.Add([PSCustomObject]@{
                        Timestamp = $ts
                        State     = $state
                        Cause     = $rawCause
                        Title     = $rawTitle
                        Details   = $rawDetails
                    })
                }
            }
        }
    }

    Write-Host "Log Analytics: fetched $($rows.Count) events for $($dataByRes.Count) resource(s)"
    $dataByRes
}
#endregion

#region Kind configuration
# Maps resource kind → metric namespace, metric names, and aggregation.
# Used by both the per-resource ARM Metrics API and the regional Batch API.
# Storage accounts and Web Apps are not listed: they use their own algorithms (see "Storage algorithm"
# and "Web App algorithm").

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
}
#endregion

#region Test-BatchEndpoints
<#
.SYNOPSIS
    Verifies that every regional Azure Monitor Batch endpoint is reachable.

.DESCRIPTION
    Probes each region with an empty request for a dummy subscription. HTTP 400, 401 and 403 are
    the expected answers (the endpoint is reachable, the request is just not valid) and count as
    success. Any other failure aborts the run, so a blocked endpoint is found before thousands of
    metric calls are attempted.

.PARAMETER MetricsToken
    Bearer token for the metrics.monitor.azure.com audience.

.PARAMETER Regions
    Lowercase Azure region names to probe.

.OUTPUTS
    None. Throws when one or more endpoints are unreachable.
#>
function Test-BatchEndpoints {
    param(
        [string]$MetricsToken,
        [string[]]$Regions
    )

    Write-Host "Validating batch endpoint availability for $($Regions.Count) region(s)..."
    $allOk = $true
    foreach ($region in $Regions) {
        $endpoint = "https://$region.metrics.monitor.azure.com"
        # An empty probe request: the endpoint answers 400/401/403 when it is reachable.
        $testUri = "$endpoint/subscriptions/00000000-0000-0000-0000-000000000000/metrics:getBatch?api-version=2023-10-01&metricnamespace=Microsoft.Compute/virtualMachines&metricnames=Percentage%20CPU"
        $body = '{"resourceids":[]}'

        try {
            Invoke-WebRequest -Uri $testUri -Method POST -Body $body -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $MetricsToken" } -ErrorAction Stop | Out-Null
            Write-Host "  $region`: OK"
        }
        catch {
            # Only an answer from the endpoint proves it is reachable; transport errors give status 0.
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
    # Any unreachable region aborts the run before thousands of calls are attempted.
    if (-not $allOk) {
        throw 'One or more batch endpoints are unreachable. Aborting.'
    }
    Write-Host 'All batch endpoints validated successfully.'
    Write-Host ''
}
#endregion

#region Get-BatchAvailabilityMetrics
<#
.SYNOPSIS
    Fetches availability metrics through the regional Azure Monitor Batch API.

.DESCRIPTION
    Groups resources by (subscription, region, kind), splits each group into chunks of at most
    BatchSize resources (the API accepts up to 50), and sends the chunks in parallel waves with a
    garbage collection between waves to bound memory on large estates. Responses are parsed from the
    stream by the compiled MetricProcessor. A chunk that fails entirely yields excluded placeholders
    for its resources, so one failed call never hides the others.

.PARAMETER Resources
    Resource descriptors from Get-ResourceInventory.

.PARAMETER StartDate
    Start of the observation window.

.PARAMETER EndDate
    End of the observation window.

.PARAMETER ThrottleLimit
    Number of batch calls per parallel wave.

.PARAMETER BatchSize
    Maximum resources per batch call.

.PARAMETER MetricsToken
    Bearer token for the metrics.monitor.azure.com audience.

.OUTPUTS
    Hashtable keyed by lowercase resource ID with one MetricResult per resource.
#>
function Get-BatchAvailabilityMetrics {
    param(
        [object[]]$Resources,
        [DateTimeOffset]$StartDate,
        [DateTimeOffset]$EndDate,
        [int]$ThrottleLimit,
        [int]$BatchSize,
        [string]$MetricsToken
    )

    # The Batch API takes the time range with millisecond precision.
    $startIso = $StartDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $endIso   = $EndDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Group resources by (subscriptionId, location, kind) — the Batch API requires
    # all resources in a single call to share the same subscription, Azure region
    # and metric namespace.
    $groups = @{}
    foreach ($res in $Resources) {
        $groupKey = "$($res.SubscriptionId)|$($res.Location.ToLowerInvariant())|$($res.Kind)"
        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$groupKey].Add($res)
    }

    # Split each group into chunks of BatchSize to form individual batch API
    # calls — the Batch API has a max of 50 resources per call.
    $batchWorkItems = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $groups.GetEnumerator()) {
        # The group key packs subscription, region and kind.
        $parts = $entry.Key -split '\|'
        $subId    = $parts[0]
        $location = $parts[1]
        $kind     = $parts[2]

        # A kind without a metric configuration has its own algorithm and cannot be batched.
        $config = $KindConfig[$kind]
        if (-not $config) {
            Write-Warning "No batch config for kind '$kind', skipping."
            continue
        }

        # Split the group into chunks of BatchSize resources; each chunk is one batch API call.
        $items = $entry.Value
        for ($i = 0; $i -lt $items.Count; $i += $BatchSize) {
            $batchWorkItems.Add([PSCustomObject]@{
                SubscriptionId = $subId
                Location       = $location
                Kind           = $kind
                Config         = $config
                Resources      = @($items.GetRange($i, [math]::Min($BatchSize, $items.Count - $i)))
            })
        }
    }

    # Describe the plan to the user: how many batches go to which region, kind and subscription.
    $totalResources = $Resources.Count
    $totalBatches   = $batchWorkItems.Count
    $uniqueRegions  = @($groups.Keys | ForEach-Object { ($_ -split '\|')[1] } | Select-Object -Unique | Sort-Object)
    Write-Host "Grouped $totalResources resource(s) into $totalBatches batch(es) across $($uniqueRegions.Count) region(s) (max $BatchSize per batch)."
    $sortedEntries = @($groups.GetEnumerator() | Sort-Object { ($_.Key -split '\|')[1] }, { ($_.Key -split '\|')[2] }, { ($_.Key -split '\|')[0] })
    foreach ($entry in $sortedEntries) {
        # One summary line per group, with the number of calls it needs.
        $parts = $entry.Key -split '\|'
        $subName  = $entry.Value[0].SubscriptionName
        $kind     = Get-ShortKind $parts[2]
        $location = $parts[1]
        $count    = $entry.Value.Count
        # Number of API calls this group needs.
        $chunks   = [math]::Ceiling($count / $BatchSize)
        Write-Host "  $location / $kind / $(Get-TruncatedString $subName 30) : $count resource(s) -> $chunks batch(es)"
    }
    Write-Host ''

    $resultByRes = @{}
    $batchesDone = 0

    # Shared HttpClient for all batch calls — reuses TCP connections.
    $batchHttpClient = [System.Net.Http.HttpClient]::new()
    $batchHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $MetricsToken")
    $batchHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    # Process batches in waves of $ThrottleLimit parallel calls each,
    # with GC between waves to bound memory usage.
    $waveSize = $ThrottleLimit
    for ($waveStart = 0; $waveStart -lt $batchWorkItems.Count; $waveStart += $waveSize) {
        # Slice the next wave and prepare the shared progress counter the runspaces update.
        $waveEnd   = [math]::Min($waveStart + $waveSize, $batchWorkItems.Count)
        $waveItems = @($batchWorkItems[$waveStart..($waveEnd - 1)])
        $waveNum   = [math]::Floor($waveStart / $waveSize) + 1
        $totalWaves = [math]::Ceiling($batchWorkItems.Count / $waveSize)

        $waveProgress = [hashtable]::Synchronized(@{ Done = 0; Total = $waveItems.Count; Base = $batchesDone; Grand = $totalBatches; Waves = $totalWaves; Wave = $waveNum })
        [Console]::Write("`r  Fetching batch metrics: wave $waveNum/$totalWaves, batch $batchesDone/$totalBatches done")

        # Each parallel iteration is one batch call. Runspaces do not see the caller's variables,
        # so everything is passed in through $using:.
        $waveResults = @($waveItems | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        # Unpack the work item and the values shared with the caller.
        $workItem     = $_
        $client       = $using:batchHttpClient
        $startIso     = $using:startIso
        $endIso       = $using:endIso
        $wp           = $using:waveProgress

        # The work item says which subscription, region, kind and resources this call covers.
        $subId    = $workItem.SubscriptionId
        $location = $workItem.Location
        $kind     = $workItem.Kind
        $config   = $workItem.Config
        $resources = $workItem.Resources

        # Only VM values are 0/1; SQL values are percentages (see MetricProcessor).
        $isVm      = $kind -eq 'VirtualMachine'

        $resourceIds = @($resources | ForEach-Object { $_.ResourceId })

        $endpoint = "https://$location.metrics.monitor.azure.com"

        # The Batch API is regional; the time range, namespace, metric and aggregation are query parameters.
        $uri = "$endpoint/subscriptions/$subId/metrics:getBatch" +
               "?starttime=$([uri]::EscapeDataString($startIso))" +
               "&endtime=$([uri]::EscapeDataString($endIso))" +
               "&interval=PT1M" +
               "&metricnamespace=$([uri]::EscapeDataString($config.Namespace))" +
               "&metricnames=$([uri]::EscapeDataString($config.MetricNames))" +
               "&aggregation=$([uri]::EscapeDataString($config.Aggregation))" +
               "&api-version=2023-10-01"

        $bodyJson = @{ resourceids = $resourceIds } | ConvertTo-Json -Compress -Depth 3

        # POST with retry on throttling, server errors and transient transport failures.
        $http = [AzHttp]::Post($client, $uri, $bodyJson)
        $doc  = $http.Doc
        if (-not $doc) {
            $names = ($resources | ForEach-Object { $_.Name }) -join ', '
            Write-Warning "Batch metric query failed for [$names]: $($http.Error)"
        }

        # If the batch call failed entirely, emit placeholder results
        # marking each resource as excluded from availability.
        if (-not $doc) {
            foreach ($resource in $resources) { [MetricResult]::Excluded($resource.ResourceId, $resource.Name) }
            $wp.Done++
            [Console]::Write("`r  Fetching batch metrics: wave $($wp.Wave)/$($wp.Waves), batch $($wp.Base + $wp.Done)/$($wp.Grand) done")
            return
        }

        # Map resource IDs to resource objects for name lookup after processing.
        $resById = @{}
        foreach ($r in $resources) { $resById[$r.ResourceId.ToLowerInvariant()] = $r }

        # Parse the batch response and extract per-resource metric results.
        try {
            $batchResults = [MetricProcessor]::ProcessBatch($doc, $isVm)
            foreach ($br in $batchResults) {
                $resName = $resById[$br.ResourceIdLower]?.Name ?? $br.ResourceId
                [MetricResult]::From($br.ResourceId, $resName, $br.Metrics)
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

        # Force GC between waves to release JSON documents and response
        # buffers — prevents memory from accumulating across large estates.
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
#endregion

#region Get-AvailabilityMetrics
<#
.SYNOPSIS
    Fetches availability metrics one resource at a time through the ARM Metrics API.

.DESCRIPTION
    Runs the calls in parallel with a shared HttpClient (connection pooling) and parses each
    response from the stream with the compiled MetricProcessor. Throttling and transient failures
    are retried; a resource whose query or parsing fails gets an excluded placeholder.

.PARAMETER Resources
    Resource descriptors from Get-ResourceInventory.

.PARAMETER StartDate
    Start of the observation window.

.PARAMETER EndDate
    End of the observation window.

.PARAMETER ThrottleLimit
    Maximum concurrent calls.

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.OUTPUTS
    Hashtable keyed by lowercase resource ID with one MetricResult per resource.
#>
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

    # One shared client for all calls (connection pooling); the token is set once.
    $armHttpClient = [System.Net.Http.HttpClient]::new()
    $armHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $armHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    $done = 0
    $resultByRes = @{}

    # Process each resource in parallel — each iteration builds the ARM
    # Metrics API URL, fetches with retry, and parses via compiled C#.
    $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $resource = $_
        # Runspaces do not see the caller's variables: pass the client and the period through $using:.
        $client   = $using:armHttpClient
        $startIso = ($using:StartDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endIso   = ($using:EndDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $isVm      = $resource.Kind -eq 'VirtualMachine'

        # Look up metric namespace, names, and aggregation for this resource kind
        $kindCfg = ($using:KindConfig)[$resource.Kind]
        $metricNames = $kindCfg.MetricNames
        $agg         = $kindCfg.Aggregation
        $ns          = $kindCfg.Namespace

        # Build ARM Metrics API URL with PT1M granularity over the observation window
        $uri = "https://management.azure.com$($resource.ResourceId)/providers/Microsoft.Insights/metrics?" +
               "api-version=2024-02-01&metricnamespace=$([uri]::EscapeDataString($ns))" +
               "&metricnames=$([uri]::EscapeDataString($metricNames))" +
               "&timespan=$startIso/$endIso&interval=PT1M&aggregation=$agg"

        # GET with retry on throttling, server errors and transient transport failures.
        $http = [AzHttp]::Get($client, $uri)
        $doc  = $http.Doc
        if (-not $doc) { Write-Warning "Metric query failed for '$($resource.Name)': $($http.Error)" }

        # Parse the JSON response via compiled C# MetricProcessor — classifies
        # each per-minute datapoint as available, null, zero, or degraded.
        $m = $null
        if ($doc) {
            try   { $m = [MetricProcessor]::ProcessSingle($doc, $isVm) }
            catch { Write-Warning "Metric processing failed for '$($resource.Name)': $_" }
            finally { $doc.Dispose() }
        }

        # Emit a standardised result object (or an excluded placeholder if the query or parsing failed)
        if ($m) { [MetricResult]::From($resource.ResourceId, $resource.Name, $m) }
        else    { [MetricResult]::Excluded($resource.ResourceId, $resource.Name) }
    # Collect results as they complete, index by lowercase resource ID,
    # and update the progress bar on every 10th resource.
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
#endregion

#region Invoke-SuspectGapInvestigation
<#
.SYNOPSIS
    Classifies every suspect minute of the resources that have any, using Activity Log and Resource Health.

.DESCRIPTION
    For each candidate resource, collects Activity Log lifecycle events and Resource Health history
    and classifies every suspect minute (null, 0% or degraded metric value). Virtual machines and
    Azure SQL databases are the kinds served here; each follows its own algorithm (README, "Algorithms").

    Virtual machines: zero minutes are attributed with the metric's Context dimension, Resource Health
    notes are classified by what they say, platform notes explain minutes only within a bounded window,
    and a gap stays explained by what started it.

    SQL databases: a zero minute is excused inside a resume window, a failover window or a customer or planned
    Resource Health window, is a Fault inside a platform window and is Unresolved otherwise. The minutes in
    which a serverless database is paused (no billed compute) are not Deployment Minutes.

    Resource Health notes come from the REST history and the workspace combined, exactly as for the
    other kinds (see Get-HealthSources). When Log Analytics data is provided, the Activity Log uses
    the pre-fetched events; otherwise it is read per resource from the REST API.

.PARAMETER Candidates
    Resources with at least one suspect minute, with their null, zero and degraded ticks.

.PARAMETER PeriodStart
    Start of the observation window.

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER ThrottleLimit
    Maximum concurrent investigations.

.PARAMETER GraceMinutes
    Grace window after Activity Log lifecycle events.

.PARAMETER FaultWindowMinutes
    How long a platform Resource Health note can explain suspect minutes that the metric itself does
    not attribute (VM algorithm).

.PARAMETER HealthLeadMinutes
    Minutes before a platform Resource Health event that a SQL zero minute is still attributed to it
    (SQL algorithm).

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.PARAMETER HealthCoverageStart
    Start of the period covered by Resource Health history.

.PARAMETER LogAnalyticsData
    Optional output of Get-LogAnalyticsData.

.OUTPUTS
    Hashtable keyed by lowercase resource ID with one classification record per resource.
#>
function Invoke-SuspectGapInvestigation {
    param(
        [object[]]$Candidates,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$ThrottleLimit,
        [int]$GraceMinutes,
        [int]$FaultWindowMinutes = 30,
        [int]$HealthLeadMinutes = 5,
        [string]$ArmToken,
        [DateTimeOffset]$HealthCoverageStart,
        [hashtable]$LogAnalyticsData
    )
    Write-Host "Investigating suspect gaps for $($Candidates.Count) resource(s)..."

    $done = 0
    $total = $Candidates.Count
    $resultByRes = @{}

    $healthSources = Get-HealthSources -LogAnalyticsData $LogAnalyticsData -PeriodEnd $PeriodEnd

    # Shared HttpClient for the REST calls within the parallel block: Resource Health (combined with
    # the workspace history), the metric Context split, and the Activity Log when no workspace is used.
    $gapHttpClient = [System.Net.Http.HttpClient]::new()
    $gapHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $gapHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    $Candidates | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        # Unpack the candidate and the values shared with the caller.
        $c         = $_
        $client      = $using:gapHttpClient
        $pStart      = $using:PeriodStart
        $pEnd        = $using:PeriodEnd
        $graceMin    = $using:GraceMinutes
        $faultWinMin = $using:FaultWindowMinutes
        $leadMin     = $using:HealthLeadMinutes
        $hcStart     = $using:HealthCoverageStart
        $laData      = $using:LogAnalyticsData
        $healthSources = $using:healthSources

        # Pre-fetched Log Analytics data for this resource (if available)
        $resLaData = $null
        if ($laData) {
            $resKey = $c.ResourceId.ToLowerInvariant()
            if ($laData.ContainsKey($resKey)) {
                $resLaData = $laData[$resKey]
            }
        }

        # Functions defined inside the parallel block: runspaces started by ForEach-Object -Parallel
        # do not see the script's functions, so each iteration carries its own copies.

        <#
        .SYNOPSIS
            Sends an ARM GET request and returns the parsed JSON response.
        .DESCRIPTION
            Uses the shared retrying client (AzHttp) and throws when the call fails.
        .PARAMETER uri
            Request URI.
        .PARAMETER httpClient
            Shared HttpClient carrying the bearer token.
        .OUTPUTS
            PSCustomObject - the response body (timestamps kept as strings).
        #>
        function script:GetArmJson([string]$uri, [System.Net.Http.HttpClient]$httpClient) {
            $http = [AzHttp]::Get($httpClient, $uri)
            if (-not $http.Doc) { throw "GET failed: $($http.Error)" }
            try   { $http.Doc.RootElement.GetRawText() | ConvertFrom-Json -DateKind String }
            finally { $http.Doc.Dispose() }
        }

        <#
        .SYNOPSIS
            Truncates a DateTimeOffset to the minute boundary.
        .PARAMETER v
            Timestamp to truncate.
        .OUTPUTS
            System.DateTimeOffset (UTC, seconds = 0).
        #>
        function script:TruncMin([DateTimeOffset]$v) {
            [DateTimeOffset]::new($v.Year, $v.Month, $v.Day, $v.Hour, $v.Minute, 0, [TimeSpan]::Zero)
        }

        <#
        .SYNOPSIS
            Sorts intervals by start and merges the ones that overlap or touch.
        .PARAMETER intervals
            Objects with From, To, FromTicks and ToTicks.
        .OUTPUTS
            PSCustomObject[] - the merged, non-overlapping intervals.
        #>
        function script:MergeIntervals([object[]]$intervals) {
            if ($intervals.Count -le 1) { return $intervals }
            $sorted = @($intervals | Sort-Object FromTicks)
            $merged = [System.Collections.Generic.List[object]]::new()
            $merged.Add($sorted[0])
            # Extend the last merged interval while the next one starts inside it or touches it.
            for ($i = 1; $i -lt $sorted.Count; $i++) {
                $last = $merged[$merged.Count - 1]
                if ($sorted[$i].FromTicks -le $last.ToTicks) {
                    if ($sorted[$i].ToTicks -gt $last.ToTicks) {
                        $last.ToTicks = $sorted[$i].ToTicks
                        $last.To = $sorted[$i].To
                    }
                } else { $merged.Add($sorted[$i]) }
            }
            @($merged)
        }

        <#
        .SYNOPSIS
            Builds the windows of the operations of an Azure SQL database (auto-resume, failover) from their Activity Log events.
        .DESCRIPTION
            Events are grouped into one window per operation by proximity, not by correlation ID: the
            platform logs the resume of a paused serverless database with an all-zero correlation ID, so
            grouping by it would join every resume of the period into one window. Consecutive events
            at most 5 minutes apart belong to the same operation (a window never exceeds 15 minutes), and
            a failed operation leaves a lone Started event that explains a single minute. A window runs
            from the minute of its first event to one minute after the minute of its last event, which
            covers the first failed connections and the minute the resume completes.
        .PARAMETER Events
            Activity Log events (Timestamp) of the resume operation.
        .OUTPUTS
            PSCustomObject[] with From, To, FromTicks and ToTicks, merged and clamped to the period.
        #>
        function script:NewResumeIntervals($Events) {
            $intervals = [System.Collections.Generic.List[object]]::new()
            $first = $null; $last = $null
            # Closes the open window: first event's minute to two minutes after the last event's minute, clamped to the period.
            $close = {
                $from = TruncMin $first
                $to   = (TruncMin $last).AddMinutes(2)
                if ($from -lt $pStart) { $from = $pStart }
                if ($to -gt $pEnd)     { $to = $pEnd }
                if ($to -gt $from) {
                    $intervals.Add([PSCustomObject]@{ From = $from; To = $to; FromTicks = $from.UtcTicks; ToTicks = $to.UtcTicks })
                }
            }
            # Start a new window when the gap exceeds 5 minutes or the window would exceed 15 minutes.
            foreach ($evt in ($Events | Sort-Object Timestamp)) {
                if ($first -and (($evt.Timestamp - $last).TotalMinutes -gt 5 -or ($evt.Timestamp - $first).TotalMinutes -gt 15)) {
                    & $close; $first = $null
                }
                if (-not $first) { $first = $evt.Timestamp }
                $last = $evt.Timestamp
            }
            if ($first) { & $close }
            MergeIntervals @($intervals)
        }
        # Checks Activity Log for events that explain metric gaps:
        #   a) Resource creation/deletion — the creation time establishes initial
        #      existence; delete→write cycles establish later non-existence.
        #   b) Kind-specific lifecycle operations (VM start/deallocate/poweroff/restart,
        #      SQL resume).
        # When Log Analytics data is available, use pre-fetched events; otherwise call
        # the Activity Log REST API per-resource.
        $activityIntervals = @()
        # The VM algorithm needs lifecycle and non-existence intervals separately: a measured
        # zero is attributed before lifecycle windows are consulted.
        $lifecycleIntervals    = @()
        $nonExistenceIntervals = @()
        # SQL: the failover windows of the customer's own operations (the resume windows are the lifecycle ones).
        $operationIntervals    = @()
        if ($c.AllGapTicks.Count -gt 0 -or $c.Kind -eq 'AzureSqlDatabase') {
            try {
                # VM lifecycle: each operation explains the minutes around it, with the grace window.
                $vmRules = @(
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/start/action', 'start virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/deallocate/action', 'deallocate virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/poweroff/action', 'power off virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/restart/action', 'restart virtual machine') }
                )
                # SQL lifecycle: the resume of a paused serverless database explains failed connections, and so does
                # a failover started by the customer (the SLA excludes the customer's own operations).
                # No zero minute was ever explained by a pause alone, so pause events are not used.
                $sqlRules = @(
                    @{ ApplyGrace = $false; Tokens = @('microsoft.sql/servers/databases/resume', 'resume sql database', 'resume database') }
                    @{ ApplyGrace = $false; Tokens = @('microsoft.sql/servers/databases/failover', 'failover sql database') }
                )
                $rules = switch ($c.Kind) {
                    'VirtualMachine'   { $vmRules }
                    'AzureSqlDatabase' { $sqlRules }
                    default            { @() }
                }

                $events = [System.Collections.Generic.List[object]]::new()

                # Resource creation/deletion tokens — derived from the metric namespace of the kind
                # (e.g. 'microsoft.compute/virtualmachines/write', '.../delete').
                # Used to build non-existence intervals where the resource did not exist:
                # before the first write, between delete→write pairs, and after a
                # trailing delete.
                $createToken = (($using:KindConfig)[$c.Kind].Namespace + '/write').ToLowerInvariant()
                $deleteToken = (($using:KindConfig)[$c.Kind].Namespace + '/delete').ToLowerInvariant()
                $existenceEvents = [System.Collections.Generic.List[object]]::new()

                <#
                .SYNOPSIS
                    Routes one Activity Log event to the existence and lifecycle lists.
                .DESCRIPTION
                    Creation (write) and deletion events feed the existence tracking; an event matching a
                    lifecycle rule of the resource kind is kept, with the grace window of its rule, for the
                    interval building below. Reads the enclosing scope's rules, tokens and event lists.
                .PARAMETER OperationKey
                    Operation name of the event (operation value, or its localized label).
                .PARAMETER Timestamp
                    When the event happened.
                .PARAMETER CorrelationId
                    Correlation ID that ties together the events of one operation.
                #>
                function script:AddActivityEvent([string]$OperationKey, [DateTimeOffset]$Timestamp, [string]$CorrelationId) {
                    $normalized = $OperationKey.ToLowerInvariant()

                    if ($normalized.Contains($createToken)) {
                        $existenceEvents.Add([PSCustomObject]@{ Timestamp = $Timestamp; Type = 'Write' })
                    }
                    elseif ($normalized.Contains($deleteToken)) {
                        $existenceEvents.Add([PSCustomObject]@{ Timestamp = $Timestamp; Type = 'Delete' })
                    }

                    # The first rule whose token matches keeps the event, with the grace window of that rule.
                    foreach ($rule in $rules) {
                        foreach ($token in $rule.Tokens) {
                            if (-not $normalized.Contains($token)) { continue }
                            $events.Add([PSCustomObject]@{
                                Timestamp     = $Timestamp
                                OperationKey  = $OperationKey
                                CorrelationId = $CorrelationId
                                GraceMinutes  = $rule.ApplyGrace ? $graceMin : 0
                            })
                            return
                        }
                    }
                }

                # Unlike the generic ARM write operation, the creation time of a VM or SQL database
                # is authoritative creation evidence for its current incarnation.
                if ($c.Kind -in 'VirtualMachine', 'AzureSqlDatabase' -and $null -ne $c.CreationTime) {
                    $existenceEvents.Add([PSCustomObject]@{
                        Timestamp = [DateTimeOffset]$c.CreationTime
                        Type      = 'Created'
                    })
                }

                if ($resLaData -and $resLaData.ActivityEvents.Count -gt 0) {
                    # ── Log Analytics path: use pre-fetched events ────
                    foreach ($laEvt in $resLaData.ActivityEvents) {
                        if (-not $laEvt.OperationName) { continue }
                        AddActivityEvent ([string]$laEvt.OperationName) $laEvt.Timestamp ([string]$laEvt.CorrelationId)
                    }
                } elseif (-not $laData) {
                    # ── REST API path: no workspace, read the Activity Log of this resource ──
                    # Page through the Activity Log of the resource, filtered by time and resource.
                    $filter = "eventTimestamp ge '$($pStart.ToString('O'))' and eventTimestamp le '$($pEnd.ToString('O'))' and resourceUri eq '$($c.ResourceId)'"
                    $select = 'eventTimestamp,operationName,correlationId,status'
                    $url = "https://management.azure.com/subscriptions/$($c.SubscriptionId)" +
                           "/providers/microsoft.insights/eventtypes/management/values" +
                           "?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))" +
                           "&`$select=$([uri]::EscapeDataString($select))"

                    # The API returns pages: keep reading until there is no next link, then route the events.
                    $restEvents = [System.Collections.Generic.List[ActivityEvent]]::new()
                    while ($url) {
                        $http = [AzHttp]::Get($client, $url)
                        if (-not $http.Doc) { throw $http.Error }
                        try   { $url = [ActivityLogParser]::ReadPage($http.Doc, $restEvents) }
                        finally { $http.Doc.Dispose() }
                    }
                    foreach ($e in $restEvents) {
                        AddActivityEvent $e.Operation ([DateTimeOffset]::new($e.Ticks, [TimeSpan]::Zero)) $e.CorrelationId
                    }
                }

                # Build time intervals from events. SQL resume and failover events become one window per operation
                # (see NewResumeIntervals), kept apart so that the two can be told in the report. The other kinds group events by operation+correlationId
                # so that events belonging to the same action collapse into a single interval.
                # Compute from/to per group, apply the grace window for
                # operations that have trailing transition time, then merge overlaps.
                if ($c.Kind -eq 'AzureSqlDatabase') {
                    $activityIntervals  = NewResumeIntervals @($events | Where-Object { $_.OperationKey -match 'resume' })
                    $operationIntervals = NewResumeIntervals @($events | Where-Object { $_.OperationKey -match 'failover' })
                }
                elseif ($events.Count -gt 0) {
                    # Group events by operation key + correlation ID.  Events without
                    # a correlation ID are grouped by their truncated timestamp.
                    $groups = @{}
                    foreach ($evt in $events) {
                        $corrPart = if ($evt.CorrelationId) { $evt.CorrelationId }
                                    else { (TruncMin $evt.Timestamp).ToString('O') }
                        $gk = "$($evt.OperationKey)|$corrPart"
                        if (-not $groups.ContainsKey($gk)) { $groups[$gk] = [System.Collections.Generic.List[object]]::new() }
                        $groups[$gk].Add($evt)
                    }

                    # For each correlated group, compute an interval from the
                    # earliest event to the latest event + 1 min + grace window.
                    # Clamp to the observation period boundaries.
                    $rawIntervals = [System.Collections.Generic.List[object]]::new()
                    foreach ($group in $groups.Values) {
                        $minTs = ($group | ForEach-Object { $_.Timestamp } | Measure-Object -Minimum).Minimum
                        $maxTs = ($group | ForEach-Object { $_.Timestamp } | Measure-Object -Maximum).Maximum
                        $maxGr = ($group | ForEach-Object { $_.GraceMinutes } | Measure-Object -Maximum).Maximum

                        # One interval per group: first event's minute to the last event's minute, plus one minute and the grace.
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

                    # Merge overlapping/adjacent intervals so that overlapping
                    # lifecycle events don't double-count.
                    $activityIntervals = MergeIntervals $rawIntervals
                }

                # Build non-existence intervals from resource creation/deletion
                # events. Walk events chronologically as a state machine:
                #   Created → authoritative VM creation timestamp
                #   Write   → recreation only after a confirmed Delete
                #   Delete → resource destroyed (non-existence begins)
                # Non-existence intervals cover:
                #   - periodStart → VM timeCreated (when no prior incarnation is seen)
                #   - Delete → next Write (destroy/recreate cycle)
                #   - last Delete → periodEnd (resource deleted, not recreated)
                $lifecycleIntervals = @($activityIntervals)
                if ($existenceEvents.Count -gt 0) {
                    $sortedExEvts = $existenceEvents | Sort-Object Timestamp
                    $nonExistIntervals = [System.Collections.Generic.List[object]]::new()
                    # Initial state: existing when created before the period, absent when created inside it
                    # (unless a delete came first), otherwise unknown.
                    $createdEvent = $sortedExEvts | Where-Object { $_.Type -eq 'Created' } | Select-Object -First 1
                    $deleteBeforeCreation = $createdEvent -and ($sortedExEvts | Where-Object {
                        $_.Type -eq 'Delete' -and $_.Timestamp -lt $createdEvent.Timestamp
                    } | Select-Object -First 1)
                    $exState = if ($createdEvent -and $createdEvent.Timestamp -le $pStart) {
                        'exists'
                    } elseif ($createdEvent -and -not $deleteBeforeCreation) {
                        'not-exists'
                    } else {
                        'unknown'
                    }
                    # Non-existence runs from the start of the period when the resource was created inside it.
                    $nonExistStart = $null   # timestamp where non-existence began
                    $absenceEstablishedByDelete = $false
                    if ($exState -eq 'not-exists') { $nonExistStart = $pStart }

                    # Replay the events in time order.
                    foreach ($exEvt in $sortedExEvts) {
                        if ($exEvt.Type -eq 'Created' -or $exEvt.Type -eq 'Write') {
                            $isAuthoritativeCreation = $exEvt.Type -eq 'Created'
                            if ($exState -eq 'not-exists' -and
                                ($isAuthoritativeCreation -or $absenceEstablishedByDelete)) {
                                # Resource came into existence — close non-existence interval
                                $nFrom = if ($nonExistStart) { TruncMin $nonExistStart } else { $pStart }
                                $nTo   = (TruncMin $exEvt.Timestamp).AddMinutes(1 + $graceMin)
                                if ($nFrom -lt $pStart) { $nFrom = $pStart }
                                if ($nTo -gt $pEnd)     { $nTo = $pEnd }
                                if ($nTo -gt $nFrom) {
                                    $nonExistIntervals.Add([PSCustomObject]@{
                                        From = $nFrom; To = $nTo
                                        FromTicks = $nFrom.UtcTicks; ToTicks = $nTo.UtcTicks
                                    })
                                }
                                $exState = 'exists'
                                $nonExistStart = $null
                                $absenceEstablishedByDelete = $false
                            }
                            # A write while state is exists or unknown is only an update.
                        }
                        elseif ($exEvt.Type -eq 'Delete') {
                            $exState = 'not-exists'
                            $nonExistStart = $exEvt.Timestamp
                            $absenceEstablishedByDelete = $true
                        }
                    }

                    # If resource was deleted and not recreated, non-existence extends to period end
                    if ($exState -eq 'not-exists' -and $null -ne $nonExistStart) {
                        $nFrom = TruncMin $nonExistStart
                        if ($nFrom -lt $pStart) { $nFrom = $pStart }
                        if ($pEnd -gt $nFrom) {
                            $nonExistIntervals.Add([PSCustomObject]@{
                                From = $nFrom; To = $pEnd
                                FromTicks = $nFrom.UtcTicks; ToTicks = $pEnd.UtcTicks
                            })
                        }
                    }

                    # Merge non-existence intervals with lifecycle activity intervals
                    $nonExistenceIntervals = @($nonExistIntervals)
                    if ($nonExistIntervals.Count -gt 0) {
                        $activityIntervals = MergeIntervals (@($activityIntervals) + @($nonExistIntervals))
                    }
                }
            }
            catch {
                Write-Warning "Activity Log query failed for '$($c.Name)': $_"
            }
        }

        # Both algorithms read the same combined history (Get-HealthSources, HealthHistory.Collect): the
        # REST history plus, with a workspace, the Activity Log events. VMs classify each note, SQL
        # databases turn the notes into impact windows. It is skipped when the period lies entirely
        # outside the coverage of the available sources.
        $healthHistoryApplied = [DateTimeOffset]$hcStart -lt [DateTimeOffset]$pEnd
        # Classified Resource Health notes (UTC ticks + class) used by the VM algorithm.
        $vmEntries = [System.Collections.Generic.List[object]]::new()
        # Impact windows built from the combined history, used by the SQL algorithm.
        $healthWindows = @()

        if ($healthHistoryApplied) {
            try {
                # One combined history (REST + workspace) per resource.
                $fetch = [HealthHistory]::Collect($client, $c.ResourceId,
                    $healthSources.WorkspaceNotes[$c.ResourceId.ToLowerInvariant()], $healthSources.UseRest)
                if ($fetch.Error) { Write-Warning "Resource Health query failed for '$($c.Name)': $($fetch.Error)" }
                # VMs classify each note by what it says; SQL databases turn the notes into impact windows.
                if ($c.Kind -eq 'VirtualMachine') {
                    foreach ($note in $fetch.Notes) {
                        $vmEntries.Add([PSCustomObject]@{
                            Ticks = $note.Ticks
                            Title = $note.Title
                            Class = [VmHealthClassifier]::Classify($note.Title, $note.State, $note.Customer, $note.Reason)
                        })
                    }
                }
                else {
                    $healthWindows = @([HealthHistory]::BuildWindows($fetch.Notes, 30 * 600000000L, 2 * 600000000L))
                }
            }
            catch {
                Write-Warning "Resource Health query failed for '$($c.Name)': $_"
            }
        }

        # Virtual machines and SQL databases each follow their own algorithm (README, "Algorithms").
        # Both fill $cr (counts per outcome), $outcomeText (one-line summary) and $evidence.
        $outcomeText  = $null
        $outcomeLabel = $null
        # The spans of minutes that count against availability (VMs only; SQL lists its minutes as evidence).
        $lossSpans    = @()
        # The counted zero minutes of a SQL database with their connection detail (the same purpose).
        $lossMinutes  = @()
        $evidence     = [System.Collections.Generic.List[string]]::new()

        if ($c.Kind -eq 'VirtualMachine') {
            # Who caused each zero minute: a second metric call split by the Context
            # dimension (Platform / User / Unknown). Without it, zeros stay Unknown.
            $zeroTicks = [long[]]@($c.ZeroTicksArray)
            # Every zero starts as Unknown (8) until the Context split says otherwise.
            $zeroMasks = [int[]]::new($zeroTicks.Length)
            for ($i = 0; $i -lt $zeroMasks.Length; $i++) { $zeroMasks[$i] = 8 }
            if ($zeroTicks.Length -gt 0) {
                try {
                    # A second call splits the metric by its Context dimension (Platform / User / Unknown).
                    $ctxUrl = "https://management.azure.com$($c.ResourceId)/providers/Microsoft.Insights/metrics?" +
                              'api-version=2024-02-01&metricnamespace=Microsoft.Compute%2FvirtualMachines' +
                              '&metricnames=VmAvailabilityMetric&interval=PT1M&aggregation=Minimum' +
                              "&timespan=$($pStart.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($pEnd.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))" +
                              '&$filter=' + [uri]::EscapeDataString("Context eq '*'")
                    $ctxHttp = [AzHttp]::Get($client, $ctxUrl)
                    if (-not $ctxHttp.Doc) { throw $ctxHttp.Error }
                    try { $zeroMasks = [VmGapClassifier]::GetZeroMasks($ctxHttp.Doc, $zeroTicks) }
                    finally { $ctxHttp.Doc.Dispose() }
                }
                catch {
                    Write-Warning "Metric Context query failed for '$($c.Name)'; zero minutes treated as Unknown: $_"
                }
            }

            # Health notes in time order; lifecycle and non-existence intervals as tick pairs.
            $sortedNotes = @($vmEntries | Sort-Object Ticks)
            $lcFrom = [long[]]@($lifecycleIntervals    | ForEach-Object { $_.FromTicks })
            $lcTo   = [long[]]@($lifecycleIntervals    | ForEach-Object { $_.ToTicks })
            $nxFrom = [long[]]@($nonExistenceIntervals | ForEach-Object { $_.FromTicks })
            $nxTo   = [long[]]@($nonExistenceIntervals | ForEach-Object { $_.ToTicks })

            # Run the compiled VM algorithm over every suspect minute of the VM.
            $vr = [VmGapClassifier]::Classify(
                [long[]]@($c.NullTicksArray), $zeroTicks, $zeroMasks,
                $lcFrom, $lcTo, $nxFrom, $nxTo,
                [long[]]@($sortedNotes | ForEach-Object { $_.Ticks }),
                [int[]]@($sortedNotes  | ForEach-Object { $_.Class }),
                [string[]]@($sortedNotes | ForEach-Object { $_.Title }),
                ([long]$faultWinMin * 600000000L))

            # Map outcomes to the record the final assembly step consumes:
            #   1,2 platform fault | 3,5 lifecycle | 4,6,7,8,9,12 explained | 10 metric gap | 11 unresolved
            $gap = $vr.GapCounts
            $lossSpans = @($vr.LossSpans)
            $cr = [PSCustomObject]@{
                PlatformFaultGapMin          = $gap[1] + $gap[2]
                ActivityLogExcludedGapMin    = $gap[3] + $gap[5]
                HealthExplainedGapMin        = $gap[4] + $gap[6] + $gap[7] + $gap[8] + $gap[9] + $gap[12]
                MetricIssueNullMin           = $gap[10]
                UnresolvedZeroDowntimeMin    = $gap[11]
                # Every excused VM minute leaves the Maximum Available Minutes (the VM is not running, or did not exist).
                EligibleReductionMin         = $gap[3] + $gap[5] + $gap[4] + $gap[6] + $gap[7] + $gap[8] + $gap[9] + $gap[12] + $gap[10]
                EligibleReductions           = @(
                    if ($gap[3] + $gap[5] -gt 0) { "$($gap[3] + $gap[5]) gap min excluded by Activity Log" }
                    if ($gap[4] + $gap[6] + $gap[7] + $gap[8] + $gap[9] + $gap[12] -gt 0) {
                        "$($gap[4] + $gap[6] + $gap[7] + $gap[8] + $gap[9] + $gap[12]) gap min excluded by Health History"
                    }
                    if ($gap[10] -gt 0) { "$($gap[10]) null suspect min treated as metric issues" }
                )
            }

            # One-line breakdown of what decided the suspect minutes, for the console narration.
            $outcomeNames = 'platform fault (metric Context)', 'platform fault (health note)', 'before creation',
                'customer (metric Context)', 'lifecycle operation', 'customer (health note)', 'planned maintenance',
                'spot eviction', 'health unknown', 'metric gap', 'unresolved 0%', 'continues customer stop'
            $outcomeLabel = 'VM algorithm'
            $outcomeText = (@(foreach ($k in 1..12) {
                $n = $gap[$k]
                if ($n -gt 0) { "$($outcomeNames[$k - 1]) $n" }
            })) -join '; '
        }
        elseif ($c.Kind -eq 'AzureSqlDatabase') {
            # SQL algorithm (README, "Algorithms > Azure SQL databases"). The metric is 0 when every connection of
            # the minute failed with a system error and 100 otherwise (never null in practice), so a zero minute
            # is the only downtime signal. Decision order for a zero minute:
            #   before creation -> excused; inside a resume window -> excused (auto-resume is by design);
            #   inside a failover window of the customer -> excused; inside a customer health window -> excused;
            #   inside a planned-maintenance health window -> excused (Scheduled Downtime);
            #   inside a platform health window -> Fault; anything else -> Unresolved.
            # A null minute is a metric gap unless creation or a resume explains it.
            # The excused minutes stay in the Deployment Minutes (the SLA excludes them from Downtime only); the
            # minutes before creation and, for a serverless database, the paused minutes are not Deployment Minutes.
            $tpm = 600000000L
            $leadTicks  = $leadMin * $tpm
            $graceTicks = 2 * $tpm
            # True when the minute lies inside any of the given intervals.
            $inAny = {
                param($list, [long]$t)
                foreach ($w in $list) { if ($t -ge $w.FromTicks -and $t -lt $w.ToTicks) { return $true } }
                $false
            }
            $lifecycle = @($lifecycleIntervals)
            $operation = @($operationIntervals)
            $nonExist  = @($nonExistenceIntervals)
            $n = @{ NotExists = 0; Resume = 0; Operation = 0; Customer = 0; Scheduled = 0; Fault = 0; Unresolved = 0; Gap = 0 }
            $badMinutes = [System.Collections.Generic.List[object]]::new()   # Fault and Unresolved minutes, for the evidence
            # The minutes already removed as "before creation", so that the paused minutes do not count them again.
            $notExistTicks = [System.Collections.Generic.HashSet[long]]::new()

            foreach ($t in [long[]]@($c.ZeroTicksArray)) {
                # Zero minute: apply the decision order described above.
                if (& $inAny $nonExist $t)  { $n.NotExists++; [void]$notExistTicks.Add($t); continue }
                if (& $inAny $lifecycle $t) { $n.Resume++; continue }
                if (& $inAny $operation $t) { $n.Operation++; continue }
                $win = $null
                foreach ($w in $healthWindows) {
                    if ($t -ge $w.Start - $leadTicks -and $t -le $w.End + $graceTicks) { $win = $w; break }
                }
                if ($win -and $win.Customer) { $n.Customer++ }
                elseif ($win -and $win.Planned) { $n.Scheduled++ }
                elseif ($win) { $n.Fault++;      $badMinutes.Add([PSCustomObject]@{ Ticks = $t; Verdict = 'Fault'; Title = $win.Title }) }
                else          { $n.Unresolved++; $badMinutes.Add([PSCustomObject]@{ Ticks = $t; Verdict = 'Unresolved'; Title = '' }) }
            }
            # Null minute: excused by creation or a resume, otherwise a metric gap.
            foreach ($t in [long[]]@($c.NullTicksArray)) {
                if (& $inAny $nonExist $t)  { $n.NotExists++; [void]$notExistTicks.Add($t) }
                elseif (& $inAny $lifecycle $t) { $n.Resume++ }
                else { $n.Gap++ }
            }

            # Serverless: a paused database is not operational, so its minutes are not Deployment Minutes. A paused
            # database bills nothing and app_cpu_billed has no value for its minutes. The zero minutes that count
            # against availability stay in the Deployment Minutes, so a failure never hides as a pause.
            $pausedMin = 0
            if ($c.SkuName -match '_S_') {
                $nMin = [int]($pEnd - $pStart).TotalMinutes
                $startTicks = $pStart.UtcTicks
                $billed = [bool[]]::new($nMin)
                # Spans of 10 days; MetricSpans splits a span that the service refuses as too large.
                $spanBounds = [System.Collections.Generic.List[long]]::new()
                for ($m = 0; $m -lt $nMin; $m += 14400) {
                    $spanBounds.Add($startTicks + $m * $tpm)
                    $spanBounds.Add($startTicks + [math]::Min($m + 14400, $nMin) * $tpm)
                }
                $billedUri = "https://management.azure.com$($c.ResourceId)/providers/Microsoft.Insights/metrics?api-version=2024-02-01" +
                             '&metricnamespace=Microsoft.Sql%2Fservers%2Fdatabases&metricnames=app_cpu_billed&aggregation=Total&interval=PT1M'
                $billedError = [MetricSpans]::Read($client, $billedUri, $spanBounds.ToArray(), [Action[System.Text.Json.JsonDocument]]{
                    param($doc) [ServerlessParser]::AddBilledMinutes($doc, $startTicks, $billed)
                })
                if ($billedError) { Write-Warning "Billed-compute metric failed for '$($c.Name)'; paused minutes stay eligible: $billedError" }
                else {
                    $counted = [System.Collections.Generic.HashSet[long]]::new($notExistTicks)
                    foreach ($b in $badMinutes) { [void]$counted.Add([long]$b.Ticks) }
                    # The latest minutes of a period that ends now have no data yet: they are not judged.
                    $limit = $pEnd -gt [DateTimeOffset]::UtcNow.AddMinutes(-15) ? $nMin - 15 : $nMin
                    # A pause lasts many minutes; a shorter run without data is a hole in the telemetry, not a pause.
                    $run = 0; $runPaused = 0
                    for ($i = 0; $i -le $limit; $i++) {
                        if ($i -lt $limit -and -not $billed[$i]) {
                            $run++
                            if (-not $counted.Contains($startTicks + $i * $tpm)) { $runPaused++ }
                        }
                        else {
                            if ($run -ge 5) { $pausedMin += $runPaused }
                            $run = 0; $runPaused = 0
                        }
                    }
                }
            }

            # The same record shape as the VM branch, so Step 7 treats both kinds alike. Only the minutes before
            # creation and the paused ones leave the Deployment Minutes.
            $cr = [PSCustomObject]@{
                PlatformFaultGapMin          = $n.Fault
                ActivityLogExcludedGapMin    = $n.NotExists + $n.Resume + $n.Operation
                HealthExplainedGapMin        = $n.Customer + $n.Scheduled
                MetricIssueNullMin           = $n.Gap
                UnresolvedZeroDowntimeMin    = $n.Unresolved
                EligibleReductionMin         = $n.NotExists + $pausedMin
                EligibleReductions           = @(
                    if ($n.NotExists -gt 0) { "$($n.NotExists) min before creation" }
                    if ($pausedMin   -gt 0) { "$pausedMin min paused (no billed compute)" }
                )
            }
            # One-line summary of what decided the suspect minutes, for the console narration.
            $outcomeLabel = 'SQL algorithm'
            $outcomeText = (@(
                if ($n.NotExists   -gt 0) { "before creation $($n.NotExists)" }
                if ($n.Resume      -gt 0) { "auto-resume $($n.Resume)" }
                if ($n.Operation   -gt 0) { "customer failover $($n.Operation)" }
                if ($n.Customer    -gt 0) { "customer (health note) $($n.Customer)" }
                if ($n.Scheduled   -gt 0) { "planned maintenance (health note) $($n.Scheduled)" }
                if ($n.Fault       -gt 0) { "platform fault (health note) $($n.Fault)" }
                if ($n.Gap         -gt 0) { "metric gap $($n.Gap)" }
                if ($n.Unresolved  -gt 0) { "unresolved 0% $($n.Unresolved)" }
            )) -join '; '

            # What the failed connections were, for the minutes that count against availability: the error
            # codes of connection_failed and the successful connections of the same minute. One pair of calls
            # per day that has such minutes (at most 6 days).
            if ($badMinutes.Count -gt 0) {
                # Detail per minute (keyed by its ticks): the error codes and the successful connections.
                $detail = @{}
                $days = @($badMinutes | ForEach-Object { [long][math]::Floor($_.Ticks / 864000000000L) } | Sort-Object -Unique | Select-Object -First 6)
                foreach ($day in $days) {
                    # One call per day keeps each response small; the day starts at midnight UTC.
                    $dayStart = [DateTime]::new($day * 864000000000L, [DateTimeKind]::Utc)
                    $base = "https://management.azure.com$($c.ResourceId)/providers/Microsoft.Insights/metrics?api-version=2024-02-01" +
                            '&metricnamespace=Microsoft.Sql%2Fservers%2Fdatabases&aggregation=Total&interval=PT1M' +
                            "&timespan=$($dayStart.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($dayStart.AddDays(1).ToString('yyyy-MM-ddTHH:mm:ssZ'))"
                    try {
                        # connection_failed is split by its Error dimension; connection_successful is one series.
                        $failedResp = GetArmJson ($base + '&metricnames=connection_failed&$filter=' + [uri]::EscapeDataString("Error eq '*'")) $client
                        $okResp     = GetArmJson ($base + '&metricnames=connection_successful') $client
                    }
                    catch { Write-Warning "SQL connection metrics failed for '$($c.Name)': $_"; continue }
                    # Failed connections: one series per error code; keep them per minute.
                    foreach ($series in $failedResp.value[0].timeseries) {
                        $code = ($series.metadatavalues | Where-Object { $_.name.value -eq 'error' }).value
                        # The index of a data point is its minute within the day.
                        for ($i = 0; $i -lt $series.data.Count; $i++) {
                            $v = $series.data[$i].PSObject.Properties['total']
                            if ($v -and $v.Value -gt 0) {
                                $key = $dayStart.Ticks + $i * $tpm
                                if (-not $detail.ContainsKey($key)) { $detail[$key] = @{ Errors = @(); Ok = 0 } }
                                $detail[$key].Errors += "$code x$($v.Value)"
                            }
                        }
                    }
                    # Successful connections of the same minutes (attached to the minutes that had failures).
                    $okData = $okResp.value[0].timeseries[0].data
                    for ($i = 0; $i -lt $okData.Count; $i++) {
                        $v = $okData[$i].PSObject.Properties['total']
                        if ($v -and $v.Value -gt 0) {
                            $key = $dayStart.Ticks + $i * $tpm
                            if ($detail.ContainsKey($key)) { $detail[$key].Ok = $v.Value }
                        }
                    }
                }
                # One evidence line for each of the first five minutes that count.
                foreach ($b in ($badMinutes | Select-Object -First 5)) {
                    $d = $detail[[long]$b.Ticks]
                    $what = $d ? "$($d.Errors -join ', ') failed connection(s), $($d.Ok) successful" : 'no connection metric data for the minute'
                    $why  = $b.Verdict -eq 'Fault' ? "Resource Health '$($b.Title)'" : 'no Resource Health event'
                    $evidence.Add("minute $([DateTime]::new([long]$b.Ticks, [DateTimeKind]::Utc).ToString('u')): $what -> $($b.Verdict) ($why)")
                }
                if ($badMinutes.Count -gt 5) { $evidence.Add("... and $($badMinutes.Count - 5) more minute(s) counted against availability") }

                # The minutes that count with the failed and successful connections of each, for the "most impact"
                # report (the detail exists only for the days that were queried).
                $lossMinutes = @(foreach ($b in $badMinutes) {
                    $d = $detail[[long]$b.Ticks]
                    [PSCustomObject]@{
                        Ticks = $b.Ticks; Verdict = $b.Verdict; Title = $b.Title
                        HasDetail = [bool]$d; Errors = $d ? @($d.Errors) : @(); Ok = $d ? $d.Ok : 0
                    }
                })
            }

            # Resource Health platform events that produced no zero minute and are not an auto-resume: brief
            # failures (Resource Health reports about two seconds) that the metric does not count, because
            # at least one connection succeeded in the minute.
            $briefEvents = 0
            $zeroTicksAll = [long[]]@($c.ZeroTicksArray)
            foreach ($w in $healthWindows) {
                # A brief event is a platform event inside the period that overlaps neither a resume nor a zero minute.
                if ($w.Customer -or $w.Planned -or $w.End -lt $pStart.UtcTicks -or $w.Start -ge $pEnd.UtcTicks) { continue }
                $from = $w.Start - $leadTicks; $to = $w.End + $graceTicks
                # A resume or failover that overlaps the event explains it; a zero minute inside it means the metric did count it.
                $overlapsResume = $false
                foreach ($r in @($lifecycle) + @($operation)) { if ($r.FromTicks -lt $to -and $r.ToTicks -gt $from) { $overlapsResume = $true; break } }
                if ($overlapsResume) { continue }
                $hasZero = $false
                foreach ($t in $zeroTicksAll) { if ($t -ge $from -and $t -le $to) { $hasZero = $true; break } }
                if (-not $hasZero) { $briefEvents++ }
            }
            if ($briefEvents -gt 0) {
                $evidence.Add("$briefEvents Resource Health platform event(s) without a zero minute: brief failures that the metric does not count (some connections succeeded in the minute)")
            }
        }

        # Emit the classification result for this resource — will be wired
        # into the eligibility record in Step 7 of the main pipeline.
        [PSCustomObject]@{
            ResourceId                        = $c.ResourceId
            ActivityLogExcludedGapMinutes     = $cr.ActivityLogExcludedGapMin
            HealthExplainedGapMinutes         = $cr.HealthExplainedGapMin
            MetricIssueNullMinutes            = $cr.MetricIssueNullMin
            PlatformFaultGapMinutes           = $cr.PlatformFaultGapMin
            UnresolvedZeroDowntimeMinutes     = $cr.UnresolvedZeroDowntimeMin
            EligibleReductionMinutes          = $cr.EligibleReductionMin
            EligibleReductions                = @($cr.EligibleReductions)
            OutcomeText                       = $outcomeText
            OutcomeLabel                      = $outcomeLabel
            LossSpans                         = $lossSpans
            LossMinutes                       = $lossMinutes
            Evidence                          = @($evidence)
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
    $gapHttpClient.Dispose()
    $resultByRes
}
#endregion

#region Storage algorithm
# Storage accounts do not use the PT1M Availability metric: its Minimum is the worst single
# ApiName/Authentication/GeoType series of the minute, so one failed request can cost a full minute.
# Instead the score follows the Azure Storage SLA: the Error Rate of an hour is failed / Total Storage
# Transactions over all the accounts of a pool (subscription and region), the Average Error Rate is
# the mean over the hours, and every account carries its share of it, idle hours counting as available
# (README, "Algorithms > Storage accounts").

# Transactions are read split by ResponseType: StorageParser tells the failed ones, the Excluded
# Transactions (authentication failures, quota throttling) and the other counted ones.
$StorageResponseFilter = "ResponseType eq '*'"

# Accounts with fewer counted requests than this in the period are flagged as low-volume.
$StorageLowVolumeRequests = 10000

#region Get-StorageHourlyCounts
<#
.SYNOPSIS
    Gets the hourly counted and failed request totals of storage accounts for the whole period.

.DESCRIPTION
    One Azure Monitor call per account (Transactions, PT1H, Total, split by ResponseType). A failed
    query yields a null result, which excludes the account from availability.

.PARAMETER Resources
    Storage account descriptors from Get-ResourceInventory.

.PARAMETER PeriodStart
    Start of the observation window (aligned to a whole hour).

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER ThrottleLimit
    Maximum concurrent calls.

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.OUTPUTS
    Hashtable keyed by lowercase resource ID; each value is a StorageHourly or $null.
#>
function Get-StorageHourlyCounts {
    param(
        [object[]]$Resources,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$ThrottleLimit,
        [string]$ArmToken
    )

    $hours      = [int][math]::Ceiling(($PeriodEnd - $PeriodStart).TotalHours)
    $startTicks = $PeriodStart.UtcTicks
    $timespan   = "$($PeriodStart.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($PeriodEnd.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    # Hourly slots of the period; the filter keeps Success and server failures only.
    $filter     = [uri]::EscapeDataString($StorageResponseFilter)

    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $client.Timeout = [TimeSpan]::FromMinutes(5)

    $byRes = @{}
    $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $res = $_
        $uri = "https://management.azure.com$($res.ResourceId)/providers/Microsoft.Insights/metrics?api-version=2024-02-01" +
               "&metricnamespace=Microsoft.Storage%2FstorageAccounts&metricnames=Transactions&aggregation=Total&interval=PT1H" +
               "&timespan=$($using:timespan)&`$filter=$($using:filter)"
        $http = [AzHttp]::Get($using:client, $uri)
        # A failed query leaves a null result, which excludes the account from availability.
        $hourly = $null
        if ($http.Doc) {
            try   { $hourly = [StorageParser]::ParseHourly($http.Doc, $using:startTicks, $using:hours) }
            catch { Write-Warning "Storage metric processing failed for '$($res.Name)': $_" }
            finally { $http.Doc.Dispose() }
        }
        else { Write-Warning "Storage metric query failed for '$($res.Name)': $($http.Error)" }
        [PSCustomObject]@{ Key = $res.ResourceId.ToLowerInvariant(); Hourly = $hourly }
    } | ForEach-Object { $byRes[$_.Key] = $_.Hourly }

    $client.Dispose()
    $byRes
}
#endregion

#region Invoke-StorageInvestigation
<#
.SYNOPSIS
    Attributes the server failures of the given storage accounts minute by minute.

.DESCRIPTION
    For each account: (1) reads the PT1M counts (split by ResponseType) of the days that had failures
    (one call per day when there are few, otherwise 10-day spans, halved again when the response is too
    large); (2) builds the platform and customer Resource Health windows from the REST history combined
    with Log Analytics when a workspace is used; (3) classifies every minute that had failures. A minute inside a
    platform window (starting HealthLeadMinutes before the event, because Resource Health raises it after
    the first failures, and ending two minutes after it is resolved) is a Fault, inside a customer window
    (for example "Throttled") is Excused, anything else is Unresolved. The excused requests per hour and the
    verdict of each hour are returned: they leave the hourly error rates when the pool is computed.

.PARAMETER Candidates
    Objects with Resource, Hourly (StorageHourly) and FirstMinute (first minute after the account was created).

.PARAMETER PeriodStart
    Start of the observation window.

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER ThrottleLimit
    Maximum concurrent investigations.

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.PARAMETER HealthLeadMinutes
    Minutes before a Resource Health event that its failures are still attributed to it.

.PARAMETER LogAnalyticsData
    Optional output of Get-LogAnalyticsData (Resource Health history held in the Activity Log).

.OUTPUTS
    Hashtable keyed by lowercase resource ID; each value has the failing-minute counts per class, the
    excused requests per hour, the verdict of each failing hour and the evidence (incidents, health windows).
#>
function Invoke-StorageInvestigation {
    param(
        [object[]]$Candidates,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$ThrottleLimit,
        [string]$ArmToken,
        [int]$HealthLeadMinutes,
        [hashtable]$LogAnalyticsData
    )

    $filter = [uri]::EscapeDataString($StorageResponseFilter)
    $healthSources = Get-HealthSources -LogAnalyticsData $LogAnalyticsData -PeriodEnd $PeriodEnd

    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $client.Timeout = [TimeSpan]::FromMinutes(5)

    $byRes = @{}
    $Candidates | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        # Unpack the candidate and the values shared with the caller.
        $c      = $_
        $res    = $c.Resource
        $hourly = $c.Hourly
        $client = $using:client
        $pStart = ($using:PeriodStart).UtcDateTime
        $pEnd   = ($using:PeriodEnd).UtcDateTime
        $nMin   = [int]($pEnd - $pStart).TotalMinutes
        $hours  = $hourly.Counted.Length
        $tpm    = [TimeSpan]::TicksPerMinute
        $key    = $res.ResourceId.ToLowerInvariant()
        $healthSources = $using:healthSources
        # A platform window starts HealthLeadMinutes before the event and ends two minutes after it.
        $leadTicks  = $using:HealthLeadMinutes * $tpm
        $graceTicks = 2 * $tpm

        # Success and server failures per minute, only for the periods that had failures.
        $failedMin  = [double[]]::new($nMin)
        $countedMin = [double[]]::new($nMin)
        # Index (within the period) of the days that had failures; the minute detail is read only for those.
        $days = [System.Collections.Generic.SortedSet[int]]::new()
        for ($h = 0; $h -lt $hours; $h++) { if ($hourly.Failed[$h] -gt 0) { [void]$days.Add([int][math]::Floor($h / 24)) } }
        # One call per failing day when there are few, otherwise spans of 10 days.
        $spanDays = $days.Count -le 2 ? 1 : 10
        # The spans (units of $spanDays days) that contain at least one failing day.
        $units = [System.Collections.Generic.SortedSet[int]]::new()
        foreach ($d in $days) { [void]$units.Add([int][math]::Floor($d / $spanDays)) }
        # The spans to read (start and end ticks); MetricSpans splits a span that the service refuses as too large.
        $bounds = [long[]]@(foreach ($u in $units) {
            $spanEnd = $pStart.AddDays(($u + 1) * $spanDays)
            if ($spanEnd -gt $pEnd) { $spanEnd = $pEnd }
            $pStart.AddDays($u * $spanDays).Ticks
            $spanEnd.Ticks
        })
        $uri = "https://management.azure.com$($res.ResourceId)/providers/Microsoft.Insights/metrics?api-version=2024-02-01" +
               "&metricnamespace=Microsoft.Storage%2FstorageAccounts&metricnames=Transactions&aggregation=Total&interval=PT1M" +
               "&`$filter=$($using:filter)"
        $detailError = [MetricSpans]::Read($client, $uri, $bounds, [Action[System.Text.Json.JsonDocument]]{
            param($doc) [StorageParser]::AddMinutes($doc, $pStart.Ticks, $failedMin, $countedMin)
        })
        $detailComplete = -not $detailError
        if ($detailError) { Write-Warning "Storage minute detail failed for '$($res.Name)': $detailError" }
        # The same combined history and the same window rules as the VM and SQL algorithms
        # (Get-HealthSources, HealthHistory.BuildWindows).
        $fetch = [HealthHistory]::Collect($client, $res.ResourceId, $healthSources.WorkspaceNotes[$key], $healthSources.UseRest)
        if ($fetch.Error) { Write-Warning "Resource Health query failed for '$($res.Name)': $($fetch.Error)" }
        $windows = [HealthHistory]::BuildWindows($fetch.Notes, 30 * $tpm, $graceTicks)
        # Each minute that had server failures is a Fault (platform window), Excused (customer window)
        # or Unresolved. Consecutive failing minutes (gap of at most 5) form one incident for the evidence.
        $count = @{ Fault = 0; Excused = 0; Unresolved = 0 }
        $weighted = 0.0
        $excusedByHour = [double[]]::new($hours)
        $hourClass = @{}
        $incidents = [System.Collections.Generic.List[object]]::new()
        $cur = $null
        for ($m = $c.FirstMinute; $m -lt $nMin; $m++) {
            $failed = $failedMin[$m]
            if ($failed -le 0 -or $countedMin[$m] -le 0) { continue }
            # The share of this minute's counted requests that failed weights the loss.
            $share = $failed / $countedMin[$m]
            $ticks = $pStart.Ticks + $m * $tpm
            # A window covers the minute from the lead before its start to the grace after its end.
            $class = 'Unresolved'; $win = $null
            foreach ($w in $windows) {
                if ($ticks -ge $w.Start - $leadTicks -and $ticks -le $w.End + $graceTicks) {
                    $class = $w.Customer ? 'Excused' : 'Fault'; $win = $w; break
                }
            }
            $count[$class]++
            $weighted += $share
            $hourOfMinute = [int][math]::Floor($m / 60)
            if ($class -eq 'Excused') { $excusedByHour[$hourOfMinute] += $failed }
            # Per hour: how many of its failing minutes were faults or unresolved, and the Resource Health event of a fault.
            if (-not $hourClass.ContainsKey($hourOfMinute)) { $hourClass[$hourOfMinute] = @{ Fault = 0; Unresolved = 0; Title = '' } }
            if ($class -eq 'Fault') {
                $hourClass[$hourOfMinute].Fault++
                if (-not $hourClass[$hourOfMinute].Title) { $hourClass[$hourOfMinute].Title = $win.Title }
            }
            elseif ($class -eq 'Unresolved') { $hourClass[$hourOfMinute].Unresolved++ }
            # Extend the current incident, or close it and start a new one.
            if ($cur -and ($m - $cur.EndMinute) -le 5) {
                $cur.EndMinute = $m; $cur.Minutes++; $cur.Failed += $failed; $cur.Counted += $countedMin[$m]; $cur.Weighted += $share
                if ($share -gt $cur.Peak) { $cur.Peak = $share }
                if ($class -ne 'Unresolved') { $cur.Class = $class; $cur.Window = $win }
            }
            else {
                if ($cur) { $incidents.Add($cur) }
                $cur = [PSCustomObject]@{ StartMinute = $m; EndMinute = $m; Minutes = 1; Failed = $failed; Counted = $countedMin[$m]
                                          Weighted = $share; Peak = $share; Class = $class; Window = $win }
            }
        }
        if ($cur) { $incidents.Add($cur) }

        # The result of the account: counts per class, what the pool needs (the excused requests and the verdict
        # of each failing hour) and the heaviest incidents first.
        [PSCustomObject]@{
            Key = $key; Fault = $count.Fault; Excused = $count.Excused; Unresolved = $count.Unresolved
            Weighted = $weighted; DetailComplete = $detailComplete
            Windows = $windows.Count; PeriodStart = $pStart
            ExcusedByHour = $excusedByHour; HourClass = $hourClass
            Incidents = @($incidents | Sort-Object Weighted -Descending)
        }
    } | ForEach-Object { $byRes[$_.Key] = $_ }

    $client.Dispose()
    $byRes
}
#endregion

#region Invoke-StorageAvailability
<#
.SYNOPSIS
    Runs the storage availability algorithm for all storage accounts and returns one result per account.

.DESCRIPTION
    1. Hourly request totals for every account (Get-StorageHourlyCounts).
    2. The accounts that had server failures are investigated minute by minute against Resource Health
       (Invoke-StorageInvestigation); with -SourceWorkspaceId the older health history comes from Log Analytics.
    3. The Error Rate of every hour is computed over all the accounts of a pool (subscription and region), as in the
       SLA. Each account carries its share of it, so that the average of the accounts' availability is the pool's
       Uptime Percentage. Idle hours count as available; an account with no counted request in the period is
       excluded (N/A).

.PARAMETER Resources
    Storage account descriptors from Get-ResourceInventory.

.PARAMETER PeriodStart
    Start of the observation window.

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER TotalMinutes
    Length of the observation window in minutes.

.PARAMETER ThrottleLimit
    Maximum concurrent calls.

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.PARAMETER HealthLeadMinutes
    Minutes before a Resource Health event that its failures are still attributed to it.

.PARAMETER SourceWorkspaceId
    Optional Log Analytics workspace with the Activity Log (Resource Health history).

.PARAMETER SubscriptionIds
    Subscription IDs queried in the workspace.

.OUTPUTS
    Hashtable keyed by lowercase resource ID with one result per account.
#>
function Invoke-StorageAvailability {
    param(
        [object[]]$Resources,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$TotalMinutes,
        [int]$ThrottleLimit,
        [string]$ArmToken,
        [int]$HealthLeadMinutes,
        [string]$SourceWorkspaceId,
        [string[]]$SubscriptionIds
    )
    Write-Host "Querying hourly request counts for $($Resources.Count) storage account(s) with parallelism $ThrottleLimit..."
    $hourlyByRes = Get-StorageHourlyCounts -Resources $Resources -PeriodStart $PeriodStart -PeriodEnd $PeriodEnd `
        -ThrottleLimit $ThrottleLimit -ArmToken $ArmToken

    # First minute of the period in which the account existed (idle hours before creation are not eligible).
    $candidates = [System.Collections.Generic.List[object]]::new()
    $firstMinuteByRes = @{}
    foreach ($res in $Resources) {
        $key = $res.ResourceId.ToLowerInvariant()
        $first = 0
        if ($res.CreationTime -and $res.CreationTime -gt $PeriodStart) {
            $first = [math]::Min($TotalMinutes, [int][math]::Ceiling(($res.CreationTime - $PeriodStart).TotalMinutes))
        }
        $firstMinuteByRes[$key] = $first
        $hourly = $hourlyByRes[$key]
        if ($hourly -and ($hourly.Failed | Measure-Object -Sum).Sum -gt 0) {
            $candidates.Add([PSCustomObject]@{ Resource = $res; Hourly = $hourly; FirstMinute = $first })
        }
    }

    # Accounts with server failures are investigated minute by minute; the workspace, if any, supplies the health history.
    $investigation = @{}
    if ($candidates.Count -gt 0) {
        Write-Host "Investigating server failures of $($candidates.Count) storage account(s)..."
        $logAnalyticsData = $null
        if ($SourceWorkspaceId) {
            Write-Host -NoNewline 'Fetching Resource Health history from Log Analytics... '
            $logAnalyticsToken = Get-PlainToken 'https://api.loganalytics.io'
            $logAnalyticsData = Get-LogAnalyticsData -WorkspaceId $SourceWorkspaceId -SubscriptionIds $SubscriptionIds `
                -ResourceIds @($candidates.Resource.ResourceId) -PeriodStart $PeriodStart -PeriodEnd $PeriodEnd `
                -ArmToken $logAnalyticsToken
        }
        $investigation = Invoke-StorageInvestigation -Candidates @($candidates) -PeriodStart $PeriodStart -PeriodEnd $PeriodEnd `
            -ThrottleLimit $ThrottleLimit -ArmToken $ArmToken -HealthLeadMinutes $HealthLeadMinutes -LogAnalyticsData $logAnalyticsData
    }

    # One result per account. The Error Rate of an hour is the failed over the counted transactions of all the
    # accounts of the pool (subscription and region), as in the SLA, and every account carries its share of
    # it: its failed requests over the pool's counted requests of the hour, times the accounts of the pool,
    # so that the average of the accounts is the Uptime Percentage of the pool (see the README).
    $hours  = [int][math]::Ceiling(($PeriodEnd - $PeriodStart).TotalHours)
    $results = @{}
    $members = [System.Collections.Generic.List[object]]::new()
    foreach ($res in $Resources) {
        $key    = $res.ResourceId.ToLowerInvariant()
        $hourly = $hourlyByRes[$key]
        $first  = $firstMinuteByRes[$key]
        $counted = $hourly ? ($hourly.Counted | Measure-Object -Sum).Sum : 0
        $failed  = $hourly ? ($hourly.Failed  | Measure-Object -Sum).Sum : 0
        $inv     = $investigation[$key]
        $eligibleMinutes = $TotalMinutes - $first

        $results[$key] = [PSCustomObject]@{
            Excluded        = (-not $hourly) -or $counted -le 0 -or $eligibleMinutes -le 0
            EligibleMinutes = $eligibleMinutes
            Percent         = 100.0
            LostMinutes     = 0.0
            CountedRequests = $counted
            FailedRequests  = $failed
            Fault           = $inv ? $inv.Fault : 0
            Excused         = $inv ? $inv.Excused : 0
            Unresolved      = $inv ? $inv.Unresolved : 0
            Weighted        = $inv ? $inv.Weighted : 0.0
            DetailComplete  = $inv ? $inv.DetailComplete : $true
            Incidents       = $inv ? $inv.Incidents : @()
            LossHours       = @()
            PoolAccounts    = 1
            PoolUptime      = 100.0
            PeriodStart     = $PeriodStart.UtcDateTime
            LowVolume       = $counted -lt $StorageLowVolumeRequests
        }
        if (-not $results[$key].Excluded) {
            $members.Add([PSCustomObject]@{ Resource = $res; Key = $key; Hourly = $hourly; FirstHour = [int][math]::Floor($first / 60); Inv = $inv })
        }
    }

    foreach ($pool in ($members | Group-Object { "$($_.Resource.SubscriptionId)|$($_.Resource.Location.ToLowerInvariant())" })) {
        $accounts = @($pool.Group)
        $lost = @{}; $lossHours = @{}
        foreach ($a in $accounts) { $lost[$a.Key] = 0.0; $lossHours[$a.Key] = [System.Collections.Generic.List[object]]::new() }
        $poolEligible = 0.0; $poolLost = 0.0
        for ($h = 0; $h -lt $hours; $h++) {
            # The minutes of the hour (the last one can be shorter when the period ends now).
            $minutes = [math]::Min(60, $TotalMinutes - 60 * $h)
            if ($minutes -le 0) { break }
            # The accounts that existed in this hour, with their transactions after the excused requests are removed.
            $live = [System.Collections.Generic.List[object]]::new()
            $poolFailed = 0.0; $poolCounted = 0.0
            foreach ($a in $accounts) {
                if ($a.FirstHour -gt $h) { continue }
                $excused = $a.Inv ? $a.Inv.ExcusedByHour[$h] : 0.0
                $n = [math]::Max(0, $a.Hourly.Counted[$h] - $excused)
                $f = [math]::Max(0, $a.Hourly.Failed[$h] - $excused)
                $live.Add([PSCustomObject]@{ Account = $a; Failed = $f; Counted = $n })
                $poolFailed += $f; $poolCounted += $n
            }
            if ($live.Count -eq 0) { continue }
            $poolEligible += $minutes * $live.Count
            # An hour without transactions has an error rate of 0%.
            if ($poolCounted -le 0 -or $poolFailed -le 0) { continue }
            foreach ($x in $live) {
                if ($x.Failed -le 0) { continue }
                $loss = $minutes * $live.Count * $x.Failed / $poolCounted
                $lost[$x.Account.Key] += $loss
                $poolLost += $loss
                $hc = ($x.Account.Inv -and $x.Account.Inv.HourClass.ContainsKey($h)) ? $x.Account.Inv.HourClass[$h] : @{ Fault = 0; Unresolved = 0; Title = '' }
                $lossHours[$x.Account.Key].Add([PSCustomObject]@{ Hour = $h; Failed = $x.Failed; Counted = $x.Counted; Lost = $loss
                    PoolFailed = $poolFailed; PoolCounted = $poolCounted; Fault = $hc.Fault; Unresolved = $hc.Unresolved; Title = $hc.Title })
            }
        }
        $poolUptime = $poolEligible -gt 0 ? 100 - 100 * $poolLost / $poolEligible : 100.0
        $sample = $accounts[0].Resource
        Write-Host ("  Storage pool {0}, {1} [{2} account(s)]: Uptime Percentage {3:N5}% (Average Error Rate {4:N5}%)" -f
            $sample.SubscriptionName, $sample.Location, $accounts.Count, $poolUptime, (100 - $poolUptime))
        foreach ($a in $accounts) {
            $r = $results[$a.Key]
            $r.LostMinutes  = $lost[$a.Key]
            $r.Percent      = 100 - 100 * $lost[$a.Key] / $r.EligibleMinutes
            $r.LossHours    = @($lossHours[$a.Key] | Sort-Object Lost -Descending)
            $r.PoolAccounts = $accounts.Count
            $r.PoolUptime   = $poolUptime
        }
    }
    $results
}
#endregion

#region Set-StorageEligibility
<#
.SYNOPSIS
    Writes the result of the storage algorithm into a resource's eligibility record and prints the narration.

.DESCRIPTION
    Suspect = Faults + Excused + Unresolved holds, counted in failing minutes (minutes with at least one
    server failure). AvailableMinutes is the eligible minutes less the minutes the account carries of its
    pool's loss, so the accounts of a pool add up to the pool's Uptime Percentage.

.PARAMETER Record
    The eligibility record of the account (see Step 4).

.PARAMETER Result
    The account's result from Invoke-StorageAvailability.

.OUTPUTS
    None. Updates Record and writes the narration lines to the host.
#>
function Set-StorageEligibility {
    param(
        [PSCustomObject]$Record,
        [PSCustomObject]$Result
    )
    $name = $Record.Name
    if ($Result.Excluded) {
        $Record.EligibleMinutes = 0
        $Record.AvailableMinutes = 0
        Write-Host "  [$name] excluded from availability (no counted storage requests in period)"
        return
    }

    # Suspect minutes are the failing minutes; the available minutes follow from the account's share of the pool's loss.
    $Record.EligibleMinutes           = $Result.EligibleMinutes
    $Record.SuspectMinutes            = $Result.Fault + $Result.Excused + $Result.Unresolved
    $Record.ConfirmedDowntimeMinutes  = $Result.Fault
    $Record.ExcusedMinutes            = $Result.Excused
    $Record.UnexplainedSuspectMinutes = $Result.Unresolved
    $Record.AvailableMinutes          = [math]::Round($Result.EligibleMinutes - $Result.LostMinutes, 2)
    $Record.AvailabilityPct           = [math]::Round($Result.Percent, 5).ToString('F5')

    if ($Record.SuspectMinutes -gt 0) {
        Write-Host ("  [$name] storage: {0:N0} server failure(s) in {1:N0} counted request(s) (own error rate {2:P4}); {3} failing min = {4} confirmed by Resource Health + {5} customer-excused + {6} unresolved (worth {7:N2} min of the pool)" -f
            $Result.FailedRequests, $Result.CountedRequests, ($Result.FailedRequests / [math]::Max(1, $Result.CountedRequests)),
            $Record.SuspectMinutes, $Result.Fault, $Result.Excused, $Result.Unresolved, $Result.LostMinutes)
        # The three heaviest incidents are listed; the rest is counted.
        foreach ($i in ($Result.Incidents | Select-Object -First 3)) {
            $when = $Result.PeriodStart.AddMinutes($i.StartMinute).ToString('u')
            Write-Host ("  [$name]   incident {0}, {1} min: {2:N0} failed of {3:N0} counted ({4:P2} peak) -> {5} -> {6}" -f
                $when, $i.Minutes, $i.Failed, $i.Counted, $i.Peak, $i.Class, (Get-WindowCause $i.Window))
        }
        if ($Result.Incidents.Count -gt 3) { Write-Host "  [$name]   ... and $($Result.Incidents.Count - 3) smaller incident(s)" }
        if (-not $Result.DetailComplete) { Write-Host "  [$name]   WARNING: minute detail incomplete, some failing minutes are not classified" }

        # The causes of the "most impact" report: the failing minutes that count, split by who explains them.
        # The minutes lost are the account's share of its pool's hourly error rates (see the note below), so they
        # differ from the number of failing minutes.
        $Record.Causes = @(foreach ($g in (@($Result.LossHours) | Group-Object { $_.Fault -gt $_.Unresolved ? 'platform fault' : 'unresolved' })) {
            $isFault = $g.Name -eq 'platform fault'
            $because = $isFault ? "Resource Health '$(($g.Group | Where-Object Title | Select-Object -First 1).Title)'" : 'no Resource Health event'
            $lost = ($g.Group | Measure-Object Lost -Sum).Sum
            # The incidents (runs of failing minutes) behind this verdict, the largest first.
            $counted = @($Result.Incidents | Where-Object { $_.Class -eq ($isFault ? 'Fault' : 'Unresolved') })
            if ($counted.Count -eq 0) {
                New-LossCause $lost $g.Name "failures in $($g.Count) hour(s), minute detail not available; $because"
                continue
            }
            $minutes = ($counted | Measure-Object Minutes -Sum).Sum
            $failed  = ($counted | Measure-Object Failed -Sum).Sum
            $what = ('{0:N0} failing {1}, {2:N0} failed {3}' -f $minutes, ($minutes -eq 1 ? 'minute' : 'minutes'), $failed, ($failed -eq 1 ? 'request' : 'requests'))
            if ($counted.Count -gt 1) {
                $from = $Result.PeriodStart.AddMinutes(($counted | Measure-Object StartMinute -Minimum).Minimum)
                $to   = $Result.PeriodStart.AddMinutes(($counted | Measure-Object EndMinute -Maximum).Maximum)
                # Isolated minutes are "scattered"; longer runs are counted as incidents.
                $spread = $counted.Count -eq $minutes ? 'scattered' : "in $($counted.Count) incidents"
                $what += " $spread between $(Format-Occurrence $from) and $(Format-Occurrence $to)"
            }
            $when = @($counted | Select-Object -First 3 |
                ForEach-Object { Format-Occurrence $Result.PeriodStart.AddMinutes($_.StartMinute) $_.Minutes })
            New-LossCause $lost $g.Name "$what; $because" $when ($counted.Count -gt 1 ? 'largest:' : 'at')
        })
        $notes = [System.Collections.Generic.List[string]]::new()
        $notes.Add(('scored as in the SLA, per subscription and region: the pool of {0} account(s) has an Uptime Percentage of {1:N5}%, and this account carries its share of the pool''s loss ({2:N2} min)' -f
            $Result.PoolAccounts, $Result.PoolUptime, $Result.LostMinutes))
        if ($Result.LowVolume) { $notes.Add(('low volume: only {0:N0} counted request(s) in the period, the percentage rests on very few requests' -f $Result.CountedRequests)) }
        if (-not $Result.DetailComplete) { $notes.Add('minute detail incomplete: some failing minutes are not classified') }
        $Record.Notes = $notes.ToArray()
    }
    if ($Result.LowVolume) {
        Write-Host ("  [$name] low volume: only {0:N0} counted request(s) in the period, the percentage rests on very few requests" -f $Result.CountedRequests)
    }
}
#endregion
#endregion

#region Web App algorithm
# Web Apps have no availability metric. The score follows what a customer sees: a minute is down when
# every request of the minute failed with an HTTP 5xx. Only the minutes the app is set to running count
# (the App Service SLA "Deployment Minutes"). Minutes without requests are not judged and count as
# available (README, "Algorithms > Web Apps").

# Apps with fewer requests than this in the period are flagged as low-volume when they have down minutes.
$WebLowVolumeRequests = 10000

# App Service plan tiers the App Service SLA does not cover.
$WebNoSlaTiers = @('Free', 'Shared')

#region Get-WebHourlyCounts
<#
.SYNOPSIS
    Gets the hourly request and HTTP 5xx totals of Web Apps for the whole period.

.DESCRIPTION
    One Azure Monitor call per app (Requests and Http5xx, PT1H, Total). It tells which apps had traffic
    and which had any 5xx, so that only the latter need the minute detail. A failed query yields a null
    result, which excludes the app from availability.

.PARAMETER Resources
    Web App descriptors from Get-ResourceInventory.

.PARAMETER PeriodStart
    Start of the observation window (aligned to a whole hour).

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER ThrottleLimit
    Maximum concurrent calls.

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.OUTPUTS
    Hashtable keyed by lowercase resource ID; each value has Requests and Errors (double[] per hour) or is $null.
#>
function Get-WebHourlyCounts {
    param(
        [object[]]$Resources,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$ThrottleLimit,
        [string]$ArmToken
    )

    $hours      = [int][math]::Ceiling(($PeriodEnd - $PeriodStart).TotalHours)
    $startTicks = $PeriodStart.UtcTicks
    $timespan   = "$($PeriodStart.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($PeriodEnd.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"

    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $client.Timeout = [TimeSpan]::FromMinutes(5)

    $byRes = @{}
    $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $res = $_
        $uri = "https://management.azure.com$($res.ResourceId)/providers/Microsoft.Insights/metrics?api-version=2024-02-01" +
               "&metricnamespace=Microsoft.Web%2Fsites&metricnames=Requests,Http5xx&aggregation=Total&interval=PT1H" +
               "&timespan=$($using:timespan)"
        $http = [AzHttp]::Get($using:client, $uri)
        # One call per app: the hourly totals fill two arrays; a failed query leaves $null and excludes the app.
        $counts = $null
        if ($http.Doc) {
            try {
                $counts = [PSCustomObject]@{ Requests = [double[]]::new($using:hours); Errors = [double[]]::new($using:hours) }
                [WebParser]::AddCounts($http.Doc, $using:startTicks, [TimeSpan]::TicksPerHour, $counts.Requests, $counts.Errors)
            }
            catch { $counts = $null; Write-Warning "Web App metric processing failed for '$($res.Name)': $_" }
            finally { $http.Doc.Dispose() }
        }
        else { Write-Warning "Web App metric query failed for '$($res.Name)': $($http.Error)" }
        [PSCustomObject]@{ Key = $res.ResourceId.ToLowerInvariant(); Counts = $counts }
    } | ForEach-Object { $byRes[$_.Key] = $_.Counts }

    $client.Dispose()
    $byRes
}
#endregion

#region Invoke-WebInvestigation
<#
.SYNOPSIS
    Finds and classifies the down minutes of the given Web Apps.

.DESCRIPTION
    For each app: (1) builds the stopped periods and the recycle windows from the stop, start and restart
    operations of the Activity Log (from Log Analytics when a workspace is used; otherwise read from the
    REST API, only for the apps that had 5xx); (2) for an app that had 5xx, reads the PT1M Requests and
    Http5xx counts (spans of 5 days, halved when the response is too large) and builds the Resource Health
    windows from the REST history combined with Log Analytics (Get-HealthSources); (3) lets the compiled
    WebClassifier decide each minute in which every request failed (see the README for the order of decisions).

.PARAMETER Candidates
    Objects with Resource, FirstMinute (first minute after the app was created) and Detail ($true when the
    app had any 5xx in the period).

.PARAMETER PeriodStart
    Start of the observation window.

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER ThrottleLimit
    Maximum concurrent investigations.

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.PARAMETER HealthLeadMinutes
    Minutes before a Resource Health event that its down minutes are still attributed to it.

.PARAMETER GraceMinutes
    Minutes after a stop, start or restart that its down minutes are still excused.

.PARAMETER LogAnalyticsData
    Optional output of Get-LogAnalyticsData (Activity Log and Resource Health history in the workspace).

.OUTPUTS
    Hashtable keyed by lowercase resource ID; each value has the WebResult of the app, whether the minute
    detail was complete and the number of Resource Health windows.
#>
function Invoke-WebInvestigation {
    param(
        [object[]]$Candidates,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$ThrottleLimit,
        [string]$ArmToken,
        [int]$HealthLeadMinutes,
        [int]$GraceMinutes,
        [hashtable]$LogAnalyticsData
    )

    $healthSources = Get-HealthSources -LogAnalyticsData $LogAnalyticsData -PeriodEnd $PeriodEnd

    $client = [System.Net.Http.HttpClient]::new()
    $client.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $client.Timeout = [TimeSpan]::FromMinutes(5)

    $byRes = @{}
    $Candidates | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        # Unpack the candidate and the values shared with the caller.
        $c      = $_
        $res    = $c.Resource
        $client = $using:client
        $pStart = ($using:PeriodStart).UtcDateTime
        $pEnd   = ($using:PeriodEnd).UtcDateTime
        $nMin   = [int]($pEnd - $pStart).TotalMinutes
        $tpm    = [TimeSpan]::TicksPerMinute
        $key    = $res.ResourceId.ToLowerInvariant()
        $laData = $using:LogAnalyticsData
        $healthSources = $using:healthSources

        # Lifecycle operations come from the workspace, or from the REST API when there is none.
        $events = [System.Collections.Generic.List[WebEvent]]::new()
        if ($laData) {
            # The events were fetched in bulk: keep the stop, start and restart operations of this app.
            if ($laData.ContainsKey($key)) {
                foreach ($e in $laData[$key].ActivityEvents) {
                    $kind = [WebParser]::LifecycleKind([string]$e.OperationName)
                    if ($kind) { $events.Add([WebEvent]::new($e.Timestamp.UtcTicks, $kind)) }
                }
            }
        }
        elseif ($c.Detail) {
            # Without a workspace the Activity Log is read per app, and only for the apps that need it.
            $raw = [System.Collections.Generic.List[ActivityEvent]]::new()
            $filter = "eventTimestamp ge '$($pStart.ToString('O'))' and eventTimestamp le '$($pEnd.ToString('O'))' and resourceUri eq '$($res.ResourceId)'"
            $url = "https://management.azure.com/subscriptions/$($res.SubscriptionId)/providers/microsoft.insights/eventtypes/management/values" +
                   "?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))&`$select=$([uri]::EscapeDataString('eventTimestamp,operationName,correlationId,status'))"
            while ($url) {
                $http = [AzHttp]::Get($client, $url)
                if (-not $http.Doc) { Write-Warning "Activity Log query failed for '$($res.Name)': $($http.Error)"; break }
                try   { $url = [ActivityLogParser]::ReadPage($http.Doc, $raw) }
                finally { $http.Doc.Dispose() }
            }
            foreach ($e in $raw) {
                $kind = [WebParser]::LifecycleKind($e.Operation)
                if ($kind) { $events.Add([WebEvent]::new($e.Ticks, $kind)) }
            }
        }
        # Turn the operations into the stopped periods and the recycle windows.
        $stopped = [System.Collections.Generic.List[long[]]]::new()
        $recycle = [System.Collections.Generic.List[long[]]]::new()
        [WebClassifier]::BuildLifecycle($events, $pEnd.Ticks, $using:GraceMinutes * $tpm, $stopped, $recycle)
        # Per-minute counts of the period; they stay empty for an app without 5xx.
        $requestsMin = [double[]]::new($nMin)
        $errorsMin   = [double[]]::new($nMin)
        $detailComplete = $true
        $windows = [System.Collections.Generic.List[HealthWindow]]::new()
        if ($c.Detail) {
            # Spans of 5 days (7,200 minutes); MetricSpans splits a span that the service refuses as too large.
            $bounds = [long[]]@(for ($d = 0; $d -lt $nMin; $d += 7200) {
                $pStart.AddMinutes($d).Ticks
                $pStart.AddMinutes([math]::Min($d + 7200, $nMin)).Ticks
            })
            $uri = "https://management.azure.com$($res.ResourceId)/providers/Microsoft.Insights/metrics?api-version=2024-02-01" +
                   "&metricnamespace=Microsoft.Web%2Fsites&metricnames=Requests,Http5xx&aggregation=Total&interval=PT1M"
            $detailError = [MetricSpans]::Read($client, $uri, $bounds, [Action[System.Text.Json.JsonDocument]]{
                param($doc) [WebParser]::AddCounts($doc, $pStart.Ticks, $tpm, $requestsMin, $errorsMin)
            })
            $detailComplete = -not $detailError
            if ($detailError) { Write-Warning "Web App minute detail failed for '$($res.Name)': $detailError" }

            # The same combined history and the same window rules as the VM, SQL and storage algorithms.
            $fetch = [HealthHistory]::Collect($client, $res.ResourceId, $healthSources.WorkspaceNotes[$key], $healthSources.UseRest)
            if ($fetch.Error) { Write-Warning "Resource Health query failed for '$($res.Name)': $($fetch.Error)" }
            $windows = [HealthHistory]::BuildWindows($fetch.Notes, 30 * $tpm, 2 * $tpm)
        }
        $result = [WebClassifier]::Classify($requestsMin, $errorsMin, $c.FirstMinute, $pStart.Ticks, $stopped, $recycle,
                                            $windows, $using:HealthLeadMinutes * $tpm, 2 * $tpm)
        [PSCustomObject]@{ Key = $key; Result = $result; DetailComplete = $detailComplete; Windows = $windows.Count }
    } | ForEach-Object { $byRes[$_.Key] = $_ }

    $client.Dispose()
    $byRes
}
#endregion

#region Invoke-WebAvailability
<#
.SYNOPSIS
    Runs the Web App availability algorithm for all Web Apps and returns one result per app.

.DESCRIPTION
    1. Hourly request and 5xx totals for every app (Get-WebHourlyCounts). An app with no request in the
       period cannot be judged and is excluded (N/A).
    2. Every other app is investigated (Invoke-WebInvestigation): its stopped periods leave the eligible
       minutes, and for an app that had 5xx each minute in which every request failed is decided.
       With -SourceWorkspaceId the Activity Log comes from Log Analytics for all the apps; without it only
       the apps that had 5xx read it, so the stopped minutes of the other apps are not removed from their
       eligible minutes (their availability stays 100%).
    3. Eligible minutes = minutes since the app was created, without the minutes it was stopped and the
       down minutes excused by a recycle or a customer Resource Health window.
       Availability % = (eligible - Fault - Unresolved down minutes) / eligible.

.PARAMETER Resources
    Web App descriptors from Get-ResourceInventory.

.PARAMETER PeriodStart
    Start of the observation window.

.PARAMETER PeriodEnd
    End of the observation window.

.PARAMETER TotalMinutes
    Length of the observation window in minutes.

.PARAMETER ThrottleLimit
    Maximum concurrent calls.

.PARAMETER ArmToken
    Bearer token for Azure Resource Manager.

.PARAMETER HealthLeadMinutes
    Minutes before a Resource Health event that its down minutes are still attributed to it.

.PARAMETER GraceMinutes
    Minutes after a stop, start or restart that its down minutes are still excused.

.PARAMETER SourceWorkspaceId
    Optional Log Analytics workspace with the Activity Log (lifecycle operations and Resource Health history).

.PARAMETER SubscriptionIds
    Subscription IDs queried in the workspace.

.OUTPUTS
    Hashtable keyed by lowercase resource ID with one result per app.
#>
function Invoke-WebAvailability {
    param(
        [object[]]$Resources,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$TotalMinutes,
        [int]$ThrottleLimit,
        [string]$ArmToken,
        [int]$HealthLeadMinutes,
        [int]$GraceMinutes,
        [string]$SourceWorkspaceId,
        [string[]]$SubscriptionIds
    )
    Write-Host "Querying hourly request counts for $($Resources.Count) web app(s) with parallelism $ThrottleLimit..."
    $hourlyByRes = Get-WebHourlyCounts -Resources $Resources -PeriodStart $PeriodStart -PeriodEnd $PeriodEnd `
        -ThrottleLimit $ThrottleLimit -ArmToken $ArmToken

    # Apps with traffic are investigated; the first minute is the first one in which the app existed.
    $candidates = [System.Collections.Generic.List[object]]::new()
    $totals = @{}
    foreach ($res in $Resources) {
        $key    = $res.ResourceId.ToLowerInvariant()
        $hourly = $hourlyByRes[$key]
        # The totals tell which apps have traffic (investigated) and which had any 5xx (minute detail).
        $requests = $hourly ? ($hourly.Requests | Measure-Object -Sum).Sum : 0
        $errors   = $hourly ? ($hourly.Errors   | Measure-Object -Sum).Sum : 0
        $first = 0
        if ($res.CreationTime -and $res.CreationTime -gt $PeriodStart) {
            $first = [math]::Min($TotalMinutes, [int][math]::Ceiling(($res.CreationTime - $PeriodStart).TotalMinutes))
        }
        $totals[$key] = [PSCustomObject]@{ Requests = $requests; Errors = $errors; FirstMinute = $first }
        if ($requests -gt 0) {
            $candidates.Add([PSCustomObject]@{ Resource = $res; FirstMinute = $first; Detail = $errors -gt 0 })
        }
    }

    # The workspace, if any, supplies the Activity Log and the health history of all the apps with traffic.
    $investigation = @{}
    if ($candidates.Count -gt 0) {
        $detailCount = @($candidates | Where-Object Detail).Count
        Write-Host "Investigating $($candidates.Count) web app(s) with traffic ($detailCount with HTTP 5xx)..."
        $logAnalyticsData = $null
        if ($SourceWorkspaceId) {
            Write-Host -NoNewline 'Fetching Activity Log + Resource Health history from Log Analytics... '
            $logAnalyticsToken = Get-PlainToken 'https://api.loganalytics.io'
            $logAnalyticsData = Get-LogAnalyticsData -WorkspaceId $SourceWorkspaceId -SubscriptionIds $SubscriptionIds `
                -ResourceIds @($candidates.Resource.ResourceId) -PeriodStart $PeriodStart -PeriodEnd $PeriodEnd `
                -ArmToken $logAnalyticsToken
        }
        $investigation = Invoke-WebInvestigation -Candidates @($candidates) -PeriodStart $PeriodStart -PeriodEnd $PeriodEnd `
            -ThrottleLimit $ThrottleLimit -ArmToken $ArmToken -HealthLeadMinutes $HealthLeadMinutes -GraceMinutes $GraceMinutes `
            -LogAnalyticsData $logAnalyticsData
    }

    # One result per app.
    $results = @{}
    foreach ($res in $Resources) {
        $key = $res.ResourceId.ToLowerInvariant()
        $t   = $totals[$key]
        $inv = $investigation[$key]
        $w   = $inv ? $inv.Result : $null
        # Eligible minutes leave the time before creation, the stopped minutes and the excused down minutes.
        $stoppedMinutes = $w ? $w.StoppedMinutes : 0
        $excused  = $w ? $w.Recycle + $w.Customer : 0
        $lost     = $w ? $w.Fault + $w.Unresolved : 0
        $eligible = $TotalMinutes - $t.FirstMinute - $stoppedMinutes - $excused
        $results[$key] = [PSCustomObject]@{
            Excluded        = $t.Requests -le 0 -or $eligible -le 0
            EligibleMinutes = $eligible
            Percent         = $eligible -gt 0 ? 100 * ($eligible - $lost) / $eligible : 0
            Tier            = $res.Tier
            Requests        = $t.Requests
            Errors          = $t.Errors
            Detail          = $w
            DetailComplete  = $inv ? $inv.DetailComplete : $true
            PeriodStart     = $PeriodStart.UtcDateTime
            LowVolume       = $t.Requests -lt $WebLowVolumeRequests
        }
    }
    $results
}
#endregion

#region Set-WebEligibility
<#
.SYNOPSIS
    Writes the result of the Web App algorithm into an app's eligibility record and prints the narration.

.DESCRIPTION
    Suspect = down minutes (every request failed with a 5xx) = Faults + Excused + Unresolved, where Excused
    counts the minutes the app was stopped, recycled or inside a customer Resource Health window.
    AvailableMinutes is the eligible minutes minus the Fault and Unresolved down minutes.

.PARAMETER Record
    The eligibility record of the app (see Step 4).

.PARAMETER Result
    The app's result from Invoke-WebAvailability.

.OUTPUTS
    None. Updates Record and writes the narration lines to the host.
#>
function Set-WebEligibility {
    param(
        [PSCustomObject]$Record,
        [PSCustomObject]$Result
    )
    $name = $Record.Name
    if ($Result.Excluded) {
        $Record.EligibleMinutes = 0
        $Record.AvailableMinutes = 0
        Write-Host "  [$name] excluded from availability (no requests in period)"
        return
    }

    # Without minute detail (an app that never had a 5xx) there is no down minute: the figure is 100%.
    $w = $Result.Detail
    $down = $w ? $w.Down : 0
    $lost = $w ? $w.Fault + $w.Unresolved : 0
    # Fill the eligibility record; the available minutes are the eligible ones minus Fault and Unresolved.
    $Record.EligibleMinutes           = $Result.EligibleMinutes
    $Record.SuspectMinutes            = $down
    $Record.ConfirmedDowntimeMinutes  = $w ? $w.Fault : 0
    $Record.ExcusedMinutes            = $w ? $w.Stopped + $w.Recycle + $w.Customer : 0
    $Record.UnexplainedSuspectMinutes = $w ? $w.Unresolved : 0
    $Record.AvailableMinutes          = [math]::Round($Result.EligibleMinutes - $lost, 2)
    $Record.AvailabilityPct           = [math]::Round($Result.Percent, 5).ToString('F5')

    if ($Result.Tier -in $WebNoSlaTiers) {
        Write-Host "  [$name] tier $($Result.Tier): the App Service SLA does not cover this tier, the figure is informative only"
    }
    # Narration: the share of minutes with traffic that were down, the heaviest incidents and the volume warnings.
    if ($down -gt 0) {
        Write-Host ("  [$name] web: {0:N0} of {1:N0} min with traffic had every request fail with a 5xx ({2:P1}), {3:N0} request(s) in all: {4} confirmed by Resource Health + {5} excused ({6} stopped, {7} recycle, {8} customer) + {9} unresolved" -f
            $down, $w.Active, ($down / $w.Active), $Result.Requests, $w.Fault, $Record.ExcusedMinutes, $w.Stopped, $w.Recycle, $w.Customer, $w.Unresolved)
        # The heaviest incidents (longest first), three at most.
        $sorted = @($w.Incidents | Sort-Object Minutes -Descending)
        # The first three incidents are listed with their cause; the others are only counted.
        foreach ($i in ($sorted | Select-Object -First 3)) {
            $when = $Result.PeriodStart.AddMinutes($i.StartMinute).ToString('u')
            Write-Host ("  [$name]   incident {0}, {1} min, {2:N0} request(s) -> {3} -> {4}" -f $when, $i.Minutes, $i.Requests, $i.Class, (Get-WindowCause $i.Window))
        }
        if ($sorted.Count -gt 3) { Write-Host "  [$name]   ... and $($sorted.Count - 3) smaller incident(s)" }
        # Warnings about how much the percentage can be trusted: sparse down minutes and few requests.
        if ($w.DownFewRequests -gt 0) {
            Write-Host "  [$name]   $($w.DownFewRequests) of the down minute(s) carried fewer than 5 requests"
        }
        if ($Result.LowVolume) {
            Write-Host ("  [$name] low volume: only {0:N0} request(s) in the period, the percentage rests on very few requests" -f $Result.Requests)
        }

        # The causes of the "most impact" report: the down minutes that count, by Resource Health event or none.
        $counted = @($sorted | Where-Object { $_.Class -in 'Fault', 'Unresolved' })
        $Record.Causes = @(foreach ($g in ($counted | Group-Object { $_.Class + '|' + ($_.Window ? $_.Window.Title : '') })) {
            $first = $g.Group[0]
            $isFault = $first.Class -eq 'Fault'
            $requests = ($g.Group | Measure-Object Requests -Sum).Sum
            $what = ($isFault ? (Get-WindowCause $first.Window) : 'no stop, restart or Resource Health event') +
                "; $($g.Count) incident(s), $('{0:N0}' -f $requests) request(s) failed"
            # A single incident is as long as the lost minutes already shown, so its length is left out.
            $when = @($g.Group | Sort-Object Minutes -Descending |
                ForEach-Object { Format-Occurrence $Result.PeriodStart.AddMinutes($_.StartMinute) ($g.Count -eq 1 ? 0 : $_.Minutes) })
            New-LossCause (($g.Group | Measure-Object Minutes -Sum).Sum) ($isFault ? 'platform fault' : 'unresolved') $what $when
        })
        # Notes on how far the percentage can be trusted.
        $notes = [System.Collections.Generic.List[string]]::new()
        if ($w.DownFewRequests -gt 0) { $notes.Add("$($w.DownFewRequests) of the $down down minutes carried fewer than 5 requests") }
        if ($Result.LowVolume) { $notes.Add(('low volume: only {0:N0} request(s) in the period, the percentage rests on very few requests' -f $Result.Requests)) }
        if ($Result.Tier -in $WebNoSlaTiers) { $notes.Add("tier $($Result.Tier): the App Service SLA does not cover this tier, the figure is informative only") }
        if (-not $Result.DetailComplete) { $notes.Add('minute detail incomplete: some down minutes are not classified') }
        $Record.Notes = $notes.ToArray()
    }
    if ($w -and $w.Partial -gt 0) {
        Write-Host ("  [$name] {0:N0} min with traffic had some requests fail with a 5xx ({1:P1} of those requests); not scored" -f
            $w.Partial, ($w.PartialErrors / $w.PartialRequests))
    }
    if ($w -and -not $Result.DetailComplete) { Write-Host "  [$name]   WARNING: minute detail incomplete, some down minutes are not classified" }
}
#endregion
#endregion

#region Write-ResultsTable
<#
.SYNOPSIS
    Prints a fixed-width table with one row per resource.

.DESCRIPTION
    Columns: subscription, name, kind, location, suspect minutes, faults, excused minutes,
    unresolved minutes, available minutes, eligible minutes and availability percentage.
    Counters that are zero are left blank so the interesting rows stand out.

.PARAMETER Sorted
    Per-resource eligibility records, already sorted.

.OUTPUTS
    None. Writes to the host.
#>
function Write-ResultsTable([object[]]$Sorted) {
    $fmt = '{0,-24} {1,-30} {2,-7} {3,-12} {4,7} {5,6} {6,7} {7,10} {8,10} {9,8} {10,10}'
    Write-Host ''
    Write-Host ($fmt -f 'Subscription', 'Name', 'Kind', 'Location',
        'Suspect', 'Faults', 'Excused', 'Unresolved', 'AvailMin', 'EligMin', 'Avail%')
    Write-Host ([string]::new([char]0x2500, 141))

    # Zero counters stay blank so that the interesting rows stand out.
    foreach ($r in $Sorted) {
        Write-Host ($fmt -f
            (Get-TruncatedString $r.SubscriptionName 24),
            (Get-TruncatedString $r.Name 30),
            (Get-ShortKind $r.Kind),
            $r.Location,
            ($r.SuspectMinutes -gt 0 ? "$($r.SuspectMinutes)" : ''),
            ($r.ConfirmedDowntimeMinutes -gt 0 ? "$($r.ConfirmedDowntimeMinutes)" : ''),
            ($r.ExcusedMinutes -gt 0 ? "$($r.ExcusedMinutes)" : ''),
            ($r.UnexplainedSuspectMinutes -gt 0 ? "$($r.UnexplainedSuspectMinutes)" : ''),
            [math]::Round($r.AvailableMinutes, 2),
            $r.EligibleMinutes,
            $r.AvailabilityPct)
    }
    Write-Host ''
}
#endregion

#region Get-AvailabilitySummaries
<#
.SYNOPSIS
    Calculates the summary records shown on the console and ingested into Log Analytics.

.DESCRIPTION
    Resources without an availability figure (N/A) are left out. Summaries are produced per
    subscription and kind/location, per subscription in total and, when more than one
    subscription is involved, across all subscriptions.

.PARAMETER Sorted
    Per-resource eligibility records.

.OUTPUTS
    PSCustomObject[] with SummaryLevel (KindLocation, SubscriptionTotal, OverallKindLocation,
    Overall), SubscriptionName, Kind, Location, ResourceCount, AvailableMinutes, EligibleMinutes
    and AvailabilityPct.
#>
function Get-AvailabilitySummaries([object[]]$Sorted) {
    <#
    .SYNOPSIS
        Aggregates per-resource records into one summary record.
    .PARAMETER Level
        Summary level name.
    .PARAMETER SubscriptionName
        Subscription the summary belongs to ('' for cross-subscription levels).
    .PARAMETER Kind
        Resource kind ('' when the summary spans kinds).
    .PARAMETER Location
        Location ('' when the summary spans locations).
    .PARAMETER Items
        Per-resource records to aggregate.
    .OUTPUTS
        PSCustomObject summary record.
    #>
    function New-Summary([string]$Level, [string]$SubscriptionName, [string]$Kind, [string]$Location, [object[]]$Items) {
        $available = ($Items | Measure-Object AvailableMinutes -Sum).Sum
        $eligibleMinutes = ($Items | Measure-Object EligibleMinutes -Sum).Sum
        [PSCustomObject]@{
            SummaryLevel     = $Level
            SubscriptionName = $SubscriptionName
            Kind             = $Kind
            Location         = $Location
            ResourceCount    = $Items.Count
            AvailableMinutes = $available
            EligibleMinutes  = $eligibleMinutes
            AvailabilityPct  = $eligibleMinutes -gt 0 ? [math]::Round($available / $eligibleMinutes * 100, 5) : 0
        }
    }

    # N/A resources have no availability figure and are left out.
    $eligible = @($Sorted | Where-Object { $_.AvailabilityPct -ne 'N/A' })
    $summaries = [System.Collections.Generic.List[object]]::new()
    $subscriptionGroups = @($eligible | Group-Object SubscriptionName | Sort-Object Name)

    # Per subscription: one summary per kind and location, then the subscription total.
    foreach ($subGroup in $subscriptionGroups) {
        foreach ($g in ($subGroup.Group | Group-Object { "$($_.Kind)|$($_.Location)" } | Sort-Object Name)) {
            $items = @($g.Group)
            $summaries.Add((New-Summary 'KindLocation' $subGroup.Name $items[0].Kind $items[0].Location $items))
        }
        $summaries.Add((New-Summary 'SubscriptionTotal' $subGroup.Name '' '' @($subGroup.Group)))
    }

    # Across subscriptions: only meaningful when more than one is involved.
    if ($subscriptionGroups.Count -gt 1) {
        foreach ($g in ($eligible | Group-Object { "$($_.Kind)|$($_.Location)" } | Sort-Object Name)) {
            $items = @($g.Group)
            $summaries.Add((New-Summary 'OverallKindLocation' '' $items[0].Kind $items[0].Location $items))
        }
        $summaries.Add((New-Summary 'Overall' '' '' '' $eligible))
    }

    $summaries.ToArray()
}
#endregion

#region Write-SubscriptionSummaries
<#
.SYNOPSIS
    Prints the per-subscription and cross-subscription summaries.

.PARAMETER Summaries
    Records produced by Get-AvailabilitySummaries.

.OUTPUTS
    None. Writes to the host.
#>
function Write-SubscriptionSummaries([object[]]$Summaries) {
    <#
    .SYNOPSIS
        Formats one summary line.
    .PARAMETER Label
        Text identifying the summary (kind and location, TOTAL or OVERALL).
    .PARAMETER Summary
        Summary record.
    .OUTPUTS
        System.String.
    #>
    function Format-SummaryLine([string]$Label, $Summary) {
        $available = [math]::Round($Summary.AvailableMinutes, 2)
        $eligibleMinutes = [math]::Round($Summary.EligibleMinutes, 2)
        "  $Label [$($Summary.ResourceCount) res]: $($Summary.AvailabilityPct)% ($available / $eligibleMinutes eligible min)"
    }

    $subscriptionTotals = @($Summaries |
        Where-Object SummaryLevel -eq 'SubscriptionTotal' |
        Sort-Object SubscriptionName)

    # One block per subscription: its kinds and locations, then its total.
    foreach ($total in $subscriptionTotals) {
        Write-Host "--- $($total.SubscriptionName) Summary ---"
        foreach ($summary in ($Summaries |
            Where-Object { $_.SummaryLevel -eq 'KindLocation' -and $_.SubscriptionName -eq $total.SubscriptionName } |
            Sort-Object Kind, Location)) {
            Write-Host (Format-SummaryLine "$(Get-ShortKind $summary.Kind), $($summary.Location)" $summary)
        }
        Write-Host (Format-SummaryLine 'TOTAL' $total)
        Write-Host ''
    }

    # The overall block exists only when several subscriptions were processed.
    $overall = $Summaries | Where-Object SummaryLevel -eq 'Overall' | Select-Object -First 1
    if ($overall) {
        Write-Host ([string]::new([char]0x2550, 62))
        Write-Host '               OVERALL (all subscriptions)'
        Write-Host ([string]::new([char]0x2550, 62))
        foreach ($summary in ($Summaries |
            Where-Object SummaryLevel -eq 'OverallKindLocation' |
            Sort-Object Kind, Location)) {
            Write-Host (Format-SummaryLine "$(Get-ShortKind $summary.Kind), $($summary.Location)" $summary)
        }
        Write-Host (Format-SummaryLine 'OVERALL' $overall)
        Write-Host ''
    }
}
#endregion

#region Write-TopImpact
<#
.SYNOPSIS
    Prints the resources that lost the most minutes, with the reason for each.

.DESCRIPTION
    A resource loses the eligible minutes that were not available (faults, unresolved minutes, and the
    fractional loss of degraded minutes). Because the aggregate figures are the sums of those minutes,
    the lost minutes are also the resource's weight in them. Resources are ranked across all subscriptions.
    Each one gets a line with its own percentage and its share of the total loss, then one line per cause
    (lost minutes, verdict, what happened and the evidence, where it happened), and notes on how far to
    trust the figure.

.PARAMETER Sorted
    Per-resource eligibility records.

.PARAMETER Top
    How many resources to list.

.OUTPUTS
    None. Writes to the host.
#>
function Write-TopImpact([object[]]$Sorted, [int]$Top) {
    # Resources with no availability figure (N/A) cannot have lost anything.
    $scored = @($Sorted | Where-Object { $_.AvailabilityPct -ne 'N/A' })
    $withLoss = @($scored |
        Select-Object *, @{ n = 'LostMinutes'; e = { [double]$_.EligibleMinutes - [double]$_.AvailableMinutes } } |
        Where-Object { $_.LostMinutes -gt 0.005 } |
        Sort-Object LostMinutes -Descending)
    $totalLost = ($withLoss | Measure-Object LostMinutes -Sum).Sum
    $totalEligible = ($scored | Measure-Object EligibleMinutes -Sum).Sum

    Write-Host ([string]::new([char]0x2550, 62))
    if ($withLoss.Count -eq 0) {
        Write-Host "  RESOURCES WITH MOST IMPACT: none of the $($scored.Count) resources lost any minute"
        Write-Host ''
        return
    }
    Write-Host "  RESOURCES WITH MOST IMPACT (top $([math]::Min($Top, $withLoss.Count)) of $($withLoss.Count) with lost minutes)"
    Write-Host ("  Together: {0:N2} min lost of {1:N0} eligible min ({2:N5}% of the eligible time)" -f
        $totalLost, $totalEligible, ($totalLost / $totalEligible * 100))
    Write-Host ([string]::new([char]0x2550, 62))

    $rank = 0
    foreach ($r in ($withLoss | Select-Object -First $Top)) {
        $rank++
        Write-Host ("{0,2}. {1}  ({2}, {3}, {4})" -f $rank, $r.Name, (Get-ShortKind $r.Kind), $r.Location, $r.SubscriptionName)
        # Storage loses availability as a share of the hourly error rate of its pool, not as minutes down.
        $lossWording = $r.Kind -eq 'StorageAccount' ? 'failure rate worth' : 'lost'
        Write-Host ("    {0}% available: {4} {1:N2} of {2:N0} eligible min ({3:P1} of all lost minutes)" -f
            $r.AvailabilityPct, $r.LostMinutes, $r.EligibleMinutes, ($r.LostMinutes / $totalLost), $lossWording)
        # One line per cause, the heaviest first, with where it happened; what the causes do not add up to is shown too.
        $causes = @($r.Causes | Sort-Object Lost -Descending)
        foreach ($c in $causes) {
            $text = $c.What
            if ($c.When.Count -gt 0) {
                $shown = @($c.When | Select-Object -First 3) -join '; '
                $more = $c.When.Count -gt 3 ? " (+$($c.When.Count - 3) more)" : ''
                $text += " - $($c.WhenLabel) $shown$more"
            }
            Write-Host ("      {0,9:N2} min  {1,-14}  {2}" -f $c.Lost, $c.Verdict, $text)
        }
        $unitemised = $r.LostMinutes - ($causes | Measure-Object Lost -Sum).Sum
        if ($unitemised -gt 0.05) {
            Write-Host ("      {0,9:N2} min  {1,-14}  {2}" -f $unitemised, 'other', 'partial availability values that are not itemised')
        }
        foreach ($note in $r.Notes) { Write-Host "      note: $note" }
    }
    Write-Host ''
}
#endregion

#region Send-ToLogAnalytics
<#
.SYNOPSIS
    Sends objects to a Log Analytics custom table through the Azure Monitor Ingestion API.

.DESCRIPTION
    Gzip-compresses the JSON payload and sends it in one call. When the compressed size reaches
    900 KB (the API limit is 1 MB) the payload is split into evenly sized chunks that are sent
    one by one, each with retries.

.PARAMETER Endpoint
    Data Collection Endpoint ingestion URL.

.PARAMETER RuleId
    Data Collection Rule immutable ID.

.PARAMETER StreamName
    Stream (custom table) to send to, for example 'Custom-GetAvailResources_CL'.

.PARAMETER Token
    Bearer token for the Azure Monitor ingestion audience.

.PARAMETER Payload
    Objects to ingest. Nothing is sent when the array is empty.

.OUTPUTS
    None.
#>
function Send-ToLogAnalytics {
    param(
        [string]$Endpoint,
        [string]$RuleId,
        [string]$StreamName,
        [string]$Token,
        [object[]]$Payload
    )

    if ($Payload.Count -eq 0) { return }

    # The API takes a gzip-compressed JSON array; the stream name selects the target table.
    $uri = "$Endpoint/dataCollectionRules/$RuleId/streams/${StreamName}?api-version=2023-01-01"
    $headers = @{
        'Authorization'    = "Bearer $Token"
        'Content-Type'     = 'application/json'
        'Content-Encoding' = 'gzip'
    }

    <#
    .SYNOPSIS
        Gzip-compresses a JSON array.
    .DESCRIPTION
        Returns the byte[] directly, not through the pipeline, so PowerShell does not unroll
        the array into individual System.Byte objects.
    .PARAMETER Items
        Objects serialized as one JSON array.
    .OUTPUTS
        System.Byte[] with the compressed JSON.
    #>
    function Compress-JsonPayload([object[]]$Items) {
        $json = $Items | ConvertTo-Json -Depth 5 -Compress -AsArray
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $ms = [System.IO.MemoryStream]::new()
        try {
            # The gzip stream is disposed before reading the buffer so that all compressed data is flushed.
            $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Optimal, $true)
            $gz.Write($bytes, 0, $bytes.Length)
            $gz.Dispose()
            [byte[]]$ms.ToArray()
        } finally { $ms.Dispose() }
    }

    <#
    .SYNOPSIS
        POSTs one compressed chunk with retries.
    .DESCRIPTION
        Three attempts with exponential backoff; the last failure is rethrown.
    .PARAMETER Body
        Gzip-compressed JSON.
    .OUTPUTS
        None.
    #>
    function Send-Chunk([byte[]]$Body) {
        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $Body -TimeoutSec 60 -StatusCodeVariable statusCode
                return
            } catch {
                # Backoff 2 s, then 4 s; after the last attempt the error propagates to the caller.
                if ($attempt -eq $maxAttempts) { throw }
                $delay = [math]::Pow(2, $attempt)
                Write-Warning "Ingestion attempt $attempt to $StreamName failed (HTTP $statusCode): $($_.Exception.Message). Retrying in ${delay}s..."
                Start-Sleep -Seconds $delay
            }
        }
    }

    # Try the full payload as a single call; split only if the compressed size exceeds 900 KB.
    [byte[]]$compressed = Compress-JsonPayload $Payload
    if ($compressed.Length -lt 900KB) {
        Send-Chunk $compressed
        return
    }

    # Estimate the chunk size from the compression ratio, then send each chunk separately.
    $chunkSize = [math]::Max(1, [math]::Floor($Payload.Count / [math]::Ceiling($compressed.Length / 900KB)))
    for ($i = 0; $i -lt $Payload.Count; $i += $chunkSize) {
        $chunk = @($Payload[$i..([math]::Min($i + $chunkSize - 1, $Payload.Count - 1))])
        [byte[]]$body = Compress-JsonPayload $chunk
        Send-Chunk $body
    }
}
#endregion

#region Main
$sw = [System.Diagnostics.Stopwatch]::StartNew()

#region Step 1: Resolve the observation window
$window = Resolve-ObservationWindow $Month
$utcStart     = $window.Start
$utcEnd       = $window.End
$totalMinutes = $window.TotalMinutes

# Resource Health history covers the whole period with a workspace, otherwise only the REST retention (~30 days).
$healthCoverageStart = Get-HealthCoverageStart $utcStart -UseLogAnalytics:([bool]$SourceWorkspaceId)
$healthCoveredMinutes = $healthCoverageStart -lt $utcEnd ? [int]($utcEnd - $healthCoverageStart).TotalMinutes : 0

$periodLabel = $window.IsMonthToDate ? "month $($window.NormalizedMonth) (month-to-date)" : "month $($window.NormalizedMonth)"
Write-Host "Period: $periodLabel ($($utcStart.ToString('u')) -> $($utcEnd.ToString('u')), $totalMinutes min)"

if ($SourceWorkspaceId) {
    Write-Host "Log Analytics source workspace: $SourceWorkspaceId (Activity Log via KQL, Resource Health via KQL + REST API)"
} elseif ($healthCoverageStart -gt $utcStart -and $healthCoveredMinutes -gt 0) {
    Write-Host "WARNING: Resource Health history covers only part of this period ($($healthCoverageStart.ToString('u')) -> $($utcEnd.ToString('u')), $healthCoveredMinutes of $totalMinutes min). Earlier minutes have no Resource Health evidence."
} elseif ($healthCoveredMinutes -eq 0) {
    Write-Host 'WARNING: Resource Health history does not cover this period. Suspect minutes have no Resource Health evidence.'
}

#endregion

#region Step 2: Authenticate and resolve subscriptions
# -BatchSize explicitly set implies -Batch
if ($PSBoundParameters.ContainsKey('BatchSize') -and -not $Batch) { $Batch = [switch]::new($true) }

Write-Host -NoNewline 'Authenticating... '
# Resolve subscription display names to objects, build ID→Name map
$allAzSubs = @(Get-AzSubscription)
$azSubsByName = @{}
foreach ($subscription in $allAzSubs) {
    if (-not $azSubsByName.ContainsKey($subscription.Name)) {
        $azSubsByName[$subscription.Name] = [System.Collections.Generic.List[object]]::new()
    }
    $azSubsByName[$subscription.Name].Add($subscription)
}
# Every requested name must match exactly one subscription.
$resolvedSubs = @(foreach ($name in $Subscriptions) {
    if (-not $azSubsByName.ContainsKey($name)) { throw "Subscription '$name' not found." }
    if ($azSubsByName[$name].Count -gt 1) { throw "Multiple subscriptions named '$name'." }
    $azSubsByName[$name][0]
})
$subIds      = @($resolvedSubs.Id)
$subIdToName = @{}; foreach ($s in $resolvedSubs) { $subIdToName[$s.Id] = $s.Name }

# One ARM token serves all the REST calls of the run.
$armToken = Get-PlainToken 'https://management.azure.com'

Write-Host 'OK'
Write-Host "Processing $($resolvedSubs.Count) subscription(s): $($resolvedSubs.Name -join ', ')"
Write-Host "Kinds: $($Kinds -join ', ')"

#endregion

#region Step 3: Query the Resource Graph inventory
Write-Host -NoNewline 'Querying resource inventory... '
$resources = Get-ResourceInventory -SubscriptionIds $subIds -SubIdToName $subIdToName `
    -Kinds $Kinds -ResourceNameFilter $Resource

$regionCount = @($resources | ForEach-Object { $_.Location } | Select-Object -Unique).Count
Write-Host "Found $($resources.Count) resource(s) across $($resolvedSubs.Count) subscription(s), $regionCount region(s)."

if ($resources.Count -eq 0) { Write-Host 'No resources found.'; return }

if ($Batch) {
    $metricsToken = Get-PlainToken 'https://metrics.monitor.azure.com'
    Write-Host "Mode: Batch (batch-size=$BatchSize)"
}

#endregion

#region Step 4: Build the initial eligibility records
# Every minute starts as eligible; the later steps subtract the minutes that are not Maximum Available Minutes.
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
        # What the "most impact" report shows: the causes of the lost minutes and notes on how far to trust the figure.
        Causes                   = @()
        Notes                    = @()
    }
}

#endregion

#region Step 5: Fetch Azure Monitor metrics
# Storage accounts and Web Apps use their own algorithms (Steps 5b and 5c) and are not part of the PT1M metric fetch.
$metricResources = @($resources | Where-Object { $_.Kind -notin 'StorageAccount', 'WebApp' })
$metricResults = @{}
# Batch mode sends one call per group of resources of a region; otherwise every resource is queried on its own.
if ($metricResources.Count -gt 0) {
    if ($Batch) {
        $uniqueRegions = @($metricResources | ForEach-Object { $_.Location.ToLowerInvariant() } | Select-Object -Unique | Sort-Object)
        Test-BatchEndpoints -MetricsToken $metricsToken -Regions $uniqueRegions
        $metricResults = Get-BatchAvailabilityMetrics -Resources $metricResources -StartDate $utcStart `
            -EndDate $utcEnd -ThrottleLimit $Parallelism -BatchSize $BatchSize -MetricsToken $metricsToken
    } else {
        $metricResults = Get-AvailabilityMetrics -Resources $metricResources -StartDate $utcStart `
            -EndDate $utcEnd -ThrottleLimit $Parallelism -ArmToken $armToken
    }
}
$metricsToken = $null

#endregion

#region Step 5b: Storage accounts
# The storage algorithm (README, "Algorithms > Storage accounts") scores the hourly Error Rate of each pool
# (subscription and region) and attributes the failing minutes to Resource Health. It fills the eligibility records directly.
$storageResources = @($resources | Where-Object { $_.Kind -eq 'StorageAccount' })
if ($storageResources.Count -gt 0) {
    $storageResults = Invoke-StorageAvailability -Resources $storageResources -PeriodStart $utcStart -PeriodEnd $utcEnd `
        -TotalMinutes $totalMinutes -ThrottleLimit $Parallelism -ArmToken $armToken `
        -HealthLeadMinutes $HealthLeadMinutes -SourceWorkspaceId $SourceWorkspaceId -SubscriptionIds $subIds
    foreach ($res in $storageResources) {
        $key = $res.ResourceId.ToLowerInvariant()
        Set-StorageEligibility -Record $eligByRes[$key] -Result $storageResults[$key]
    }
}

#endregion

#region Step 5c: Web Apps
# The Web App algorithm (README, "Algorithms > Web Apps") counts the minutes in which every request failed
# with a 5xx and attributes them to the Activity Log and Resource Health. It fills the eligibility records directly.
$webResources = @($resources | Where-Object { $_.Kind -eq 'WebApp' })
if ($webResources.Count -gt 0) {
    $webResults = Invoke-WebAvailability -Resources $webResources -PeriodStart $utcStart -PeriodEnd $utcEnd `
        -TotalMinutes $totalMinutes -ThrottleLimit $Parallelism -ArmToken $armToken `
        -HealthLeadMinutes $HealthLeadMinutes -GraceMinutes $ActivityGraceMinutes `
        -SourceWorkspaceId $SourceWorkspaceId -SubscriptionIds $subIds
    foreach ($res in $webResources) {
        $key = $res.ResourceId.ToLowerInvariant()
        Set-WebEligibility -Record $eligByRes[$key] -Result $webResults[$key]
    }
}

#endregion

#region Step 5d: Detect perpetually-deallocated VMs
# VMs that are currently deallocated/stopped AND had zero healthy minutes for the
# entire period are excused — the VM was never running so availability is N/A.
# This handles cases where the deallocate event fell outside Activity Log and
# Resource Health retention windows.
$perpetuallyDeallocated = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$vmCandidates = @($resources | Where-Object {
    $_.Kind -eq 'VirtualMachine' -and
    $metricResults.ContainsKey($_.ResourceId.ToLowerInvariant()) -and
    $metricResults[$_.ResourceId.ToLowerInvariant()].SuspectMinutes -ge $totalMinutes
})
# The instance view tells the current power state of each candidate.
foreach ($vm in $vmCandidates) {
    try {
        $ivUrl = "https://management.azure.com$($vm.ResourceId)/instanceView?api-version=2024-07-01"
        $ivResp = Invoke-RestMethod -Uri $ivUrl -Headers @{ Authorization = "Bearer $armToken" } -Method Get
        $powerCode = ($ivResp.statuses | Where-Object { $_.code -like 'PowerState/*' } | Select-Object -First 1).code
        if ($powerCode -in 'PowerState/deallocated', 'PowerState/stopped') {
            [void]$perpetuallyDeallocated.Add($vm.ResourceId)
            $elig = $eligByRes[$vm.ResourceId.ToLowerInvariant()]
            $elig.EligibleMinutes = 0
            $elig.ExcusedMinutes = $totalMinutes
            $elig.SuspectMinutes = $totalMinutes
            $elig.AvailabilityPct = 'N/A'
            Write-Host "  [$($vm.Name)] Deallocated for entire period — excluded from availability counts"
        }
    }
    catch {
        Write-Warning "Instance View check failed for '$($vm.Name)': $_"
    }
}

#endregion

#region Step 6: Build the suspect candidates
# Collect the resources that have at least one suspect minute: these need Activity Log and
# Resource Health investigation. Null and zero ticks are combined into one AllGapTicks array,
# and kept separately as well because the VM algorithm treats them differently.
$suspectCandidates = [System.Collections.Generic.List[object]]::new()
foreach ($res in $resources) {
    $key = $res.ResourceId.ToLowerInvariant()
    if ($perpetuallyDeallocated.Contains($res.ResourceId)) { continue }
    $mr = $metricResults[$key]
    if ($mr -and $mr.SuspectMinutes -gt 0) {
        # Null and zero minutes together are the gap ticks; the VM algorithm also needs them apart.
        $allTicks = [System.Collections.Generic.List[long]]::new()
        $allTicks.AddRange([long[]]@($mr.GapTicks))
        $allTicks.AddRange([long[]]@($mr.ZeroAvailTicks))
        if ($allTicks.Count -gt 0) {
            $suspectCandidates.Add([PSCustomObject]@{
                Name           = $res.Name
                Kind           = $res.Kind
                ResourceId     = $res.ResourceId
                SubscriptionId = $res.SubscriptionId
                CreationTime   = $res.CreationTime
                SkuName        = $res.SkuName
                AllGapTicks    = @($allTicks)
                NullTicksArray = @($mr.GapTicks)
                ZeroTicksArray = @($mr.ZeroAvailTicks)
            })
        }
    }
}

#endregion

#region Step 6b: Investigate the suspect minutes
# With -SourceWorkspaceId, Activity Log events and Resource Health history are fetched
# in bulk from Log Analytics and combined with the REST history (see "Resource Health history" in the README).
# The workspace is also asked about every SQL database: one whose history shows a platform health event
# is investigated even without a zero minute, to report the brief failures the metric does not count.
$logAnalyticsData = $null
$sqlResources = @($resources | Where-Object { $_.Kind -eq 'AzureSqlDatabase' -and $metricResults.ContainsKey($_.ResourceId.ToLowerInvariant()) -and
        -not $metricResults[$_.ResourceId.ToLowerInvariant()].ExcludeFromAvailability })
if ($SourceWorkspaceId -and ($suspectCandidates.Count -gt 0 -or $sqlResources.Count -gt 0)) {
    Write-Host -NoNewline 'Fetching Activity Log + Resource Health history from Log Analytics... '
    # One bulk query fetches the Activity Log and the Resource Health history of every candidate.
    $laTokenStr = Get-PlainToken 'https://api.loganalytics.io'
    $laResourceIds = @(@($suspectCandidates | ForEach-Object { $_.ResourceId }) + @($sqlResources | ForEach-Object { $_.ResourceId }))
    $logAnalyticsData = Get-LogAnalyticsData -WorkspaceId $SourceWorkspaceId `
        -SubscriptionIds $subIds -ResourceIds $laResourceIds `
        -PeriodStart $utcStart -PeriodEnd $utcEnd `
        -ArmToken $laTokenStr
    $laTokenStr = $null

    # Add the SQL databases that had a platform health event but no suspect minute.
    $investigated = [System.Collections.Generic.HashSet[string]]::new([string[]]@($suspectCandidates | ForEach-Object { $_.ResourceId.ToLowerInvariant() }))
    foreach ($res in $sqlResources) {
        $key = $res.ResourceId.ToLowerInvariant()
        if ($investigated.Contains($key) -or -not $logAnalyticsData.ContainsKey($key)) { continue }
        $platformEvent = @($logAnalyticsData[$key].HealthRaw | Where-Object { $_.State -in 'Unavailable', 'Degraded' -and $_.Cause -ne 'UserInitiated' })
        if ($platformEvent.Count -eq 0) { continue }
        $suspectCandidates.Add([PSCustomObject]@{
            Name = $res.Name; Kind = $res.Kind; ResourceId = $res.ResourceId; SubscriptionId = $res.SubscriptionId
            CreationTime = $res.CreationTime; SkuName = $res.SkuName; AllGapTicks = @(); NullTicksArray = @(); ZeroTicksArray = @()
        })
    }
}

# Every serverless SQL database is investigated, with or without suspect minutes: its paused minutes are not
# Deployment Minutes and only the billed-compute metric tells them.
$investigated = [System.Collections.Generic.HashSet[string]]::new([string[]]@($suspectCandidates | ForEach-Object { $_.ResourceId.ToLowerInvariant() }))
foreach ($res in $sqlResources) {
    if ($res.SkuName -notmatch '_S_' -or $investigated.Contains($res.ResourceId.ToLowerInvariant())) { continue }
    $suspectCandidates.Add([PSCustomObject]@{
        Name = $res.Name; Kind = $res.Kind; ResourceId = $res.ResourceId; SubscriptionId = $res.SubscriptionId
        CreationTime = $res.CreationTime; SkuName = $res.SkuName; AllGapTicks = @(); NullTicksArray = @(); ZeroTicksArray = @()
    })
}

# The investigation attributes every suspect minute (VM and SQL algorithms).
$suspectResults = $null
if ($suspectCandidates.Count -gt 0) {
    $suspectResults = Invoke-SuspectGapInvestigation -Candidates @($suspectCandidates) `
        -PeriodStart $utcStart -PeriodEnd $utcEnd -ThrottleLimit $Parallelism `
        -GraceMinutes $ActivityGraceMinutes -FaultWindowMinutes $FaultWindowMinutes -HealthLeadMinutes $HealthLeadMinutes -ArmToken $armToken `
        -HealthCoverageStart $healthCoverageStart `
        -LogAnalyticsData $logAnalyticsData
}

#endregion

#region Step 7: Assemble the final results
# Wires investigation outcomes into each resource's eligibility record:
#   - Subtracts the minutes that are not Maximum Available Minutes from EligibleMinutes
#   - Computes AvailableMinutes, ConfirmedDowntimeMinutes, UnexplainedSuspectMinutes
#   - Prints per-resource classification narration
# Storage accounts were already completed by their own algorithm (Step 5b) and have no metric result here.
foreach ($res in $resources) {
    $key  = $res.ResourceId.ToLowerInvariant()
    $elig = $eligByRes[$key]
    $mr   = $metricResults[$key]

    if (-not $mr) { continue }

    # No numeric datapoint at all: the resource cannot be judged and is N/A.
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

    # Skip perpetually-deallocated VMs — already handled in Step 5d
    if ($perpetuallyDeallocated.Contains($res.ResourceId)) { continue }

    $gc = $suspectResults ? $suspectResults[$key] : $null

    # Counters from the investigation (all zero when the resource had no suspect minutes).
    $activityLogExcludedGapMinutes = $gc ? $gc.ActivityLogExcludedGapMinutes : 0
    $healthExplainedGapMinutes     = $gc ? $gc.HealthExplainedGapMinutes : 0
    $metricIssueNullMinutes        = $gc ? $gc.MetricIssueNullMinutes : 0
    # The minutes that are not Maximum Available Minutes (the SLA's Deployment Minutes): a VM that was not running or
    # did not exist; a SQL database before its creation or paused. The other excused minutes stay in the denominator.
    $eligibleReductionMinutes      = $gc ? $gc.EligibleReductionMinutes : 0

    # They leave the eligible total, which never goes below zero.
    $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes - $eligibleReductionMinutes)

    if ($gc) {
        $totalSuspectMinutes = $mr.SuspectMinutes

        # Count contiguous suspect gaps for narration by sorting all suspect
        # ticks and counting boundaries where consecutive ticks are >1 min apart.
        $allSuspectTicks = [System.Collections.Generic.List[long]]::new()
        $allSuspectTicks.AddRange([long[]]@($mr.GapTicks))
        $allSuspectTicks.AddRange([long[]]@($mr.ZeroAvailTicks))
        # A new gap starts wherever consecutive suspect minutes are more than one minute apart.
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
            Write-Host "  [$($res.Name)] metric scan found $totalSuspectMinutes suspect min across $suspectGapCount suspect gaps (null or zero availability values)"
            # One line with what decided the suspect minutes, then the evidence.
            Write-Host "  [$($res.Name)] $($gc.OutcomeLabel) classified suspect min: $($gc.OutcomeText)"
            foreach ($line in $gc.Evidence) { Write-Host "  [$($res.Name)]   $line" }
        }
        elseif ($gc.Evidence) {
            # Investigated without any suspect minute (a SQL database with a platform health event): evidence only.
            foreach ($line in $gc.Evidence) { Write-Host "  [$($res.Name)] $line" }
        }
    }

    # Downtime is binary, as in the SLA: platform-attributed minutes (Faults) plus the zero minutes nothing
    # explains (Unresolved). Without an investigation every suspect minute is unexplained.
    $faultMinutes      = $gc ? $gc.PlatformFaultGapMinutes : 0
    $unresolvedMinutes = $gc ? $gc.UnresolvedZeroDowntimeMinutes : $mr.SuspectMinutes

    # Degraded minutes (availability above 0 and below 100%) are never downtime: the SLA counts a minute as down
    # only when there is no connectivity. They stay eligible and available and are only reported.
    if ($mr.DegradedMinutes -gt 0) {
        Write-Host "  [$($res.Name)] $($mr.DegradedMinutes) degraded min (availability above 0 and below 100%) are not counted as downtime"
    }

    # Wire final totals into the eligibility record.
    # Invariant: Suspect = Faults + Excused + Unresolved
    $elig.SuspectMinutes = $mr.SuspectMinutes
    $elig.ConfirmedDowntimeMinutes = $faultMinutes
    $elig.ExcusedMinutes = $activityLogExcludedGapMinutes + $healthExplainedGapMinutes + $metricIssueNullMinutes
    $elig.UnexplainedSuspectMinutes = $unresolvedMinutes

    # The causes of the "most impact" report: VMs from the spans of counted minutes, SQL databases from their zero minutes.
    if ($gc) {
        $elig.Causes = @(
            if ($gc.LossSpans) { Get-VmLossCauses @($gc.LossSpans) }
            if ($gc.LossMinutes) { Get-SqlLossCauses @($gc.LossMinutes) }
        )
    }
    # Show how the eligible minutes were reduced.
    if ($eligibleReductionMinutes -gt 0) {
        Write-Host "  [$($res.Name)] eligible min = $totalMinutes - $(@($gc.EligibleReductions) -join ' - ') = $($elig.EligibleMinutes)"
    }

    # The SLA formula: Uptime Percentage = (Maximum Available Minutes - Downtime) / Maximum Available Minutes x 100,
    # with the eligible minutes as Maximum Available Minutes.
    $elig.AvailableMinutes = [math]::Max(0, $elig.EligibleMinutes - $faultMinutes - $unresolvedMinutes)
    $elig.AvailabilityPct = $elig.EligibleMinutes -gt 0 ?
        [math]::Round($elig.AvailableMinutes / $elig.EligibleMinutes * 100, 5).ToString('F5') :
        'N/A'
}

#endregion

#region Step 8: Print the results table and summaries
# Sort the results and print the table plus the per-subscription summaries.
$sorted = @($eligByRes.Values |
    Sort-Object SubscriptionName, Kind, Name)
$summaries = @(Get-AvailabilitySummaries $sorted)

Write-ResultsTable $sorted
Write-SubscriptionSummaries $summaries
if ($TopImpact -gt 0) { Write-TopImpact $sorted $TopImpact }

#endregion

#region Step 9: Optional Log Analytics ingestion
if ($sendToLogAnalytics) {
    Write-Host -NoNewline 'Sending results to Log Analytics... '

    $monitorToken = Get-PlainToken 'https://monitor.azure.com'

    $runId = [guid]::NewGuid().ToString()
    $normalizedMonth = $window.NormalizedMonth
    $isMonthToDate = $window.IsMonthToDate
    $periodStartIso = $utcStart.ToString('o')
    $periodEndIso = $utcEnd.ToString('o')

    # Build per-resource detail payload
    $resourcePayload = @(foreach ($elig in $eligByRes.Values) {
        @{
            RunId                     = $runId
            Month                     = $normalizedMonth
            PeriodStart               = $periodStartIso
            PeriodEnd                 = $periodEndIso
            IsMonthToDate             = $isMonthToDate
            SubscriptionName          = $elig.SubscriptionName
            ResourceName              = $elig.Name
            ResourceId                = $elig.ResourceId
            ResourceGroup             = $elig.ResourceGroupName
            Kind                      = $elig.Kind
            Location                  = $elig.Location
            EligibleMinutes           = $elig.EligibleMinutes
            AvailableMinutes          = $elig.AvailableMinutes
            SuspectMinutes            = $elig.SuspectMinutes
            ConfirmedDowntimeMinutes  = $elig.ConfirmedDowntimeMinutes
            ExcusedMinutes            = $elig.ExcusedMinutes
            UnexplainedSuspectMinutes = $elig.UnexplainedSuspectMinutes
            AvailabilityPct           = if ($elig.AvailabilityPct -eq 'N/A') { -1 } else { [double]$elig.AvailabilityPct }
        }
    })

    Send-ToLogAnalytics -Endpoint $DceEndpoint -RuleId $DcrImmutableId `
        -StreamName 'Custom-GetAvailResources_CL' -Token $monitorToken -Payload $resourcePayload

    # Project precomputed summaries into the ingestion schema.
    $commonSummary = @{
        RunId         = $runId
        Month         = $normalizedMonth
        PeriodStart   = $periodStartIso
        PeriodEnd     = $periodEndIso
        IsMonthToDate = $isMonthToDate
    }

    $summaryPayload = @(foreach ($summary in ($summaries |
        Where-Object SummaryLevel -ne 'OverallKindLocation')) {
        $commonSummary + @{
            SummaryLevel     = $summary.SummaryLevel
            SubscriptionName = $summary.SubscriptionName
            Kind             = $summary.Kind
            Location         = $summary.Location
            ResourceCount    = $summary.ResourceCount
            EligibleMinutes  = [math]::Round($summary.EligibleMinutes, 2)
            AvailableMinutes = [math]::Round($summary.AvailableMinutes, 2)
            AvailabilityPct  = $summary.AvailabilityPct
        }
    })

    if ($summaryPayload.Count -gt 0) {
        Send-ToLogAnalytics -Endpoint $DceEndpoint -RuleId $DcrImmutableId `
            -StreamName 'Custom-GetAvailSummary_CL' -Token $monitorToken -Payload $summaryPayload
    }

    $monitorToken = $null
    Write-Host "OK (RunId: $runId, $($resourcePayload.Count) resource rows, $($summaryPayload.Count) summary rows)"
}

#endregion

$sw.Stop()
Write-Host "Completed in $($sw.Elapsed.ToString('hh\:mm\:ss\.ff'))"
#endregion
