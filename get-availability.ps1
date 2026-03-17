#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Reports rolling 14-day availability for VMs and Azure SQL databases.

.DESCRIPTION
    Uses Azure Resource Graph to inventory VMs and SQL DBs, detect lifecycle
    transitions (start/stop/create/delete) from the resourcechanges table,
    and query Azure Monitor availability metrics at PT1M granularity.

    Builds exclusion windows for non-existence and purposeful stops, then:
      EligibleMinutes = TotalMinutes - ExcludedMinutes
      AvailabilityPct = AvailableMinutes / EligibleMinutes * 100

    For VMs with null VmAvailabilityMetric data points during eligible minutes,
    supplementary guest-level metrics (CPU, Network, Disk) are checked. A gap
    minute is recovered only if ALL 5 metrics report non-null data.

.PARAMETER SubscriptionName
    Azure subscription display name.

.PARAMETER ResourceName
    Optional single resource to report on (server/db format for SQL DBs).

.PARAMETER TransitionBufferMinutes
    Symmetric buffer (+-N) around each start/stop event. Default 5.

.EXAMPLE
    ./get-availability.ps1 -SubscriptionName 'POSTE-BANCOPOSTA-PRODUZIONE'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionName,

    [ValidateRange(1, 64)]
    [int]$Parallelism = 8,

    [string]$ResourceName,

    [ValidateRange(0, 120)]
    [int]$TransitionBufferMinutes = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Exclusion window helpers ─────────────────────────────────────────────────

function Add-Window([System.Collections.Generic.List[object]]$Windows, [datetime]$From, [datetime]$To, [datetime]$PeriodStart, [datetime]$PeriodEnd) {
    $f = [DateTime]::SpecifyKind($From, [DateTimeKind]::Utc)
    $t = [DateTime]::SpecifyKind($To, [DateTimeKind]::Utc)
    if ($t -le $PeriodStart -or $f -ge $PeriodEnd) { return }
    if ($f -lt $PeriodStart) { $f = $PeriodStart }
    if ($t -gt $PeriodEnd)   { $t = $PeriodEnd }
    if ($t -gt $f) { $Windows.Add([PSCustomObject]@{ From = $f; To = $t }) }
}

function Merge-Windows([object[]]$Windows) {
    $sorted = $Windows | Sort-Object From, To
    $merged = [System.Collections.Generic.List[object]]::new()
    $f = $sorted[0].From; $t = $sorted[0].To
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i].From -le $t) {
            if ($sorted[$i].To -gt $t) { $t = $sorted[$i].To }
        } else {
            $merged.Add([PSCustomObject]@{ From = $f; To = $t })
            $f = $sorted[$i].From; $t = $sorted[$i].To
        }
    }
    $merged.Add([PSCustomObject]@{ From = $f; To = $t })
    @($merged)
}

function Get-WindowMinutes([object[]]$Windows) {
    if ($Windows.Count -eq 0) { return 0 }
    [double]$sum = 0; foreach ($w in $Windows) { $sum += ($w.To - $w.From).TotalMinutes }
    [math]::Round($sum, 2)
}

# Floor(From), Ceil(To) so eligible minute counts match discrete metric data points.
function Snap-WindowBoundaries([object[]]$Windows, [datetime]$PeriodStart, [datetime]$PeriodEnd) {
    foreach ($w in $Windows) {
        $w.From = [datetime]::new($w.From.Year, $w.From.Month, $w.From.Day, $w.From.Hour, $w.From.Minute, 0, [DateTimeKind]::Utc)
        $toMin  = [datetime]::new($w.To.Year, $w.To.Month, $w.To.Day, $w.To.Hour, $w.To.Minute, 0, [DateTimeKind]::Utc)
        $w.To   = if ($w.To -gt $toMin) { $toMin.AddMinutes(1) } else { $toMin }
        if ($w.From -lt $PeriodStart) { $w.From = $PeriodStart }
        if ($w.To   -gt $PeriodEnd)   { $w.To   = $PeriodEnd }
    }
}

# ── Resource inventory via Azure Resource Graph ──────────────────────────────

