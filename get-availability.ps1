#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.Monitor

<#
.SYNOPSIS
    Calculates VM availability percentage using the VmAvailabilityMetric.

.DESCRIPTION
    Queries the VmAvailabilityMetric from Azure Monitor at 1-minute granularity
    and computes the actual availability percentage for each VM and an overall
    figure across all targeted VMs.

    Metrics are fetched via the Azure Monitor batch REST API
    (metrics.monitor.azure.com) which retrieves data for all VMs in a single
    call per region, split by the Context dimension.  The Context dimension
    classifies each metric data point as:
      Platform  — Azure-initiated unavailability (counts against SLA).
      Customer  — user/guest-initiated action, e.g. in-guest shutdown
                  (excluded from the SLA denominator).
      Unknown   — ambiguous; currently covers Service Healing and Live
                  Migration (counted against SLA conservatively).
    If the batch API is unavailable, the script falls back to per-resource
    ARM metric queries via Invoke-AzRestMethod.

    The metric emits:
      1   — the VM was available during that minute.
      0   — the VM was unavailable (Context tells why).
      null — no metric was emitted (VM not running).

    A null value alone does NOT prove user-initiated deallocation. The script
    therefore queries the Activity Log for each VM to find
    deallocate / start pairs initiated by a known principal (user or service
    principal). Deallocation windows begin at the earliest event (Started or
    Accepted) to cover the shutdown transition period when the metric drops
    from 1 to 0 before reaching null.  Only the time windows covered by those
    legitimate deallocation pairs are excluded from the availability calculation.

    Similarly, OS patching windows (planned maintenance) are detected from
    the Activity Log ("Install OS update patches" operations). Null metrics
    during patching windows are excluded from the denominator since they
    represent expected, planned maintenance rather than unforeseen outages.

    VMs that were deallocated for the entire period are excluded from the
    overall calculation and reported separately. This includes VMs whose
    deallocation windows cover the full range.

    VMs that never reported the metric at all during the observation period
    (no metric = 1 and no metric = 0) are also excluded as anomalies,
    regardless of their power state. These may be VMs that were deallocated
    before the period started, or running VMs with metric collection issues.
    Either way they provide no usable data for availability calculation.

    VM lifecycle (create / delete / recreate cycles) is also tracked from
    the Activity Log.  Minutes when the VM did not exist are excluded from
    the denominator.  The VM's TimeCreated property is used as a fallback
    to detect first-time creation within the observation period.

    Each VM's Azure region, availability zone(s), and placement type
    (Zonal or Regional) are included in the output.

    Service principal callers are resolved to display names via the
    Microsoft Graph API (batch getByIds + appId lookup) for clearer
    reporting.

    State transitions (start after deallocation, reboot after patching, first
    boot after creation) often produce 1-2 minutes of null or zero metric while
    the VM is booting and the Guest Agent reconnects.  A configurable grace
    period (TransitionGraceMinutes, default 2) extends each exclusion window's
    trailing edge so those transition minutes are not penalised as unavailable.
    Data points where the metric is already 1 (available) are never suppressed
    by the grace period.

    Null data points that fall outside any known user-initiated deallocation
    or patching window (including the grace period) are treated as unavailable
    (potential platform issue).  Metric = 0 data points outside any window
    are classified by their Context dimension: Platform and Unknown count
    as unavailable; Customer-initiated minutes are excluded from the
    denominator (like user-deallocation).

    For VMs with detected unavailability (UnavailableMinutes > 0 or
    UnknownNullMinutes > 0), Azure Resource Health is queried via the
    Microsoft.ResourceHealth/availabilityStatuses API.  Resource Health
    tracks platform-level VM status transitions (Available → Unavailable →
    Available) with root cause analysis, including Service Healing, Live
    Migration, and host failures.  Health event windows with
    healthEventCause = PlatformInitiated independently confirm that the
    metric-based unavailability was caused by an Azure platform issue,
    strengthening SLA evidence.  The PlatformEventConfirmed flag is set
    on any VM where Resource Health reports at least one such event.

    When null metric minutes fall within a Resource Health event window,
    they are reclassified from UnknownNullMinutes into the appropriate
    cause-based column: PlatformInitiated → PlatformUnavailableMinutes,
    other causes → UnknownContextMinutes.  The HealthAttributedNullMinutes
    counter tracks how many null minutes were reclassified.  Availability %
    is unchanged by this reclassification (both columns count as
    unavailable); only the attribution improves.

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
        Write-Host "Getting all VMs in subscription '$((Get-AzContext).Subscription.Name)'..."
        Get-AzVM
    }
}

if ($vms.Count -eq 0) {
    Write-Warning 'No virtual machines found for the specified scope.'
    return
}

Write-Host "Found $($vms.Count) VM(s). Querying VmAvailabilityMetric ($($StartDate.ToString('u')) -> $($EndDate.ToString('u')))..."

# ---------------------------------------------------------------------------
# Query Activity Log for each VM in parallel
# ---------------------------------------------------------------------------
$throttleLimit = 20  # max concurrent threads

# Operation name patterns for Activity Log filtering (defined once, shared
# across all parallel runspaces via $using: to avoid re-allocating per VM).
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

# Capture the current Az context so each parallel runspace can reuse it.
$azContext = Get-AzContext

# Thread-safe progress counter for Activity Log queries
$activityLogProgress = [System.Collections.Concurrent.ConcurrentDictionary[string,byte]]::new()
$activityLogTotal    = $vms.Count

