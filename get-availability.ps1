#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.Monitor, Az.Resources

<#
.SYNOPSIS
    Calculates VM availability percentage using the VmAvailabilityMetric.

.DESCRIPTION
    Queries the VmAvailabilityMetric from Azure Monitor at 1-minute granularity
    and computes the actual availability percentage for each VM and an overall
    figure across all targeted VMs.

    The metric emits:
      1   - the VM was available during that minute.
      0   - the VM was unavailable (platform-initiated).
      null - no metric was emitted (VM not running).

    A null value alone does NOT prove user-initiated deallocation. The script
    therefore queries the Activity Log for each VM to find successful
    deallocate / start pairs initiated by a known principal (user or service
    principal). Only the time windows covered by those legitimate deallocation
    pairs are excluded from the availability calculation.

    Similarly, OS patching windows (planned maintenance) are detected from
    the Activity Log ("Install OS update patches" operations). Null metrics
    during patching windows are excluded from the denominator since they
    represent expected, planned maintenance rather than unforeseen outages.

    VMs that were deallocated for the entire period are excluded from the
    overall calculation and reported separately. This includes VMs whose
    deallocation windows cover the full range, as well as VMs that show
    no metric signals at all and no Activity Log events (deallocated before
    the query period started).

    VM lifecycle (create / delete / recreate cycles) is also tracked from
    the Activity Log.  Minutes when the VM did not exist are excluded from
    the denominator.  The VM's TimeCreated property is used as a fallback
    to detect first-time creation within the observation period.

    Service principal callers are resolved to display names using
    Get-AzADServicePrincipal for clearer reporting.

    State transitions (start after deallocation, reboot after patching, first
    boot after creation) often produce 1-2 minutes of null or zero metric while
    the VM is booting and the Guest Agent reconnects.  A configurable grace
    period (TransitionGraceMinutes, default 2) extends each exclusion window's
    trailing edge so those transition minutes are not penalised as unavailable.
    Data points where the metric is already 1 (available) are never suppressed
    by the grace period.

    Null data points that fall outside any known user-initiated deallocation
    or patching window (including the grace period) are treated as unavailable
    (potential platform issue).

    Availability % = AvailableMinutes / (AvailableMinutes + UnavailableMinutes) * 100

    When multiple VMs are in scope the overall availability is the ratio of the
    sum of available minutes to the sum of eligible minutes across all VMs
    (resource-weighted average).

    Reference: https://clemens.ms/calculate-the-availability-and-sla-for-your-azure-solution/

    Assumes an Azure context is already established (Connect-AzAccount).

.PARAMETER VMName
    The name of a specific virtual machine. Requires ResourceGroupName.

.PARAMETER ResourceGroupName
    The name of the resource group containing the VM(s).

.PARAMETER StartDate
    Start of the time range to query (UTC).

.PARAMETER EndDate
    End of the time range to query (UTC).

.EXAMPLE
    # Single VM
    ./get-availability.ps1 -VMName "web-01" -ResourceGroupName "rg-prod" `
        -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z"

.EXAMPLE
    # All VMs in a resource group
    ./get-availability.ps1 -ResourceGroupName "rg-prod" `
        -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z"

.EXAMPLE
    # All VMs in the current subscription
    ./get-availability.ps1 -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z"

.EXAMPLE
    # Custom grace period (0 = disable, max 10)
    ./get-availability.ps1 -VMName "web-01" -ResourceGroupName "rg-prod" `
        -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z" `
        -TransitionGraceMinutes 3
#>

[CmdletBinding(DefaultParameterSetName = 'Subscription')]
param(
    [Parameter(Mandatory, ParameterSetName = 'SingleVM')]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory, ParameterSetName = 'SingleVM')]
    [Parameter(Mandatory, ParameterSetName = 'ResourceGroup')]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [datetime]$StartDate,

    [Parameter(Mandatory)]
    [datetime]$EndDate,

    [Parameter()]
    [ValidateRange(0, 10)]
    [int]$TransitionGraceMinutes = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Normalise dates to UTC
