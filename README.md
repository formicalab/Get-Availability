# Get-Availability

Reports rolling 14-day availability for Azure Virtual Machines, Azure SQL Databases, and Azure Storage Accounts across one or more Azure subscriptions.

Available in two implementations:

| | PowerShell | C# (.NET 10, Native AOT) |
|---|---|---|
| **Location** | `get-availability.ps1` | `csharp/GetAvailability/` |
| **Runtime** | PowerShell 7+ with Az modules | Standalone `.exe` — no runtime required |
| **Auth** | `Connect-AzAccount` | `DefaultAzureCredential` (az login, managed identity, etc.) |
| **Parallelism** | `ForEach-Object -Parallel` | `Parallel.ForEachAsync` (async/await) |
| **Typical speed** | ~9 min (237 resources, 3 subs) | ~1 min (same workload, ~9× faster) |
| **Binary size** | N/A | ~15 MB self-contained |

Both implementations share identical business logic, produce identical results, and support the same parameters.

For each resource, the script answers:

- How many minutes was it **eligible** (expected to be running/available)?
- How many of those minutes was it **available** (confirmed by Azure Monitor)?
- What is the **availability percentage** (Available / Eligible × 100)?

## How it works

```
┌─────────────────────────────────────────────────────────────────────────┐
│  1. Resource Graph — Inventory query (resources table)                  │
│     → VMs + SQL DBs + Storage Accounts, current state, creation date   │
│                                                                         │
│  2. Resource Graph — Change events (resourcechanges table)              │
│     → start/stop/create/delete lifecycle transitions, 14-day retention  │
│                                                                         │
│  3. Azure Monitor Metrics REST API (parallel, per-resource)             │
│     → VMs: VmAvailabilityMetric + CPU + Network (3 metrics, one call)  │
│     → SQL DBs: Availability (single metric)                            │
│     → Storage: Availability + Transactions (2 metrics, one call)       │
│                                                                         │
│  4. Per-resource: build exclusion windows → eligible minutes            │
│  5. Per-resource: filter metric data points against windows → available │
│  6. Per-resource: inline gap recovery via supplementary metrics (VMs)   │
│  7. Per-resource: zero-transaction exclusion (Storage Accounts)         │
│  8. Output: availability % per resource + summary by kind/location      │
└─────────────────────────────────────────────────────────────────────────┘
```

### Step 1 — Resource inventory

A single KQL query against the `resources` table returns all VMs, SQL databases (excluding system `master` DBs), and Storage Accounts with their **current state** inline — no per-resource REST calls needed.

- VMs: `properties.extended.instanceView.powerState.code` → stripped to `running`, `deallocated`, etc.
- SQL DBs: `properties.status` → `Online`, `Paused`, `Resuming`, etc.
- Storage Accounts: `properties.creationTime` for creation date (no power state concept).

### Step 2 — Lifecycle events

Three KQL queries against the `resourcechanges` table (VMs, SQL DBs, Storage Accounts) detect lifecycle transitions within the 14-day window. Each change is normalized into one of four event kinds:

| Source state | Event kind | Resource types |
|---|---|---|
| `PowerState/running`, `Online` | **Start** | VM, SQL DB |
| `PowerState/deallocated`, `PowerState/stopped`, `PowerState/deallocating`, `PowerState/stopping`, `Paused`, `Pausing` | **Stop** | VM, SQL DB |
| changeType = `Create` | **Create** | VM, SQL DB, Storage |
| changeType = `Delete` | **Delete** | VM, SQL DB, Storage |

**Shutdown-direction intermediates** (`Pausing`, `deallocating`, `stopping`) are mapped to `Stop` so the exclusion window starts as soon as shutdown begins — independent of the transition tolerance. Startup-direction intermediates (`Resuming`, `starting`) are intentionally **not** mapped; the `Online`/`running` event marks actual availability.

Storage Accounts only track Create/Delete events (no start/stop concept).

### Step 3 — Availability metrics

Azure Monitor is queried per-resource in parallel (configurable parallelism, default 8) with exponential backoff on 429/5xx errors:

| Resource type | Metrics requested | Scale | Aggregation |
|---|---|---|---|
| Virtual Machine | `VmAvailabilityMetric`, `Percentage CPU`, `Network In Total` | 0.0–1.0 (primary) | Minimum, Average |
| Azure SQL Database | `Availability` | 0–100 → normalized to 0.0–1.0 | Minimum |
| Storage Account | `Availability`, `Transactions` | 0–100 → normalized to 0.0–1.0 | Minimum, Total |