$activityLogData = $vms | ForEach-Object -ThrottleLimit $throttleLimit -Parallel {
    # Import variables from the caller scope
    $vm                 = $_
    $startDate          = $using:StartDate
    $endDate            = $using:EndDate
    $azCtx              = $using:azContext
    $deallocatePatterns = $using:deallocatePatterns
    $startPatterns      = $using:startPatterns
    $patchPatterns      = $using:patchPatterns
    $deletePatterns     = $using:deletePatterns
    $writePatterns      = $using:writePatterns
    $progressDict       = $using:activityLogProgress
    $totalVMs           = $using:activityLogTotal

    # Each parallel runspace needs its own Az context
    $null = Set-AzContext -Context $azCtx -ErrorAction Stop

    # -----------------------------------------------------------------
    # 1. Query the Activity Log ONCE for all relevant operations
    # -----------------------------------------------------------------
    $null = $progressDict.TryAdd($vm.Name, 0)
    $done = $progressDict.Count
    Write-Progress -Activity 'Querying Activity Log' -Status "$done / $totalVMs VMs ($($vm.Name))" `
        -PercentComplete ([math]::Min(100, [int]($done / $totalVMs * 100)))

    # Single Activity Log call — categorise events in a single pass
    $allEvents = Get-AzActivityLog `
        -ResourceId $vm.Id `
        -StartTime  $startDate `
        -EndTime    $endDate `
        -WarningAction SilentlyContinue

    # Bucket events by category in one scan (avoids 3 × Where-Object passes)
    $deallocStartEvents = [System.Collections.Generic.List[object]]::new()
    $lifecycleEvents    = [System.Collections.Generic.List[object]]::new()
    $patchEvents        = [System.Collections.Generic.List[object]]::new()

    foreach ($evt in $allEvents) {
        $opDisplay = $evt.OperationName.ToString()
        $opValue   = $evt.OperationName.Value
        $stDisplay = $evt.Status.ToString()
        $stValue   = $evt.Status.Value

        $isDealloc = $opDisplay -in $deallocatePatterns -or $opValue -in $deallocatePatterns
        $isStart   = $opDisplay -in $startPatterns      -or $opValue -in $startPatterns
        $isDelete  = $opDisplay -in $deletePatterns     -or $opValue -in $deletePatterns
        $isWrite   = $opDisplay -in $writePatterns      -or $opValue -in $writePatterns
        $isPatch   = $opDisplay -in $patchPatterns      -or $opValue -in $patchPatterns
        $isSuccess = $stDisplay -eq 'Succeeded'         -or $stValue -eq 'Succeeded'

        # Deallocate: accept Started/Accepted (earliest signal the shutdown began)
        # as well as Succeeded.  Start VM: only Succeeded (VM fully available).
        $isDeallocRelevant = $isDealloc -and (
            $isSuccess -or
            $stDisplay -in 'Started','Accepted' -or
            $stValue   -in 'Started','Accepted'
        )
        $isStartRelevant = $isStart -and $isSuccess

        if ($isDeallocRelevant -or $isStartRelevant) {
            $deallocStartEvents.Add($evt)
        }
        if (($isDelete -or $isWrite) -and $isSuccess) {
            $lifecycleEvents.Add($evt)
        }
        if ($isPatch -and (
            ($stDisplay -in 'Started','Accepted','Succeeded') -or
            ($stValue   -in 'Started','Accepted','Succeeded')
        )) {
            $patchEvents.Add($evt)
        }
    }

    # Sort each bucket by timestamp
    $deallocStartEvents = @($deallocStartEvents | Sort-Object EventTimestamp)
    $lifecycleEvents    = @($lifecycleEvents    | Sort-Object EventTimestamp)
    $patchEvents        = @($patchEvents        | Sort-Object EventTimestamp)

    # Release raw event set
    $allEvents = $null

    # Build deallocation windows: pair each deallocate with the next start.
    # A window = [DeallocateStarted, StartSucceeded).  Using the earliest
    # deallocate event (Started/Accepted) ensures the shutdown transition
    # (metric goes 1 → 0 → null) is covered by the window.  If no start
    # follows, the window extends to $endDate (VM stayed deallocated).
    $deallocWindows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pendingDealloc = $null

    foreach ($evt in $deallocStartEvents) {
        $opDisplay = $evt.OperationName.ToString()
        $opValue   = $evt.OperationName.Value
        $isDealloc = $opDisplay -in $deallocatePatterns -or $opValue -in $deallocatePatterns
        $isStart   = $opDisplay -in $startPatterns      -or $opValue -in $startPatterns

        if ($isDealloc) {
            # Only record the FIRST dealloc event per sequence (Started)
            # so subsequent Accepted/Succeeded don't overwrite the earlier
            # timestamp.  This captures the moment the shutdown began.
            if ($null -eq $pendingDealloc) {
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

    # --- Build non-existence windows: each delete opens a gap, next write closes it ---
    $nonExistWindows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $pendingDelete = $null

    foreach ($evt in $lifecycleEvents) {
        $opDisplay = $evt.OperationName.ToString()
        $opValue   = $evt.OperationName.Value
        $isDelete = $opDisplay -in $deletePatterns -or $opValue -in $deletePatterns

        if ($isDelete) {
            $pendingDelete = $evt.EventTimestamp
        }
        elseif ($null -ne $pendingDelete) {
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

    # --- Build patching windows ---
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

    # -----------------------------------------------------------------
    # 2. Return Activity Log data for post-parallel metric fetch
    # -----------------------------------------------------------------
    $vmLocation  = $vm.Location
    $vmZones     = if ($vm.Zones -and $vm.Zones.Count -gt 0) { $vm.Zones -join ',' } else { $null }
    $vmPlacement = if ($vmZones) { "Zonal ($vmZones)" } else { 'Regional' }

    [PSCustomObject]@{
        VMName            = $vm.Name
        ResourceGroupName = $vm.ResourceGroupName
        VMId              = $vm.Id
        Location          = $vmLocation
        Zones             = $vmZones
        Placement         = $vmPlacement
        DeallocWindows    = $deallocWindows
        PatchWindows      = $patchWindows
        NonExistWindows   = $nonExistWindows
    }
}
Write-Progress -Activity 'Querying Activity Log' -Completed

# ---------------------------------------------------------------------------
# Batch-fetch VmAvailabilityMetric via Azure Monitor REST API (Context split)
# ---------------------------------------------------------------------------
# The batch data-plane API (metrics.monitor.azure.com) fetches metrics for
# multiple VMs in a single call, split by the Context dimension:
#   Platform  — Azure-initiated unavailability (counts against SLA)
#   Customer  — user/guest-initiated, e.g. in-guest shutdown (excluded)
#   Unknown   — ambiguous: Service Healing, Live Migration (counts against SLA)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Fetching VmAvailabilityMetric via batch REST API (split by Context)...'

$subscriptionId = $azContext.Subscription.Id
$minuteTicks    = [TimeSpan]::FromMinutes(1).Ticks
$startTimeStr   = $StartDate.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
$endTimeStr     = $EndDate.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

# Acquire a token scoped to the metrics data-plane audience
$metricsToken = $null
try {
    $tokenValue = (Get-AzAccessToken -ResourceUrl 'https://metrics.monitor.azure.com').Token
    $metricsToken = if ($tokenValue -is [securestring]) {
        $tokenValue | ConvertFrom-SecureString -AsPlainText
    } else { $tokenValue }
} catch {
    Write-Warning "Could not acquire metrics data-plane token: $_. Falling back to per-resource ARM API."
}

# Group VMs by region (the batch endpoint is regional)
$vmsByRegion = @{}
foreach ($r in $activityLogData) {
    $region = $r.Location
    if (-not $vmsByRegion.ContainsKey($region)) {
        $vmsByRegion[$region] = [System.Collections.Generic.List[object]]::new()
    }
    $vmsByRegion[$region].Add($r)
}

# Per-VM metric data: vmIdLower → hashtable of ticks → PSCustomObject{ Minimum; Context }
$metricDataByVmId = @{}

# --- Helper: parse metric timeseries JSON into per-minute lookup ---
function ParseMetricTimeseries ([object[]]$timeseries) {
    $data = @{}
    foreach ($ts in $timeseries) {
        $context = 'Unknown'
        if ($ts.metadatavalues) {
            foreach ($mv in $ts.metadatavalues) {
                if ($mv.name.value -in 'Context','context') { $context = $mv.value }
            }
        }
        foreach ($dp in $ts.data) {
            # Handle both pre-deserialised DateTime (Invoke-RestMethod) and strings
            $dpTime  = if ($dp.timeStamp -is [datetime]) { $dp.timeStamp.ToUniversalTime() } `
                       else { [datetime]::Parse($dp.timeStamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
            $tsTicks = $dpTime.Ticks - ($dpTime.Ticks % $minuteTicks)
            # StrictMode-safe: check property exists before accessing
            $minProp = $dp.PSObject.Properties['minimum']
            if ($minProp -and $null -ne $minProp.Value) {
                $data[$tsTicks] = [PSCustomObject]@{
                    Minimum = [double]$minProp.Value
                    Context = $context
                }
            }
        }
    }
    $data
}

