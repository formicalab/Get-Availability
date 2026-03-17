# Get-Availability

Reports rolling 14-day availability for Azure Virtual Machines and Azure SQL databases across one or more Azure subscriptions.

For each resource, the script answers:

- How many minutes was it **eligible** (expected to be running)?
- How many of those minutes was it **available** (confirmed by Azure Monitor)?
- What is the **availability percentage** (Available / Eligible × 100)?

## How it works

```
┌─────────────────────────────────────────────────────────────────────────┐
│  1. Resource Graph ─ Inventory query (resources table)                  │
│     → VMs + SQL DBs, current power state, creation date                │
│                                                                         │
│  2. Resource Graph ─ Change events (resourcechanges table)              │
│     → start/stop/create/delete lifecycle transitions, 14-day retention  │
│                                                                         │
│  3. Azure Monitor Metrics REST API (parallel, per-resource)             │
│     → VmAvailabilityMetric (VMs) or availability (SQL DBs), PT1M       │
│                                                                         │
│  4. Per-resource: build exclusion windows → eligible minutes            │
│  5. Per-resource: filter metric data points against windows → available │
│  6. Per-resource: recover gap minutes via fallback metrics (VMs only)   │
│  7. Output: availability % per resource + summary by kind/location      │
└─────────────────────────────────────────────────────────────────────────┘
```

### Step 1 — Resource inventory

A single KQL query against the `resources` table returns all VMs and SQL databases (excluding system `master` DBs) with their **current power state** inline — no per-resource REST calls needed.

- VMs: `properties.extended.instanceView.powerState.code` → stripped to `running`, `deallocated`, etc.
- SQL DBs: `properties.status` → `Online`, `Paused`, `Resuming`, etc.

### Step 2 — Lifecycle events

Two KQL queries against the `resourcechanges` table (one for VMs, one for SQL DBs) detect every power-state or status transition within the 14-day window. Each change is normalized into one of four event kinds:

| Source state | Event kind | Resource types |
|---|---|---|
| `PowerState/running`, `Online` | **Start** | VM, SQL DB |
| `PowerState/deallocated`, `PowerState/stopped`, `PowerState/deallocating`, `PowerState/stopping`, `Paused`, `Pausing` | **Stop** | VM, SQL DB |
| changeType = `Create` | **Create** | Both |
| changeType = `Delete` | **Delete** | Both |

**Shutdown-direction intermediates** (`Pausing`, `deallocating`, `stopping`) are mapped to `Stop` so the exclusion window starts as soon as shutdown begins — independent of the transition buffer. Startup-direction intermediates (`Resuming`, `starting`) are intentionally **not** mapped; the `Online`/`running` event marks actual availability.

### Step 3 — Availability metrics

Azure Monitor is queried per-resource in parallel (configurable parallelism, default 8) with exponential backoff on 429/5xx errors:

| Resource type | Metric | Scale |
|---|---|---|
| Virtual Machine | `VmAvailabilityMetric` | 0.0–1.0 |
| Azure SQL Database | `availability` | 0–100 (normalized to 0.0–1.0) |

Granularity is PT1M (one data point per minute), aggregation `Minimum`.

## Availability calculation

### Eligible minutes

```
EligibleMinutes = TotalMinutes − ExcludedMinutes
```

Exclusion windows are built in three phases:

**Phase 1 — Non-existence:** Delete→Create pairs mark periods when the resource didn't exist. If the resource was created during the 14-day window with no prior delete, the time before creation is also excluded.

**Phase 2 — Purposeful stops:** Stop→Start pairs mark periods when the resource was intentionally stopped (deallocated, paused). If the first observed event is a Start, the resource was stopped before the window → excluded from period start. If the current power state is stopped/deallocated/paused with no events at all → entire period excluded.

**Phase 3 — Transition buffers:** Every power event (Start or Stop) gets a **symmetric ±N minute buffer** (default N=5). This excludes the ramp-down before shutdown and ramp-up after boot where metrics are degraded.

Multiple consecutive events naturally extend the exclusion: events at 18:00 and 18:02 with N=5 produce a merged window [17:55, 18:07].

