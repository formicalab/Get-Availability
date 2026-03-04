# Get-Availability

Calculates the actual availability percentage for Azure Virtual Machines using the **VmAvailabilityMetric** from Azure Monitor.

The goal is to measure **unforeseen unavailability only** — planned operations (user-initiated deallocations, OS patching, VM lifecycle gaps) are excluded from the calculation so the result reflects genuine platform-level reliability.

Reference: [Calculate the Availability and SLA for Your Azure Solution](https://clemens.ms/calculate-the-availability-and-sla-for-your-azure-solution/)

## Prerequisites

| Requirement | Detail |
|---|---|
| **PowerShell** | 7.0 or later |
| **Az modules** | `Az.Accounts`, `Az.Compute`, `Az.Monitor`, `Az.Resources` |
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
```

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

Pairs of **Deallocate Virtual Machine** → **Start Virtual Machine** (Succeeded) events define deallocation windows. Null data points inside these windows are classified as **UserDeallocated** and excluded from the denominator.

If a deallocate event has no matching start, the window extends to the end of the observation period.

#### b) OS patching (planned maintenance)

**Install OS update patches on virtual machine** events (Started/Accepted → Succeeded) define patching windows. Both null data points and metric=0 data points inside patching windows are classified as **Patching** and excluded — these represent expected reboots, not unforeseen outages.

#### c) VM lifecycle (create / delete / recreate)

**Delete Virtual Machine** → **Create or Update Virtual Machine** (Succeeded) events define non-existence windows. The VM's `TimeCreated` property is used as a fallback to detect first-time creation mid-period (a synthetic `[startDate, TimeCreated)` gap is added if no prior delete exists).

Null data points inside non-existence windows are classified as **NonExistent** and excluded.

#### d) Unknown nulls

Null data points that don't fall into any of the above windows are classified as **UnknownNull** and treated as **unavailable** (potential platform issue).

### 3. Classification priority

When windows overlap, this priority applies:

1. **Non-existence** (VM didn't exist)
2. **User-deallocated** (intentional shutdown)
3. **OS patching** (planned maintenance)
4. **Unknown null** (unavailable)

### 4. Availability formula

```
Eligible minutes = Available + Unavailable(metric=0) + UnknownNull
Availability %   = Available / Eligible × 100
```

Minutes excluded from eligible (denominator):
- User-deallocated minutes
- OS patching minutes
- Non-existent minutes

### 5. Overall availability (multiple VMs)

When multiple VMs are in scope, the overall availability uses a **resource-weighted average**:

```
Overall % = Σ(AvailableMinutes) / Σ(EligibleMinutes) × 100
```

This means a VM that was running longer carries proportionally more weight.

### 6. VM exclusion

VMs that were completely inactive for the entire observation period are excluded from the overall calculation:

- **All eligible minutes = 0** — deallocation/patching/non-existence windows covered the full period
- **No real metric signals** (no 1s, no 0s — all nulls) **and no Activity Log events** — the VM was deallocated before the observation period started

Excluded VMs are reported separately and emitted as pipeline objects with `Status = 'Excluded (inactive entire period)'`.

### 7. Service principal name resolution

Deallocation callers that are GUIDs are resolved to display names after parallel processing completes, using a shared cache to avoid duplicate lookups:

1. `Get-AzADServicePrincipal -ObjectId`
2. `Get-AzADServicePrincipal -ApplicationId`
3. `Get-AzADServicePrincipal -Filter "appId eq '...'"` 
4. Graph API `directoryObjects` fallback

## Output

### Console (Write-Host)

A colour-coded summary:

```
=== Overall Availability ===
    VMs assessed (active)            : 2 of 3 total
    Total minutes in period           : 80640 min
  - User-deallocated                  : 1139 min
  - OS patching (planned maintenance) : 4 min
  - VM did not exist                  : 0 min
  = Eligible minutes (denominator)    : 79497 min
    Of which:
      Available (numerator)           : 79486 min
      Unavailable (metric = 0)        : 6 min
      Unavailable (no metric emitted) : 5 min

  >>> Availability: 99.9862% <<<
```

Colour thresholds: **green** ≥ 99.99%, **yellow** ≥ 99.9%, **red** < 99.9%.

### Pipeline objects

Per-VM objects for downstream processing (export to CSV, filtering, etc.):

| Property | Description |
|---|---|
| `VMName` | VM name |
| `ResourceGroupName` | Resource group |
| `Status` | `Active` or `Excluded (inactive entire period)` |
| `AvailableMinutes` | Minutes with metric ≥ 1 |
| `UnavailableMinutes` | Minutes with metric < 1 (outside patching) |
| `UnknownNullMinutes` | Null minutes not in any exclusion window |
| `UserDeallocatedMinutes` | Null minutes inside deallocation windows |
| `PatchingMinutes` | Null/0 minutes inside patching windows |
| `NonExistentMinutes` | Null minutes inside non-existence windows |
| `EligibleMinutes` | Denominator for availability % |
| `AvailabilityPct` | Per-VM availability % |
| `DeallocWindows` | Array of `{From, To, By}` |
| `PatchWindows` | Array of `{From, To}` |
| `NonExistWindows` | Array of `{From, To}` |

## Performance

- **Single Activity Log call** per VM (deallocation + patching + lifecycle events extracted from one response)
- **Parallel processing** with `ForEach-Object -Parallel` (ThrottleLimit 20)
- **Service principal resolution** runs once after parallel processing, with a shared cache per unique GUID
