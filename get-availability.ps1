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
    Resource Health is then applied for the overlap with its current 30-day
    retention window:
      - platform fault confirmed (Unavailable/Degraded) -> counts as downtime
      - Unknown / customer-initiated -> valid explanation, excluded from eligibility
    Remaining null minutes become metric issues (excluded from eligibility),
    while remaining 0% minutes are trusted as downtime.

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

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'MySubscription' -Month 202506

.EXAMPLE
    ./get-availability.ps1 -Subscriptions 'Sub1','Sub2' -Month 202505 -Kinds vm,sql
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Subscriptions,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{6}$')]
    [string]$Month,

    [ValidateSet('vm','sql','storage')]
    [string[]]$Kinds = @('vm','sql','storage'),

    [string]$Resource,

    [ValidateRange(1, 64)]
    [int]$Parallelism = [math]::Max(4, [math]::Min(16, [Environment]::ProcessorCount)),

    [ValidateRange(0, 120)]
    [int]$ActivityGraceMinutes = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-ShortKind([string]$Kind) {
    switch ($Kind) {
        'VirtualMachine'   { 'VM' }
        'AzureSqlDatabase' { 'SQL' }
        'StorageAccount'   { 'Storage' }
        default            { $Kind }
    }
}

function Get-HealthCoverageStart([DateTimeOffset]$PeriodStart) {
    $now = [DateTimeOffset]::UtcNow
    $cm = [DateTimeOffset]::new($now.Year, $now.Month, $now.Day,
        $now.Hour, $now.Minute, 0, [TimeSpan]::Zero)
    $ret = $cm.AddDays(-30)
    if ($ret -gt $PeriodStart) { $ret } else { $PeriodStart }
}

function Get-TruncatedString([string]$s, [int]$max) {
    if ($s.Length -le $max) { $s } else { $s.Substring(0, $max - 3) + '...' }
}

# ── Metrics (parallel) ───────────────────────────────────────────────────────

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

    $done = 0
    $resultByRes = @{}

    $Resources | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $resource = $_
        $token    = $using:ArmToken
        $startIso = ($using:StartDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $endIso   = ($using:EndDate).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

        $isVm      = $resource.Kind -eq 'VirtualMachine'
        $isStorage  = $resource.Kind -eq 'StorageAccount'

        if ($isVm) {
            $metricNames = 'VmAvailabilityMetric'
            $agg = 'Minimum'
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
                    $_.ToString() -match 'transport|connection.*closed|reset by peer|timed?\s*out'
                if ($retryable -and $attempt -lt 5) {
                    Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt)))
                    continue
                }
                Write-Warning "Metric query failed for '$($resource.Name)': $_"
                break
            }
        }

        [double]$availSum = 0.0
        [int]$zeroTxMin = 0
        [int]$numericPoints = 0
        $nullTicks    = [System.Collections.Generic.List[long]]::new()
        $zeroTicks    = [System.Collections.Generic.List[long]]::new()
        $degradedTicks  = [System.Collections.Generic.List[long]]::new()
        $degradedValues = [System.Collections.Generic.List[double]]::new()

        if ($jsonBody) {
            $doc = $null
            try {
                $doc = [System.Text.Json.JsonDocument]::Parse($jsonBody)
                $jsonBody = $null

                $jNull = [System.Text.Json.JsonValueKind]::Null
                $jNum  = [System.Text.Json.JsonValueKind]::Number

                function script:GetNum([System.Text.Json.JsonElement]$dp, [string]$prop) {
                    foreach ($p in $dp.EnumerateObject()) {
                        if ($p.Name -eq $prop -and $p.Value.ValueKind -eq $jNum) { return $p.Value.GetDouble() }
                    }
                    return $null
                }

                $valueArr = $doc.RootElement.GetProperty('value')

                if ($isStorage) {
                    # Build Transactions lookup
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
                    # Process Availability
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
                                    $norm = $minVal / 100.0
                                    $numericPoints++
                                    if ($norm -eq 0.0) {
                                        $zeroTicks.Add($ticks)
                                    } else {
                                        $availSum += $norm
                                        if ($norm -lt 1.0) {
                                            $degradedTicks.Add($ticks)
                                            $degradedValues.Add($norm)
                                        }
                                    }
                                } elseif ($hasTx -and $null -eq $minVal) {
                                    $nullTicks.Add($ticks)
                                } elseif (-not $hasTx) {
                                    $zeroTxMin++
                                }
                            }
                        }
                    }
                    $txByTicks = $null
                } else {
                    # VM or SQL DB
                    foreach ($metricEl in $valueArr.EnumerateArray()) {
                        $mName = $metricEl.GetProperty('name').GetProperty('value').GetString()
                        $isPrimary = $mName -eq 'VmAvailabilityMetric' -or $mName -eq 'Availability'
                        if (-not $isPrimary) { continue }

                        foreach ($tsEl in $metricEl.GetProperty('timeseries').EnumerateArray()) {
                            foreach ($dp in $tsEl.GetProperty('data').EnumerateArray()) {
                                $time = [datetime]::Parse($dp.GetProperty('timeStamp').GetString()).ToUniversalTime()
                                $ticks = $time.Ticks
                                $minVal = GetNum $dp 'minimum'

                                if ($null -ne $minVal) {
                                    $numericPoints++
                                    $v = if ($isVm) { $minVal } else { $minVal / 100.0 }
                                    if ($v -eq 0.0) {
                                        $zeroTicks.Add($ticks)
                                    } else {
                                        $availSum += $v
                                        if ($v -lt 1.0) {
                                            $degradedTicks.Add($ticks)
                                            $degradedValues.Add($v)
                                        }
                                    }
                                } else {
                                    $nullTicks.Add($ticks)
                                }
                            }
                        }
                    }
                }
            }
            finally {
                if ($doc) { $doc.Dispose() }
            }
        }

        $gapMinutes = $nullTicks.Count + $zeroTicks.Count
        $degradedMinutes = $degradedTicks.Count
        $excludeFromAvailability = $numericPoints -eq 0 -and $nullTicks.Count -eq 0 -and
            $zeroTicks.Count -eq 0 -and $degradedTicks.Count -eq 0

        [PSCustomObject]@{
            ResourceId              = $resource.ResourceId
            Name                    = $resource.Name
            AvailableSum            = $availSum
            GapMinutes              = $gapMinutes
            ZeroTxMin               = $zeroTxMin
            ExcludeFromAvailability = $excludeFromAvailability
            GapTicks                = @($nullTicks)
            ZeroAvailTicks          = @($zeroTicks)
            DegradedMinutes         = $degradedMinutes
            DegradedTicks           = @($degradedTicks)
            DegradedValues          = @($degradedValues)
            SuspectMinutes          = $gapMinutes + $degradedMinutes
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
    $resultByRes
}

