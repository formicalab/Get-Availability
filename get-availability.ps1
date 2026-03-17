#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Reports rolling 14-day availability for VMs, Azure SQL databases, and Storage Accounts.

.DESCRIPTION
    Uses Azure Resource Graph to inventory VMs, SQL DBs, and Storage Accounts,
    detect lifecycle transitions (start/stop/create/delete) from the resourcechanges
    table, and query Azure Monitor availability metrics at PT1M granularity.

    Builds exclusion windows for non-existence and purposeful stops, then:
      EligibleMinutes = TotalMinutes - ExcludedMinutes
      AvailabilityPct = AvailableMinutes / EligibleMinutes * 100

    For VMs with null VmAvailabilityMetric data points during eligible minutes,
    supplementary guest-level metrics (CPU, Network) are checked inline. A gap
    minute is recovered only if BOTH metrics report non-null data.

.PARAMETER SubscriptionNames
    One or more Azure subscription display names.

.PARAMETER ResourceName
    Optional single resource to report on (server/db format for SQL DBs).

.PARAMETER TransitionToleranceMinutes
    Symmetric tolerance (+-N) around each start/stop event. Default 5.

.EXAMPLE
    ./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-PRODUZIONE'

.EXAMPLE
    ./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-SVILUPPO','POSTE-BANCOPOSTA-PRODUZIONE','POSTE-BANCOPOSTA-CERTIFICAZIONE'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionNames,

    [ValidateRange(1, 64)]
    [int]$Parallelism = [math]::Max(4, [math]::Min(16, [Environment]::ProcessorCount)),

    [string]$ResourceName,

    [ValidateSet('vm','sql','storage')]
    [string[]]$ResourceKinds = @('vm','sql','storage'),

    [ValidateRange(0, 120)]
    [int]$TransitionToleranceMinutes = 5
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