function Get-CurrentTrackedResources([string]$SubscriptionId) {
    $query = @"
resources
| where subscriptionId =~ '$SubscriptionId'
| where type =~ 'microsoft.compute/virtualmachines' or type =~ 'microsoft.sql/servers/databases'
| extend idParts = split(id, '/')
| extend sqlServerName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[8]), '')
| extend databaseName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[10]), '')
| where not(type =~ 'microsoft.sql/servers/databases' and databaseName =~ 'master')
| extend resourceKind = case(
    type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
    type =~ 'microsoft.sql/servers/databases', 'AzureSqlDatabase',
    'Other'
)
| extend createdAt = case(
    type =~ 'microsoft.compute/virtualmachines', todatetime(properties.timeCreated),
    type =~ 'microsoft.sql/servers/databases', todatetime(properties.creationDate),
    datetime(null)
)
| extend currentPowerState = case(
    type =~ 'microsoft.compute/virtualmachines', tostring(properties.extended.instanceView.powerState.code),
    type =~ 'microsoft.sql/servers/databases', tostring(properties.status),
    ''
)
| project id, name, type, resourceGroup, location, resourceKind, createdAt, sqlServerName, databaseName, currentPowerState
"@

    $resources = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $params = @{ Query = $query; First = 1000; Subscription = $SubscriptionId }
        if ($skipToken) { $params.SkipToken = $skipToken }
        $response = Search-AzGraph @params

        foreach ($row in $response.Data) {
            $kind = [string]$row.resourceKind
            $rawPower = [string]$row.currentPowerState
            $resources.Add([PSCustomObject]@{
                Name              = ($kind -eq 'AzureSqlDatabase' -and $row.sqlServerName -and $row.databaseName) ?
                                        "$($row.sqlServerName)/$($row.databaseName)" : [string]$row.name
                Kind              = $kind
                ResourceId        = [string]$row.id
                ResourceGroupName = [string]$row.resourceGroup
                Location          = [string]$row.location
                CreatedAt         = ($null -ne $row.createdAt -and -not [string]::IsNullOrWhiteSpace([string]$row.createdAt)) ?
                                        ([datetime]$row.createdAt).ToUniversalTime() : $null
                CurrentPowerState = ($kind -eq 'VirtualMachine' -and $rawPower -match 'PowerState/(.+)') ?
                                        $Matches[1] : $rawPower
            })
        }
        $skipToken = [string]::IsNullOrWhiteSpace($response.SkipToken) ? $null : $response.SkipToken
    } while ($skipToken)

    @($resources | Sort-Object Kind, Name)
}

# ── Lifecycle change events from Resource Graph ──────────────────────────────