# ── Suspect gap investigation (parallel) ──────────────────────────────────────

function Invoke-SuspectGapInvestigation {
    param(
        [object[]]$Candidates,
        [DateTimeOffset]$PeriodStart,
        [DateTimeOffset]$PeriodEnd,
        [int]$ThrottleLimit,
        [int]$GraceMinutes,
        [string]$ArmToken,
        [DateTimeOffset]$HealthCoverageStart
    )
    Write-Host "Investigating suspect gaps for $($Candidates.Count) resource(s)..."

    $done = 0
    $total = $Candidates.Count
    $resultByRes = @{}

    $Candidates | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $c         = $_
        $token     = $using:ArmToken
        $pStart    = $using:PeriodStart
        $pEnd      = $using:PeriodEnd
        $graceMin  = $using:GraceMinutes
        $hcStart   = $using:HealthCoverageStart

        # ── Local helpers ─────────────────────────────────────────────
        function script:ArmGet([string]$uri) {
            for ($a = 0; $a -lt 6; $a++) {
                try {
                    $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                    try { $r = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing }
                    finally { $ProgressPreference = $old }
                    return $r.Content
                } catch {
                    $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                    if (($code -eq 429 -or $code -ge 500) -and $a -lt 5) {
                        Start-Sleep -Seconds ([math]::Min(30, [math]::Pow(2, $a)))
                        continue
                    }
                    throw
                }
            }
        }

        function script:TruncMin([DateTimeOffset]$v) {
            [DateTimeOffset]::new($v.Year, $v.Month, $v.Day, $v.Hour, $v.Minute, 0, [TimeSpan]::Zero)
        }

        function script:InInterval([long]$tick, [object[]]$intervals) {
            foreach ($iv in $intervals) {
                if ($tick -ge $iv.FromTicks -and $tick -lt $iv.ToTicks) { return $true }
            }
            $false
        }

        function script:GetJsonStr([System.Text.Json.JsonElement]$el, [string]$name) {
            $v = [System.Text.Json.JsonElement]::new()
            if ($el.TryGetProperty($name, [ref]$v) -and
                $v.ValueKind -ne [System.Text.Json.JsonValueKind]::Null) {
                return $v.GetString()
            }
            ''
        }

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

                $filter = "eventTimestamp ge '$($pStart.ToString('O'))' and eventTimestamp le '$($pEnd.ToString('O'))' and resourceUri eq '$($c.ResourceId)'"
                $select = 'eventTimestamp,operationName,correlationId,status'
                $url = "https://management.azure.com/subscriptions/$($c.SubscriptionId)" +
                       "/providers/microsoft.insights/eventtypes/management/values" +
                       "?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))" +
                       "&`$select=$([uri]::EscapeDataString($select))"

                $events = [System.Collections.Generic.List[object]]::new()
                while ($url) {
                    $json = ArmGet $url
                    $doc = [System.Text.Json.JsonDocument]::Parse($json)
                    try {
                        $valEl = [System.Text.Json.JsonElement]::new()
                        if ($doc.RootElement.TryGetProperty('value', [ref]$valEl) -and
                            $valEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                            foreach ($item in $valEl.EnumerateArray()) {
                                $tsStr = GetJsonStr $item 'eventTimestamp'
                                $ts = ParseTimestamp $tsStr
                                if ($null -eq $ts) { continue }

                                # Parse operationName (nested object with value + localizedValue)
                                $opValue = ''; $opLabel = ''
                                $opEl = [System.Text.Json.JsonElement]::new()
                                if ($item.TryGetProperty('operationName', [ref]$opEl) -and
                                    $opEl.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                                    $opValue = GetJsonStr $opEl 'value'
                                    $opLabel = GetJsonStr $opEl 'localizedValue'
                                }
                                $opKey = if ($opValue) { $opValue } else { $opLabel }
                                if (-not $opKey) { continue }

                                # Match against rules
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

                # Build intervals from events
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

                    # Merge intervals
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
        $healthHistoryApplied = [DateTimeOffset]$hcStart -lt [DateTimeOffset]$pEnd
        $faultIntervals    = @()
        $unknownIntervals  = @()
        $customerIntervals = @()

        if ($healthHistoryApplied) {
            try {
                $transitions = [System.Collections.Generic.List[object]]::new()
                $url = "https://management.azure.com$($c.ResourceId)" +
                       "/providers/Microsoft.ResourceHealth/availabilityStatuses" +
                       "?api-version=2025-05-01"

                while ($url) {
                    $json = ArmGet $url
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

                # API returns newest-first; reverse to chronological
                $transArr = @($transitions)
                [array]::Reverse($transArr)

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
        $zeroSet = [System.Collections.Generic.HashSet[long]]::new()
        foreach ($zt in @($c.ZeroTicksArray)) { [void]$zeroSet.Add([long]$zt) }

        $hcStartTicks = ([DateTimeOffset]$hcStart).UtcTicks

        [int]$platformFaultGapMin = 0
        [int]$unresolvedZeroDowntimeMin = 0
        [int]$healthExplainedGapMin = 0
        [int]$metricIssueNullMin = 0
        [int]$activityLogExcludedGapMin = 0
        [int]$customerExcusedDegradedMin = 0
        [double]$customerExcusedDegradedAvail = 0.0
        [int]$activityLogDegradedMin = 0
        [int]$healthConfirmedDegradedMin = 0

        foreach ($tick in @($c.AllGapTicks)) {
            $tk = [long]$tick
            $isZero      = $zeroSet.Contains($tk)
            $inActivity  = InInterval $tk $activityIntervals
            $inHCoverage = $healthHistoryApplied -and $tk -ge $hcStartTicks
            $inFault     = $inHCoverage -and (InInterval $tk $faultIntervals)
            $inUnknown   = $inHCoverage -and (InInterval $tk $unknownIntervals)
            $inCustomer  = $inHCoverage -and (InInterval $tk $customerIntervals)

            if     ($inFault)                    { $platformFaultGapMin++ }
            elseif ($inActivity)                 { $activityLogExcludedGapMin++ }
            elseif ($inCustomer -or $inUnknown)  { $healthExplainedGapMin++ }
            elseif ($isZero)                     { $unresolvedZeroDowntimeMin++ }
            else                                 { $metricIssueNullMin++ }
        }

        # Classify degraded samples
        $dgTicks  = @($c.DegradedTicks)
        $dgValues = @($c.DegradedValues)
        for ($i = 0; $i -lt $dgTicks.Count; $i++) {
            $tk = [long]$dgTicks[$i]
            $dv = [double]$dgValues[$i]

            $inActivity  = InInterval $tk $activityIntervals
            $inHCoverage = $healthHistoryApplied -and $tk -ge $hcStartTicks
            $inFault     = $inHCoverage -and (InInterval $tk $faultIntervals)
            $inCustomer  = $inHCoverage -and (InInterval $tk $customerIntervals)

            if ($inFault) {
                $healthConfirmedDegradedMin++
            } elseif ($inActivity -or $inCustomer) {
                $customerExcusedDegradedMin++
                $customerExcusedDegradedAvail += $dv
                if ($inActivity) { $activityLogDegradedMin++ }
            }
        }

        [PSCustomObject]@{
            ResourceId                        = $c.ResourceId
            HealthHistoryApplied              = $healthHistoryApplied
            ActivityLogExcludedGapMinutes     = $activityLogExcludedGapMin
            HealthExplainedGapMinutes         = $healthExplainedGapMin
            MetricIssueNullMinutes            = $metricIssueNullMin
            PlatformFaultGapMinutes           = $platformFaultGapMin
            UnresolvedZeroDowntimeMinutes     = $unresolvedZeroDowntimeMin
            CustomerExcusedDegradedMinutes    = $customerExcusedDegradedMin
            CustomerExcusedDegradedAvailableSum = $customerExcusedDegradedAvail
            ActivityLogDegradedMinutes        = $activityLogDegradedMin
            HealthConfirmedDegradedMinutes    = $healthConfirmedDegradedMin
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
    $resultByRes
}

# ── Output ────────────────────────────────────────────────────────────────────

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
        Write-Host ([char]0x2550 * 62)
        Write-Host '               OVERALL (all subscriptions)'
        Write-Host ([char]0x2550 * 62)
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

$healthCoverageStart = Get-HealthCoverageStart $utcStart
$healthCoveredMinutes = if ($healthCoverageStart -lt $utcEnd) {
    [int]($utcEnd - $healthCoverageStart).TotalMinutes
} else { 0 }

$periodLabel = if ($window.IsMonthToDate) { "month $($window.NormalizedMonth) (month-to-date)" }
               else { "month $($window.NormalizedMonth)" }
Write-Host "Period: $periodLabel ($($utcStart.ToString('u')) -> $($utcEnd.ToString('u')), $totalMinutes min)"

if ($healthCoverageStart -gt $utcStart -and $healthCoveredMinutes -gt 0) {
    Write-Host "WARNING: Resource Health history covers only part of this period ($($healthCoverageStart.ToString('u')) -> $($utcEnd.ToString('u')), $healthCoveredMinutes of $totalMinutes min). Earlier minutes will use Activity Log and metric fallback rules."
} elseif ($healthCoveredMinutes -eq 0) {
    Write-Host 'WARNING: Resource Health history does not cover this period. All suspect minutes will use Activity Log and metric fallback rules.'
}

# Step 2: Authenticate and resolve subscriptions
Write-Host -NoNewline 'Authenticating... '
$allAzSubs = @(Get-AzSubscription)
$resolvedSubs = @(foreach ($name in $Subscriptions) {
    $matches = @($allAzSubs | Where-Object Name -eq $name)
    if ($matches.Count -eq 0) { throw "Subscription '$name' not found." }
    if ($matches.Count -gt 1) { throw "Multiple subscriptions named '$name'." }
    $matches[0]
})
$subIds      = @($resolvedSubs.Id)
$subIdToName = @{}; foreach ($s in $resolvedSubs) { $subIdToName[$s.Id] = $s.Name }
Write-Host 'OK'
Write-Host "Processing $($resolvedSubs.Count) subscription(s): $($resolvedSubs.Name -join ', ')"
Write-Host "Kinds: $($Kinds -join ', ')"

# Step 3: Query Resource Graph inventory
Write-Host -NoNewline 'Querying resource inventory... '
$resources = Get-ResourceInventory -SubscriptionIds $subIds -SubIdToName $subIdToName `
    -Kinds $Kinds -ResourceNameFilter $Resource
Write-Host "Found $($resources.Count) resource(s) across $($resolvedSubs.Count) subscription(s)."

if ($resources.Count -eq 0) { Write-Host 'No resources found.'; return }

# Step 4: Build initial eligibility (all minutes eligible)
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

# Step 5: Fetch Azure Monitor metrics per resource in parallel
$rawToken = (Get-AzAccessToken -ResourceUrl 'https://management.azure.com').Token
$armToken = ($rawToken -is [securestring]) ? ($rawToken | ConvertFrom-SecureString -AsPlainText) : [string]$rawToken
$rawToken = $null

$metricResults = Get-AvailabilityMetrics -Resources $resources -StartDate $utcStart `
    -EndDate $utcEnd -ThrottleLimit $Parallelism -ArmToken $armToken

# Step 6: Build suspect candidates and investigate
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

$suspectResults = $null
if ($suspectCandidates.Count -gt 0) {
    $suspectResults = Invoke-SuspectGapInvestigation -Candidates @($suspectCandidates) `
        -PeriodStart $utcStart -PeriodEnd $utcEnd -ThrottleLimit $Parallelism `
        -GraceMinutes $ActivityGraceMinutes -ArmToken $armToken `
        -HealthCoverageStart $healthCoverageStart
}

# Step 7: Assemble final results
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

        # Count suspect gaps for narration
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

# Output objects for pipeline use
$sorted