function Get-CurrentTrackedResources([string[]]$SubscriptionIds, [hashtable]$SubIdToName) {
    $query = @"
resources
| where type =~ 'microsoft.compute/virtualmachines'
    or type =~ 'microsoft.sql/servers/databases'
    or type =~ 'microsoft.storage/storageaccounts'
| extend idParts = split(id, '/')
| extend sqlServerName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[8]), '')
| extend databaseName = iff(type =~ 'microsoft.sql/servers/databases', tostring(idParts[10]), '')
| where not(type =~ 'microsoft.sql/servers/databases' and databaseName =~ 'master')
| extend resourceKind = case(
    type =~ 'microsoft.compute/virtualmachines', 'VirtualMachine',
    type =~ 'microsoft.sql/servers/databases', 'AzureSqlDatabase',
    type =~ 'microsoft.storage/storageaccounts', 'StorageAccount',
    'Other'
)
| extend createdAt = case(
    type =~ 'microsoft.compute/virtualmachines', todatetime(properties.timeCreated),
    type =~ 'microsoft.sql/servers/databases', todatetime(properties.creationDate),
    type =~ 'microsoft.storage/storageaccounts', todatetime(properties.creationTime),
    datetime(null)
)
| extend currentPowerState = case(
    type =~ 'microsoft.compute/virtualmachines', tostring(properties.extended.instanceView.powerState.code),
    type =~ 'microsoft.sql/servers/databases', tostring(properties.status),
    ''
)
| project id, name, type, subscriptionId, resourceGroup, location, resourceKind, createdAt, sqlServerName, databaseName, currentPowerState
"@

    $resources = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $params = @{ Query = $query; First = 1000; Subscription = $SubscriptionIds }
        if ($skipToken) { $params.SkipToken = $skipToken }
        $response = Search-AzGraph @params

        foreach ($row in $response.Data) {
            $kind = [string]$row.resourceKind
            $rawPower = [string]$row.currentPowerState
            $subId = [string]$row.subscriptionId
            $resources.Add([PSCustomObject]@{
                Name              = ($kind -eq 'AzureSqlDatabase' -and $row.sqlServerName -and $row.databaseName) ?
                                        "$($row.sqlServerName)/$($row.databaseName)" : [string]$row.name
                Kind              = $kind
                ResourceId        = [string]$row.id
                SubscriptionId    = $subId
                SubscriptionName  = $SubIdToName.ContainsKey($subId) ? $SubIdToName[$subId] : $subId
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

    @($resources | Sort-Object SubscriptionName, Kind, Name)
}

# ── Lifecycle change events from Resource Graph ──────────────────────────────

function Get-ResourceChangeEvents([string[]]$SubscriptionIds, [datetime]$StartDate, [datetime]$EndDate) {
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

    $storageQuery = @"
resourcechanges
| extend changeTime  = todatetime(properties.changeAttributes.timestamp),
         changeType   = tostring(properties.changeType),
         targetId     = tostring(properties.targetResourceId),
         targetType   = tostring(properties.targetResourceType)
| where targetType =~ 'microsoft.storage/storageaccounts'
| where changeTime >= datetime('$startIso') and changeTime <= datetime('$endIso')
| where changeType in ('Create', 'Delete')
| project changeTime, changeType, targetId
"@

    $allEvents = [System.Collections.Generic.List[object]]::new()
    foreach ($queryPair in @(
        @{ Query = $vmQuery;      Kind = 'VM' },
        @{ Query = $sqlQuery;     Kind = 'SQL' },
        @{ Query = $storageQuery; Kind = 'Storage' }
    )) {
        $skipToken = $null
        do {
            $params = @{ Query = $queryPair.Query; First = 1000; Subscription = $SubscriptionIds }
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
                        } elseif ($queryPair.Kind -eq 'SQL') {
                            switch ([string]$row.newStatus) {
                                'Online'   { 'Start' }
                                'Paused'   { 'Stop' }
                                'Pausing'  { 'Stop' }
                                default    { $null }
                            }
                        } else { $null }
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

# ── Availability metric retrieval (parallel, inline computation) ──────────────

function Get-AvailabilityMetrics([object[]]$Resources, [datetime]$StartDate, [datetime]$EndDate, [int]$ThrottleLimit, [string]$ArmToken) {
    $total = $Resources.Count
    Write-Host "Querying metrics for $total resource(s) with parallelism $ThrottleLimit..."

    $done = 0
    $resultByRes = @{}

    $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $resource = $_
        $token    = $using:ArmToken
        $startIso = ($using:StartDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endIso   = ($using:EndDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $isVm      = $resource.Kind -eq 'VirtualMachine'
        $isStorage = $resource.Kind -eq 'StorageAccount'

        # Build HashSet of excluded minute ticks for O(1) lookup
        $exclFrom  = @($resource._ExclFrom)
        $exclTo    = @($resource._ExclTo)
        $ticksPerMin = [TimeSpan]::TicksPerMinute
        $excludedTicks = [System.Collections.Generic.HashSet[long]]::new()
        for ($i = 0; $i -lt $exclFrom.Count; $i++) {
            $t = [long]$exclFrom[$i]
            $end = [long]$exclTo[$i]
            while ($t -lt $end) { [void]$excludedTicks.Add($t); $t += $ticksPerMin }
        }

        if ($isVm) {
            $metricNames = 'VmAvailabilityMetric,Percentage CPU,Network In Total'
            $agg = 'Minimum,Average'
        } elseif ($isStorage) {
            $metricNames = 'Availability,Transactions'
            $agg = 'Minimum,Total'
        } else {
            $metricNames = 'Availability'
            $agg = 'Minimum'
        }

        $uri = "https://management.azure.com$($resource.ResourceId)/providers/Microsoft.Insights/metrics?" +
               "api-version=2024-02-01&metricnames=$([uri]::EscapeDataString($metricNames))" +
               "&timespan=$startIso/$endIso&interval=PT1M&aggregation=$agg"

        # Use Invoke-WebRequest + System.Text.Json instead of Invoke-RestMethod to avoid
        # deserializing ~60K data points into costly PSObject trees. JsonDocument uses pooled
        # memory and is disposable — peak per-response memory drops from ~30-50 MB to ~2-5 MB.
        $jsonBody = $null
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                $oldPref = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                try { $resp = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -Method GET -UseBasicParsing }
                finally { $ProgressPreference = $oldPref }
                $jsonBody = $resp.Content
                $resp = $null
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
                Write-Warning "Metric query failed for '$($resource.Name)': $_"
                break
            }
        }

        [double]$availSum = 0.0
        [int]$recovered = 0
        [int]$zeroTxMin = 0

        if ($jsonBody) {
            $doc = $null
            try {
                $doc = [System.Text.Json.JsonDocument]::Parse($jsonBody)
                $jsonBody = $null  # release the string immediately

                $jNull = [System.Text.Json.JsonValueKind]::Null
                $jNum  = [System.Text.Json.JsonValueKind]::Number

                # Safe numeric extraction: data points may omit aggregation keys entirely
                function script:GetNum([System.Text.Json.JsonElement]$dp, [string]$prop) {
                    foreach ($p in $dp.EnumerateObject()) {
                        if ($p.Name -eq $prop -and $p.Value.ValueKind -eq $jNum) { return $p.Value.GetDouble() }
                    }
                    return $null
                }

                $valueArr = $doc.RootElement.GetProperty('value')
                if ($isStorage) {
                    # First pass: build Transactions lookup
                    $txByTicks = [System.Collections.Generic.Dictionary[long,double]]::new()
                    foreach ($metricEl in $valueArr.EnumerateArray()) {
                        $mName = $metricEl.GetProperty('name').GetProperty('value').GetString()
                        if ($mName -ne 'Transactions') { continue }
                        foreach ($tsEl in $metricEl.GetProperty('timeseries').EnumerateArray()) {
                            foreach ($dp in $tsEl.GetProperty('data').EnumerateArray()) {
                                $time = [datetime]::Parse($dp.GetProperty('timeStamp').GetString()).ToUniversalTime()
                                $tot = GetNum $dp 'total'
                                if ($null -ne $tot) { $txByTicks[$time.Ticks] = $tot }
                            }
                        }
                    }
                    # Second pass: process Availability
                    foreach ($metricEl in $valueArr.EnumerateArray()) {
                        $mName = $metricEl.GetProperty('name').GetProperty('value').GetString()
                        if ($mName -ne 'Availability') { continue }
                        foreach ($tsEl in $metricEl.GetProperty('timeseries').EnumerateArray()) {
                            foreach ($dp in $tsEl.GetProperty('data').EnumerateArray()) {
                                $time = [datetime]::Parse($dp.GetProperty('timeStamp').GetString()).ToUniversalTime()
                                $ticks = $time.Ticks
                                $txVal = [double]0
                                $hasTx = $txByTicks.TryGetValue($ticks, [ref]$txVal) -and $txVal -gt 0
                                $minVal = GetNum $dp 'minimum'
                                if ($hasTx -and $null -ne $minVal) {
                                    if (-not $excludedTicks.Contains($ticks)) { $availSum += $minVal / 100.0 }
                                } elseif (-not $hasTx) {
                                    if (-not $excludedTicks.Contains($ticks)) { $zeroTxMin++ }
                                }
                            }
                        }
                    }
                    $txByTicks = $null
                } else {
                    # VM or SQL DB
                    $suppByMinute = @{}
                    $nullTicks = [System.Collections.Generic.List[long]]::new()
                    foreach ($metricEl in $valueArr.EnumerateArray()) {
                        $mName = $metricEl.GetProperty('name').GetProperty('value').GetString()
                        $isPrimary = $mName -eq 'VmAvailabilityMetric' -or $mName -eq 'Availability'
                        foreach ($tsEl in $metricEl.GetProperty('timeseries').EnumerateArray()) {
                            foreach ($dp in $tsEl.GetProperty('data').EnumerateArray()) {
                                $time = [datetime]::Parse($dp.GetProperty('timeStamp').GetString()).ToUniversalTime()
                                $ticks = $time.Ticks
                                if ($isPrimary) {
                                    $minVal = GetNum $dp 'minimum'
                                    if ($null -ne $minVal) {
                                        if (-not $isVm) { $minVal /= 100.0 }
                                        if (-not $excludedTicks.Contains($ticks)) { $availSum += $minVal }
                                    } else {
                                        $nullTicks.Add($ticks)
                                    }
                                } elseif ($isVm) {
                                    $avgVal = GetNum $dp 'average'
                                    if ($null -ne $avgVal) {
                                        $tsKey = $time.ToString('yyyy-MM-dd HH:mm')
                                        $suppByMinute[$tsKey] = ($suppByMinute[$tsKey] ?? 0) + 1
                                    }
                                }
                            }
                        }
                    }
                    # Inline gap recovery (VMs only, require both CPU + Network)
                    if ($isVm -and $nullTicks.Count -gt 0) {
                        foreach ($nt in $nullTicks) {
                            if (-not $excludedTicks.Contains($nt)) {
                                $ts = [datetime]::new($nt, [DateTimeKind]::Utc)
                                if (($suppByMinute[$ts.ToString('yyyy-MM-dd HH:mm')] ?? 0) -ge 2) {
                                    $recovered++; $availSum += 1.0
                                }
                            }
                        }
                    }
                    $suppByMinute = $null; $nullTicks = $null
                }
            }
            finally {
                if ($doc) { $doc.Dispose() }
            }
        }
        $excludedTicks = $null

        [PSCustomObject]@{
            ResourceId   = $resource.ResourceId
            Name         = $resource.Name
            AvailableSum = $availSum
            Recovered    = $recovered
            ZeroTxMin    = $zeroTxMin
        }
    } | ForEach-Object {
        $done++
        $key = $_.ResourceId.ToLowerInvariant()
        $resultByRes[$key] = $_
        Write-Progress -Activity 'Querying metrics' `
            -Status "[$done / $total] $($_.Name)" `
            -PercentComplete ([math]::Min(100, $done / $total * 100))
    }
    Write-Progress -Activity 'Querying metrics' -Completed
    $resultByRes
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
        [int]$TransitionToleranceMinutes = 5
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

    # Symmetric +-N tolerance around every power event
    $buf = [TimeSpan]::FromMinutes($TransitionToleranceMinutes)
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
    $eligibleMin = [math]::Max(0, [int]($TotalMinutes - $excludedMin))

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

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$now      = [datetime]::UtcNow
$utcEnd   = [datetime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $now.Minute, 0, [DateTimeKind]::Utc)
$utcStart = $utcEnd.AddDays(-14)
$period   = [PSCustomObject]@{ Start = $utcStart; End = $utcEnd; TotalMinutes = [int](($utcEnd - $utcStart).TotalMinutes) }

Write-Host "Window: $($period.Start.ToString('u')) -> $($period.End.ToString('u')) ($($period.TotalMinutes) min, tolerance: +/-$TransitionToleranceMinutes min)"

# Resolve all subscriptions up front
$allAzSubs = @(Get-AzSubscription)
$resolvedSubs = @(foreach ($name in $SubscriptionNames) {
    $matches = @($allAzSubs | Where-Object Name -eq $name)
    if ($matches.Count -eq 0) { Write-Error "Subscription '$name' not found." }
    if ($matches.Count -gt 1) { Write-Error "Multiple subscriptions named '$name'." }
    $matches[0]
})
$subIds     = @($resolvedSubs.Id)
$subIdToName = @{}; foreach ($s in $resolvedSubs) { $subIdToName[$s.Id] = $s.Name }
Write-Host "Processing $($resolvedSubs.Count) subscription(s): $($resolvedSubs.Name -join ', ')"

# Single batched inventory query across all subscriptions
Write-Host 'Querying resource inventory...'
$resources = Get-CurrentTrackedResources $subIds $subIdToName
if ($resources.Count -eq 0) { Write-Warning 'No VMs or SQL databases found.'; return }
# Filter by requested resource kinds
$kindMap = @{ 'vm' = 'VirtualMachine'; 'sql' = 'AzureSqlDatabase'; 'storage' = 'StorageAccount' }
$selectedKinds = @($ResourceKinds | ForEach-Object { $kindMap[$_] })
$resources = @($resources | Where-Object Kind -in $selectedKinds)
Write-Host "  Found $($resources.Count) resource(s) across $($resolvedSubs.Count) subscription(s) (kinds: $($ResourceKinds -join ', '))."

if ($ResourceName) {
    $resources = @($resources | Where-Object Name -eq $ResourceName)
    if ($resources.Count -eq 0) { Write-Error "Resource '$ResourceName' not found." }
    Write-Host "  Filtered to $($resources.Count) resource(s) matching '$ResourceName'."
}

# Single batched change events query across all subscriptions
Write-Host 'Querying lifecycle events...'
$allEvents = Get-ResourceChangeEvents $subIds $period.Start $period.End

# Single ARM token (tenant/management-plane scoped, works across all subscriptions)
$rawToken = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
$armToken = ($rawToken -is [securestring]) ? ($rawToken | ConvertFrom-SecureString -AsPlainText) : [string]$rawToken
$rawToken = $null

# Group events by resource, then release raw events list
$eventsByRes = @{}
foreach ($evt in $allEvents) {
    $key = $evt.ResourceId.ToLowerInvariant()
    if (-not $eventsByRes.ContainsKey($key)) { $eventsByRes[$key] = [System.Collections.Generic.List[object]]::new() }
    $eventsByRes[$key].Add($evt)
}
$allEvents = $null

# Pre-compute eligibility (exclusion windows) before metric fetch
Write-Host 'Computing eligibility...'
$eligByRes = @{}
foreach ($res in $resources) {
    $key = $res.ResourceId.ToLowerInvariant()
    $elig = Get-ResourceEligibilityResult -Resource $res `
        -Events ($eventsByRes.ContainsKey($key) ? @($eventsByRes[$key]) : @()) `
        -PeriodStart $period.Start -PeriodEnd $period.End -TotalMinutes $period.TotalMinutes `
        -CurrentPowerState ($res.CurrentPowerState ? $res.CurrentPowerState : 'Unknown') `
        -TransitionToleranceMinutes $TransitionToleranceMinutes
    $eligByRes[$key] = $elig
    # Attach exclusion windows as tick arrays for efficient serialization into parallel runspaces
    $res | Add-Member -NotePropertyName _ExclFrom -NotePropertyValue @($elig.ExclusionWindows | ForEach-Object { $_.From.Ticks }) -Force
    $res | Add-Member -NotePropertyName _ExclTo   -NotePropertyValue @($elig.ExclusionWindows | ForEach-Object { $_.To.Ticks })   -Force
}
$eventsByRes = $null

# Fetch metrics and compute availability inline (no large data arrays cross the parallel boundary)
$metricResults = Get-AvailabilityMetrics $resources $period.Start $period.End $Parallelism $armToken

Update-TypeData -TypeName ResourceEligibilityResult -DefaultDisplayPropertySet @(
    'SubscriptionName','Name','Kind','Location','AvailabilityPct','AvailableMinutes','EligibleMinutes','TotalMinutes','Explanation'
) -Force

# Assemble final results from pre-computed eligibility + metric scalars
$results = foreach ($res in $resources) {
    $key = $res.ResourceId.ToLowerInvariant()
    $elig = $eligByRes[$key]
    $mr   = $metricResults.ContainsKey($key) ? $metricResults[$key] : $null

    if ($mr -and $mr.Recovered -gt 0) {
        Write-Host "  [$($res.Name)] Recovered $($mr.Recovered) gap min via supplementary metrics"
    }
    if ($mr -and $mr.ZeroTxMin -gt 0 -and $res.Kind -eq 'StorageAccount') {
        $elig.EligibleMinutes = [math]::Max(0, $elig.EligibleMinutes - $mr.ZeroTxMin)
    }

    $availMin = $mr ? [math]::Round($mr.AvailableSum, 2) : 0
    $elig | Add-Member -NotePropertyName AvailableMinutes -NotePropertyValue $availMin
    $elig | Add-Member -NotePropertyName AvailabilityPct -NotePropertyValue (
        $elig.EligibleMinutes -gt 0 ? [math]::Round($availMin / $elig.EligibleMinutes * 100, 5) : 'N/A'
    )
    $elig | Add-Member -NotePropertyName SubscriptionName -NotePropertyValue $res.SubscriptionName
    $elig.PSObject.TypeNames.Insert(0, 'ResourceEligibilityResult')
    $elig
}
$eligByRes = $null; $metricResults = $null

$sorted = @($results | Sort-Object SubscriptionName, Kind, Name)
$sorted

# Per-subscription summaries
$eligible = @($sorted | Where-Object { $_.AvailabilityPct -ne 'N/A' })
foreach ($subGroup in ($eligible | Group-Object SubscriptionName | Sort-Object Name)) {
    Write-Host ''
    Write-Host "--- $($subGroup.Name) Summary ---"
    foreach ($g in ($subGroup.Group | Group-Object Kind, Location | Sort-Object Name)) {
        $n = $g.Count
        $a = ($g.Group | Measure-Object AvailableMinutes -Sum).Sum
        $e = ($g.Group | Measure-Object EligibleMinutes  -Sum).Sum
        Write-Host "  $($g.Name) [$n res]: $(($e -gt 0) ? [math]::Round($a / $e * 100, 5) : 0)% ($([math]::Round($a, 2)) / $([math]::Round($e, 2)) eligible min)"
    }
    $tn = $subGroup.Count
    $ta = ($subGroup.Group | Measure-Object AvailableMinutes -Sum).Sum
    $te = ($subGroup.Group | Measure-Object EligibleMinutes  -Sum).Sum
    Write-Host "  TOTAL [$tn res]: $(($te -gt 0) ? [math]::Round($ta / $te * 100, 5) : 0)% ($([math]::Round($ta, 2)) / $([math]::Round($te, 2)) eligible min)"
}

# Cross-subscription summary
if ($resolvedSubs.Count -gt 1 -and $eligible.Count -gt 0) {
    Write-Host ''
    Write-Host '══════════════════════════════════════════════════════════════'
    Write-Host '               OVERALL (all subscriptions)'
    Write-Host '══════════════════════════════════════════════════════════════'
    foreach ($g in ($eligible | Group-Object Kind, Location | Sort-Object Name)) {
        $n = $g.Count
        $a = ($g.Group | Measure-Object AvailableMinutes -Sum).Sum
        $e = ($g.Group | Measure-Object EligibleMinutes  -Sum).Sum
        Write-Host "  $($g.Name) [$n res]: $(($e -gt 0) ? [math]::Round($a / $e * 100, 5) : 0)% ($([math]::Round($a, 2)) / $([math]::Round($e, 2)) eligible min)"
    }
    $tn = $eligible.Count
    $ta = ($eligible | Measure-Object AvailableMinutes -Sum).Sum
    $te = ($eligible | Measure-Object EligibleMinutes  -Sum).Sum
    Write-Host "  OVERALL [$tn res]: $(($te -gt 0) ? [math]::Round($ta / $te * 100, 5) : 0)% ($([math]::Round($ta, 2)) / $([math]::Round($te, 2)) eligible min)"
    Write-Host ''
}

$sw.Stop()
Write-Host "Completed in $($sw.Elapsed.ToString('hh\:mm\:ss\.ff'))"