function Get-ResourceChangeEvents([string]$SubscriptionId, [datetime]$StartDate, [datetime]$EndDate) {
    $startIso = $StartDate.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $endIso   = $EndDate.ToString('yyyy-MM-ddTHH:mm:ssZ')

    $vmQuery = @"
resourcechanges
| extend changeTime  = todatetime(properties.changeAttributes.timestamp),
         changeType   = tostring(properties.changeType),
         targetId     = tostring(properties.targetResourceId),
         targetType   = tostring(properties.targetResourceType),
         changes      = properties.changes
| where targetType =~ 'microsoft.compute/virtualmachines'
| where changeTime >= datetime('$startIso') and changeTime <= datetime('$endIso')
| where changeType in ('Create', 'Delete') or isnotempty(changes['properties.extended.instanceView.powerState.code'])
| extend powerStateChange = changes['properties.extended.instanceView.powerState.code']
| project changeTime, changeType, targetId,
          newPowerState = tostring(powerStateChange.newValue)
"@

    $sqlQuery = @"
resourcechanges
| extend changeTime  = todatetime(properties.changeAttributes.timestamp),
         changeType   = tostring(properties.changeType),
         targetId     = tostring(properties.targetResourceId),
         targetType   = tostring(properties.targetResourceType),
         changes      = properties.changes
| where targetType =~ 'microsoft.sql/servers/databases'
| where changeTime >= datetime('$startIso') and changeTime <= datetime('$endIso')
| where changeType in ('Create', 'Delete') or isnotempty(changes['properties.status'])
| extend statusChange = changes['properties.status']
| project changeTime, changeType, targetId,
          newStatus = tostring(statusChange.newValue)
"@

    $allEvents = [System.Collections.Generic.List[object]]::new()
    foreach ($queryPair in @(
        @{ Query = $vmQuery;  Kind = 'VM' },
        @{ Query = $sqlQuery; Kind = 'SQL' }
    )) {
        $skipToken = $null
        do {
            $params = @{ Query = $queryPair.Query; First = 1000; Subscription = $SubscriptionId }
            if ($skipToken) { $params.SkipToken = $skipToken }
            $response = Search-AzGraph @params

            foreach ($row in $response.Data) {
                $changeType = [string]$row.changeType
                $targetId   = [string]$row.targetId
                $changeTime = [DateTime]::SpecifyKind([datetime]$row.changeTime, [DateTimeKind]::Utc)

                $eventKind = switch ($changeType) {
                    'Create' { 'Create'; break }
                    'Delete' { 'Delete'; break }
                    default {
                        if ($queryPair.Kind -eq 'VM') {
                            switch -Wildcard ([string]$row.newPowerState) {
                                'PowerState/running'      { 'Start' }
                                'PowerState/deallocat*'   { 'Stop' }
                                'PowerState/stop*'        { 'Stop' }
                                default                   { $null }
                            }
                        } else {
                            switch ([string]$row.newStatus) {
                                'Online'   { 'Start' }
                                'Paused'   { 'Stop' }
                                'Pausing'  { 'Stop' }
                                default    { $null }
                            }
                        }
                    }
                }

                if ($eventKind) {
                    $allEvents.Add([PSCustomObject]@{
                        ResourceId     = $targetId
                        EventTimestamp = $changeTime
                        EventKind      = $eventKind
                    })
                }
            }
            $skipToken = [string]::IsNullOrWhiteSpace($response.SkipToken) ? $null : $response.SkipToken
        } while ($skipToken)
    }

    Write-Host "  Resource Graph Changes: $($allEvents.Count) lifecycle event(s) found."
    @($allEvents)
}

# ── Availability metric retrieval (parallel) ─────────────────────────────────

function Get-AvailabilityMetrics([object[]]$Resources, [datetime]$StartDate, [datetime]$EndDate, [int]$ThrottleLimit, [string]$ArmToken) {
    Write-Host "Querying Availability metric for $($Resources.Count) resource(s) with parallelism $ThrottleLimit..."

    $metricResults = $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $resource = $_
        $token    = $using:ArmToken
        $startIso = ($using:StartDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endIso   = ($using:EndDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $metricName = switch ($resource.Kind) {
            'VirtualMachine'   { 'VmAvailabilityMetric' }
            'AzureSqlDatabase' { 'availability' }
            default            { 'Availability' }
        }

        $uri = "https://management.azure.com$($resource.ResourceId)/providers/Microsoft.Insights/metrics?" +
               "api-version=2024-02-01&metricnames=$metricName&timespan=$startIso/$endIso&interval=PT1M&aggregation=Minimum"

        $dataPoints     = [System.Collections.Generic.List[object]]::new()
        $nullTimestamps = [System.Collections.Generic.List[datetime]]::new()

        $response = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $token" } -Method GET
                break
            }
            catch {
                $statusCode = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                $retryable = $statusCode -eq 429 -or $statusCode -ge 500 -or
                    $_.ToString() -match 'TooManyRequests|ThrottledError|EOF|transport|connection.*closed|reset by peer|timed?\s*out'
                if ($retryable -and $attempt -lt 5) {
                    Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt)))
                    continue
                }
                Write-Warning "Availability metric failed for '$($resource.Name)': $_"
                break
            }
        }

        if ($response -and $response.value) {
            $isSqlDb = $metricName -eq 'availability'
            foreach ($metric in $response.value) {
                foreach ($ts in $metric.timeseries) {
                    foreach ($dp in $ts.data) {
                        $time = [DateTime]::SpecifyKind([datetime]$dp.timeStamp, [DateTimeKind]::Utc)
                        if ($null -ne $dp.minimum) {
                            $val = [double]$dp.minimum
                            if ($isSqlDb) { $val /= 100.0 }
                            $dataPoints.Add([PSCustomObject]@{ Timestamp = $time; Value = $val })
                        } else {
                            $nullTimestamps.Add($time)
                        }
                    }
                }
            }
        }

        [PSCustomObject]@{
            ResourceId     = $resource.ResourceId
            DataPoints     = @($dataPoints)
            NullTimestamps = @($nullTimestamps)
        }
    }

    $dpLookup = @{}; $nullLookup = @{}
    foreach ($item in $metricResults) {
        if ($item) {
            $key = $item.ResourceId.ToLowerInvariant()
            $dpLookup[$key]   = $item.DataPoints
            $nullLookup[$key] = $item.NullTimestamps
        }
    }
    [PSCustomObject]@{ DataPoints = $dpLookup; NullTimestamps = $nullLookup }
}

