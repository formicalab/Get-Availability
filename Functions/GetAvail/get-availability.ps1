#Requires -Version 7.6
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Reports month-scoped availability for VMs, Azure SQL databases, Storage Accounts, and Web Apps.

.DESCRIPTION
    Availability pipeline:
      1. Resolve subscriptions
      2. Inventory via Resource Graph
      3. Fetch metrics (Azure Monitor, parallel)
      4. Investigate suspect gaps (Activity Log + Resource Health)
      5. Assemble results
      6. Print table + summaries

    A suspect minute is any metric datapoint that is null or below 100%.
    Contiguous suspect minutes form "suspect gaps" for narration.

    Suspect minutes are first checked against Activity Log events:
            - Resource creation/deletion: VM timeCreated establishes initial existence;
                successful delete/write pairs establish later non-existence intervals.
      - Virtual Machines: start/deallocate/power off/restart
      - Azure SQL Databases: pause/resume
      - Web Apps: stop/start/restart
    Resource Health is then applied to classify remaining suspects:
      - platform fault confirmed (Unavailable/Degraded) -> counts as downtime
      - Unknown / customer-initiated -> valid explanation, excluded from eligibility
    Remaining null minutes become metric issues (excluded from eligibility),
    while remaining 0% minutes are trusted as downtime.

    Virtual machines follow a different algorithm, described step by step in the
    README ("Algorithms"): zero minutes are attributed with the metric's Context
    dimension (Platform / User / Unknown), Resource Health notes are classified by
    what they say, platform notes explain minutes only within -FaultWindowMinutes,
    and a gap stays explained by what started it.

    When -SourceWorkspaceId is specified, Activity Log lifecycle events are
    fetched from a Log Analytics workspace via a single bulk KQL query instead
    of per-resource REST API calls. This is faster for large estates and uses
    workspace retention (typically 365 days). Resource Health data uses a
    hybrid approach: Log Analytics transitions cover the period beyond the
    REST API's ~30-day retention, while REST API transitions (curated,
    synthetic, with retroactively corrected causes) are authoritative for
    the last ~30 days. The two sources are merged to produce complete
    coverage. Without -SourceWorkspaceId, the REST APIs are used directly.
    Note: this is NOT the workspace used for result ingestion (see
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
    Post-operation grace window for Activity Log lifecycle events (default: 10).

.PARAMETER FaultWindowMinutes
    Virtual machines only: how long a platform Resource Health note (for example
    "Redeploying due to host failure") can explain suspect minutes that the metric
    does not attribute itself (default: 30).

.PARAMETER HealthLeadMinutes
    Storage accounts only: how many minutes before a platform Resource Health event
    (for example "Degraded") its server failures are still attributed to it, because
    Resource Health raises the event after the first failed requests (default: 5).

.PARAMETER Batch
    Use the regional Metrics Batch API instead of per-resource metric calls.

.PARAMETER BatchSize
    Max resources per batch call (default: 10, max 50). Implies -Batch.

.PARAMETER SourceWorkspaceId
    Log Analytics workspace ID (GUID) used as a source for historical Activity
    Log and Resource Health data. This is NOT the ingestion target — it is
    an existing workspace that receives Activity Log diagnostic settings from
    the target subscriptions. When provided, lifecycle events are fetched via
    a single bulk KQL query (faster for large estates, uses workspace
    retention). Resource Health uses a hybrid approach: Log Analytics
    transitions cover the period beyond the REST API's ~30-day retention
    limit, while REST API transitions (curated, with corrected causes) are
    authoritative for the last ~30 days.

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

#region Log Analytics ingestion

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

    if ($start -ge $currentMinute) { throw '-Month must not be in the future.' }
    if ($start -lt $currentMinute.AddDays(-90)) { throw '-Month cannot start more than 90 days before now.' }

    $nextMonth = $start.AddMonths(1)
    $end = $nextMonth -lt $currentMinute ? $nextMonth : $currentMinute
    if ($end -le $start) { throw '-Month produced an empty observation period.' }

    [PSCustomObject]@{
        Start           = $start
        End             = $end
        NormalizedMonth = $start.ToString('yyyyMM', [System.Globalization.CultureInfo]::InvariantCulture)
        IsMonthToDate   = $end -lt $nextMonth
        TotalMinutes    = [int]($end - $start).TotalMinutes
    }
}

#endregion

#region Resource inventory (Azure Resource Graph)

<#
.SYNOPSIS
    Lists the resources to measure through Azure Resource Graph.

.DESCRIPTION
    Queries Resource Graph for the requested resource kinds across the supplied subscriptions,
    optionally filtered by name, and returns lightweight descriptors for the metrics pipeline.
    SQL system databases (master) and Function Apps are excluded. For virtual machines the
    creation time is included, because it marks when the VM started to exist.

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
    ResourceGroupName, Location and CreationTime, sorted by subscription, kind and name.
#>
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
        'webapp'  = 'microsoft.web/sites'
    }
    $unsupported = @($Kinds | Where-Object { -not $kindToType.ContainsKey($_) })
    if ($unsupported.Count -gt 0) {
        throw "Unsupported kind(s): $($unsupported -join ', '). Allowed values: vm, sql, storage, webapp."
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
${nameFilter}| where not(type =~ 'microsoft.web/sites' and kind contains 'functionapp')
| extend resourceKind = case(
    type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
    type =~ 'microsoft.sql/servers/databases', 'AzureSqlDatabase',
    type =~ 'microsoft.storage/storageaccounts', 'StorageAccount',
    type =~ 'microsoft.web/sites', 'WebApp',
    'Other'
)
| project id, name, displayName, type, subscriptionId, resourceGroup, location, resourceKind,
          sqlServerName, databaseName,
          creationTime=case(
              type =~ 'microsoft.compute/virtualmachines', tostring(properties.timeCreated),
              type =~ 'microsoft.storage/storageaccounts', tostring(properties.creationTime),
              '')
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
            # Resource Graph returns the creation time either as a DateTime or as an
            # ISO string, depending on the Az.ResourceGraph version; normalise to UTC.
            $creationTime = $null
            if ($kind -in 'VirtualMachine', 'StorageAccount' -and $row.creationTime) {
                if ($row.creationTime -is [datetime]) {
                    $creationTime = ([DateTimeOffset][datetime]$row.creationTime).ToUniversalTime()
                } else {
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
            $resources.Add([PSCustomObject]@{
                Name              = $name
                Kind              = $kind
                ResourceId        = [string]$row.id
                SubscriptionId    = $subId
                SubscriptionName  = $SubIdToName[$subId] ?? $subId
                ResourceGroupName = [string]$row.resourceGroup
                Location          = [string]$row.location
                CreationTime      = $creationTime
            })
        }
        $skipToken = [string]::IsNullOrWhiteSpace($response.SkipToken) ? $null : $response.SkipToken
    } while ($skipToken)

    @($resources | Sort-Object SubscriptionName, Kind, Name)
}

#endregion

#region Helpers

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
    Returns the ~30-day Resource Health REST retention cutoff.

.DESCRIPTION
    In hybrid mode, workspace history older than this cutoff is kept, and REST history
    (curated, with retroactively corrected causes) is authoritative for the last ~30 days.

.OUTPUTS
    System.DateTimeOffset - the current UTC minute minus 30 days.
#>
function Get-RestHealthCutoff {
    (Get-CurrentUtcMinute).AddDays(-30)
}

<#
.SYNOPSIS
    Prepares the Resource Health history sources shared by the VM and storage algorithms.