Granularity is PT1M (one data point per minute). VMs fetch 3 metrics in a single API call (~4MB, under the 8MB Azure response limit). The supplementary CPU and Network metrics enable inline gap recovery without a separate API call.

## Availability calculation

### Eligible minutes

```
EligibleMinutes = TotalMinutes − ExcludedMinutes
```

Exclusion windows are built in three phases:

**Phase 1 — Non-existence:** Delete→Create pairs mark periods when the resource didn't exist. If the resource was created during the 14-day window with no prior delete, the time before creation is also excluded.

**Phase 2 — Purposeful stops:** Stop→Start pairs mark periods when the resource was intentionally stopped (deallocated, paused). If the first observed event is a Start, the resource was stopped before the window → excluded from period start. If the current power state is stopped/deallocated/paused with no events at all → entire period excluded.

**Phase 3 — Transition tolerance:** Every power event (Start or Stop) gets a **symmetric ±N minute tolerance zone** (default N=5). This excludes the ramp-down before shutdown and ramp-up after boot where metrics may be degraded.

Multiple consecutive events naturally extend the exclusion: events at 18:00 and 18:02 with N=5 produce a merged window [17:55, 18:07].

All windows are merged and snapped to whole-minute boundaries (floor the start, ceil the end) so that discrete metric data points align with eligible minute counts.

### Available minutes

Each metric data point at time T covers the interval [T, T+1min). A data point is counted toward availability only if **no part** of its interval overlaps any exclusion window.

```
AvailableMinutes = Σ metric.Value  (for non-excluded data points)
```

Since the metric values are 0.0–1.0, a fully available minute contributes 1.0 and a degraded minute contributes its fractional value.

### Inline gap recovery (VMs only)

Azure's `VmAvailabilityMetric` occasionally has null data points even when the VM is fully operational (a known telemetry gap). Since the script fetches CPU and Network metrics alongside the primary metric in a single API call, gap recovery is performed inline — no additional API calls needed.

A gap minute is **recovered** (counted as available = 1.0) only if **both** supplementary metrics (`Percentage CPU` and `Network In Total`) report non-null data at that minute.

### Storage Account — transaction-based eligibility

Storage Account `Availability` is a transaction-success-rate metric — it is only meaningful when there are actual transactions. Minutes with zero transactions have no availability signal and are **excluded from eligible minutes** rather than counted as unavailable.

The script fetches both `Availability` and `Transactions` in a single API call. For each minute:
- **Transactions > 0 and Availability not null:** use the Availability value as the data point
- **Transactions = 0 or null:** subtract this minute from eligible minutes

### Final formula

```
AvailabilityPct = AvailableMinutes / EligibleMinutes × 100
```

Resources that are stopped/non-existent for the entire period show `N/A` (zero eligible minutes).

## Parameters

### PowerShell

| Parameter | Default | Description |
|---|---|---|
| `SubscriptionNames` | *(required)* | One or more Azure subscription display names (string array) |
| `ResourceKinds` | `vm,sql,storage` | Resource kinds to process |
| `ResourceName` | *(all)* | Filter to a single resource. Use `server/db` format for SQL DBs |
| `TransitionToleranceMinutes` | `5` | Symmetric ±N tolerance around each start/stop event (0–120) |
| `Parallelism` | *(auto)* | Max concurrent metric API calls (1–64) |

### C# (CLI)

| Option | Short | Default | Description |
|---|---|---|---|
| `--subscriptions` | `-s` | *(required)* | One or more Azure subscription display names |
| `--kinds` | `-k` | `vm sql storage` | Resource kinds to process |
| `--resource` | `-r` | *(all)* | Filter to a single resource name |
| `--tolerance` | `-t` | `5` | Symmetric ±N tolerance around each start/stop event |
| `--parallelism` | `-p` | *(auto)* | Max concurrent metric API calls |

## Prerequisites

### PowerShell

| Requirement | Detail |
|---|---|
| PowerShell | 7.0 or later |
| Az modules | `Az.Accounts`, `Az.ResourceGraph` |
| Azure context | `Connect-AzAccount` must already be established |

### C# (build from source)