# ── Supplementary metric recovery for VMs ────────────────────────────────────
# When VmAvailabilityMetric has null data points for eligible minutes, check
# guest-level metrics. A minute is recovered only if ALL 5 metrics report data.

function Get-SupplementaryMetricRecovery([pscustomobject]$Resource, [datetime[]]$GapTimestamps, [string]$ArmToken) {
    if ($Resource.Kind -ne 'VirtualMachine' -or $GapTimestamps.Count -eq 0) { return 0 }

    $minTs = ($GapTimestamps | Measure-Object -Minimum).Minimum.AddMinutes(-2)
    $maxTs = ($GapTimestamps | Measure-Object -Maximum).Maximum.AddMinutes(2)
    $timespan = "$($minTs.ToString('yyyy-MM-ddTHH:mm:ssZ'))/$($maxTs.ToString('yyyy-MM-ddTHH:mm:ssZ'))"

    $metricNames = 'Percentage CPU,Network In Total,Network Out Total,Disk Read Bytes,Disk Write Bytes'
    $uri = "https://management.azure.com$($Resource.ResourceId)/providers/Microsoft.Insights/metrics?" +
           "api-version=2024-02-01&metricnames=$([uri]::EscapeDataString($metricNames))" +
           "&timespan=$timespan&interval=PT1M&aggregation=Average&metricnamespace=microsoft.compute/virtualmachines"

    try { $response = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $ArmToken" } -Method GET }
    catch { Write-Warning "  Supplementary metric query failed for '$($Resource.Name)': $_"; return 0 }

    $gapSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ts in $GapTimestamps) { $null = $gapSet.Add($ts.ToString('yyyy-MM-dd HH:mm')) }

    $countByMinute = @{}
    if ($response -and $response.value) {
        foreach ($metric in $response.value) {
            $minutesSeen = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($ts in $metric.timeseries) {
                foreach ($dp in $ts.data) {
                    $avg = $dp.PSObject.Properties['average']
                    if ($avg -and $null -ne $avg.Value) {
                        $tsKey = ([datetime]$dp.timeStamp).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
                        if ($gapSet.Contains($tsKey)) { $null = $minutesSeen.Add($tsKey) }
                    }
                }
            }
            foreach ($tsKey in $minutesSeen) {
                $countByMinute[$tsKey] = ($countByMinute[$tsKey] ?? 0) + 1
            }
        }
    }

    $recovered = @($countByMinute.GetEnumerator() | Where-Object { $_.Value -ge 5 }).Count
    if ($recovered -gt 0) {
        Write-Host "  [$($Resource.Name)] Recovered $recovered gap min via supplementary metrics"
    }
    $recovered
}

# ── Eligibility calculation per resource ─────────────────────────────────────