.DESCRIPTION
    Both algorithms read Resource Health history the same way (see HealthHistory in the compiled code):
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
    foreach ($entry in ($LogAnalyticsData ?? @{}).GetEnumerator()) {
        $list = [System.Collections.Generic.List[HealthNote]]::new()
        foreach ($raw in $entry.Value.HealthRaw) {
            $list.Add([HealthHistory]::FromWorkspace($raw.Timestamp.UtcTicks, $raw.State, $raw.Title, $raw.Cause))
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
    With -UseLogAnalytics the hybrid approach (workspace for older history, REST for the last
    ~30 days) covers the whole period. Without it, coverage is limited to the REST retention.

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

#region Log Analytics bulk data fetch

<#
.SYNOPSIS
    Bulk-fetches Activity Log events and Resource Health history from a Log Analytics workspace.

.DESCRIPTION
    Runs a single KQL query that returns Activity Log events (lifecycle operations plus
    creation/deletion) and Resource Health events for the given subscriptions and
    resources. All non-failed Activity Log statuses are kept: a lifecycle operation is
    logged as Start, Accept and Success, and the Start event marks when the minutes it
    affects begin, so filtering on Success alone leaves those first minutes unexplained.

    ActivityEvents drive lifecycle classification and existence tracking.
    HealthTransitions (state changes with consolidated causes) are used only for
    transitions older than the REST API's ~30-day retention cutoff; the investigation
    function merges them with REST API transitions for the last ~30 days.
    HealthRaw keeps every raw health event (state, cause, title) and is used by the VM
    algorithm, which classifies health notes by what they say rather than by state change.

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
    Hashtable keyed by lowercase resource ID; each value has ActivityEvents,
    HealthTransitions and HealthRaw lists.
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

    $startIso = $PeriodStart.ToString('O')
    $endIso   = $PeriodEnd.ToString('O')
    $subList  = ($SubscriptionIds | ForEach-Object { "'$_'" }) -join ', '
    $normalizedResourceIds = @($ResourceIds |
        ForEach-Object { $_.ToLowerInvariant() } |
        Sort-Object -Unique)
    $resourceList = ($normalizedResourceIds | ForEach-Object {
        "'$($_.Replace("'", "''"))'"
    }) -join ', '

    #region Query the workspace
    # Single KQL query that fetches both Activity Log operations and Resource
    # Health transitions, tagged with a Source column to distinguish them.
    $kql = @"
let subs = dynamic([$subList]);
let resourceIds = dynamic([$resourceList]);
let actOps = dynamic([
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/START/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/DEALLOCATE/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/POWEROFF/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/RESTART/ACTION',
  'MICROSOFT.SQL/SERVERS/DATABASES/PAUSE/ACTION',
  'MICROSOFT.SQL/SERVERS/DATABASES/RESUME/ACTION',
  'MICROSOFT.WEB/SITES/STOP/ACTION',
  'MICROSOFT.WEB/SITES/START/ACTION',
  'MICROSOFT.WEB/SITES/RESTART/ACTION',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/WRITE',
  'MICROSOFT.SQL/SERVERS/DATABASES/WRITE',
  'MICROSOFT.STORAGE/STORAGEACCOUNTS/WRITE',
  'MICROSOFT.WEB/SITES/WRITE',
  'MICROSOFT.COMPUTE/VIRTUALMACHINES/DELETE',
  'MICROSOFT.SQL/SERVERS/DATABASES/DELETE',
  'MICROSOFT.STORAGE/STORAGEACCOUNTS/DELETE',
  'MICROSOFT.WEB/SITES/DELETE'
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

    $result = $jsonStr | ConvertFrom-Json
    $table = $result.tables[0]
    $columns = @($table.columns | ForEach-Object { $_.name })
    $rows = @($table.rows)
    #endregion

    #region Parse rows into per-resource data
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
                HealthRaw         = [System.Collections.Generic.List[object]]::new()
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

                # Extract the health note title (e.g. 'Redeploying due to host failure');
                # the VM algorithm classifies notes by title.
                $rawTitle = ''
                if ($props.PSObject.Properties['title']) {
                    $rawTitle = [string]$props.title
                }

                if ($state) {
                    # Determine incident lifecycle phase from OperationNameValue
                    # (e.g. 'Microsoft.Resourcehealth/healthevent/Activated/action')
                    $opName = [string]$row[$iOp]
                    $opType = if ($opName -match '/Activated/') { 'Activated' }
                              elseif ($opName -match '/Resolved/')  { 'Resolved' }
                              elseif ($opName -match '/InProgress/') { 'InProgress' }
                              else { 'Updated' }

                    # Collect raw events per resource for post-processing into
                    # clean transitions (deduplication + cause consolidation)
                    if (-not $rawHealthEvents.ContainsKey($resId)) {
                        $rawHealthEvents[$resId] = [System.Collections.Generic.List[object]]::new()
                    }
                    $rawHealthEvents[$resId].Add([PSCustomObject]@{
                        Timestamp     = $ts
                        State         = $state
                        RawCause      = $rawCause
                        OperationType = $opType
                    })

                    # Keep the unprocessed event too (state, cause and title as logged).
                    $entry.HealthRaw.Add([PSCustomObject]@{
                        Timestamp = $ts
                        State     = $state
                        Cause     = $rawCause
                        Title     = $rawTitle
                    })
                }
            }
        }
    }

    #endregion

    #region Consolidate health events into transitions

    <#
    .SYNOPSIS
        Sets the REST-style cause fields of a health transition from a raw Activity Log cause.
    .DESCRIPTION
        Maps UserInitiated / PlatformInitiated to the REST API's reasonType wording. Other causes
        become an empty reasonType, or are kept as-is with -KeepUnmapped (used when updating a
        transition whose cause is already known to be meaningful).
    .PARAMETER Transition
        Transition object whose ReasonType, Context and HealthEventCause are overwritten.
    .PARAMETER Cause
        Raw cause (for example 'UserInitiated').
    .PARAMETER KeepUnmapped
        Keep causes other than UserInitiated / PlatformInitiated instead of blanking them.
    .OUTPUTS
        None. The transition is modified in place.
    #>
    function Set-TransitionCause {
        param($Transition, [string]$Cause, [switch]$KeepUnmapped)
        $Transition.ReasonType = switch ($Cause) {
            'UserInitiated'     { 'Customer Initiated' }
            'PlatformInitiated' { 'Platform Initiated' }
            default             { $KeepUnmapped ? $Cause : '' }
        }
        $isUser = $Cause -eq 'UserInitiated'
        $Transition.Context          = $isUser ? 'Customer Initiated' : ''
        $Transition.HealthEventCause = $isUser ? 'UserInitiated' : ''
    }

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
                # Build a transition object matching the REST API schema so the
                # investigation function can process both sources identically
                $transition = [PSCustomObject]@{
                    OccurredOn       = $evt.Timestamp
                    State            = $st
                    ReasonType       = ''
                    Context          = ''
                    HealthEventCause = ''
                }
                Set-TransitionCause $transition $rc
                $entry.HealthTransitions.Add($transition)
                $trackedState = $st
                $lastTransition = $transition

                # Track non-Available transitions for retroactive cause fix on Resolved
                if ($inIncident -and $st -ne 'Available') {
                    $incidentTransitions.Add($transition)
                }
            }
            elseif ($lastTransition -and $rc -and $rc -ne 'Unknown' -and
                    $lastTransition.ReasonType -in @('', 'Unknown')) {
                # Same state — update cause on last transition if a more specific
                # cause arrived (e.g. Updated event reveals 'UserInitiated')
                Set-TransitionCause $lastTransition $rc -KeepUnmapped
            }

            # Close incident on Resolved — retroactively apply the final
            # determined cause to ALL transitions in this incident, replicating
            # the REST API's behaviour of correcting causes after the fact
            if ($op -eq 'Resolved') {
                if ($incidentCause -and $incidentCause -ne 'Unknown') {
                    foreach ($t in $incidentTransitions) { Set-TransitionCause $t $incidentCause -KeepUnmapped }
                }
                # Reset incident tracking for next incident
                $inIncident = $false
                $incidentTransitions = [System.Collections.Generic.List[object]]::new()
                $incidentCause = ''
            }
        }

        # Handle open incident at end of event stream — incident was never
        # Resolved (e.g. still ongoing or data truncated). Apply the best
        # known cause retroactively to any transitions in the open incident.
        if ($inIncident -and $incidentCause -and $incidentCause -ne 'Unknown') {
            foreach ($t in $incidentTransitions) { Set-TransitionCause $t $incidentCause -KeepUnmapped }
        }
    }
    #endregion

    Write-Host "Log Analytics: fetched $($rows.Count) events for $($dataByRes.Count) resource(s)"
    $dataByRes
}

#endregion

#region Compiled metric processor
# The JSON processing loop iterates ~44 K data-points per resource (PT1M × 1
# month).  In interpreted PowerShell that is the dominant bottleneck; compiling
# the identical logic as C# via Add-Type makes it run at native .NET speed.