# ---------------------------------------------------------------------------
$StartDate = $StartDate.ToUniversalTime()
$EndDate   = $EndDate.ToUniversalTime()

if ($EndDate -le $StartDate) {
    Write-Error 'EndDate must be greater than StartDate.'
}

# ---------------------------------------------------------------------------
# Warn if the query period exceeds Activity Log retention (90 days)
# ---------------------------------------------------------------------------
$activityLogMaxDays = 89
$daysBack = ((Get-Date).ToUniversalTime() - $StartDate).TotalDays
if ($daysBack -gt $activityLogMaxDays) {
    Write-Warning ("StartDate is {0:N0} days ago. Azure Activity Log retains events for ~90 days. " +
                   "Deallocation, patching, and lifecycle events older than 90 days will be missing, " +
                   "which may cause null metrics to be incorrectly counted as unavailable.") -f $daysBack
}

# ---------------------------------------------------------------------------
# Resolve the target VM(s)
# ---------------------------------------------------------------------------
Write-Verbose "Parameter set: $($PSCmdlet.ParameterSetName)"

[array]$vms = switch ($PSCmdlet.ParameterSetName) {
    'SingleVM' {
        Write-Host "Getting VM '$VMName' in resource group '$ResourceGroupName'..."
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
    }
    'ResourceGroup' {
        Write-Host "Getting all VMs in resource group '$ResourceGroupName'..."
        Get-AzVM -ResourceGroupName $ResourceGroupName
    }
    'Subscription' {
        Write-Host 'Getting all VMs in the current subscription...'
        Get-AzVM
    }
}

if ($vms.Count -eq 0) {
    Write-Warning 'No virtual machines found for the specified scope.'
    return
}

Write-Host "Found $($vms.Count) VM(s). Querying VmAvailabilityMetric ($($StartDate.ToString('u')) -> $($EndDate.ToString('u')))..."

# ---------------------------------------------------------------------------
# Query the VmAvailabilityMetric for each VM in parallel
# ---------------------------------------------------------------------------
$metricName    = 'VmAvailabilityMetric'
$timeGrainMins = 1   # 1-minute intervals
$throttleLimit = 20  # max concurrent threads

# Capture the current Az context so each parallel runspace can reuse it.
$azContext = Get-AzContext