function Get-ResourceEligibilityResult {
    param(
        [pscustomobject]$Resource,
        [AllowEmptyCollection()] [object[]]$Events = @(),
        [datetime]$PeriodStart,
        [datetime]$PeriodEnd,
        [int]$TotalMinutes,
        [string]$CurrentPowerState = 'Unknown',
        [int]$TransitionBufferMinutes = 5
    )

    $sortedEvents = @($Events | Sort-Object EventTimestamp)
    $nonExistWindows = [System.Collections.Generic.List[object]]::new()
    $stoppedWindows  = [System.Collections.Generic.List[object]]::new()

    # Phase 1: Non-existence windows
    $deleteEvents = @($sortedEvents | Where-Object EventKind -eq 'Delete')

    if ($Resource.CreatedAt -and $Resource.CreatedAt -gt $PeriodStart -and $Resource.CreatedAt -lt $PeriodEnd) {
        if (-not ($deleteEvents | Where-Object { $_.EventTimestamp -lt $Resource.CreatedAt })) {
            Add-Window $nonExistWindows $PeriodStart $Resource.CreatedAt $PeriodStart $PeriodEnd
        }
    }

    $pendingDelete = $null
    foreach ($evt in $sortedEvents) {
        if ($evt.EventKind -eq 'Delete') { $pendingDelete = $evt.EventTimestamp; continue }
        if ($evt.EventKind -eq 'Create' -and $pendingDelete) {
            Add-Window $nonExistWindows $pendingDelete $evt.EventTimestamp $PeriodStart $PeriodEnd
            $pendingDelete = $null
        }
    }
    if ($pendingDelete) { Add-Window $nonExistWindows $pendingDelete $PeriodEnd $PeriodStart $PeriodEnd }

    # Phase 2: Purposeful-stop windows
    $powerEvents = [System.Collections.Generic.List[object]]::new()
    foreach ($evt in $sortedEvents) {
        if ($evt.EventKind -eq 'Stop')  { $powerEvents.Add([PSCustomObject]@{ Kind = 'Stop';  Time = $evt.EventTimestamp }) }
        if ($evt.EventKind -eq 'Start') { $powerEvents.Add([PSCustomObject]@{ Kind = 'Start'; Time = $evt.EventTimestamp }) }
    }

    if ($powerEvents.Count -gt 0 -and $powerEvents[0].Kind -eq 'Start') {
        Add-Window $stoppedWindows $PeriodStart $powerEvents[0].Time $PeriodStart $PeriodEnd
    }
    elseif ($powerEvents.Count -eq 0 -and $CurrentPowerState -in @('deallocated','deallocating','stopped','stopping','Paused','Pausing','Resuming')) {
        Add-Window $stoppedWindows $PeriodStart $PeriodEnd $PeriodStart $PeriodEnd
    }

    $pendingStop = $null
    foreach ($pe in $powerEvents) {
        if ($pe.Kind -eq 'Stop') { if ($null -eq $pendingStop) { $pendingStop = $pe.Time }; continue }
        if ($pe.Kind -eq 'Start' -and $pendingStop) {
            Add-Window $stoppedWindows $pendingStop $pe.Time $PeriodStart $PeriodEnd
            $pendingStop = $null
        }
    }
    if ($pendingStop) { Add-Window $stoppedWindows $pendingStop $PeriodEnd $PeriodStart $PeriodEnd }

    # Symmetric +-N buffer around every power event
    $buf = [TimeSpan]::FromMinutes($TransitionBufferMinutes)
    foreach ($pe in $powerEvents) {
        Add-Window $stoppedWindows ($pe.Time - $buf) ($pe.Time + $buf) $PeriodStart $PeriodEnd
    }

    # Phase 3: Merge, snap to minute boundaries, compute eligible minutes
    [array]$mergedNonExist = $nonExistWindows.Count -gt 0 ? (Merge-Windows $nonExistWindows.ToArray()) : @()
    [array]$mergedStopped  = $stoppedWindows.Count  -gt 0 ? (Merge-Windows $stoppedWindows.ToArray())  : @()
    [array]$mergedExcluded = ($mergedNonExist + $mergedStopped).Count -gt 0 ?
        (Merge-Windows ($mergedNonExist + $mergedStopped)) : @()

    Snap-WindowBoundaries $mergedNonExist $PeriodStart $PeriodEnd
    Snap-WindowBoundaries $mergedStopped  $PeriodStart $PeriodEnd
    Snap-WindowBoundaries $mergedExcluded $PeriodStart $PeriodEnd

    $nonExistMin = Get-WindowMinutes $mergedNonExist
    $stoppedMin  = Get-WindowMinutes $mergedStopped
    $excludedMin = Get-WindowMinutes $mergedExcluded
    $eligibleMin = [math]::Max(0, [math]::Round($TotalMinutes - $excludedMin, 2))

    # Build explanation
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($eligibleMin -eq $TotalMinutes) {
        $parts.Add('Fully eligible for the entire period')
    }
    elseif ($eligibleMin -eq 0) {
        if ($nonExistMin -ge $TotalMinutes) { $parts.Add('Did not exist during the period') }
        elseif ($stoppedMin -ge $TotalMinutes) { $parts.Add("Stopped/deallocated for the entire period (current state: $CurrentPowerState)") }
        else { $parts.Add('Excluded for the entire period') }
    }
    else {
        if ($nonExistMin -gt 0) {
            $parts.Add("Non-existent for $nonExistMin min")
            foreach ($w in $mergedNonExist) { $parts.Add("  non-exist: $($w.From.ToString('MM/dd HH:mm'))-$($w.To.ToString('MM/dd HH:mm'))") }
        }
        if ($stoppedMin -gt 0) {
            $parts.Add("Stopped/deallocated for $stoppedMin min")
            foreach ($w in $mergedStopped) { $parts.Add("  stopped: $($w.From.ToString('MM/dd HH:mm'))-$($w.To.ToString('MM/dd HH:mm'))") }
        }
    }

    [PSCustomObject]@{
        Name              = $Resource.Name
        Kind              = $Resource.Kind
        EligibleMinutes   = $eligibleMin
        TotalMinutes      = $TotalMinutes
        Explanation       = $parts -join '; '
        ResourceGroupName = $Resource.ResourceGroupName
        Location          = $Resource.Location
        ResourceId        = $Resource.ResourceId
        CreatedAt         = $Resource.CreatedAt
        ExclusionWindows  = $mergedExcluded
    }
}