All windows are merged and snapped to whole-minute boundaries (floor the start, ceil the end) so that discrete metric data points align with eligible minute counts.

### Available minutes

Each metric data point at time T covers the interval [T, T+1min). A data point is counted toward availability only if **no part** of its interval overlaps any exclusion window.

```
AvailableMinutes = Σ metric.Value  (for non-excluded data points)
```

Since the metric values are 0.0–1.0, a fully available minute contributes 1.0 and a degraded minute contributes its fractional value.

### Fallback metrics (VMs only)

Azure's `VmAvailabilityMetric` occasionally has null data points even when the VM is fully operational (a known telemetry gap). For VMs with null data points during eligible minutes, the script checks 5 guest-level metrics over a narrow time window around the gaps (±2 minutes):

1. Percentage CPU
2. Network In Total
3. Network Out Total
4. Disk Read Bytes
5. Disk Write Bytes

A gap minute is **recovered** (counted as available = 1.0) only if **all 5** supplementary metrics report non-null data at that minute. This is conservative — a single missing metric means the minute stays as a gap.

This check is **on-demand**: only VMs that actually have gaps trigger the extra API call, and only for the narrow time range around the gaps. Resources with no gaps incur zero extra cost.

### Final formula

```
AvailabilityPct = AvailableMinutes / EligibleMinutes × 100
```

Resources that are stopped/non-existent for the entire period show `N/A` (zero eligible minutes).

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `SubscriptionNames` | *(required)* | One or more Azure subscription display names (string array) |
| `ResourceName` | *(all)* | Filter to a single resource. Use `server/db` format for SQL DBs |
| `TransitionBufferMinutes` | `5` | Symmetric ±N buffer around each start/stop event (0–120) |
| `Parallelism` | `8` | Max concurrent metric API calls (1–64) |

## Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 7.0 or later |
| Az modules | `Az.Accounts`, `Az.ResourceGraph` |
| Azure context | `Connect-AzAccount` must already be established |

## Usage

```powershell
# Single subscription
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-PRODUZIONE'

# Multiple subscriptions
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-SVILUPPO','POSTE-BANCOPOSTA-PRODUZIONE','POSTE-BANCOPOSTA-CERTIFICAZIONE'

# Single resource (searched in each subscription)
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-SVILUPPO' -ResourceName 'spiacomdgs01'

# Custom buffer
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-PRODUZIONE' -TransitionBufferMinutes 10
```

## Output

Default table view:

| SubscriptionName | Name | Kind | Location | AvailabilityPct | AvailableMinutes | EligibleMinutes | TotalMinutes | Explanation |
|---|---|---|---|---:|---:|---:|---:|---|
| `POSTE-BANCOPOSTA-SVILUPPO` | `sabfpsql01azne/sabfpsqldb01azne` | `AzureSqlDatabase` | `northeurope` | `100` | `20160` | `20160` | `20160` | Fully eligible for the entire period |
| `POSTE-BANCOPOSTA-SVILUPPO` | `spiacomdgs01` | `VirtualMachine` | `northeurope` | `100` | `2794` | `2794` | `20160` | Stopped/deallocated for 17366 min; ... |

A per-subscription summary (by Kind + Location) is printed after each subscription's results. When multiple subscriptions are processed, a cross-subscription overall summary is printed at the end.

Additional properties available on the pipeline object: `ResourceId`, `ResourceGroupName`, `CreatedAt`, `ExclusionWindows`.

## Architecture notes

- **No per-resource REST calls for inventory or power state.** The `resources` table returns current power state inline.
- **No Activity Log dependency.** The `resourcechanges` table provides 14-day lifecycle history with a single paginated query per resource type.
- **Shutdown intermediates captured early.** `Pausing`/`deallocating`/`stopping` map to Stop events so exclusion starts immediately, not after the transition completes.
- **Metric boundary alignment.** Exclusion windows are floor/ceil-snapped to whole minutes so discrete metric data points match eligible minute counts exactly.
- **Fallback is conservative and cheap.** Supplementary metrics are only fetched for VMs with actual gaps, over narrow time ranges, and require all 5 metrics to confirm availability.