# --- Primary path: batch data-plane API ---
if ($metricsToken) {
    $metricsHeaders = @{
        Authorization  = "Bearer $metricsToken"
        'Content-Type' = 'application/json'
    }

    foreach ($region in $vmsByRegion.Keys) {
        $regionVms   = $vmsByRegion[$region]
        $resourceIds = @($regionVms | ForEach-Object { $_.VMId })

        # Batch up to 50 resource IDs per call
        for ($i = 0; $i -lt $resourceIds.Count; $i += 50) {
            $endIdx   = [Math]::Min($i + 49, $resourceIds.Count - 1)
            $batchIds = @($resourceIds[$i..$endIdx])
            $body     = @{ resourceids = $batchIds } | ConvertTo-Json -Compress

            $batchUri = "https://$region.metrics.monitor.azure.com" +
                        "/subscriptions/$subscriptionId/metrics:getBatch" +
                        "?metricnamespace=Microsoft.Compute/virtualMachines" +
                        "&metricnames=VmAvailabilityMetric" +
                        "&aggregation=minimum" +
                        "&interval=PT1M" +
                        "&starttime=$startTimeStr" +
                        "&endtime=$endTimeStr" +
                        "&filter=Context eq '*'" +
                        "&api-version=2024-02-01"

            try {
                $resp = Invoke-RestMethod -Uri $batchUri -Method POST `
                    -Body $body -Headers $metricsHeaders `
                    -ContentType 'application/json'

                foreach ($entry in $resp.values) {
                    $vmId = $entry.resourceid.ToLower()
                    foreach ($metricDef in $entry.value) {
                        $metricDataByVmId[$vmId] = ParseMetricTimeseries $metricDef.timeseries
                    }
                }
                Write-Verbose "  Batch OK for region $region ($($batchIds.Count) VMs)"
            }
            catch {
                Write-Warning "  Batch metric fetch failed for region $region (offset $i): $_"
            }
        }
    }
}

# --- Fallback: per-resource ARM API for any VMs not covered by batch ---
foreach ($vmData in $activityLogData) {
    $vmIdLower = $vmData.VMId.ToLower()
    if ($metricDataByVmId.ContainsKey($vmIdLower)) { continue }

    Write-Verbose "  [$($vmData.VMName)] Falling back to per-resource ARM metric API..."
    $armUri = "https://management.azure.com$($vmData.VMId)/providers/Microsoft.Insights/metrics" +
              "?api-version=2024-02-01" +
              "&metricnames=VmAvailabilityMetric" +
              "&timespan=$startTimeStr/$endTimeStr" +
              "&interval=PT1M" +
              "&aggregation=minimum" +
              "&`$filter=Context eq '*'"

    try {
        $armResp = Invoke-AzRestMethod -Uri $armUri -Method GET -ErrorAction Stop
        if ($armResp.StatusCode -eq 200) {
            $parsed = $armResp.Content | ConvertFrom-Json
            foreach ($metricDef in $parsed.value) {
                $metricDataByVmId[$vmIdLower] = ParseMetricTimeseries $metricDef.timeseries
            }
        } else {
            Write-Warning "  [$($vmData.VMName)] ARM metric query returned HTTP $($armResp.StatusCode)"
        }
    }
    catch {
        Write-Warning "  [$($vmData.VMName)] ARM metric query failed: $_"
    }
}