if (-not ([System.Management.Automation.PSTypeName]'MetricProcessor').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;

public sealed class MetricProcessorResult
{
    public double AvailableSum;
    public int    NumericPoints;
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

/// <summary>
/// The per-resource metric result consumed by the rest of the pipeline. Both the per-resource
/// and the batch fetchers return this type, and failed queries yield an "excluded" placeholder.
/// </summary>
public sealed class MetricResult
{
    public string   ResourceId      = "";
    public string   ResourceIdLower = "";
    public string   Name            = "";
    public double   AvailableSum;
    public int      GapMinutes;
    public bool     ExcludeFromAvailability;
    public long[]   GapTicks        = Array.Empty<long>();
    public long[]   ZeroAvailTicks  = Array.Empty<long>();
    public int      DegradedMinutes;
    public long[]   DegradedTicks   = Array.Empty<long>();
    public double[] DegradedValues  = Array.Empty<double>();
    public int      SuspectMinutes;

    /// <summary>Builds the result of a resource whose metric response was processed.</summary>
    public static MetricResult From(string resourceId, string name, MetricProcessorResult m)
    {
        return new MetricResult
        {
            ResourceId = resourceId, ResourceIdLower = resourceId.ToLowerInvariant(), Name = name,
            AvailableSum = m.AvailableSum, GapMinutes = m.GapMinutes,
            ExcludeFromAvailability = m.ExcludeFromAvailability,
            GapTicks = m.NullTicks, ZeroAvailTicks = m.ZeroTicks,
            DegradedMinutes = m.DegradedMinutes, DegradedTicks = m.DegradedTicks,
            DegradedValues = m.DegradedValues, SuspectMinutes = m.SuspectMinutes
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

public sealed class HttpJsonResult
{
    public JsonDocument Doc;      // null when the call failed
    public int          Status;   // last HTTP status, 0 for transport failures
    public string       Error = "";
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

    private static void Backoff(int attempt)
    {
        Thread.Sleep(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt))));
    }

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
                    if (sc >= 200 && sc < 300)
                    {
                        using (var stream = resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
                            return new HttpJsonResult { Doc = JsonDocument.ParseAsync(stream).GetAwaiter().GetResult(), Status = sc };
                    }
                    if ((sc == 429 || sc >= 500) && attempt < MaxAttempts) { Backoff(attempt); continue; }
                    return new HttpJsonResult { Status = sc, Error = "HTTP " + sc };
                }
            }
            catch (Exception ex)
            {
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
    private static long ParseTicks(string s)
        => DateTime.Parse(s, System.Globalization.CultureInfo.InvariantCulture,
               System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal).Ticks;

    /// <summary>Builds a note from an Activity Log row: UserInitiated is the customer, PlatformInitiated maps to "Unplanned".</summary>
    public static HealthNote FromWorkspace(long ticks, string state, string title, string cause)
        => new HealthNote
        {
            Ticks = ticks, State = state ?? "", Title = title ?? "",
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
            notes.Add(new HealthNote
            {
                Ticks   = ParseTicks(occurred),
                State   = Str("availabilityState"),
                Title   = Str("title"),
                Summary = Str("summary"),
                Reason  = reason,
                Customer = reason.Equals("Customer Initiated", StringComparison.OrdinalIgnoreCase) ||
                           reason.Equals("User Initiated", StringComparison.OrdinalIgnoreCase) ||
                           Str("context").Equals("Customer Initiated", StringComparison.OrdinalIgnoreCase) ||
                           Str("healthEventCause").Equals("UserInitiated", StringComparison.OrdinalIgnoreCase)
            });
        }
        return next;
    }

    /// <summary>
    /// Returns the workspace notes plus, when useRest is true, every page of the REST history.
    /// useRest is false when the whole period predates the REST retention and a workspace is available.
    /// </summary>
    public static HealthFetch Collect(HttpClient client, string resourceId, List<HealthNote> workspaceNotes, bool useRest)
    {
        var result = new HealthFetch();
        if (workspaceNotes != null) result.Notes.AddRange(workspaceNotes);
        if (!useRest) return result;
        string url = "https://management.azure.com" + resourceId +
                     "/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2025-05-01";
        while (url.Length > 0)
        {
            var http = AzHttp.Get(client, url);
            if (http.Doc == null) { result.Error = http.Error; break; }
            using (http.Doc) url = ParsePage(http.Doc, result.Notes);
        }
        return result;
    }
}

/// <summary>Hourly request counts of a storage account: server failures and counted requests.</summary>
public sealed class StorageHourly
{
    public double[] Failed;    // ServerOtherError + ServerTimeoutError per hour
    public double[] Counted;   // Success + failed per hour
}

/// <summary>
/// Parsers for the Azure Storage availability algorithm (README, "Algorithms"). Requests are
/// counted per ResponseType: Success and the server failures (ServerOtherError, ServerTimeoutError)
/// make up the counted requests; every other response type is not requested at all, so throttling,
/// network, client and authentication errors never reach the score.
/// </summary>
public static class StorageParser
{
    private static long ParseTicks(string s)
        => DateTime.Parse(s, System.Globalization.CultureInfo.InvariantCulture,
               System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal).Ticks;

    /// <summary>Returns 1 for Success, 2 for a server failure, 0 for anything else.</summary>
    private static int Classify(JsonElement series)
    {
        if (!series.TryGetProperty("metadatavalues", out var mv)) return 0;
        foreach (var m in mv.EnumerateArray())
        {
            if (!string.Equals(m.GetProperty("name").GetProperty("value").GetString(), "responsetype", StringComparison.OrdinalIgnoreCase)) continue;
            string v = m.GetProperty("value").GetString() ?? "";
            if (v.Equals("Success", StringComparison.OrdinalIgnoreCase)) return 1;
            if (v.Equals("ServerOtherError", StringComparison.OrdinalIgnoreCase) ||
                v.Equals("ServerTimeoutError", StringComparison.OrdinalIgnoreCase)) return 2;
        }
        return 0;
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
            foreach (var dp in series.GetProperty("data").EnumerateArray())
            {
                if (!dp.TryGetProperty("total", out var tot) || tot.ValueKind != JsonValueKind.Number) continue;
                double n = tot.GetDouble();
                if (n <= 0) continue;
                long slot = (ParseTicks(dp.GetProperty("timeStamp").GetString()!) - startTicks) / slotTicks;
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

public static class MetricProcessor
{
    /// <summary>Per-resource response: root has "value" array.</summary>
    public static MetricProcessorResult ProcessSingle(JsonDocument doc, bool isVm, bool isWebApp = false)
        => ProcessMetricArray(doc.RootElement.GetProperty("value"), isVm, isWebApp);

    /// <summary>Batch response: root has "values" array, each with "resourceid" + "value".</summary>
    public static BatchResourceResult[] ProcessBatch(JsonDocument doc, bool isVm, bool isWebApp = false)
    {
        var results = new List<BatchResourceResult>();
        foreach (var entry in doc.RootElement.GetProperty("values").EnumerateArray())
        {
            string resId = entry.GetProperty("resourceid").GetString() ?? "";
            results.Add(new BatchResourceResult
            {
                ResourceId      = resId,
                ResourceIdLower = resId.ToLowerInvariant(),
                Metrics         = ProcessMetricArray(entry.GetProperty("value"), isVm, isWebApp)
            });
        }
        return results.ToArray();
    }

    // ── shared inner loop ────────────────────────────────────────────────────
    private static MetricProcessorResult ProcessMetricArray(
        JsonElement valueArr, bool isVm, bool isWebApp)
    {
        var r = new MetricProcessorResult();
        var nullTicks      = new List<long>();
        var zeroTicks      = new List<long>();
        var degradedTicks  = new List<long>();
        var degradedValues = new List<double>();

        if (isWebApp)
        {
            // Web App: MemoryWorkingSet as availability proxy.
            // Average aggregation (bytes): value > 0 means the app process is alive (available 1.0),
            // value == 0 means the app is stopped (suspect zero), null means platform could not
            // collect metrics (suspect null). No degraded state — binary up/down model.
            foreach (var metricEl in valueArr.EnumerateArray())
            {
                string mName = metricEl.GetProperty("name").GetProperty("value").GetString() ?? "";
                if (!string.Equals(mName, "MemoryWorkingSet", StringComparison.OrdinalIgnoreCase)) continue;

                foreach (var tsEl in metricEl.GetProperty("timeseries").EnumerateArray())
                foreach (var dp  in tsEl.GetProperty("data").EnumerateArray())
                {
                    long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!)
                                         .ToUniversalTime().Ticks;
                    double? avgVal = null;
                    if (dp.TryGetProperty("average", out var avgEl) && avgEl.ValueKind == JsonValueKind.Number)
                        avgVal = avgEl.GetDouble();

                    if (avgVal.HasValue)
                    {
                        r.NumericPoints++;
                        if (avgVal.Value > 0.0)
                            r.AvailableSum += 1.0;   // process alive → fully available
                        else
                            zeroTicks.Add(ticks);     // process not running → suspect zero
                    }
                    else
                        nullTicks.Add(ticks);         // no data from platform → suspect null
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

#endregion

#region Compiled gap investigation helpers
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

#endregion

#region Compiled VM algorithm helpers
# The VM algorithm (see README, "Algorithms") classifies every suspect minute with
# the evidence available for it. It runs as compiled C# for the same reason as the
# helpers above: a month holds ~44 K minutes per VM.

if (-not ([System.Management.Automation.PSTypeName]'VmGapClassifier').Type) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;

public sealed class VmClassifyResult
{
    public int[]  GapCounts = new int[13];   // null + zero minutes, indexed by outcome code
    public int[]  DegCounts = new int[13];   // fractional (degraded) minutes, indexed by outcome code
    public double ExcusedDegradedAvail;      // availability carried by excused degraded minutes
}

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

public static class VmGapClassifier
{
    private const long OneMin = 600_000_000L;

    // Outcome codes (index into GapCounts / DegCounts)
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
        foreach (var metric in split.RootElement.GetProperty("value").EnumerateArray())
        foreach (var ts in metric.GetProperty("timeseries").EnumerateArray())
        {
            int ctxBit = 8;
            if (ts.TryGetProperty("metadatavalues", out var mvs))
            {
                foreach (var mv in mvs.EnumerateArray())
                {
                    string n = mv.GetProperty("name").GetProperty("value").GetString() ?? "";
                    if (n.IndexOf("context", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    string v = mv.GetProperty("value").GetString() ?? "";
                    if (v.Equals("Platform", StringComparison.OrdinalIgnoreCase)) ctxBit = 2;
                    else if (v.Equals("User", StringComparison.OrdinalIgnoreCase) ||
                             v.Equals("Customer", StringComparison.OrdinalIgnoreCase)) ctxBit = 4;
                }
            }
            foreach (var dp in ts.GetProperty("data").EnumerateArray())
            {
                if (!dp.TryGetProperty("minimum", out var mn) ||
                    mn.ValueKind != JsonValueKind.Number || mn.GetDouble() != 0.0) continue;
                long ticks = DateTime.Parse(dp.GetProperty("timeStamp").GetString()!,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal).Ticks;
                zeroMask.TryGetValue(ticks, out int cur);
                zeroMask[ticks] = cur | ctxBit;
            }
        }
        var masks = new int[zeroTicks.Length];
        for (int i = 0; i < zeroTicks.Length; i++)
            masks[i] = zeroMask.TryGetValue(zeroTicks[i], out int m) ? m : 8;
        return masks;
    }

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
    /// Classifies every suspect minute (null, zero, fractional) of one VM. Rules are applied in
    /// order and the first match wins; see README, "Algorithms".
    /// </summary>
    public static VmClassifyResult Classify(
        long[] nullTicks, long[] zeroTicks, int[] zeroMasks, long[] degTicks, double[] degVals,
        long[] actFrom, long[] actTo, long[] nxFrom, long[] nxTo,
        long[] entryTicks, int[] entryClasses, long faultWindowTicks)
    {
        var act = Expand(actFrom, actTo);
        var nx  = Expand(nxFrom, nxTo);

        // Only some note classes carry a state forward in time; the rest are evidence only.
        var aStart = new List<long>(); var aClass = new List<int>();
        for (int i = 0; i < entryTicks.Length; i++)
        {
            int c = entryClasses[i];
            if (c == VmHealthClassifier.Customer || c == VmHealthClassifier.PlatformUnplanned ||
                c == VmHealthClassifier.PlatformPlanned || c == VmHealthClassifier.SpotEviction ||
                c == VmHealthClassifier.Unknown || c == VmHealthClassifier.Recovery)
            { aStart.Add(entryTicks[i]); aClass.Add(c); }
        }
        long[] anchorStart = aStart.ToArray(); int[] anchorClass = aClass.ToArray();

        // kind: 0 null, 1 zero, 2 fractional
        var items = new List<(long tick, int kind, int mask, double val)>(
            nullTicks.Length + zeroTicks.Length + degTicks.Length);
        foreach (long t in nullTicks) items.Add((t, 0, 0, 0));
        for (int i = 0; i < zeroTicks.Length; i++) items.Add((zeroTicks[i], 1, zeroMasks[i], 0));
        for (int i = 0; i < degTicks.Length; i++) items.Add((degTicks[i], 2, 0, degVals[i]));
        items.Sort((a, b) => a.tick.CompareTo(b.tick));

        var res = new VmClassifyResult();
        long prevTick = -1; int prevOutcome = 0;

        foreach (var it in items)
        {
            int outcome = 0;
            long t = it.tick;

            if (nx.Contains(t)) outcome = 3;

            // A measured zero tells who caused it, when the metric says so.
            if (outcome == 0 && it.kind == 1)
            {
                if ((it.mask & 2) != 0) outcome = 1;
                else if ((it.mask & 4) != 0 && (it.mask & 8) == 0) outcome = 4;
            }

            if (outcome == 0 && act.Contains(t)) outcome = 5;

            // A gap is explained by what started it: a null run that continues straight after a
            // customer-explained minute stays customer-explained.
            if (outcome == 0 && it.kind == 0 && prevTick >= 0 && t - prevTick <= OneMin &&
                (prevOutcome == 3 || prevOutcome == 4 || prevOutcome == 5 || prevOutcome == 6 || prevOutcome == 12))
                outcome = 12;

            if (outcome == 0 &&
                FindFaultAnchorUnlessCustomer(anchorStart, anchorClass, t, faultWindowTicks) >= 0)
                outcome = 2;

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

            if (it.kind == 2) res.DegCounts[outcome]++; else res.GapCounts[outcome]++;
            if (it.kind == 2 && ((outcome >= 3 && outcome <= 10) || outcome == 12))
                res.ExcusedDegradedAvail += it.val;
            prevTick = t; prevOutcome = outcome;
        }
        return res;
    }
}
'@
}

#endregion

#region Kind configuration
# Maps resource kind → metric namespace, metric names, and aggregation.
# Used by both the per-resource ARM Metrics API and the regional Batch API.
# Storage accounts are not listed: they use their own algorithm (see "Storage algorithm").

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
    # Web App: MemoryWorkingSet as availability proxy — non-null value > 0 means
    # the app process is alive (available); value = 0 means the app is stopped
    # (suspect zero, like a deallocated VM); null means the platform could not
    # collect metrics (suspect null). No degraded state — binary up/down model.
    'WebApp' = @{
        Namespace   = 'Microsoft.Web/sites'
        MetricNames = 'MemoryWorkingSet'
        Aggregation = 'Average'
    }
}

#endregion

#region Batch endpoint validation

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
        $testUri = "$endpoint/subscriptions/00000000-0000-0000-0000-000000000000/metrics:getBatch?api-version=2023-10-01&metricnamespace=Microsoft.Compute/virtualMachines&metricnames=Percentage%20CPU"
        $body = '{"resourceids":[]}'

        try {
            Invoke-WebRequest -Uri $testUri -Method POST -Body $body -ContentType 'application/json' `
                -Headers @{ Authorization = "Bearer $MetricsToken" } -ErrorAction Stop | Out-Null
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

#endregion

#region Batch metric processing

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

    $startIso = $StartDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $endIso   = $EndDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

    # Group resources by (subscriptionId, location, kind) — the Batch API
    # requires all resources in a single call to share the same subscription,
    # region, and metric namespace.
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
        $parts = $entry.Key -split '\|'
        $subId    = $parts[0]
        $location = $parts[1]
        $kind     = $parts[2]

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

    # Shared HttpClient for all batch calls — reuses TCP connections.
    $batchHttpClient = [System.Net.Http.HttpClient]::new()
    $batchHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $MetricsToken")
    $batchHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    # Process batches in waves of $ThrottleLimit parallel calls each,
    # with GC between waves to bound memory usage.
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
        $isWebApp  = $kind -eq 'WebApp'

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
            $batchResults = [MetricProcessor]::ProcessBatch($doc, $isVm, $isWebApp)
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

#region Per-resource metrics

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

    $armHttpClient = [System.Net.Http.HttpClient]::new()
    $armHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $armHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    $done = 0
    $resultByRes = @{}

    # Process each resource in parallel — each iteration builds the ARM
    # Metrics API URL, fetches with retry, and parses via compiled C#.
    $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $resource = $_
        $client   = $using:armHttpClient
        $startIso = ($using:StartDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endIso   = ($using:EndDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $isVm      = $resource.Kind -eq 'VirtualMachine'
        $isWebApp   = $resource.Kind -eq 'WebApp'

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
            try   { $m = [MetricProcessor]::ProcessSingle($doc, $isVm, $isWebApp) }
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

#region Suspect gap investigation

<#
.SYNOPSIS
    Classifies every suspect minute of the resources that have any, using Activity Log and Resource Health.

.DESCRIPTION
    For each candidate resource, collects Activity Log lifecycle events and Resource Health history
    and classifies every suspect minute (null, 0% or degraded metric value).

    Virtual machines use the VM algorithm (README, "Algorithms"): zero minutes are attributed with
    the metric's Context dimension, Resource Health notes are classified by what they say, platform
    notes explain minutes only within a bounded window, and a gap stays explained by what started it.
    Their Resource Health notes come from the REST history and the workspace combined, exactly as
    for storage accounts (see Get-HealthSources).

    Other kinds use the interval-based precedence:
      1. Platform fault (Resource Health)       -> stays eligible, counts as downtime
      2. Lifecycle activity (Activity Log)       -> excluded from eligibility
      3. Unknown / customer-initiated (Health)  -> excluded from eligibility
      4. Remaining null                          -> metric issue, excluded
      5. Remaining 0%                            -> trusted as downtime
      6. Remaining degraded (0% < v < 100%)     -> trusted as degraded availability

    When Log Analytics data is provided, Activity Log uses pre-fetched events. For the other kinds,
    Resource Health uses a hybrid approach: workspace history older than the REST API ~30-day
    retention cutoff is merged with REST API history for the last ~30 days. Without Log Analytics,
    REST APIs are the sole data source.

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
        [string]$ArmToken,
        [DateTimeOffset]$HealthCoverageStart,
        [hashtable]$LogAnalyticsData
    )
    Write-Host "Investigating suspect gaps for $($Candidates.Count) resource(s)..."

    $done = 0
    $total = $Candidates.Count
    $resultByRes = @{}

    # REST API Resource Health retention cutoff — in hybrid mode, LA transitions
    # older than this are kept and REST transitions cover the last ~30 days.
    $restHealthCutoff = Get-RestHealthCutoff
    $healthSources = Get-HealthSources -LogAnalyticsData $LogAnalyticsData -PeriodEnd $PeriodEnd

    # Shared HttpClient for REST API calls within the parallel block.
    # Always created: needed for Resource Health REST calls (sole source
    # without -SourceWorkspaceId; hybrid supplement with -SourceWorkspaceId)
    # and for Activity Log REST calls when -SourceWorkspaceId is not specified.
    $gapHttpClient = [System.Net.Http.HttpClient]::new()
    $gapHttpClient.DefaultRequestHeaders.Add('Authorization', "Bearer $ArmToken")
    $gapHttpClient.Timeout = [TimeSpan]::FromMinutes(5)

    $Candidates | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $c         = $_
        $client      = $using:gapHttpClient
        $pStart      = $using:PeriodStart
        $pEnd        = $using:PeriodEnd
        $graceMin    = $using:GraceMinutes
        $faultWinMin = $using:FaultWindowMinutes
        $hcStart     = $using:HealthCoverageStart
        $laData      = $using:LogAnalyticsData
        $restCutoff  = $using:restHealthCutoff
        $healthSources = $using:healthSources

        # Pre-fetched Log Analytics data for this resource (if available)
        $resLaData = $null
        if ($laData) {
            $resKey = $c.ResourceId.ToLowerInvariant()
            if ($laData.ContainsKey($resKey)) {
                $resLaData = $laData[$resKey]
            }
        }

        #region Local helpers
        # Functions defined inside the parallel block: runspaces started by ForEach-Object -Parallel
        # do not see the script's functions, so each iteration carries its own copies.

        <#
        .SYNOPSIS
            Sends an ARM GET request and returns the response body.
        .DESCRIPTION
            Retries throttling (429) and server errors (5xx) with exponential backoff, up to six attempts,
            reusing the shared HttpClient.
        .PARAMETER uri
            Request URI.
        .PARAMETER httpClient
            Shared HttpClient carrying the bearer token.
        .OUTPUTS
            System.String - the response body.
        #>
        function script:ArmGet([string]$uri, [System.Net.Http.HttpClient]$httpClient) {
            for ($a = 0; $a -lt 6; $a++) {
                $httpReq = [System.Net.Http.HttpRequestMessage]::new(
                    [System.Net.Http.HttpMethod]::Get, $uri)
                $httpResp = $null
                try {
                    $httpResp = $httpClient.SendAsync($httpReq,
                        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                    ).GetAwaiter().GetResult()
                    $sc = [int]$httpResp.StatusCode
                    if ($sc -ge 200 -and $sc -lt 300) {
                        return $httpResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    }
                    if (($sc -eq 429 -or $sc -ge 500) -and $a -lt 5) {
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
                    if ($httpResp) { $httpResp.Dispose() }
                    $httpReq.Dispose()
                }
            }
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
            Reads a string property from a JsonElement.
        .PARAMETER el
            JSON object to read from.
        .PARAMETER name
            Property name.
        .OUTPUTS
            System.String - the value, or '' when the property is absent or null.
        #>
        function script:GetJsonStr([System.Text.Json.JsonElement]$el, [string]$name) {
            $v = [System.Text.Json.JsonElement]::new()
            if ($el.TryGetProperty($name, [ref]$v) -and
                $v.ValueKind -ne [System.Text.Json.JsonValueKind]::Null) {
                return $v.GetString()
            }
            ''
        }

        <#
        .SYNOPSIS
            Parses a timestamp string from an Azure API into a UTC DateTime.
        .PARAMETER s
            Timestamp text in any format Azure APIs return; assumed UTC when it carries no offset.
        .OUTPUTS
            System.DateTime (UTC), or $null when the text is empty or cannot be parsed.
        #>
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
            Tells whether a Resource Health note was caused by the customer.
        .DESCRIPTION
            Several fields can say so: the REST API uses ReasonType, workspace history uses
            HealthEventCause, and both use Context.
        .PARAMETER t
            Health transition.
        .OUTPUTS
            System.Boolean.
        #>
        function script:IsCustomerNote($t) {
            $t.ReasonType -eq 'Customer Initiated' -or
            $t.ReasonType -eq 'User Initiated' -or
            $t.Context -eq 'Customer Initiated' -or
            $t.HealthEventCause -eq 'UserInitiated'
        }

        <#
        .SYNOPSIS
            Builds the intervals during which a resource was in a health state.
        .DESCRIPTION
            An interval opens at the first transition for which the predicate is true and closes at
            the next transition for which it is false. Intervals are clamped to the health coverage
            start and to the end of the observation period; one still open after the last transition
            runs to the end of the period.
        .PARAMETER Transitions
            Health transitions in chronological order.
        .PARAMETER InState
            Script block taking a transition and returning $true while the resource is in the state.
        .PARAMETER CoverageStart
            Start of the period covered by Resource Health history.
        .PARAMETER PeriodEnd
            End of the observation period.
        .OUTPUTS
            PSCustomObject[] with From, To, FromTicks and ToTicks.
        #>
        function script:NewStateIntervals($Transitions, [scriptblock]$InState, $CoverageStart, $PeriodEnd) {
            $intervals = [System.Collections.Generic.List[object]]::new()
            $open = $null
            foreach ($t in $Transitions) {
                # Not named $inState: variable names are case-insensitive and would overwrite $InState.
                $inside = & $InState $t
                if ($inside -and $null -eq $open) {
                    $open = $t.OccurredOn -lt $CoverageStart ? [DateTimeOffset]$CoverageStart : $t.OccurredOn
                }
                elseif (-not $inside -and $null -ne $open) {
                    $end = $t.OccurredOn -gt $PeriodEnd ? [DateTimeOffset]$PeriodEnd : $t.OccurredOn
                    if ($end -gt $open) {
                        $intervals.Add([PSCustomObject]@{
                            From = $open; To = $end; FromTicks = $open.UtcTicks; ToTicks = $end.UtcTicks
                        })
                    }
                    $open = $null
                }
            }
            if ($null -ne $open) {
                $intervals.Add([PSCustomObject]@{
                    From = $open; To = [DateTimeOffset]$PeriodEnd
                    FromTicks = $open.UtcTicks; ToTicks = ([DateTimeOffset]$PeriodEnd).UtcTicks
                })
            }
            $intervals.ToArray()
        }
        #endregion

        #region Activity Log
        # Checks Activity Log for events that explain metric gaps:
        #   a) Resource creation/deletion — VM timeCreated establishes initial
        #      existence; delete→write cycles establish later non-existence.
        #   b) Kind-specific lifecycle operations (VM start/deallocate/poweroff/restart,
        #      SQL pause/resume, WebApp stop/start/restart). Kinds with no known
        #      lifecycle ops (e.g. Storage) produce no matches here.
        # When Log Analytics data is available, use pre-fetched events; otherwise call
        # the Activity Log REST API per-resource.
        $activityIntervals = @()
        # The VM algorithm needs lifecycle and non-existence intervals separately: a measured
        # zero is attributed before lifecycle windows are consulted.
        $lifecycleIntervals    = @()
        $nonExistenceIntervals = @()

        if ($c.AllGapTicks.Count -gt 0 -or $c.DegradedTicks.Count -gt 0) {
            try {
                $vmRules = @(
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/start/action', 'start virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/deallocate/action', 'deallocate virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/poweroff/action', 'power off virtual machine') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.compute/virtualmachines/restart/action', 'restart virtual machine') }
                )
                $sqlRules = @(
                    @{ ApplyGrace = $true; Tokens = @('microsoft.sql/servers/databases/pause', 'pause sql database', 'pause database') }
                    @{ ApplyGrace = $true; Tokens = @('microsoft.sql/servers/databases/resume', 'resume sql database', 'resume database') }
                )
                # Web App lifecycle: stop applies grace (trailing zero metrics while process
                # shuts down), start/restart apply grace for the brief recycle window.
                $webAppRules = @(
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.web/sites/stop/action', 'stop web app', 'stopwebsite') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.web/sites/start/action', 'start web app', 'startwebsite') }
                    @{ ApplyGrace = $true;  Tokens = @('microsoft.web/sites/restart/action', 'restart web app', 'restartwebsite') }
                )
                $rules = switch ($c.Kind) {
                    'VirtualMachine'   { $vmRules }
                    'AzureSqlDatabase' { $sqlRules }
                    'WebApp'           { $webAppRules }
                    default            { @() }
                }

                $events = [System.Collections.Generic.List[object]]::new()

                # Resource creation/deletion tokens — derived from KindConfig
                # namespace (e.g. 'microsoft.web/sites/write', 'microsoft.web/sites/delete').
                # Used to build non-existence intervals where the resource did not exist:
                # before the first write, between delete→write pairs, and after a
                # trailing delete.  Applies universally to all resource kinds.
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

                # Unlike the generic ARM write operation, a VM's timeCreated value
                # is authoritative creation evidence for its current incarnation.
                if ($c.Kind -eq 'VirtualMachine' -and $null -ne $c.CreationTime) {
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
                                    $opKey = $opValue ? $opValue : $opLabel
                                    if (-not $opKey) { continue }

                                    AddActivityEvent $opKey ([DateTimeOffset]$ts) (GetJsonStr $item 'correlationId')
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

                # Build time intervals from events: group by operation+correlationId
                # so that events belonging to the same action collapse into a single
                # interval. Compute from/to per group, apply the grace window for
                # operations that have trailing transition time, then merge overlaps.
                if ($events.Count -gt 0) {
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

                    # Build paired stop→start intervals for web apps.  Unlike VMs
                    # (where Resource Health reports "Unavailable – Customer Initiated"
                    # for the entire deallocated period), stopped web apps show only
                    # "Available" in Resource Health.  We must infer the full stopped
                    # window from the Activity Log stop and start/restart events.
                    if ($c.Kind -eq 'WebApp') {
                        $stopTokens  = $webAppRules[0].Tokens          # stop
                        $startTokens = $webAppRules[1].Tokens + $webAppRules[2].Tokens  # start + restart

                        $stopTs  = [System.Collections.Generic.List[DateTimeOffset]]::new()
                        $startTs = [System.Collections.Generic.List[DateTimeOffset]]::new()
                        foreach ($evt in $events) {
                            $norm = $evt.OperationKey.ToLowerInvariant()
                            foreach ($t in $stopTokens)  { if ($norm.Contains($t)) { $stopTs.Add($evt.Timestamp); break } }
                            foreach ($t in $startTokens) { if ($norm.Contains($t)) { $startTs.Add($evt.Timestamp); break } }
                        }

                        if ($stopTs.Count -gt 0) {
                            $stopTs  = [System.Collections.Generic.List[DateTimeOffset]]($stopTs  | Sort-Object | Select-Object -Unique)
                            $startTs = [System.Collections.Generic.List[DateTimeOffset]]($startTs | Sort-Object | Select-Object -Unique)

                            $pairedIntervals = [System.Collections.Generic.List[object]]::new()
                            foreach ($st in $stopTs) {
                                $nextStart = $startTs | Where-Object { $_ -gt $st } | Select-Object -First 1
                                $from = TruncMin $st
                                $to   = if ($nextStart) { (TruncMin $nextStart).AddMinutes(1 + $graceMin) } else { $pEnd }
                                if ($from -lt $pStart) { $from = $pStart }
                                if ($to -gt $pEnd)     { $to = $pEnd }
                                if ($to -gt $from) {
                                    $pairedIntervals.Add([PSCustomObject]@{
                                        From = $from;  To = $to
                                        FromTicks = $from.UtcTicks; ToTicks = $to.UtcTicks
                                    })
                                }
                            }
                            if ($pairedIntervals.Count -gt 0) {
                                $activityIntervals = MergeIntervals (@($activityIntervals) + @($pairedIntervals))
                            }
                        }
                    }
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
                    $nonExistStart = $null   # timestamp where non-existence began
                    $absenceEstablishedByDelete = $false
                    if ($exState -eq 'not-exists') { $nonExistStart = $pStart }

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

        #endregion

        #region Resource Health
        # Query Resource Health transitions to classify platform faults,
        # unknown states, and customer-initiated events.
        # Hybrid mode (-SourceWorkspaceId): LA transitions older than the REST
        # API ~30-day cutoff are merged with REST API transitions for the last
        # ~30 days.  REST data is authoritative within its retention window:
        # it provides curated synthetic entries that fill coverage gaps
        # between incidents and retroactively corrects cause classification.
        # REST-only mode (no -SourceWorkspaceId): REST API is the sole source.
        $healthHistoryApplied = [DateTimeOffset]$hcStart -lt [DateTimeOffset]$pEnd
        $faultIntervals    = @()
        $unknownIntervals  = @()
        $customerIntervals = @()
        # Classified Resource Health notes (UTC ticks + class) used by the VM algorithm.
        $vmEntries = [System.Collections.Generic.List[object]]::new()

        if ($healthHistoryApplied) {
            try {
                if ($c.Kind -eq 'VirtualMachine') {
                    # VM algorithm: REST history and workspace notes combined (see Get-HealthSources),
                    # each note classified by title, state and reason.
                    $fetch = [HealthHistory]::Collect($client, $c.ResourceId,
                        $healthSources.WorkspaceNotes[$c.ResourceId.ToLowerInvariant()], $healthSources.UseRest)
                    if ($fetch.Error) { Write-Warning "Resource Health query failed for '$($c.Name)': $($fetch.Error)" }
                    foreach ($note in $fetch.Notes) {
                        $vmEntries.Add([PSCustomObject]@{
                            Ticks = $note.Ticks
                            Class = [VmHealthClassifier]::Classify($note.Title, $note.State, $note.Customer, $note.Reason)
                        })
                    }
                }
                else {
                    $transitions = [System.Collections.Generic.List[object]]::new()

                    # In hybrid mode, add LA transitions older than the REST cutoff
                    if ($laData -and $resLaData -and $resLaData.HealthTransitions.Count -gt 0) {
                        foreach ($ht in $resLaData.HealthTransitions) {
                            if ($ht.OccurredOn -lt $restCutoff) {
                                $transitions.Add($ht)
                            }
                        }
                    }

                    # Fetch REST health transitions when they can overlap the period.
                    # In hybrid mode, Log Analytics is sufficient when the period
                    # ends before the REST API's ~30-day retention window.
                    $useRestHealth = $null -eq $laData -or $pEnd -gt $restCutoff
                    $url = if ($useRestHealth) {
                        "https://management.azure.com$($c.ResourceId)" +
                        "/providers/Microsoft.ResourceHealth/availabilityStatuses" +
                        "?api-version=2025-05-01"
                    } else { $null }

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

                    # Sort transitions chronologically (REST API returns newest-
                    # first; LA data arrives in query order — sort to be safe)
                    $transArr = @($transitions | Sort-Object { $_.OccurredOn })

                    # Interval-based classification (every kind except VMs): the periods during which the
                    # resource was in a given health state. VMs classify each note individually instead
                    # (see $vmEntries), so the intervals are not built for them.
                    # Fault: unavailable or degraded for a reason that is neither unknown nor customer-initiated.
                    $faultIntervals = NewStateIntervals $transArr {
                        param($t) $t.State -ne 'Available' -and $t.State -ne 'Unknown' -and -not (IsCustomerNote $t)
                    } $hcStart $pEnd

                    # Unknown: Azure could not determine health (a monitoring gap, not necessarily an outage).
                    $unknownIntervals = NewStateIntervals $transArr { param($t) $t.State -eq 'Unknown' } $hcStart $pEnd

                    # Customer-initiated: stops, restarts and so on. These minutes are excluded from
                    # eligibility (the customer chose to cause the unavailability).
                    $customerIntervals = NewStateIntervals $transArr { param($t) IsCustomerNote $t } $hcStart $pEnd
                }
            }
            catch {
                Write-Warning "Resource Health query failed for '$($c.Name)': $_"
            }
        }

        #endregion

        #region Classify each suspect minute
        # Virtual machines use the VM algorithm (README, "Algorithms"); every other kind
        # keeps the interval-based precedence below, evaluated via compiled C# (GapProcessor):
        #   1. Platform fault (Resource Health)       → stays eligible, 0 available
        #   2. Lifecycle activity (Activity Log)       → excluded from eligibility
        #   3. Unknown / customer-initiated (Health)  → excluded from eligibility
        #   4. Remaining null                          → metric issue, excluded
        #   5. Remaining 0%                            → downtime, stays eligible
        #   6. Remaining degraded (0% < v < 100%)     → trusted, stays eligible
        $vmOutcomeText = $null

        if ($c.Kind -eq 'VirtualMachine') {
            # Who caused each zero minute: a second metric call split by the Context
            # dimension (Platform / User / Unknown). Without it, zeros stay Unknown.
            $zeroTicks = [long[]]@($c.ZeroTicksArray)
            $zeroMasks = [int[]]::new($zeroTicks.Length)
            for ($i = 0; $i -lt $zeroMasks.Length; $i++) { $zeroMasks[$i] = 8 }
            if ($zeroTicks.Length -gt 0) {
                try {
                    $ctxUrl = "https://management.azure.com$($c.ResourceId)/providers/Microsoft.Insights/metrics?" +
                              'api-version=2024-02-01&metricnamespace=Microsoft.Compute%2FvirtualMachines' +
                              '&metricnames=VmAvailabilityMetric&interval=PT1M&aggregation=Minimum' +
                              "&timespan=$($pStart.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($pEnd.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))" +
                              '&$filter=' + [uri]::EscapeDataString("Context eq '*'")
                    $ctxDoc = [System.Text.Json.JsonDocument]::Parse((ArmGet $ctxUrl $client))
                    try { $zeroMasks = [VmGapClassifier]::GetZeroMasks($ctxDoc, $zeroTicks) }
                    finally { $ctxDoc.Dispose() }
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

            $vr = [VmGapClassifier]::Classify(
                [long[]]@($c.NullTicksArray), $zeroTicks, $zeroMasks,
                [long[]]@($c.DegradedTicks), [double[]]@($c.DegradedValues),
                $lcFrom, $lcTo, $nxFrom, $nxTo,
                [long[]]@($sortedNotes | ForEach-Object { $_.Ticks }),
                [int[]]@($sortedNotes  | ForEach-Object { $_.Class }),
                ([long]$faultWinMin * 600000000L))

            # Map outcomes to the record the final assembly step consumes:
            #   1,2 platform fault | 3,5 lifecycle | 4,6,7,8,9,12 explained | 10 metric gap | 11 unresolved
            $gap = $vr.GapCounts; $deg = $vr.DegCounts
            $degExcused = 0
            foreach ($k in 3..10 + 12) { $degExcused += $deg[$k] }
            $cr = [PSCustomObject]@{
                PlatformFaultGapMin          = $gap[1] + $gap[2]
                ActivityLogExcludedGapMin    = $gap[3] + $gap[5]
                HealthExplainedGapMin        = $gap[4] + $gap[6] + $gap[7] + $gap[8] + $gap[9] + $gap[12]
                MetricIssueNullMin           = $gap[10]
                UnresolvedZeroDowntimeMin    = $gap[11]
                HealthConfirmedDegradedMin   = $deg[1] + $deg[2]
                ActivityLogDegradedMin       = $deg[3] + $deg[5]
                CustomerExcusedDegradedMin   = $degExcused
                CustomerExcusedDegradedAvail = $vr.ExcusedDegradedAvail
            }

            # One-line breakdown of what decided the suspect minutes, for the console narration.
            $outcomeNames = 'platform fault (metric Context)', 'platform fault (health note)', 'before creation',
                'customer (metric Context)', 'lifecycle operation', 'customer (health note)', 'planned maintenance',
                'spot eviction', 'health unknown', 'metric gap', 'unresolved 0%', 'continues customer stop'
            $vmOutcomeText = (@(foreach ($k in 1..12) {
                $n = $gap[$k] + $deg[$k]
                if ($n -gt 0) { "$($outcomeNames[$k - 1]) $n" }
            })) -join '; '
        }
        else {
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
        }

        # Emit the classification result for this resource — will be wired
        # into the eligibility record in Step 7 of the main pipeline.
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
            VmOutcomeText                     = $vmOutcomeText
        }
        #endregion
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
# Instead the score follows the Azure Storage SLA: failed / counted requests per hour, averaged over
# the hours of the period, idle hours counting as available (README, "Algorithms > Storage accounts").

# Only these response types are requested: counted = Success + server failures. Throttling, network,
# client and authentication errors are therefore never part of the score.
$StorageResponseFilter = "ResponseType eq 'Success' or ResponseType eq 'ServerOtherError' or ResponseType eq 'ServerTimeoutError'"

# Accounts with fewer counted requests than this in the period are flagged as low-volume.
$StorageLowVolumeRequests = 10000

<#
.SYNOPSIS
    Gets the hourly counted and failed request totals of storage accounts for the whole period.

.DESCRIPTION
    One Azure Monitor call per account (Transactions, PT1H, Total, filtered to Success and server
    failures). A failed query yields a null result, which excludes the account from availability.

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

<#
.SYNOPSIS
    Attributes the server failures of the given storage accounts minute by minute.

.DESCRIPTION
    For each account: (1) reads the PT1M Success and server-failure counts of the days that had failures
    (one call per day when there are few, otherwise 10-day spans, halved again when the response is too
    large); (2) builds the platform and customer Resource Health windows from the REST history combined
    with Log Analytics when a workspace is used; (3) classifies every minute that had failures. A minute inside a
    platform window (starting HealthLeadMinutes before the event, because Resource Health raises it after
    the first failures, and ending two minutes after it is resolved) is a Fault, inside a customer window
    (for example "Throttled") is Excused, anything else is Unresolved. Excused requests then leave the
    hourly error rates, and the sum of the hourly error rates is returned.

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
    sum of the hourly error rates and the evidence (incidents, health windows).
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
        $leadTicks  = $using:HealthLeadMinutes * $tpm
        $graceTicks = 2 * $tpm

        #region Minute detail
        # Success and server failures per minute, only for the periods that had failures. A response
        # over the Azure Monitor size limit is answered with HTTP 400: halve the span and retry.
        $failedMin  = [double[]]::new($nMin)
        $countedMin = [double[]]::new($nMin)
        $days = [System.Collections.Generic.SortedSet[int]]::new()
        for ($h = 0; $h -lt $hours; $h++) { if ($hourly.Failed[$h] -gt 0) { [void]$days.Add([int][math]::Floor($h / 24)) } }
        $spanDays = $days.Count -le 2 ? 1 : 10
        $units = [System.Collections.Generic.SortedSet[int]]::new()
        foreach ($d in $days) { [void]$units.Add([int][math]::Floor($d / $spanDays)) }
        $queue = [System.Collections.Generic.Queue[datetime[]]]::new()
        foreach ($u in $units) {
            $spanEnd = $pStart.AddDays(($u + 1) * $spanDays)
            if ($spanEnd -gt $pEnd) { $spanEnd = $pEnd }
            $queue.Enqueue(@($pStart.AddDays($u * $spanDays), $spanEnd))
        }
        $detailComplete = $true
        while ($queue.Count -gt 0) {
            $span = $queue.Dequeue()
            $uri = "https://management.azure.com$($res.ResourceId)/providers/Microsoft.Insights/metrics?api-version=2024-02-01" +
                   "&metricnamespace=Microsoft.Storage%2FstorageAccounts&metricnames=Transactions&aggregation=Total&interval=PT1M" +
                   "&timespan=$($span[0].ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($span[1].ToString('yyyy-MM-ddTHH:mm:ssZ'))&`$filter=$($using:filter)"
            $http = [AzHttp]::Get($client, $uri)
            if ($http.Doc) {
                try   { [StorageParser]::AddMinutes($http.Doc, $pStart.Ticks, $failedMin, $countedMin) }
                finally { $http.Doc.Dispose() }
            }
            elseif ($http.Status -eq 400 -and ($span[1] - $span[0]).TotalMinutes -gt 15) {
                $mid = $span[0].AddMinutes([math]::Ceiling(($span[1] - $span[0]).TotalMinutes / 2))
                $queue.Enqueue(@($span[0], $mid))
                $queue.Enqueue(@($mid, $span[1]))
            }
            else {
                $detailComplete = $false
                Write-Warning "Storage minute detail failed for '$($res.Name)': $($http.Error)"
            }
        }
        #endregion

        #region Resource Health windows
        # Notes come from the same combined history as the VM algorithm (REST plus workspace, see
        # Get-HealthSources). A window opens at a Degraded/Unavailable note and closes at the next
        # Available note; Log Analytics "Updated" rows (Available state, Degraded title) are progress
        # updates of the open event and are neither an opening nor a closing note. A throttling note
        # is customer-caused whatever its recorded reason.
        $fetch = [HealthHistory]::Collect($client, $res.ResourceId, $healthSources.WorkspaceNotes[$key], $healthSources.UseRest)
        if ($fetch.Error) { Write-Warning "Resource Health query failed for '$($res.Name)': $($fetch.Error)" }
        $notes = $fetch.Notes

        $raws = [System.Collections.Generic.List[object]]::new()
        $open = $null
        foreach ($n in ($notes | Sort-Object Ticks)) {
            $isOpener = $n.State -in 'Degraded', 'Unavailable' -or
                        ([string]::IsNullOrEmpty($n.State) -and $n.Title -match 'Degraded|Throttl|Unavailable')
            $isCloser = $n.State -eq 'Available' -and $n.Title -notmatch 'Degraded|Throttl|Unavailable'
            if ($isOpener -and -not $open) { $open = $n }
            elseif ($isCloser -and $open) {
                $raws.Add([PSCustomObject]@{ Start = $open.Ticks; End = $n.Ticks; Customer = ($open.Customer -or $open.Title -match 'Throttl'); Title = $open.Title; Summary = $open.Summary })
                $open = $null
            }
        }
        # An event that never resolved explains at most 30 minutes.
        if ($open) { $raws.Add([PSCustomObject]@{ Start = $open.Ticks; End = $open.Ticks + 30 * $tpm; Customer = ($open.Customer -or $open.Title -match 'Throttl'); Title = $open.Title; Summary = $open.Summary }) }

        # The REST history and the workspace describe the same events: merge windows that touch.
        $windows = [System.Collections.Generic.List[object]]::new()
        foreach ($w in ($raws | Sort-Object Start)) {
            $last = $windows.Count -gt 0 ? $windows[$windows.Count - 1] : $null
            if ($last -and $w.Start -le $last.End + $graceTicks -and $w.Customer -eq $last.Customer) {
                if ($w.End -gt $last.End) { $last.End = $w.End }
                if (-not $last.Summary) { $last.Summary = $w.Summary }
            }
            else { $windows.Add([PSCustomObject]@{ Start = $w.Start; End = $w.End; Customer = $w.Customer; Title = $w.Title; Summary = $w.Summary }) }
        }
        #endregion

        #region Classify the failing minutes
        # Each minute that had server failures is a Fault (platform window), Excused (customer window)
        # or Unresolved. Consecutive failing minutes (gap of at most 5) form one incident for the evidence.
        $count = @{ Fault = 0; Excused = 0; Unresolved = 0 }
        $weighted = 0.0
        $excusedByHour = [double[]]::new($hours)
        $incidents = [System.Collections.Generic.List[object]]::new()
        $cur = $null
        for ($m = $c.FirstMinute; $m -lt $nMin; $m++) {
            $failed = $failedMin[$m]
            if ($failed -le 0 -or $countedMin[$m] -le 0) { continue }
            $share = $failed / $countedMin[$m]
            $ticks = $pStart.Ticks + $m * $tpm
            $class = 'Unresolved'; $win = $null
            foreach ($w in $windows) {
                if ($ticks -ge $w.Start - $leadTicks -and $ticks -le $w.End + $graceTicks) {
                    $class = $w.Customer ? 'Excused' : 'Fault'; $win = $w; break
                }
            }
            $count[$class]++
            $weighted += $share
            if ($class -eq 'Excused') { $excusedByHour[[int][math]::Floor($m / 60)] += $failed }
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
        #endregion

        # Hourly error rates, after removing the excused requests from both counts.
        $firstHour = [int][math]::Floor($c.FirstMinute / 60)
        $errorSum = 0.0
        for ($h = $firstHour; $h -lt $hours; $h++) {
            $f = $hourly.Failed[$h] - $excusedByHour[$h]
            $n = $hourly.Counted[$h] - $excusedByHour[$h]
            if ($f -gt 0 -and $n -gt 0) { $errorSum += $f / $n }
        }

        [PSCustomObject]@{
            Key = $key; Fault = $count.Fault; Excused = $count.Excused; Unresolved = $count.Unresolved
            Weighted = $weighted; ErrorSum = $errorSum; DetailComplete = $detailComplete
            Windows = $windows.Count; PeriodStart = $pStart
            Incidents = @($incidents | Sort-Object Weighted -Descending)
        }
    } | ForEach-Object { $byRes[$_.Key] = $_ }

    $client.Dispose()
    $byRes
}

<#
.SYNOPSIS
    Runs the storage availability algorithm for all storage accounts and returns one result per account.

.DESCRIPTION
    1. Hourly request totals for every account (Get-StorageHourlyCounts).
    2. The accounts that had server failures are investigated minute by minute against Resource Health
       (Invoke-StorageInvestigation); with -SourceWorkspaceId the older health history comes from Log Analytics.
    3. Availability % = 100 - average hourly error rate over the hours since the account was created. Idle
       hours count as available; an account with no counted request in the period is excluded (N/A).

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

    # One result per account.
    $results = @{}
    foreach ($res in $Resources) {
        $key    = $res.ResourceId.ToLowerInvariant()
        $hourly = $hourlyByRes[$key]
        $first  = $firstMinuteByRes[$key]
        $hours  = [int][math]::Ceiling(($PeriodEnd - $PeriodStart).TotalHours)
        $firstHour = [int][math]::Floor($first / 60)
        $counted = $hourly ? ($hourly.Counted | Measure-Object -Sum).Sum : 0
        $failed  = $hourly ? ($hourly.Failed  | Measure-Object -Sum).Sum : 0
        $inv     = $investigation[$key]
        $errorSum = $inv ? $inv.ErrorSum : 0.0
        $eligibleMinutes = $TotalMinutes - $first

        $results[$key] = [PSCustomObject]@{
            Excluded        = (-not $hourly) -or $counted -le 0 -or $eligibleMinutes -le 0
            EligibleMinutes = $eligibleMinutes
            Percent         = 100 - 100 * $errorSum / [math]::Max(1, $hours - $firstHour)
            CountedRequests = $counted
            FailedRequests  = $failed
            Fault           = $inv ? $inv.Fault : 0
            Excused         = $inv ? $inv.Excused : 0
            Unresolved      = $inv ? $inv.Unresolved : 0
            Weighted        = $inv ? $inv.Weighted : 0.0
            DetailComplete  = $inv ? $inv.DetailComplete : $true
            Incidents       = $inv ? $inv.Incidents : @()
            PeriodStart     = $PeriodStart.UtcDateTime
            LowVolume       = $counted -lt $StorageLowVolumeRequests
        }
    }
    $results
}

<#
.SYNOPSIS
    Writes the result of the storage algorithm into a resource's eligibility record and prints the narration.

.DESCRIPTION
    Suspect = Faults + Excused + Unresolved holds, counted in failing minutes (minutes with at least one
    server failure). AvailableMinutes is the eligible minutes scaled by the hourly availability, so
    AvailabilityPct equals the hourly SLA figure.

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

    $Record.EligibleMinutes           = $Result.EligibleMinutes
    $Record.SuspectMinutes            = $Result.Fault + $Result.Excused + $Result.Unresolved
    $Record.ConfirmedDowntimeMinutes  = $Result.Fault
    $Record.ExcusedMinutes            = $Result.Excused
    $Record.UnexplainedSuspectMinutes = $Result.Unresolved
    $Record.AvailableMinutes          = [math]::Round($Result.EligibleMinutes * $Result.Percent / 100, 2)
    $Record.AvailabilityPct           = [math]::Round($Result.Percent, 5).ToString('F5')

    if ($Record.SuspectMinutes -gt 0) {
        Write-Host ("  [$name] storage: {0:N0} server failure(s) in {1:N0} counted request(s); {2} failing min = {3} confirmed by Resource Health + {4} customer-excused + {5} unresolved (weighted loss {6:N2} min)" -f
            $Result.FailedRequests, $Result.CountedRequests, $Record.SuspectMinutes, $Result.Fault, $Result.Excused, $Result.Unresolved, $Result.Weighted)
        foreach ($i in ($Result.Incidents | Select-Object -First 3)) {
            $when = $Result.PeriodStart.AddMinutes($i.StartMinute).ToString('u')
            $cause = $i.Window ? "Resource Health '$($i.Window.Title)'$($i.Window.Summary ? ': ' + $i.Window.Summary : '')" : 'no Resource Health event'
            Write-Host ("  [$name]   incident {0}, {1} min: {2:N0} failed of {3:N0} counted ({4:P2} peak) -> {5} -> {6}" -f
                $when, $i.Minutes, $i.Failed, $i.Counted, $i.Peak, $i.Class, $cause)
        }
        if ($Result.Incidents.Count -gt 3) { Write-Host "  [$name]   ... and $($Result.Incidents.Count - 3) smaller incident(s)" }
        if (-not $Result.DetailComplete) { Write-Host "  [$name]   WARNING: minute detail incomplete, some failing minutes are not classified" }
    }
    if ($Result.LowVolume) {
        Write-Host ("  [$name] low volume: only {0:N0} counted request(s) in the period, the percentage rests on very few requests" -f $Result.CountedRequests)
    }
}

#endregion

#region Output

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

    $eligible = @($Sorted | Where-Object { $_.AvailabilityPct -ne 'N/A' })
    $summaries = [System.Collections.Generic.List[object]]::new()
    $subscriptionGroups = @($eligible | Group-Object SubscriptionName | Sort-Object Name)

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

#region Main

$sw = [System.Diagnostics.Stopwatch]::StartNew()

#region Step 1: Resolve the observation window
$window = Resolve-ObservationWindow $Month
$utcStart     = $window.Start
$utcEnd       = $window.End
$totalMinutes = $window.TotalMinutes

$healthCoverageStart = Get-HealthCoverageStart $utcStart -UseLogAnalytics:([bool]$SourceWorkspaceId)
$healthCoveredMinutes = $healthCoverageStart -lt $utcEnd ? [int]($utcEnd - $healthCoverageStart).TotalMinutes : 0

$periodLabel = $window.IsMonthToDate ? "month $($window.NormalizedMonth) (month-to-date)" : "month $($window.NormalizedMonth)"
Write-Host "Period: $periodLabel ($($utcStart.ToString('u')) -> $($utcEnd.ToString('u')), $totalMinutes min)"

if ($SourceWorkspaceId) {
    Write-Host "Log Analytics source workspace: $SourceWorkspaceId (Activity Log via KQL, Resource Health via KQL + REST API hybrid)"
} elseif ($healthCoverageStart -gt $utcStart -and $healthCoveredMinutes -gt 0) {
    Write-Host "WARNING: Resource Health history covers only part of this period ($($healthCoverageStart.ToString('u')) -> $($utcEnd.ToString('u')), $healthCoveredMinutes of $totalMinutes min). Earlier minutes will use Activity Log and metric fallback rules."
} elseif ($healthCoveredMinutes -eq 0) {
    Write-Host 'WARNING: Resource Health history does not cover this period. All suspect minutes will use Activity Log and metric fallback rules.'
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
$resolvedSubs = @(foreach ($name in $Subscriptions) {
    if (-not $azSubsByName.ContainsKey($name)) { throw "Subscription '$name' not found." }
    if ($azSubsByName[$name].Count -gt 1) { throw "Multiple subscriptions named '$name'." }
    $azSubsByName[$name][0]
})
$subIds      = @($resolvedSubs.Id)
$subIdToName = @{}; foreach ($s in $resolvedSubs) { $subIdToName[$s.Id] = $s.Name }

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
# Every minute starts as eligible; the later steps subtract the excused minutes.
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

#endregion

#region Step 5: Fetch Azure Monitor metrics
# Storage accounts use their own algorithm (Step 5c) and are not part of the PT1M metric fetch.
$metricResources = @($resources | Where-Object { $_.Kind -ne 'StorageAccount' })
$metricResults = @{}
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

#region Step 5c: Storage accounts
# The storage algorithm (README, "Algorithms > Storage accounts") scores the hourly server-failure rate
# and attributes the failing minutes to Resource Health. It fills the eligibility records directly.
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

#region Step 5b: Detect perpetually-deallocated VMs
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
        $allTicks = [System.Collections.Generic.List[long]]::new()
        $allTicks.AddRange([long[]]@($mr.GapTicks))
        $allTicks.AddRange([long[]]@($mr.ZeroAvailTicks))
        if ($allTicks.Count -gt 0 -or $mr.DegradedTicks.Count -gt 0) {
            $suspectCandidates.Add([PSCustomObject]@{
                Name           = $res.Name
                Kind           = $res.Kind
                ResourceId     = $res.ResourceId
                SubscriptionId = $res.SubscriptionId
                CreationTime   = $res.CreationTime
                AllGapTicks    = @($allTicks)
                NullTicksArray = @($mr.GapTicks)
                ZeroTicksArray = @($mr.ZeroAvailTicks)
                DegradedTicks  = @($mr.DegradedTicks)
                DegradedValues = @($mr.DegradedValues)
            })
        }
    }
}

#endregion

#region Step 6b: Investigate the suspect minutes
# With -SourceWorkspaceId, Activity Log events and older Resource Health history are fetched
# in bulk from Log Analytics; Resource Health transitions complement the REST API data in
# hybrid mode (the workspace covers the period before the ~30-day REST retention, REST is
# authoritative for the last ~30 days).
$logAnalyticsData = $null
if ($SourceWorkspaceId -and $suspectCandidates.Count -gt 0) {
    Write-Host -NoNewline 'Fetching Activity Log + Resource Health history from Log Analytics... '
    $laTokenStr = Get-PlainToken 'https://api.loganalytics.io'
    $logAnalyticsData = Get-LogAnalyticsData -WorkspaceId $SourceWorkspaceId `
        -SubscriptionIds $subIds -ResourceIds @($suspectCandidates.ResourceId) `
        -PeriodStart $utcStart -PeriodEnd $utcEnd `
        -ArmToken $laTokenStr
    $laTokenStr = $null
}

$suspectResults = $null
if ($suspectCandidates.Count -gt 0) {
    $suspectResults = Invoke-SuspectGapInvestigation -Candidates @($suspectCandidates) `
        -PeriodStart $utcStart -PeriodEnd $utcEnd -ThrottleLimit $Parallelism `
        -GraceMinutes $ActivityGraceMinutes -FaultWindowMinutes $FaultWindowMinutes -ArmToken $armToken `
        -HealthCoverageStart $healthCoverageStart `
        -LogAnalyticsData $logAnalyticsData
}

#endregion

#region Step 7: Assemble the final results
# Wires investigation outcomes into each resource's eligibility record:
#   - Subtracts excused minutes from EligibleMinutes
#   - Computes AvailableMinutes, ConfirmedDowntimeMinutes, UnexplainedSuspectMinutes
#   - Prints per-resource classification narration
# Storage accounts were already completed by their own algorithm (Step 5c) and have no metric result here.
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

    # Skip perpetually-deallocated VMs — already handled in Step 5b
    if ($perpetuallyDeallocated.Contains($res.ResourceId)) { continue }

    $gc = $suspectResults ? $suspectResults[$key] : $null

    # Counters from the investigation (all zero when the resource had no suspect minutes).
    $activityLogExcludedGapMinutes = $gc ? $gc.ActivityLogExcludedGapMinutes : 0
    $healthExplainedGapMinutes     = $gc ? $gc.HealthExplainedGapMinutes : 0
    $metricIssueNullMinutes        = $gc ? $gc.MetricIssueNullMinutes : 0
    $excludedDegradedMinutes       = $gc ? $gc.CustomerExcusedDegradedMinutes : 0

    # Excused minutes leave the eligible total, which never goes below zero.
    $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes -
        ($activityLogExcludedGapMinutes + $healthExplainedGapMinutes + $metricIssueNullMinutes + $excludedDegradedMinutes))

    if ($gc) {
        $totalSuspectMinutes = $mr.SuspectMinutes

        # Count contiguous suspect gaps for narration by sorting all suspect
        # ticks and counting boundaries where consecutive ticks are >1 min apart.
        $allSuspectTicks = [System.Collections.Generic.List[long]]::new()
        $allSuspectTicks.AddRange([long[]]@($mr.GapTicks))
        $allSuspectTicks.AddRange([long[]]@($mr.ZeroAvailTicks))
        $allSuspectTicks.AddRange([long[]]@($mr.DegradedTicks))
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
            if ($gc.VmOutcomeText) {
                # VM algorithm: one line with what decided the suspect minutes.
                Write-Host "  [$($res.Name)] VM algorithm classified suspect min: $($gc.VmOutcomeText)"
            }
            elseif ($remainingAfterActivity -gt 0) {
                Write-Host "  [$($res.Name)] checked against Activity Log: $activityExplainedSuspectMinutes suspect min explained by admin lifecycle events, $remainingAfterActivity remain for Health History / fallback rules"
            } else {
                Write-Host "  [$($res.Name)] checked against Activity Log: $activityExplainedSuspectMinutes suspect min explained by admin lifecycle events"
            }

            if ($gc.VmOutcomeText) {
                # Already covered by the VM algorithm line above.
            }
            elseif ($remainingAfterActivity -gt 0 -and $gc.HealthHistoryApplied) {
                $healthExplainedSuspectMinutes = $gc.HealthExplainedGapMinutes + ($gc.CustomerExcusedDegradedMinutes - $gc.ActivityLogDegradedMinutes)
                Write-Host "  [$($res.Name)] checked remaining suspect min against Health History: $($gc.PlatformFaultGapMinutes) gap min confirmed as platform issues, $healthExplainedSuspectMinutes suspect min explained as Unknown / customer-initiated"
            } elseif ($remainingAfterActivity -gt 0) {
                Write-Host "  [$($res.Name)] Health History skipped for remaining suspect min (outside current retention window); applying fallback rules directly"
            }
        }

        if ($gc.MetricIssueNullMinutes -gt 0) {
            Write-Host "  [$($res.Name)] $($gc.MetricIssueNullMinutes) unresolved null suspect min treated as metric issues and excluded from eligibility"
        }
        if ($gc.CustomerExcusedDegradedMinutes -gt 0) {
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
        # The VM algorithm line above already says what decided each minute, and a VM fault can come from the
        # metric's Context rather than from Resource Health, so these Health History lines are for other kinds.
        if ($gc.PlatformFaultGapMinutes -gt 0 -and -not $gc.VmOutcomeText) {
            Write-Host "  [$($res.Name)] $($gc.PlatformFaultGapMinutes) gap min confirmed as downtime (Health History platform issue)"
        }
        if ($gc.HealthConfirmedDegradedMinutes -gt 0 -and -not $gc.VmOutcomeText) {
            Write-Host "  [$($res.Name)] $($gc.HealthConfirmedDegradedMinutes) degraded suspect min confirmed as downtime (Health History platform issue)"
        }
        if ($gc.UnresolvedZeroDowntimeMinutes -gt 0) {
            Write-Host "  [$($res.Name)] $($gc.UnresolvedZeroDowntimeMinutes) unresolved 0% suspect min trusted as downtime"
        }
    }

    # Total confirmed downtime = platform fault gap minutes + degraded minutes
    # confirmed by Health History as platform issues.
    $confirmedHealthDowntimeMinutes = $gc ? $gc.PlatformFaultGapMinutes + $gc.HealthConfirmedDegradedMinutes : 0

    # Unexplained degraded = total degraded - excused by customer/activity - confirmed by health.
    # These stay eligible and contribute their fractional availability.
    $unexplainedPositiveDegradedMinutes = $gc ?
        [math]::Max(0, $mr.DegradedMinutes - $gc.CustomerExcusedDegradedMinutes - $gc.HealthConfirmedDegradedMinutes) :
        $mr.DegradedMinutes

    # Unresolved suspect = zero-value downtime + unexplained degraded.
    $unexplainedSuspectMinutes = $gc ?
        $gc.UnresolvedZeroDowntimeMinutes + $unexplainedPositiveDegradedMinutes :
        $mr.SuspectMinutes

    # Wire final totals into the eligibility record.
    # Invariant: Suspect = Faults + Excused + Unresolved
    $elig.SuspectMinutes = $mr.SuspectMinutes
    $elig.ConfirmedDowntimeMinutes = $confirmedHealthDowntimeMinutes
    $elig.ExcusedMinutes = $activityLogExcludedGapMinutes + $healthExplainedGapMinutes +
        $metricIssueNullMinutes + $excludedDegradedMinutes
    $elig.UnexplainedSuspectMinutes = $unexplainedSuspectMinutes

    if ($activityLogExcludedGapMinutes -gt 0 -or $healthExplainedGapMinutes -gt 0 -or
        $metricIssueNullMinutes -gt 0 -or $excludedDegradedMinutes -gt 0) {
        $adjustments = [System.Collections.Generic.List[string]]::new()
        if ($activityLogExcludedGapMinutes -gt 0) { $adjustments.Add("$activityLogExcludedGapMinutes gap min excluded by Activity Log") }
        if ($healthExplainedGapMinutes -gt 0)     { $adjustments.Add("$healthExplainedGapMinutes gap min excluded by Health History") }
        if ($metricIssueNullMinutes -gt 0)        { $adjustments.Add("$metricIssueNullMinutes null suspect min treated as metric issues") }
        if ($excludedDegradedMinutes -gt 0)       { $adjustments.Add("$excludedDegradedMinutes customer-excused degraded min") }
        Write-Host "  [$($res.Name)] eligible min = $totalMinutes - $($adjustments -join ' - ') = $($elig.EligibleMinutes)"
    }

    # Compute final availability: subtract the fractional available sum from
    # customer-excused degraded minutes (they were excluded from eligibility,
    # so their contribution must also leave the available sum).
    $customerExcusedAvail = $gc ? $gc.CustomerExcusedDegradedAvailableSum : 0
    $elig.AvailableMinutes = [math]::Round([math]::Max(0, $mr.AvailableSum - $customerExcusedAvail), 2)
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