# ── Main ─────────────────────────────────────────────────────────────────────

$utcEnd   = [datetime]::UtcNow
$utcStart = $utcEnd.AddDays(-14)
$period   = [PSCustomObject]@{ Start = $utcStart; End = $utcEnd; TotalMinutes = [int](($utcEnd - $utcStart).TotalMinutes) }

Write-Host "Resolving subscription '$SubscriptionName'..."
$subs = @(Get-AzSubscription | Where-Object Name -eq $SubscriptionName)
if ($subs.Count -eq 0) { Write-Error "Subscription '$SubscriptionName' not found." }
if ($subs.Count -gt 1) { Write-Error "Multiple subscriptions named '$SubscriptionName'." }

$sub = $subs[0]
$null = Set-AzContext -SubscriptionId $sub.Id -Tenant $sub.TenantId -ErrorAction Stop

Write-Host "Using '$($sub.Name)' ($($sub.Id))."
Write-Host "Window: $($period.Start.ToString('u')) -> $($period.End.ToString('u')) ($($period.TotalMinutes) min, buffer: +/-$TransitionBufferMinutes min)"

Write-Host 'Querying resource inventory...'
$resources = Get-CurrentTrackedResources $sub.Id
if ($resources.Count -eq 0) { Write-Warning 'No VMs or SQL databases found.'; return }
Write-Host "Found $($resources.Count) resource(s)."

if ($ResourceName) {
    $resources = @($resources | Where-Object Name -eq $ResourceName)
    if ($resources.Count -eq 0) { Write-Error "Resource '$ResourceName' not found." }
    Write-Host "Filtered to $($resources.Count) resource(s) matching '$ResourceName'."
}

Write-Host 'Querying lifecycle events...'
$allEvents = Get-ResourceChangeEvents $sub.Id $period.Start $period.End

# Single ARM token shared by availability metrics and supplementary recovery
$rawToken = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
$armToken = ($rawToken -is [securestring]) ? ($rawToken | ConvertFrom-SecureString -AsPlainText) : [string]$rawToken

$metrics    = Get-AvailabilityMetrics $resources $period.Start $period.End $Parallelism $armToken
$availByRes = $metrics.DataPoints
$nullByRes  = $metrics.NullTimestamps