# ---------------------------------------------------------------------------
# Classify each 1-minute data point per VM (using Context dimension)
# ---------------------------------------------------------------------------
Write-Host 'Classifying metric data...'

$expectedMinutes = [int](($EndDate - $StartDate).TotalMinutes)
$periodStartTick = $StartDate.Ticks - ($StartDate.Ticks % $minuteTicks)

$perVmResults = foreach ($vmData in $activityLogData) {
    $vmIdLower    = $vmData.VMId.ToLower()
    $vmMinuteData = if ($metricDataByVmId.ContainsKey($vmIdLower)) {
                        $metricDataByVmId[$vmIdLower]
                    } else { @{} }

    # Rebuild HashSets from windows (avoids cross-runspace serialisation issues)
    $setNonExist      = [System.Collections.Generic.HashSet[long]]::new()
    $setDealloc       = [System.Collections.Generic.HashSet[long]]::new()
    $setPatch         = [System.Collections.Generic.HashSet[long]]::new()
    $setNonExistGrace = [System.Collections.Generic.HashSet[long]]::new()
    $setDeallocGrace  = [System.Collections.Generic.HashSet[long]]::new()
    $setPatchGrace    = [System.Collections.Generic.HashSet[long]]::new()

    foreach ($w in $vmData.NonExistWindows) {
        $t = $w.From.Ticks - ($w.From.Ticks % $minuteTicks)
        $wEnd = $w.To.Ticks
        while ($t -lt $wEnd)          { $null = $setNonExist.Add($t);      $t += $minuteTicks }
        $gEnd = $w.To.AddMinutes($TransitionGraceMinutes).Ticks
        while ($t -lt $gEnd)          { $null = $setNonExistGrace.Add($t); $t += $minuteTicks }
    }
    foreach ($w in $vmData.DeallocWindows) {
        $t = $w.From.Ticks - ($w.From.Ticks % $minuteTicks)
        $wEnd = $w.To.Ticks
        while ($t -lt $wEnd)          { $null = $setDealloc.Add($t);      $t += $minuteTicks }
        $gEnd = $w.To.AddMinutes($TransitionGraceMinutes).Ticks
        while ($t -lt $gEnd)          { $null = $setDeallocGrace.Add($t); $t += $minuteTicks }
    }
    foreach ($w in $vmData.PatchWindows) {
        $t = $w.From.Ticks - ($w.From.Ticks % $minuteTicks)
        $wEnd = $w.To.Ticks
        while ($t -lt $wEnd)          { $null = $setPatch.Add($t);      $t += $minuteTicks }
        $gEnd = $w.To.AddMinutes($TransitionGraceMinutes).Ticks
        while ($t -lt $gEnd)          { $null = $setPatchGrace.Add($t); $t += $minuteTicks }
    }

    # --- Classify each minute in the period ---
    $availableMinutes           = 0
    $platformUnavailableMinutes = 0
    $customerInitiatedMinutes   = 0
    $unknownContextMinutes      = 0
    $userDeallocatedMinutes     = 0
    $patchingMinutes            = 0
    $nonExistentMinutes         = 0
    $unknownNullMinutes         = 0
    $graceExcludedMinutes       = 0
    $unknownNullTicks           = [System.Collections.Generic.List[long]]::new()

    $t = $periodStartTick
    for ($m = 0; $m -lt $expectedMinutes; $m++) {
        $dp = $null
        if ($vmMinuteData.Count -gt 0) { $dp = $vmMinuteData[$t] }

        if ($dp -and $dp.Minimum -ge 1) {
            # VM was available — always count, even inside grace windows
            $availableMinutes++
        }
        elseif ($setNonExist.Contains($t))  { $nonExistentMinutes++ }
        elseif ($setDealloc.Contains($t))   { $userDeallocatedMinutes++ }
        elseif ($setPatch.Contains($t))     { $patchingMinutes++ }
        elseif ($TransitionGraceMinutes -gt 0 -and (
            $setNonExistGrace.Contains($t) -or
            $setDeallocGrace.Contains($t)  -or
            $setPatchGrace.Contains($t)
        )) {
            $graceExcludedMinutes++
        }
        elseif ($dp) {
            # metric = 0 (or < 1), outside any exclusion window — classify by Context
            switch ($dp.Context) {
                'Customer' { $customerInitiatedMinutes++ }
                'Platform' { $platformUnavailableMinutes++ }
                default    { $unknownContextMinutes++ }
            }
        }
        else {
            # No data point — null metric, outside any known window
            $unknownNullMinutes++
            $unknownNullTicks.Add($t)
        }

        $t += $minuteTicks
    }

    $unavailableMinutes = $platformUnavailableMinutes + $unknownContextMinutes
    $totalUnavail       = $unavailableMinutes + $unknownNullMinutes
    $eligibleMinutes    = $availableMinutes + $totalUnavail
    $availabilityPct    = $eligibleMinutes -gt 0 ? [math]::Round(($availableMinutes / $eligibleMinutes) * 100, 4) : $null

    [PSCustomObject]@{
        VMName                      = $vmData.VMName
        ResourceGroupName           = $vmData.ResourceGroupName
        Location                    = $vmData.Location
        Zones                       = $vmData.Zones
        Placement                   = $vmData.Placement
        AvailableMinutes            = $availableMinutes
        UnavailableMinutes          = $unavailableMinutes
        PlatformUnavailableMinutes  = $platformUnavailableMinutes
        CustomerInitiatedMinutes    = $customerInitiatedMinutes
        UnknownContextMinutes       = $unknownContextMinutes
        UnknownNullMinutes          = $unknownNullMinutes
        UserDeallocatedMinutes      = $userDeallocatedMinutes
        PatchingMinutes             = $patchingMinutes
        NonExistentMinutes          = $nonExistentMinutes
        TransitionGraceMinutes      = $graceExcludedMinutes
        EligibleMinutes             = $eligibleMinutes
        AvailabilityPct             = $availabilityPct
        DeallocWindows              = $vmData.DeallocWindows
        PatchWindows                = $vmData.PatchWindows
        NonExistWindows             = $vmData.NonExistWindows
        HealthEventWindows          = @()
        PlatformEventConfirmed      = $false
        HealthAttributedNullMinutes = 0
        _UnknownNullTicks           = $unknownNullTicks
    }
}

