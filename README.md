# Get-Availability

Calculates the actual availability percentage for Azure Virtual Machines using the **VmAvailabilityMetric** from Azure Monitor.

The goal is to measure **unforeseen unavailability only** — planned operations (user-initiated deallocations, OS patching, VM lifecycle gaps) are excluded from the calculation so the result reflects genuine platform-level reliability.

Reference: [Calculate the Availability and SLA for Your Azure Solution](https://clemens.ms/calculate-the-availability-and-sla-for-your-azure-solution/)

## Prerequisites

| Requirement | Detail |
|---|---|
| **PowerShell** | 7.0 or later |
| **Az modules** | `Az.Accounts`, `Az.Compute`, `Az.Monitor` |
| **Azure context** | `Connect-AzAccount` must be run before the script |

## Usage

```powershell
# Single VM
./get-availability.ps1 -VMName "web-01" -ResourceGroupName "rg-prod" `
    -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z"

# All VMs in a resource group
./get-availability.ps1 -ResourceGroupName "rg-prod" `
    -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z"

# All VMs in the current subscription
./get-availability.ps1 -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z"

# Custom grace period (0 disables, max 10)
./get-availability.ps1 -VMName "web-01" -ResourceGroupName "rg-prod" `
    -StartDate "2026-03-01T00:00:00Z" -EndDate "2026-03-02T00:00:00Z" `
    -TransitionGraceMinutes 3
```

| Parameter | Default | Description |
|---|---|---|
| `-TransitionGraceMinutes` | **2** | Minutes of tolerance after exclusion windows end, to cover metric-emission lag during VM boot. Set to 0 to disable. |

All dates are normalised to UTC internally.

## How it works

### 1. VmAvailabilityMetric

Azure Monitor emits `VmAvailabilityMetric` at 1-minute granularity:

| Metric value | Meaning |
|---|---|
| **1** | VM was available during that minute |
| **0** | VM was unavailable (platform-initiated) |
| **null** | No metric emitted — VM was not running |

The script uses **Minimum** aggregation (pessimistic): if the VM was unavailable at any instant within a minute, the whole minute counts as unavailable.

### 2. Classifying null data points

A null metric alone does not tell us *why* the VM wasn't running. The script queries the **Activity Log** (single call per VM) to build evidence-based exclusion windows:

#### a) User-initiated deallocations

Pairs of **Deallocate Virtual Machine** (Started/Accepted) → **Start Virtual Machine** (Succeeded) events define deallocation windows. The window starts at the earliest deallocate event (Started or Accepted), not Succeeded, because during a user-initiated shutdown the metric transitions 1 → 0 → null — the metric=0 minutes between Started and Succeeded represent active shutdown, not platform-initiated unavailability. Null and metric=0 data points inside these windows are classified as **UserDeallocated** and excluded from the denominator.

If a deallocate event has no matching start, the window extends to the end of the observation period.

**Orphan start events**: If the first event in the period is a Start with no preceding Deallocate, the VM was deallocated before the observation period began. A synthetic window `[startDate, StartTimestamp)` is created to cover the gap.

#### b) OS patching (planned maintenance)

**Install OS update patches on virtual machine** events (Started/Accepted → Succeeded) define patching windows. Both null data points and metric=0 data points inside patching windows are classified as **Patching** and excluded — these represent expected reboots, not unforeseen outages.

#### c) VM lifecycle (create / delete / recreate)

**Delete Virtual Machine** → **Create or Update Virtual Machine** (Succeeded) events define non-existence windows. The VM's `TimeCreated` property is used as a fallback to detect first-time creation mid-period (a synthetic `[startDate, TimeCreated)` gap is added if no prior delete exists).

Null **and metric < 1** data points inside non-existence windows are classified as **NonExistent** and excluded.

#### d) Transition grace period

When a VM boots after deallocation, patching, or creation, the Guest Agent needs 1-3 minutes to reconnect and start reporting metrics. The `TransitionGraceMinutes` parameter (default: 2) extends each exclusion window's trailing edge so these transition minutes are not penalised as unavailable.

- Only applies to null and metric < 1 data points — if the metric is already 1 (available), the minute counts as available regardless.
- Grace minutes are tracked separately as **TransitionGraceMinutes** and excluded from the denominator.
- Set to 0 to disable.

#### e) Unknown nulls

Null data points that don't fall into any of the above windows are classified as **UnknownNull** and treated as **unavailable** (potential platform issue).

### 3. Classification priority

When windows overlap, this priority applies (for both null and metric < 1 data points):

1. **Non-existence** (VM didn't exist)
2. **User-deallocated** (intentional shutdown)
3. **OS patching** (planned maintenance)
4. **Transition grace** (within grace period after any of the above)
5. **Unknown null** (unavailable)

### 4. Availability formula

```
Eligible minutes = Available + Unavailable(metric=0) + UnknownNull
Availability %   = Available / Eligible × 100
```

Minutes excluded from eligible (denominator):
- User-deallocated minutes
- OS patching minutes
- Non-existent minutes
- Transition grace minutes

### 5. Overall availability (multiple VMs)

When multiple VMs are in scope, the overall availability uses a **resource-weighted average**:

```
Overall % = Σ(AvailableMinutes) / Σ(EligibleMinutes) × 100
```

This means a VM that was running longer carries proportionally more weight.

### 6. VM exclusion

VMs that provide no usable availability data are excluded from the overall calculation. Two categories are distinguished:

#### a) Anomaly VMs (no metric reported)

VMs where **neither metric = 1 nor metric = 0** was ever emitted during the entire period (all data points were null). These may be VMs that were deallocated before the period started, or running VMs with metric collection issues. They are reported with `Status = 'Excluded (no metric reported — anomaly)'`.

#### b) Inactive VMs (fully covered by exclusion windows)

VMs where **eligible minutes = 0** because deallocation, patching, and/or non-existence windows covered the full period. Some real metric signals (0 or 1) were observed, but all non-excluded time was accounted for. They are reported with `Status = 'Excluded (inactive entire period)'`.

Both categories are reported separately in the console output and emitted as pipeline objects for downstream processing.

### 7. Safeguards

#### Activity Log retention warning

Azure Activity Log retains events for ~90 days. If `StartDate` is older than 89 days ago the script emits a warning, because missing events could cause null metrics to be incorrectly classified as unavailable.

#### Completeness check

After querying metrics, the script compares the number of data points returned against the expected number of 1-minute slots in the period. A mismatch triggers a warning, alerting you to potential gaps in the metric data.

### 8. Service principal name resolution

Deallocation callers that are GUIDs are resolved to display names after parallel processing completes, using the Microsoft Graph API via `Invoke-AzRestMethod` and a shared cache to avoid duplicate lookups:

1. **Batch resolve** — `POST /v1.0/directoryObjects/getByIds` (up to 1000 IDs per call, covering users, service principals, groups, and applications)
2. **appId fallback** — `GET /v1.0/servicePrincipals?$filter=appId eq '...'` for GUIDs that represent Application/Client IDs rather than Object IDs

Resolved names are shown in deallocation window output as `displayName (guid)` for traceability.

## Output

### Console (Write-Host)

A colour-coded summary:

```
=== Overall Availability ===
    VMs assessed (active)            : 2 of 3 total (0 anomaly, 1 inactive)
    Total minutes in period           : 80640 min
  - User-deallocated                  : 1139 min
  - OS patching (planned maintenance) : 4 min
  - VM did not exist                  : 0 min
  - Transition grace (2 min tolerance): 4 min
  = Eligible minutes (denominator)    : 79493 min
    Of which:
      Available (numerator)           : 79486 min
      Unavailable (metric = 0)        : 4 min
      Unavailable (no metric emitted) : 3 min

  >>> Availability: 99.9912% <<<
```

Colour thresholds: **green** ≥ 99.99%, **yellow** ≥ 99.9%, **red** < 99.9%.

### Pipeline objects

Per-VM objects for downstream processing (export to CSV, filtering, etc.).

The default table view shows **VMName**, **ResourceGroupName**, **Location**, **Placement**, **Status**, **EligibleMinutes**, and **AvailabilityPct**. All other properties are accessible via `Select-Object`, `Format-List`, or export commands.

| Property | Description |
|---|---|
| `VMName` | VM name |
| `ResourceGroupName` | Resource group |
| `Location` | Azure region (e.g. `westeurope`) |
| `Zones` | Availability zone number(s), or `$null` for regional VMs |
| `Placement` | `Zonal (1)` / `Zonal (1,2)` or `Regional` |
| `Status` | `Active`, `Excluded (inactive entire period)`, or `Excluded (no metric reported — anomaly)` |
| `AvailableMinutes` | Minutes with metric ≥ 1 |
| `UnavailableMinutes` | Minutes with metric < 1 (outside patching) |
| `UnknownNullMinutes` | Null minutes not in any exclusion window |
| `UserDeallocatedMinutes` | Null minutes inside deallocation windows |
| `PatchingMinutes` | Null/0 minutes inside patching windows |
| `NonExistentMinutes` | Null/0 minutes inside non-existence windows |
| `TransitionGraceMinutes` | Null/0 minutes within grace period after exclusion windows |
| `EligibleMinutes` | Denominator for availability % |
| `AvailabilityPct` | Per-VM availability % |
| `DeallocWindows` | Array of `{From, To, By}` |
| `PatchWindows` | Array of `{From, To}` |
| `NonExistWindows` | Array of `{From, To}` |

## Performance

- **Single Activity Log call** per VM (deallocation + patching + lifecycle events extracted from one response)
- **Parallel processing** with `ForEach-Object -Parallel` (ThrottleLimit 20)
- **Service principal resolution** runs once after parallel processing, with a shared cache per unique GUID