$eventsByRes = @{}
foreach ($evt in $allEvents) {
    $key = $evt.ResourceId.ToLowerInvariant()
    if (-not $eventsByRes.ContainsKey($key)) { $eventsByRes[$key] = [System.Collections.Generic.List[object]]::new() }
    $eventsByRes[$key].Add($evt)
}

Write-Host 'Computing availability...'
$idx = 0
$results = foreach ($res in $resources) {
    $idx++
    Write-Progress -Activity 'Computing availability' -Status "[$idx / $($resources.Count)] $($res.Name)" -PercentComplete ($idx / $resources.Count * 100)

    $key = $res.ResourceId.ToLowerInvariant()
    $result = Get-ResourceEligibilityResult -Resource $res `
        -Events ($eventsByRes.ContainsKey($key) ? @($eventsByRes[$key]) : @()) `
        -PeriodStart $period.Start -PeriodEnd $period.End -TotalMinutes $period.TotalMinutes `
        -CurrentPowerState ($res.CurrentPowerState ? $res.CurrentPowerState : 'Unknown') `
        -TransitionBufferMinutes $TransitionBufferMinutes

    $dps  = $availByRes.ContainsKey($key) ? $availByRes[$key] : @()
    $excl = $result.ExclusionWindows
    [double]$availSum = 0.0
    foreach ($dp in $dps) {
        $dpEnd = $dp.Timestamp.AddMinutes(1)
        $hit = $false
        foreach ($w in $excl) { if ($w.From -lt $dpEnd -and $w.To -gt $dp.Timestamp) { $hit = $true; break } }
        if (-not $hit) { $availSum += $dp.Value }
    }

    # Recover gap minutes via supplementary guest metrics (VMs only)
    $nullTs = $nullByRes.ContainsKey($key) ? $nullByRes[$key] : @()
    $gaps = @(foreach ($ts in $nullTs) {
        $dpEnd = $ts.AddMinutes(1)
        $hit = $false
        foreach ($w in $excl) { if ($w.From -lt $dpEnd -and $w.To -gt $ts) { $hit = $true; break } }
        if (-not $hit) { $ts }
    })
    if ($gaps.Count -gt 0) { $availSum += Get-SupplementaryMetricRecovery $res $gaps $armToken }

    $availMin = [math]::Round($availSum, 2)
    $result | Add-Member -NotePropertyName AvailableMinutes -NotePropertyValue $availMin
    $result | Add-Member -NotePropertyName AvailabilityPct -NotePropertyValue (
        $result.EligibleMinutes -gt 0 ? [math]::Round($availMin / $result.EligibleMinutes * 100, 5) : 'N/A'
    )
    $result.PSObject.TypeNames.Insert(0, 'ResourceEligibilityResult')
    $result
}
Write-Progress -Activity 'Computing availability' -Completed

Update-TypeData -TypeName ResourceEligibilityResult -DefaultDisplayPropertySet @(
    'Name','Kind','Location','AvailabilityPct','AvailableMinutes','EligibleMinutes','TotalMinutes','Explanation'
) -Force

$sorted = $results | Sort-Object Kind, Name
$sorted

Write-Host ''
Write-Host '--- Availability Summary ---'
$eligible = @($sorted | Where-Object { $_.AvailabilityPct -ne 'N/A' })
foreach ($g in ($eligible | Group-Object Kind, Location | Sort-Object Name)) {
    $a = ($g.Group | Measure-Object AvailableMinutes -Sum).Sum
    $e = ($g.Group | Measure-Object EligibleMinutes  -Sum).Sum
    Write-Host "  $($g.Name): $(($e -gt 0) ? [math]::Round($a / $e * 100, 5) : 0)% ($([math]::Round($a, 2)) / $([math]::Round($e, 2)) min)"
}
$ta = ($eligible | Measure-Object AvailableMinutes -Sum).Sum
$te = ($eligible | Measure-Object EligibleMinutes  -Sum).Sum
Write-Host "  OVERALL: $(($te -gt 0) ? [math]::Round($ta / $te * 100, 5) : 0)% ($([math]::Round($ta, 2)) / $([math]::Round($te, 2)) min)"
Write-Host ''