# ---------------------------------------------------------------------------
# Query Resource Health for VMs with detected unavailability
# ---------------------------------------------------------------------------
# The Resource Health API (Microsoft.ResourceHealth/availabilityStatuses)
# provides Azure's own assessment of VM health transitions:
#   Unavailable / Degraded  — Azure detected a problem.
#   healthEventCause        — PlatformInitiated, UserInitiated, or Unknown.
#   rootCauseAttributionTime — actual failure start (often earlier than
#                              the occuredTime on the status entry).
# This data independently confirms whether metric-based unavailability
# was caused by a platform event, strengthening the SLA evidence.
# ---------------------------------------------------------------------------
$vmIdByKey = @{}
foreach ($d in $activityLogData) {
    $vmIdByKey["$($d.VMName)|$($d.ResourceGroupName)"] = $d.VMId
}

$vmsWithIssues = @($perVmResults | Where-Object { $_.UnavailableMinutes -gt 0 -or $_.UnknownNullMinutes -gt 0 })
if ($vmsWithIssues.Count -gt 0) {
    Write-Host ''
    Write-Host "Querying Resource Health for $($vmsWithIssues.Count) VM(s) with unavailable minutes..."

    foreach ($r in $vmsWithIssues) {
        $vmId = $vmIdByKey["$($r.VMName)|$($r.ResourceGroupName)"]
        if (-not $vmId) { continue }

        Write-Verbose "  [$($r.VMName)] Querying Resource Health..."
        $rhUri = "https://management.azure.com${vmId}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2024-02-01"

        try {
            $rhResp = Invoke-AzRestMethod -Uri $rhUri -Method GET -ErrorAction Stop
            if ($rhResp.StatusCode -ne 200) {
                Write-Verbose "  [$($r.VMName)] Resource Health returned HTTP $($rhResp.StatusCode)"
                continue
            }

            $rhData = ($rhResp.Content | ConvertFrom-Json).value
            # Parse all status entries into typed objects (StrictMode-safe property access)
            $allHealthEvents = foreach ($v in $rhData) {
                $p = $v.properties
                $evtTime = if ($p.occuredTime -is [datetime]) { $p.occuredTime.ToUniversalTime() } `
                           else { [datetime]::Parse($p.occuredTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }

                # Optional properties — not all entries have these
                $rcaProp  = $p.PSObject.Properties['rootCauseAttributionTime']
                $rcaTime  = $null
                if ($rcaProp -and $rcaProp.Value) {
                    $rcaTime = try {
                        if ($rcaProp.Value -is [datetime]) { $rcaProp.Value.ToUniversalTime() }
                        else { [datetime]::Parse($rcaProp.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
                    } catch { $null }
                }

                $heProp    = $p.PSObject.Properties['healthEventType']
                $hcProp    = $p.PSObject.Properties['healthEventCause']
                $rtProp    = $p.PSObject.Properties['reasonType']
                $avProp    = $p.PSObject.Properties['availabilityState']
                $sumProp   = $p.PSObject.Properties['summary']

                [PSCustomObject]@{
                    OccurredTime      = $evtTime
                    AvailabilityState = if ($avProp) { $avProp.Value } else { $null }
                    ReasonType        = if ($rtProp) { $rtProp.Value } else { $null }
                    Title             = $p.title
                    Summary           = if ($sumProp -and $sumProp.Value) { ($sumProp.Value -replace '<[^>]+>','').Trim() } else { $null }
                    RootCauseTime     = $rcaTime
                    HealthEventType   = if ($heProp) { $heProp.Value } else { $null }
                    HealthEventCause  = if ($hcProp) { $hcProp.Value } else { $null }
                }
            }

            # Filter to events within the query period (or whose RCA rootCause falls in it)
            $sorted = @($allHealthEvents | Sort-Object OccurredTime)
            $periodEvents = @($sorted | Where-Object {
                ($_.OccurredTime -ge $StartDate -and $_.OccurredTime -le $EndDate) -or
                ($_.RootCauseTime -and $_.RootCauseTime -ge $StartDate -and $_.RootCauseTime -le $EndDate)
            })

            if ($periodEvents.Count -eq 0) { continue }

            # Build health event windows: non-Available → Available transitions
            $healthWindows = [System.Collections.Generic.List[PSCustomObject]]::new()
            $idx = 0
            while ($idx -lt $periodEvents.Count) {
                $evt = $periodEvents[$idx]
                # Skip plain Available entries (they close windows)
                if ($evt.AvailabilityState -eq 'Available' -and -not $evt.HealthEventType) {
                    $idx++; continue
                }

                # Start of a health event window
                $windowStart = $evt.OccurredTime
                $title       = $evt.Title
                $cause       = $evt.HealthEventCause
                $rcaStart    = $evt.RootCauseTime
                $rcaSummary  = if ($evt.HealthEventType -eq 'Rca') { $evt.Summary } else { $null }

                # Scan forward for more context and the closing Available
                $windowEnd = $null
                $j = $idx + 1
                while ($j -lt $periodEvents.Count) {
                    $next = $periodEvents[$j]
                    if ($next.HealthEventCause -and -not $cause) { $cause = $next.HealthEventCause }
                    if ($next.Title -and $next.Title -ne 'Available') { $title = $next.Title }
                    if ($next.RootCauseTime -and (-not $rcaStart -or $next.RootCauseTime -lt $rcaStart)) { $rcaStart = $next.RootCauseTime }
                    if ($next.HealthEventType -eq 'Rca' -and $next.Summary) { $rcaSummary = $next.Summary }

                    if ($next.AvailabilityState -eq 'Available' -and -not $next.HealthEventType) {
                        $windowEnd = $next.OccurredTime
                        $idx = $j + 1
                        break
                    }
                    $j++
                }
                if ($null -eq $windowEnd) { $windowEnd = $EndDate; $idx = $periodEvents.Count }

                # Use RCA rootCauseTime as actual start if earlier
                $actualStart = if ($rcaStart -and $rcaStart -lt $windowStart) { $rcaStart } else { $windowStart }

                $healthWindows.Add([PSCustomObject]@{
                    From            = $actualStart
                    To              = $windowEnd
                    Title           = $title
                    Cause           = if ($cause) { $cause } else { 'Unknown' }
                    RootCauseSummary = $rcaSummary
                })
            }

            if ($healthWindows.Count -gt 0) {
                $r.HealthEventWindows     = @($healthWindows)
                $r.PlatformEventConfirmed = [bool]($healthWindows | Where-Object {
                    $_.Cause -eq 'PlatformInitiated'
                })

                # --- Reclassify unknown null minutes that fall within health event windows ---
                # Null minutes previously counted as UnknownNullMinutes are moved to the
                # appropriate cause-based column when Resource Health provides the cause:
                #   PlatformInitiated → PlatformUnavailableMinutes
                #   Other causes      → UnknownContextMinutes
                # Availability % is unchanged (both columns count as unavailable).
                if ($r._UnknownNullTicks -and $r._UnknownNullTicks.Count -gt 0) {
                    # Build tick → cause lookup from health windows
                    $healthTickCause = @{}
                    foreach ($hw in $healthWindows) {
                        $ht = $hw.From.Ticks - ($hw.From.Ticks % $minuteTicks)
                        $hwEnd = $hw.To.Ticks
                        while ($ht -lt $hwEnd) {
                            if (-not $healthTickCause.ContainsKey($ht)) {
                                $healthTickCause[$ht] = $hw.Cause
                            }
                            $ht += $minuteTicks
                        }
                    }

                    $reclassifiedPlatform = 0
                    $reclassifiedOther    = 0
                    foreach ($tick in $r._UnknownNullTicks) {
                        if ($healthTickCause.ContainsKey($tick)) {
                            if ($healthTickCause[$tick] -eq 'PlatformInitiated') {
                                $reclassifiedPlatform++
                            } else {
                                $reclassifiedOther++
                            }
                        }
                    }

                    $totalReclassified = $reclassifiedPlatform + $reclassifiedOther
                    if ($totalReclassified -gt 0) {
                        $r.PlatformUnavailableMinutes += $reclassifiedPlatform
                        $r.UnknownContextMinutes      += $reclassifiedOther
                        $r.UnknownNullMinutes         -= $totalReclassified
                        $r.UnavailableMinutes          = $r.PlatformUnavailableMinutes + $r.UnknownContextMinutes
                        $r.HealthAttributedNullMinutes = $totalReclassified
                        # EligibleMinutes and AvailabilityPct remain unchanged
                        Write-Verbose "  [$($r.VMName)] Reclassified $totalReclassified null min ($reclassifiedPlatform platform, $reclassifiedOther other) from health events"
                    }
                }
            }
        }
        catch {
            Write-Verbose "  [$($r.VMName)] Resource Health query failed: $_"
        }
    }
}

$spNameCache = @{}
$guidPattern = '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'

# Collect all unique unresolved caller GUIDs
$unresolvedGuids = [System.Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
foreach ($r in $perVmResults) {
    if (-not $r.DeallocWindows -or $r.DeallocWindows.Count -eq 0) { continue }
    foreach ($w in $r.DeallocWindows) {
        if ($w.Caller -and -not $w.DisplayName -and $w.Caller -match $guidPattern) {
            $null = $unresolvedGuids.Add($w.Caller)
        }
    }
}

if ($unresolvedGuids.Count -gt 0) {
    Write-Verbose "  Resolving $($unresolvedGuids.Count) unique caller GUID(s)..."

    # 1. Batch resolve via Graph POST /directoryObjects/getByIds (up to 1000 per call)
    $guidList = @($unresolvedGuids)
    for ($i = 0; $i -lt $guidList.Count; $i += 1000) {
        $batch = @($guidList[$i..[Math]::Min($i + 999, $guidList.Count - 1)])
        try {
            $body = @{ ids = $batch; types = @('user','servicePrincipal','group','application') } | ConvertTo-Json -Compress
            $resp = Invoke-AzRestMethod -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getByIds' `
                -Method POST -Payload $body -ErrorAction SilentlyContinue
            if ($resp.StatusCode -eq 200) {
                $results = ($resp.Content | ConvertFrom-Json).value
                foreach ($obj in $results) {
                    if ($obj.id -and $obj.displayName) {
                        $spNameCache[$obj.id] = $obj.displayName
                        Write-Verbose "  Resolved $($obj.id) via Graph getByIds: $($obj.displayName)"
                    }
                }
            }
        } catch { Write-Verbose "  Graph getByIds batch call failed: $_" }
    }

    # 2. For any still-unresolved GUIDs, try as appId (the Activity Log Caller
    #    for some service principals is the Application/Client ID, not the Object ID)
    foreach ($guid in $unresolvedGuids) {
        if ($spNameCache.ContainsKey($guid)) { continue }
        try {
            $uri = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$guid'&`$select=displayName"
            $resp = Invoke-AzRestMethod -Uri $uri -Method GET -ErrorAction SilentlyContinue
            if ($resp.StatusCode -eq 200) {
                $body = $resp.Content | ConvertFrom-Json
                if ($body.value -and $body.value.Count -gt 0 -and $body.value[0].displayName) {
                    $spNameCache[$guid] = $body.value[0].displayName
                    Write-Verbose "  Resolved $guid via Graph servicePrincipals(appId): $($body.value[0].displayName)"
                }
            }
        } catch { Write-Verbose "  Graph servicePrincipals(appId) lookup failed for ${guid}: $_" }
    }

    # Log any remaining unresolved GUIDs
    foreach ($guid in $unresolvedGuids) {
        if (-not $spNameCache.ContainsKey($guid)) {
            Write-Verbose "  Could not resolve GUID $guid to a display name."
        }
    }
}

# Apply resolved names back to all deallocation windows
foreach ($r in $perVmResults) {
    if (-not $r.DeallocWindows -or $r.DeallocWindows.Count -eq 0) { continue }
    foreach ($w in $r.DeallocWindows) {
        if ($w.Caller -and -not $w.DisplayName -and $w.Caller -match $guidPattern) {
            if ($spNameCache.ContainsKey($w.Caller) -and $spNameCache[$w.Caller]) {
                $w.DisplayName = $spNameCache[$w.Caller]
            } else {
                $w.DisplayName = $w.Caller
            }
        }
    }
}

# Print windows per VM (after name resolution so display names are available)
foreach ($r in $perVmResults) {
    $hasWindows = ($r.DeallocWindows -and $r.DeallocWindows.Count -gt 0) -or
                  ($r.NonExistWindows -and $r.NonExistWindows.Count -gt 0) -or
                  ($r.PatchWindows -and $r.PatchWindows.Count -gt 0) -or
                  ($r.HealthEventWindows -and $r.HealthEventWindows.Count -gt 0)
    if (-not $hasWindows) { continue }

    foreach ($w in $r.DeallocWindows) {
        $who = $w.DisplayName ? "$($w.DisplayName) ($($w.Caller))" : $w.Caller
        Write-Host "  [$($r.VMName)]   Deallocation window: $($w.From.ToString('u')) -> $($w.To.ToString('u'))  by $who"
    }
    foreach ($w in $r.NonExistWindows) {
        Write-Host "  [$($r.VMName)]   Non-existence window: $($w.From.ToString('u')) -> $($w.To.ToString('u'))"
    }
    foreach ($w in $r.PatchWindows) {
        Write-Host "  [$($r.VMName)]   Patching window: $($w.From.ToString('u')) -> $($w.To.ToString('u'))"
    }
    foreach ($w in $r.HealthEventWindows) {
        $causeLabel = $w.Cause -eq 'PlatformInitiated' ? 'PLATFORM' : $w.Cause
        Write-Host "  [$($r.VMName)]   " -NoNewline
        Write-Host "Health event: $($w.From.ToString('u')) -> $($w.To.ToString('u'))  [$causeLabel] $($w.Title)" -ForegroundColor Red
        if ($w.RootCauseSummary) {
            Write-Host "  [$($r.VMName)]     RCA: $($w.RootCauseSummary)"
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

# --- Separate fully-deallocated / anomaly VMs from active ones ---
# A VM is excluded from the availability calculation if:
#   1. EligibleMinutes = 0 (all nulls fell inside known exclusion windows), OR
#   2. No real metric signals at all (AvailableMinutes=0 AND UnavailableMinutes=0).
#      A VM that never reported the metric for the entire period is an anomaly
#      regardless of its power state — it may have been kept deallocated, or it
#      may be running with metric issues.  Either way it provides no usable data.
$activeResults    = [System.Collections.Generic.List[object]]::new()
$excludedResults  = [System.Collections.Generic.List[object]]::new()
$anomalyResults   = [System.Collections.Generic.List[object]]::new()

foreach ($r in $perVmResults) {
    $noRealMetric           = $r.AvailableMinutes -eq 0 -and $r.UnavailableMinutes -eq 0 -and $r.CustomerInitiatedMinutes -eq 0
    $fullyExcludedByWindows = $r.EligibleMinutes -eq 0

    if ($noRealMetric) {
        # VM never emitted metric = 1 or metric = 0 during the entire period.
        # Treat as anomaly — no usable data for availability calculation.
        $anomalyResults.Add($r)
    }
    elseif ($fullyExcludedByWindows) {
        # All time covered by deallocation/patching/non-existence windows
        $excludedResults.Add($r)
    }
    else {
        $activeResults.Add($r)
    }
}

if ($anomalyResults.Count -gt 0) {
    Write-Host ''
    Write-Host "=== Excluded VMs (no metric reported — anomaly) ==="
    foreach ($x in $anomalyResults) {
        Write-Host "    $($x.VMName) ($($x.ResourceGroupName))  — no metric=0 or metric=1 emitted for entire period"
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
    Write-Warning 'All VMs were inactive or had no metric data for the entire period — no eligible minutes to compute availability.'
}
else {
    # Sum once via foreach — faster than many Measure-Object pipelines
    $totalAvailable = $totalUnavailable = $totalUnknownNull = 0
    $totalPlatformUnavail = $totalCustomerInit = $totalUnknownCtx = 0
    $totalDealloc = $totalPatching = $totalNonExistent = $totalGrace = $totalEligible = 0
    $totalHealthAttrNull = 0
    foreach ($r in $activeResults) {
        $totalAvailable       += $r.AvailableMinutes
        $totalUnavailable     += $r.UnavailableMinutes
        $totalPlatformUnavail += $r.PlatformUnavailableMinutes
        $totalCustomerInit    += $r.CustomerInitiatedMinutes
        $totalUnknownCtx      += $r.UnknownContextMinutes
        $totalUnknownNull     += $r.UnknownNullMinutes
        $totalDealloc         += $r.UserDeallocatedMinutes
        $totalPatching        += $r.PatchingMinutes
        $totalNonExistent     += $r.NonExistentMinutes
        $totalGrace           += $r.TransitionGraceMinutes
        $totalEligible        += $r.EligibleMinutes
        $totalHealthAttrNull  += $r.HealthAttributedNullMinutes
    }
    $totalMinutes = $totalAvailable + $totalUnavailable + $totalUnknownNull + $totalDealloc + $totalPatching + $totalNonExistent + $totalGrace + $totalCustomerInit

    $overallPct = [math]::Round(($totalAvailable / $totalEligible) * 100, 4)
    Write-Host "=== Overall Availability ==="
    Write-Host "    VMs assessed (active)            : $($activeResults.Count) of $($perVmResults.Count) total ($($anomalyResults.Count) anomaly, $($excludedResults.Count) inactive)"
    Write-Host "    Total minutes in period           : $totalMinutes min"
    Write-Host "  - User-deallocated                  : $totalDealloc min"
    Write-Host "  - Customer-initiated (in-guest)     : $totalCustomerInit min"
    Write-Host "  - OS patching (planned maintenance) : $totalPatching min"
    Write-Host "  - VM did not exist                  : $totalNonExistent min"
    Write-Host "  - Transition grace ($TransitionGraceMinutes min tolerance)  : $totalGrace min"
    Write-Host "  = Eligible minutes (denominator)    : $totalEligible min"
    Write-Host "    Of which:"
    Write-Host "      Available (numerator)           : $totalAvailable min"
    Write-Host "      Unavailable (platform)          : $totalPlatformUnavail min"
    Write-Host "      Unavailable (unknown context)   : $totalUnknownCtx min"
    Write-Host "      Unavailable (unattributed null)  : $totalUnknownNull min"
    if ($totalHealthAttrNull -gt 0) {
        Write-Host "        (includes $totalHealthAttrNull null min reclassified from health events into platform/context above)" -ForegroundColor DarkYellow
    }
    $confirmedCount = @($activeResults | Where-Object { $_.PlatformEventConfirmed }).Count
    if ($confirmedCount -gt 0) {
        Write-Host "    Resource Health confirmed platform events on $confirmedCount VM(s)" -ForegroundColor Yellow
    }
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
# Register default display columns via type data (reliable across all hosts)
$typeName = 'VmAvailabilityResult'
Update-TypeData -TypeName $typeName -DefaultDisplayPropertySet @(
    'VMName','ResourceGroupName','Location','Placement','Status',
    'EligibleMinutes','UnavailableMinutes','UnknownNullMinutes','AvailabilityPct'
) -Force

# Helper: emit one pipeline object per VM result
function EmitVmResult ($r, [string]$status, [bool]$skipDetails) {
    $windowDetails = $skipDetails ? @() : @(
        $r.DeallocWindows | ForEach-Object {
            [PSCustomObject]@{
                From = $_.From
                To   = $_.To
                By   = $_.DisplayName ? "$($_.DisplayName) ($($_.Caller))" : $_.Caller
            }
        }
    )
    $patchDetails    = $skipDetails ? @() : @($r.PatchWindows    | ForEach-Object { [PSCustomObject]@{ From = $_.From; To = $_.To } })
    $nonExistDetails = $skipDetails ? @() : @($r.NonExistWindows | ForEach-Object { [PSCustomObject]@{ From = $_.From; To = $_.To } })

    $healthDetails = $skipDetails ? @() : @($r.HealthEventWindows | ForEach-Object {
        [PSCustomObject]@{ From = $_.From; To = $_.To; Title = $_.Title; Cause = $_.Cause; RootCauseSummary = $_.RootCauseSummary }
    })

    $obj = [PSCustomObject]@{
        VMName                     = $r.VMName
        ResourceGroupName          = $r.ResourceGroupName
        Location                   = $r.Location
        Zones                      = $r.Zones
        Placement                  = $r.Placement
        Status                     = $status
        AvailableMinutes           = $r.AvailableMinutes
        UnavailableMinutes         = $r.UnavailableMinutes
        PlatformUnavailableMinutes = $r.PlatformUnavailableMinutes
        CustomerInitiatedMinutes   = $r.CustomerInitiatedMinutes
        UnknownContextMinutes      = $r.UnknownContextMinutes
        UnknownNullMinutes         = $r.UnknownNullMinutes
        HealthAttributedNullMinutes = $r.HealthAttributedNullMinutes
        UserDeallocatedMinutes     = $r.UserDeallocatedMinutes
        PatchingMinutes            = $r.PatchingMinutes
        NonExistentMinutes         = $r.NonExistentMinutes
        TransitionGraceMinutes     = $r.TransitionGraceMinutes
        EligibleMinutes            = $r.EligibleMinutes
        AvailabilityPct            = $skipDetails ? $null : $r.AvailabilityPct
        PlatformEventConfirmed     = $r.PlatformEventConfirmed
        DeallocWindows             = $windowDetails
        PatchWindows               = $patchDetails
        NonExistWindows            = $nonExistDetails
        HealthEventWindows         = $healthDetails
    }
    $obj.PSObject.TypeNames.Insert(0, 'VmAvailabilityResult')
    $obj
}

foreach ($r in $anomalyResults)  { EmitVmResult $r 'Excluded (no metric reported — anomaly)' $true  }
foreach ($r in $excludedResults) { EmitVmResult $r 'Excluded (inactive entire period)'       $true  }
foreach ($r in $activeResults)   { EmitVmResult $r 'Active'                                   $false }