| Requirement | Detail |
|---|---|
| .NET SDK | 10.0 or later |
| Azure auth | `az login` or any method supported by `DefaultAzureCredential` |

The published binary (`GetAvailability.exe`) requires no .NET runtime — it is a Native AOT self-contained executable.

## Usage

### PowerShell

```powershell
# Single subscription
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-PRODUZIONE'

# Multiple subscriptions
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-SVILUPPO','POSTE-BANCOPOSTA-PRODUZIONE','POSTE-BANCOPOSTA-CERTIFICAZIONE'

# Single resource (searched across all specified subscriptions)
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-SVILUPPO' -ResourceName 'spiacomdgs01'

# Custom tolerance
./get-availability.ps1 -SubscriptionNames 'POSTE-BANCOPOSTA-PRODUZIONE' -TransitionToleranceMinutes 10
```

### C#

```bash
# Build the Native AOT binary (one-time)
cd csharp/GetAvailability
dotnet publish -c Release -r win-x64   # output in bin/Release/net10.0/win-x64/publish/

# Single subscription
./GetAvailability --subscriptions POSTE-BANCOPOSTA-PRODUZIONE

# Multiple subscriptions
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO POSTE-BANCOPOSTA-PRODUZIONE POSTE-BANCOPOSTA-CERTIFICAZIONE

# Filter by resource kind
./GetAvailability --subscriptions POSTE-BANCOPOSTA-PRODUZIONE --kinds VirtualMachine StorageAccount

# Single resource
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO --resource spiacomdgs01

# Custom tolerance and parallelism
./GetAvailability --subscriptions POSTE-BANCOPOSTA-PRODUZIONE --tolerance 10 --parallelism 8

# Or run directly without publishing
cd csharp/GetAvailability
dotnet run -- --subscriptions POSTE-BANCOPOSTA-PRODUZIONE
```

## Output

Default table view:

| SubscriptionName | Name | Kind | Location | AvailabilityPct | AvailableMinutes | EligibleMinutes | TotalMinutes | Explanation |
|---|---|---|---|---:|---:|---:|---:|---|
| PRODUZIONE | `sabfpsql01azne/sabfpsqldb01azne` | AzureSqlDatabase | northeurope | 100 | 20160 | 20160 | 20160 | Fully eligible for the entire period |
| PRODUZIONE | `spiacomdgs01` | VirtualMachine | northeurope | 100 | 2794 | 2794 | 20160 | Stopped/deallocated for 17366 min; ... |
| PRODUZIONE | `mystorageacct` | StorageAccount | westeurope | 99.99 | 8540 | 8541 | 20160 | Fully eligible for the entire period |

A per-subscription summary is printed grouping resources by Kind + Location with resource count and aggregate availability. When multiple subscriptions are processed, a cross-subscription overall summary is printed at the end.

Additional properties available on the pipeline object: `ResourceId`, `ResourceGroupName`, `CreatedAt`, `ExclusionWindows`.

## Architecture notes

Both implementations share the same algorithmic design:

- **Single API call per resource.** VMs fetch 3 metrics (availability + CPU + network) in one call (~4MB, under Azure's 8MB limit). Storage Accounts fetch 2 metrics (availability + transactions) in one call. SQL DBs fetch 1 metric.
- **No per-resource REST calls for inventory or power state.** The Resource Graph `resources` table returns current state inline.
- **No Activity Log dependency.** The `resourcechanges` table provides 14-day lifecycle history with a single paginated query per resource type.
- **Shutdown intermediates captured early.** `Pausing`/`deallocating`/`stopping` map to Stop events so exclusion starts immediately.
- **Metric boundary alignment.** Exclusion windows are floor/ceil-snapped to whole minutes so discrete metric data points match eligible minute counts exactly.
- **Inline gap recovery.** Supplementary CPU and Network metrics are fetched alongside the primary metric — no second-pass API calls needed. A gap minute requires both metrics to be non-null.
- **Transaction-aware storage.** Zero-transaction minutes are excluded from eligibility rather than counted as unavailable, giving an accurate picture of actual storage service availability.

The C# port adds:

- **`Parallel.ForEachAsync`** for concurrent metric queries with configurable parallelism.
- **Ticks-based metric keying** (`long` instead of `DateTime.ToString`) — zero-allocation per data point.
- **Native AOT** — ~15 MB standalone binary, no .NET runtime required, ~7× faster than PowerShell.