$perVmResults = $vms | ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
    # Import variables from the caller scope
    $vm             = $_
    $metricName     = $using:metricName
    $startDate      = $using:StartDate
    $endDate        = $using:EndDate
    $timeGrainMins  = $using:timeGrainMins
    $azCtx          = $using:azContext
    $graceMins      = $using:TransitionGraceMinutes

    # Each parallel runspace needs its own Az context
    $null = Set-AzContext -Context $azCtx -ErrorAction Stop

    # -----------------------------------------------------------------
    # 1. Query the Activity Log ONCE for all relevant operations
    # -----------------------------------------------------------------
    Write-Host "  [$($vm.Name)] Querying Activity Log..."

    # The OperationName property on PSEventDataNoDetails objects is a
    # LocalizableString whose .ToString() returns the display name
    # (e.g. "Deallocate Virtual Machine").  The .Value sub-property
    # (resource-provider path) is often empty.  Match both forms.
    $deallocatePatterns = @(
        'Microsoft.Compute/virtualMachines/deallocate/action',
        'Deallocate Virtual Machine'
    )
    $startPatterns = @(
        'Microsoft.Compute/virtualMachines/start/action',
        'Start Virtual Machine'
    )
    $patchPatterns = @(
        'Microsoft.Compute/virtualMachines/installPatches/action',
        'Install OS update patches on virtual machine'
    )
    $deletePatterns = @(
        'Microsoft.Compute/virtualMachines/delete',
        'Delete Virtual Machine'
    )
    $writePatterns = @(
        'Microsoft.Compute/virtualMachines/write',
        'Create or Update Virtual Machine'
    )

    # Single Activity Log call — filter in memory for each category
    $allEvents = Get-AzActivityLog `
        -ResourceId $vm.Id `
        -StartTime  $startDate `
        -EndTime    $endDate `
        -WarningAction SilentlyContinue

    # --- Deallocation / Start events (Succeeded only) ---
    $deallocStartEvents = $allEvents | Where-Object {
        $opDisplay = $_.OperationName.ToString()
        $opValue   = $_.OperationName.Value
        $stDisplay = $_.Status.ToString()
        $stValue   = $_.Status.Value

        $isDealloc = $opDisplay -in $deallocatePatterns -or $opValue -in $deallocatePatterns
        $isStart   = $opDisplay -in $startPatterns      -or $opValue -in $startPatterns
        $isSuccess = $stDisplay -eq 'Succeeded'         -or $stValue -eq 'Succeeded'

        ($isDealloc -or $isStart) -and $isSuccess
    } | Sort-Object EventTimestamp

    # Build deallocation windows: pair each deallocate with the next start.
    # A window = [DeallocateTime, StartTime).  If no start follows, the
    # window extends to $endDate (VM stayed deallocated).
    $deallocWindows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pendingDealloc = $null

    foreach ($evt in $deallocStartEvents) {
        $opDisplay = $evt.OperationName.ToString()
        $opValue   = $evt.OperationName.Value
        $isDealloc = $opDisplay -in $deallocatePatterns -or $opValue -in $deallocatePatterns
        $isStart   = $opDisplay -in $startPatterns      -or $opValue -in $startPatterns

        if ($isDealloc) {
            $caller = $evt.Caller
            $displayName = $null
            try {
                if ($evt.Claims -and $evt.Claims['name']) {
                    $displayName = $evt.Claims['name']
                }
            } catch { }

            $pendingDealloc = [PSCustomObject]@{
                Time        = $evt.EventTimestamp
                Caller      = $caller
                DisplayName = $displayName
            }
        }
        elseif ($isStart -and $null -ne $pendingDealloc) {
            $deallocWindows.Add([PSCustomObject]@{
                From        = $pendingDealloc.Time
                To          = $evt.EventTimestamp
                Caller      = $pendingDealloc.Caller
                DisplayName = $pendingDealloc.DisplayName
            })
            $pendingDealloc = $null
        }
    }
    if ($null -ne $pendingDealloc) {
        $deallocWindows.Add([PSCustomObject]@{
            From        = $pendingDealloc.Time
            To          = $endDate
            Caller      = $pendingDealloc.Caller
            DisplayName = $pendingDealloc.DisplayName
        })
    }

    # Orphan start: if the first dealloc/start event is a Start without a
    # preceding Deallocate, the VM was deallocated before the query period.
    # Synthesise a window [startDate, firstStartTimestamp).
    if ($deallocStartEvents.Count -gt 0) {
        $firstEvt    = $deallocStartEvents[0]
        $firstOpDisp = $firstEvt.OperationName.ToString()
        $firstOpVal  = $firstEvt.OperationName.Value
        $firstIsStart = $firstOpDisp -in $startPatterns -or $firstOpVal -in $startPatterns

        if ($firstIsStart) {
            # No matching deallocate in the period → VM was already deallocated
            $deallocWindows.Insert(0, [PSCustomObject]@{
                From        = $startDate
                To          = $firstEvt.EventTimestamp
                Caller      = '(deallocated before period)'
                DisplayName = $null
            })
        }
    }

    if ($deallocWindows.Count -gt 0) {
        foreach ($w in $deallocWindows) {
            $who = $w.DisplayName ? "$($w.DisplayName) ($($w.Caller))" : $w.Caller
            Write-Host "  [$($vm.Name)]   Deallocation window: $($w.From.ToString('u')) -> $($w.To.ToString('u'))  by $who"
        }
    }

    # --- VM lifecycle events (delete / create-or-update, Succeeded) ---
    $lifecycleEvents = $allEvents | Where-Object {
        $opDisplay = $_.OperationName.ToString()
        $opValue   = $_.OperationName.Value
        $stDisplay = $_.Status.ToString()
        $stValue   = $_.Status.Value

        $isDelete = $opDisplay -in $deletePatterns -or $opValue -in $deletePatterns
        $isWrite  = $opDisplay -in $writePatterns  -or $opValue -in $writePatterns
        $isSuccess = $stDisplay -eq 'Succeeded'    -or $stValue -eq 'Succeeded'

        ($isDelete -or $isWrite) -and $isSuccess
    } | Sort-Object EventTimestamp

    # Build non-existence windows: each delete opens a gap, next write closes it.
    $nonExistWindows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pendingDelete = $null

    foreach ($evt in $lifecycleEvents) {
        $opDisplay = $evt.OperationName.ToString()
        $opValue   = $evt.OperationName.Value
        $isDelete = $opDisplay -in $deletePatterns -or $opValue -in $deletePatterns
        $isWrite  = $opDisplay -in $writePatterns  -or $opValue -in $writePatterns

        if ($isDelete) {
            $pendingDelete = $evt.EventTimestamp
        }
        elseif ($isWrite -and $null -ne $pendingDelete) {
            $nonExistWindows.Add([PSCustomObject]@{
                From = $pendingDelete
                To   = $evt.EventTimestamp
            })
            $pendingDelete = $null
        }
    }
    # If deleted but not recreated within the period (recreated after endDate
    # or not yet), the gap extends to endDate.
    if ($null -ne $pendingDelete) {
        $nonExistWindows.Add([PSCustomObject]@{
            From = $pendingDelete
            To   = $endDate
        })
    }

    # Edge case: VM created for the first time during the period.
    # If TimeCreated falls within [startDate, endDate) and no delete event
    # precedes it (i.e. the VM simply didn't exist before), add a synthetic
    # non-existence window from startDate to TimeCreated.
    $vmCreated = $vm.TimeCreated.ToUniversalTime()
    if ($vmCreated -gt $startDate -and $vmCreated -lt $endDate) {
        $hasDeleteBeforeCreate = $false
        foreach ($evt in $lifecycleEvents) {
            $opD = $evt.OperationName.ToString(); $opV = $evt.OperationName.Value
            if (($opD -in $deletePatterns -or $opV -in $deletePatterns) -and $evt.EventTimestamp -lt $vmCreated) {
                $hasDeleteBeforeCreate = $true
                break
            }
        }
        if (-not $hasDeleteBeforeCreate) {
            # No prior delete → this is the first time the VM was created.
            # Any nulls before TimeCreated are because the VM didn't exist yet.
            $nonExistWindows.Add([PSCustomObject]@{
                From = $startDate
                To   = $vmCreated
            })
        }
    }

    if ($nonExistWindows.Count -gt 0) {
        foreach ($w in $nonExistWindows) {
            Write-Host "  [$($vm.Name)]   Non-existence window: $($w.From.ToString('u')) -> $($w.To.ToString('u'))"
        }
    }

    # --- OS Patching events (Started/Accepted/Succeeded) ---
    $patchEvents = $allEvents | Where-Object {
        $opDisplay = $_.OperationName.ToString()
        $opValue   = $_.OperationName.Value
        $isPatch   = $opDisplay -in $patchPatterns -or $opValue -in $patchPatterns
        if (-not $isPatch) { return $false }

        $stDisplay = $_.Status.ToString()
        $stValue   = $_.Status.Value
        ($stDisplay -in 'Started','Accepted','Succeeded') -or
        ($stValue   -in 'Started','Accepted','Succeeded')
    } | Sort-Object EventTimestamp

    $patchWindows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pendingPatch = $null

    foreach ($evt in $patchEvents) {
        $stDisplay = $evt.Status.ToString()
        $stValue   = $evt.Status.Value
        $isSucceeded = $stDisplay -eq 'Succeeded' -or $stValue -eq 'Succeeded'

        if (-not $isSucceeded) {
            if ($null -eq $pendingPatch) { $pendingPatch = $evt.EventTimestamp }
        }
        elseif ($null -ne $pendingPatch) {
            $patchWindows.Add([PSCustomObject]@{ From = $pendingPatch; To = $evt.EventTimestamp })
            $pendingPatch = $null
        }
    }
    if ($null -ne $pendingPatch) {
        $patchWindows.Add([PSCustomObject]@{ From = $pendingPatch; To = $endDate })
    }

    if ($patchWindows.Count -gt 0) {
        foreach ($w in $patchWindows) {
            Write-Host "  [$($vm.Name)]   Patching window: $($w.From.ToString('u')) -> $($w.To.ToString('u'))"
        }
    }

    # Release memory from the full event set
    $allEvents = $null

    # -----------------------------------------------------------------
    # 2. Pre-compute HashSets for O(1) window membership checks
    # -----------------------------------------------------------------
    $minuteTicks = [TimeSpan]::FromMinutes(1).Ticks

    $setNonExist      = [System.Collections.Generic.HashSet[long]]::new()
    $setDealloc       = [System.Collections.Generic.HashSet[long]]::new()
    $setPatch         = [System.Collections.Generic.HashSet[long]]::new()
    $setNonExistGrace = [System.Collections.Generic.HashSet[long]]::new()
    $setDeallocGrace  = [System.Collections.Generic.HashSet[long]]::new()
    $setPatchGrace    = [System.Collections.Generic.HashSet[long]]::new()

    foreach ($w in $nonExistWindows) {
        $t = $w.From.Ticks - ($w.From.Ticks % $minuteTicks)
        $endTicks = $w.To.Ticks
        while ($t -lt $endTicks)      { $null = $setNonExist.Add($t);      $t += $minuteTicks }
        $graceEndTicks = $w.To.AddMinutes($graceMins).Ticks
        while ($t -lt $graceEndTicks) { $null = $setNonExistGrace.Add($t); $t += $minuteTicks }
    }
    foreach ($w in $deallocWindows) {
        $t = $w.From.Ticks - ($w.From.Ticks % $minuteTicks)
        $endTicks = $w.To.Ticks
        while ($t -lt $endTicks)      { $null = $setDealloc.Add($t);      $t += $minuteTicks }
        $graceEndTicks = $w.To.AddMinutes($graceMins).Ticks
        while ($t -lt $graceEndTicks) { $null = $setDeallocGrace.Add($t); $t += $minuteTicks }
    }
    foreach ($w in $patchWindows) {
        $t = $w.From.Ticks - ($w.From.Ticks % $minuteTicks)
        $endTicks = $w.To.Ticks
        while ($t -lt $endTicks)      { $null = $setPatch.Add($t);      $t += $minuteTicks }
        $graceEndTicks = $w.To.AddMinutes($graceMins).Ticks
        while ($t -lt $graceEndTicks) { $null = $setPatchGrace.Add($t); $t += $minuteTicks }
    }

    # -----------------------------------------------------------------
    # 3. Query the VmAvailabilityMetric
    # -----------------------------------------------------------------
    Write-Host "  [$($vm.Name)] Querying VmAvailabilityMetric..."

    $metric = Get-AzMetric -ResourceId $vm.Id -MetricName $metricName `
        -TimeGrain ([TimeSpan]::FromMinutes($timeGrainMins)) `
        -StartTime $startDate -EndTime $endDate `
        -AggregationType 'Minimum' -WarningAction SilentlyContinue

    # -----------------------------------------------------------------
    # 4. Classify each 1-minute data point
    # -----------------------------------------------------------------
    $availableMinutes       = 0
    $unavailableMinutes     = 0
    $userDeallocatedMinutes = 0
    $patchingMinutes        = 0
    $nonExistentMinutes     = 0
    $unknownNullMinutes     = 0
    $transitionGraceMinutes = 0
    $totalDataPoints        = 0

    foreach ($timeseries in $metric.Timeseries) {
        foreach ($dataPoint in $timeseries.Data) {
            $totalDataPoints++
            $tsTicks = $dataPoint.TimeStamp.Ticks - ($dataPoint.TimeStamp.Ticks % $minuteTicks)

            if ($dataPoint.Minimum -ge 1) {
                # VM was available — always count, even inside grace windows
                $availableMinutes++
                continue
            }

            # null or < 1 — check exclusion windows (priority: non-exist > dealloc > patch > grace > unavailable)
            if     ($setNonExist.Contains($tsTicks)) { $nonExistentMinutes++ }
            elseif ($setDealloc.Contains($tsTicks))  { $userDeallocatedMinutes++ }
            elseif ($setPatch.Contains($tsTicks))    { $patchingMinutes++ }
            elseif ($graceMins -gt 0 -and (
                $setNonExistGrace.Contains($tsTicks) -or
                $setDeallocGrace.Contains($tsTicks) -or
                $setPatchGrace.Contains($tsTicks)
            )) {
                $transitionGraceMinutes++
            }
            elseif ($null -eq $dataPoint.Minimum) {
                $unknownNullMinutes++
            }
            else {
                $unavailableMinutes++
            }
        }
    }

    # Completeness sanity check
    $expectedMinutes = [int](($endDate - $startDate).TotalMinutes)
    if ($totalDataPoints -ne $expectedMinutes) {
        Write-Warning "  [$($vm.Name)] Metric returned $totalDataPoints data points but expected $expectedMinutes. Gap of $($expectedMinutes - $totalDataPoints) minute(s)."
    }

    # Unknown-null minutes count as unavailable
    $totalUnavailable = $unavailableMinutes + $unknownNullMinutes
    $eligibleMinutes  = $availableMinutes + $totalUnavailable
    $availabilityPct  = $eligibleMinutes -gt 0 ? [math]::Round(($availableMinutes / $eligibleMinutes) * 100, 4) : $null

    [PSCustomObject]@{
        VMName                 = $vm.Name
        ResourceGroupName      = $vm.ResourceGroupName
        AvailableMinutes       = $availableMinutes
        UnavailableMinutes     = $unavailableMinutes
        UnknownNullMinutes     = $unknownNullMinutes
        UserDeallocatedMinutes = $userDeallocatedMinutes
        PatchingMinutes        = $patchingMinutes
        NonExistentMinutes     = $nonExistentMinutes
        TransitionGraceMinutes = $transitionGraceMinutes
        EligibleMinutes        = $eligibleMinutes
        AvailabilityPct        = $availabilityPct
        DeallocWindows         = $deallocWindows
        PatchWindows           = $patchWindows
        NonExistWindows        = $nonExistWindows
    }
}

# ---------------------------------------------------------------------------
# Resolve service principal names (once, after parallel processing)
# ---------------------------------------------------------------------------
$spNameCache = @{}
$guidPattern = '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'

foreach ($r in $perVmResults) {
    if (-not $r.DeallocWindows -or $r.DeallocWindows.Count -eq 0) { continue }
    foreach ($w in $r.DeallocWindows) {
        if ($w.Caller -and -not $w.DisplayName -and $w.Caller -match $guidPattern) {
            if ($spNameCache.ContainsKey($w.Caller)) {
                if ($spNameCache[$w.Caller]) { $w.DisplayName = $spNameCache[$w.Caller] }
                continue
            }
            $resolved = $null
            try {
                $sp = Get-AzADServicePrincipal -ObjectId $w.Caller -ErrorAction SilentlyContinue
                if ($sp) { $resolved = $sp.DisplayName }
            } catch { }
            if (-not $resolved) {
                try {
                    $sp = Get-AzADServicePrincipal -ApplicationId $w.Caller -ErrorAction SilentlyContinue
                    if ($sp) { $resolved = $sp.DisplayName }
                } catch { }
            }
            if (-not $resolved) {
                try {
                    $graphResp = Invoke-AzRestMethod -Uri "https://graph.microsoft.com/v1.0/directoryObjects/$($w.Caller)" -Method GET -ErrorAction SilentlyContinue
                    if ($graphResp.StatusCode -eq 200) {
                        $obj = $graphResp.Content | ConvertFrom-Json
                        if ($obj.displayName) { $resolved = $obj.displayName }
                    }
                } catch { }
            }
            $spNameCache[$w.Caller] = $resolved
            if ($resolved) { $w.DisplayName = $resolved }
            else { $w.DisplayName ??= $w.Caller }
        }
    }
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($null -eq $perVmResults -or @($perVmResults).Count -eq 0) {
    Write-Warning 'No availability metric data returned for the specified time range.'
    return
}

# --- Separate fully-deallocated VMs from active ones ---
# A VM is considered fully inactive if:
#   1. EligibleMinutes = 0 (all nulls fell inside known exclusion windows), OR
#   2. No real metric signals at all (AvailableMinutes=0 AND UnavailableMinutes=0)
#      AND no Activity Log evidence of the VM being alive (no dealloc/start events).
#      This covers VMs deallocated BEFORE the query period — no events in the log,
#      all metric data points are null → unknownNullMinutes, but the VM was never
#      actually running.
$activeResults   = [System.Collections.Generic.List[object]]::new()
$excludedResults = [System.Collections.Generic.List[object]]::new()

foreach ($r in $perVmResults) {
    $hasKnownDeallocWindows = $r.DeallocWindows -and $r.DeallocWindows.Count -gt 0
    $noRealMetric           = $r.AvailableMinutes -eq 0 -and $r.UnavailableMinutes -eq 0
    $fullyExcludedByWindows = $r.EligibleMinutes -eq 0

    if ($fullyExcludedByWindows) {
        # All time covered by deallocation/patching/non-existence windows
        $excludedResults.Add($r)
    }
    elseif ($noRealMetric -and -not $hasKnownDeallocWindows) {
        # No metric=0 or metric=1 ever emitted, and no activity log events →
        # VM was deallocated before the period started
        $excludedResults.Add($r)
    }
    else {
        $activeResults.Add($r)
    }
}

if ($excludedResults.Count -gt 0) {
    Write-Host ''
    Write-Host "=== Excluded VMs (inactive for entire period) ==="
    foreach ($x in $excludedResults) {
        $totalExcl = $x.UserDeallocatedMinutes + $x.PatchingMinutes + $x.NonExistentMinutes
        Write-Host "    $($x.VMName) ($($x.ResourceGroupName))  — $totalExcl min excluded"
    }
}

# --- Overall summary (active VMs only) ---
Write-Host ''
if ($activeResults.Count -eq 0) {
    Write-Warning 'All VMs were deallocated for the entire period — no eligible minutes to compute availability.'
}
else {
    # Sum once via foreach — faster than 8 Measure-Object pipelines
    $totalAvailable = $totalUnavailable = $totalUnknownNull = 0
    $totalDealloc = $totalPatching = $totalNonExistent = $totalGrace = $totalEligible = 0
    foreach ($r in $activeResults) {
        $totalAvailable   += $r.AvailableMinutes
        $totalUnavailable += $r.UnavailableMinutes
        $totalUnknownNull += $r.UnknownNullMinutes
        $totalDealloc     += $r.UserDeallocatedMinutes
        $totalPatching    += $r.PatchingMinutes
        $totalNonExistent += $r.NonExistentMinutes
        $totalGrace       += $r.TransitionGraceMinutes
        $totalEligible    += $r.EligibleMinutes
    }
    $totalMinutes = $totalAvailable + $totalUnavailable + $totalUnknownNull + $totalDealloc + $totalPatching + $totalNonExistent + $totalGrace

    $overallPct = [math]::Round(($totalAvailable / $totalEligible) * 100, 4)
    Write-Host "=== Overall Availability ==="
    Write-Host "    VMs assessed (active)            : $($activeResults.Count) of $($perVmResults.Count) total"
    Write-Host "    Total minutes in period           : $totalMinutes min"
    Write-Host "  - User-deallocated                  : $totalDealloc min"
    Write-Host "  - OS patching (planned maintenance) : $totalPatching min"
    Write-Host "  - VM did not exist                  : $totalNonExistent min"
    Write-Host "  - Transition grace ($TransitionGraceMinutes min tolerance)  : $totalGrace min"
    Write-Host "  = Eligible minutes (denominator)    : $totalEligible min"
    Write-Host "    Of which:"
    Write-Host "      Available (numerator)           : $totalAvailable min"
    Write-Host "      Unavailable (metric = 0)        : $totalUnavailable min"
    Write-Host "      Unavailable (no metric emitted) : $totalUnknownNull min"
    Write-Host ''
    Write-Host '  >>> Availability: ' -NoNewline
    $color = $overallPct -ge 99.99 ? 'Green' : ($overallPct -ge 99.9 ? 'Yellow' : 'Red')
    Write-Host "$overallPct%" -ForegroundColor $color -NoNewline
    Write-Host ' <<<'
}

# --- Per-VM detail ---
# (printed via pipeline objects below)

# ---------------------------------------------------------------------------
# Return structured objects for pipeline consumers
# ---------------------------------------------------------------------------
# Emit excluded VMs first, then active — single unified loop
$isExcludedSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]($excludedResults | ForEach-Object { $_.VMName + '|' + $_.ResourceGroupName }),
    [StringComparer]::OrdinalIgnoreCase
)

foreach ($r in @($excludedResults) + @($activeResults)) {
    $excluded = $isExcludedSet.Contains($r.VMName + '|' + $r.ResourceGroupName)

    $windowDetails = $excluded ? @() : @(
        $r.DeallocWindows | ForEach-Object {
            [PSCustomObject]@{
                From = $_.From
                To   = $_.To
                By   = $_.DisplayName ? "$($_.DisplayName) ($($_.Caller))" : $_.Caller
            }
        }
    )
    $patchDetails    = $excluded ? @() : @($r.PatchWindows    | ForEach-Object { [PSCustomObject]@{ From = $_.From; To = $_.To } })
    $nonExistDetails = $excluded ? @() : @($r.NonExistWindows | ForEach-Object { [PSCustomObject]@{ From = $_.From; To = $_.To } })

    [PSCustomObject]@{
        VMName                 = $r.VMName
        ResourceGroupName      = $r.ResourceGroupName
        Status                 = $excluded ? 'Excluded (inactive entire period)' : 'Active'
        AvailableMinutes       = $r.AvailableMinutes
        UnavailableMinutes     = $r.UnavailableMinutes
        UnknownNullMinutes     = $r.UnknownNullMinutes
        UserDeallocatedMinutes = $r.UserDeallocatedMinutes
        PatchingMinutes        = $r.PatchingMinutes
        NonExistentMinutes     = $r.NonExistentMinutes
        TransitionGraceMinutes = $r.TransitionGraceMinutes
        EligibleMinutes        = $r.EligibleMinutes
        AvailabilityPct        = $excluded ? $null : $r.AvailabilityPct
        DeallocWindows         = $windowDetails
        PatchWindows           = $patchDetails
        NonExistWindows        = $nonExistDetails
    }
}
