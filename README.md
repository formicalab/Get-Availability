# Get-Availability

Reports rolling 30-day availability for Azure Virtual Machines, Azure SQL Databases, and Azure Storage Accounts across one or more Azure subscriptions.

The reporting window is always the last 30 days (now − 30 days → now), aligned with the [Resource Health API retention](https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview) (~30 days).

Built with .NET 10 and published as a **Native AOT** self-contained executable (~15 MB, no runtime required).

For each resource, the tool answers:

- How many minutes was it **eligible** (expected to be available)?
- How many of those minutes was it **available** (confirmed by Azure Monitor)?
- What is the **availability percentage** (Available ÷ Eligible × 100)?
- How many minutes were **degraded** (availability < 100% or confirmed faults)?

## How it works

### Step 1 — Resource inventory

A single KQL query against the Resource Graph `resources` table returns all VMs, SQL databases (excluding system `master` DBs), and Storage Accounts. Server-side KQL filters are applied when `--kinds` or `--resource` are provided, minimising data transfer.

### Step 2 — Fetch availability metrics

Azure Monitor is queried per-resource in parallel (configurable via `--parallelism`, default auto-scales to CPU cores) with retry on 429/5xx errors. Granularity is PT1M (one data point per minute).

| Resource type | Metrics requested | Native scale | Aggregation |
|---|---|---|---|
| Virtual Machine | `VmAvailabilityMetric` | 0.0–1.0 | Minimum |
| Azure SQL Database | `Availability` | 0–100 → normalised to 0.0–1.0 | Minimum |
| Storage Account | `Availability`, `Transactions` | 0–100 → normalised to 0.0–1.0 | Minimum, Total |

For each data point in the response:

- **Value > 0 and < 100%** → added to `AvailableSum` as a fractional contribution (e.g. 99.5% → 0.995). Counted as a **degraded minute**.
- **Value = 100%** → adds 1.0 to `AvailableSum` (fully available).
- **Value = 0% or null (missing)** → timestamp recorded as a **gap tick** for health verification. These are often caused by Azure Monitor issues rather than real outages.
- **Storage only: Transactions = 0** → counted as `ZeroTxMin` (no availability signal to measure).

### Step 3 — Classify metric gaps via Resource Health, then Activity Log when needed

For every resource that has non-perfect metric minutes (null, 0%, or a positive value below 100%), the tool queries the [Resource Health REST API](https://learn.microsoft.com/en-us/rest/api/resourcehealth/availability-statuses/list?view=rest-resourcehealth-2025-05-01) (`availabilityStatuses`, API version `2025-05-01`) to retrieve the health timeline.

For **supported resource kinds**, if Resource Health still leaves a non-perfect minute unexplained, the tool falls back to the [Activity Log REST API](https://learn.microsoft.com/azure/azure-monitor/platform/rest-activity-log#retrieve-activity-log-data) for the same 30-day window and the exact resource ID. It only looks for lifecycle operations that represent deliberate administrative action:

- **Virtual Machines**
  - `Microsoft.Compute/virtualMachines/start/action`
  - `Microsoft.Compute/virtualMachines/deallocate/action`
  - `Microsoft.Compute/virtualMachines/powerOff/action`
  - `Microsoft.Compute/virtualMachines/restart/action`
- **Azure SQL Databases**
  - `Microsoft.Sql/servers/databases/pause`
  - `Microsoft.Sql/servers/databases/resume`

If one of those operations overlaps the affected minute, that minute is treated as **not a real incident** and is removed from eligibility just like a customer-initiated Resource Health window. A short post-operation grace window is also applied to lifecycle operations that commonly leave trailing transition datapoints after the control-plane event finishes. The grace window is configurable through `--activity-grace-minutes` and defaults to `10` minutes.

The health timeline is converted into **fault intervals** (periods of `Unavailable`/`Degraded`) and **Unknown intervals** (periods where Azure cannot determine health). Each gap tick is classified according to its type:

**Null metric gaps** (metric absent — VM off, telemetry gap, etc.):

- In a fault interval → **fault minute**: stays in eligible, contributes 0 to available. Added to `DegradedMinutes`.
- In a customer-initiated interval → **healthy gap**: subtracted from eligible (deliberate stop/deallocate/restart).
- Outside any fault interval → **healthy gap**: subtracted from eligible (no impact on availability %). For supported kinds, the tool also checks Activity Log so the gap can be explicitly tied to a lifecycle operation when present.

**0% metric gaps** (metric explicitly reported 0% with active transactions):

- In a fault interval → **fault minute**: stays in eligible, contributes 0 to available. Added to `DegradedMinutes`.
- In a customer-initiated interval → **healthy gap**: subtracted from eligible.
- In an Unknown interval → **healthy gap**: subtracted from eligible. The 0% is likely an Azure Monitor artefact during a monitoring outage.
- Outside fault and Unknown intervals → for supported kinds, cross-check Activity Log. If a matching lifecycle operation is found, the minute becomes a **healthy gap** and is subtracted from eligible. Otherwise it is **downtime**: stays in eligible, contributes 0 to available. Added to `DegradedMinutes`.

**Positive degraded metric values** (`0% < value < 100%`):

- In a customer-initiated interval → **customer-excused degraded minute**: subtracted from eligible and removed from `AvailableMinutes`.
- Outside a customer-initiated interval → for supported kinds, cross-check Activity Log. If a matching lifecycle operation is found, the minute is excused exactly like a customer-initiated health interval. Otherwise it is counted normally as degraded availability: stays in eligible, contributes its fractional value to available, and increments `DegradedMinutes`.

States that are **not** considered faults (close any open fault interval):

| Health state | Rationale |
|---|---|
| `Available` | Resource confirmed healthy |
| `Unknown` | Azure cannot determine health — typically says *"unable to determine health due to Azure Monitor issue"*. A monitoring gap, not a confirmed outage. |
| Customer-initiated | Deliberate stop/deallocate/restart — detected via `reasonType`, `context`, or `healthEventCause` fields |

Customer-initiated Resource Health events are detected via multiple API fields for robustness:
- `reasonType`: `"Customer Initiated"` or `"User Initiated"`
- `context`: `"Customer Initiated"`
- `healthEventCause`: `"UserInitiated"`

If the Resource Health API call fails for a resource, all its gaps are conservatively treated as faults (no potential downtime is hidden). If Resource Health succeeds but the Activity Log call fails for a supported kind, the tool keeps the Resource Health decision only: unexplained 0% minutes remain downtime, unexplained degraded datapoints remain degraded, and null gaps remain non-downtime.

### Step 4 — Assemble results

```
EligibleMinutes  = TotalMinutes − HealthyGapMinutes − CustomerExcusedDegradedMinutes − ZeroTxMinutes
AvailableMinutes = Σ non-gap metric values (each 0.0–1.0) − CustomerExcusedDegradedAvailableSum
DegradedMinutes  = metric minutes < 100% (non-zero, non-null, not customer-excused) + fault-confirmed gap minutes + trusted 0% downtimes
AvailabilityPct  = AvailableMinutes / EligibleMinutes × 100
```

- **Fault gap minutes** (null or 0% in fault intervals, or 0% outside fault/Unknown/customer intervals) remain in `EligibleMinutes` and contribute 0 to `AvailableMinutes`, reducing the percentage.
- **Healthy gap minutes** (null metrics outside faults, or 0% metrics during `Unknown`, customer-initiated, or matched Activity Log lifecycle windows) are removed from `EligibleMinutes`, so they don't affect the percentage.
- **Customer-excused degraded minutes** (positive degraded datapoints during customer-initiated health windows or matched Activity Log lifecycle windows) are removed from both `EligibleMinutes` and `AvailableMinutes`, so deliberate stop/start transitions do not distort the percentage.
- **Zero-transaction storage minutes** are removed from `EligibleMinutes` (no availability signal when there are no transactions).
- **DegradedMinutes** consolidates metric-level degradation that remains eligible (non-zero values below 100%) and all gap minutes counted as downtime (fault-confirmed or trusted 0%).
- Resources with zero eligible minutes show `N/A`.
- If a resource produces no numeric availability datapoints across the whole 30-day window, it is excluded from availability calculations by setting `EligibleMinutes = 0` and `AvailableMinutes = 0`.

### Worked example

Consider a VM over a 30-day window (43,200 total minutes):

| Category | Minutes | Effect |
|---|---:|---|
| Metric = 1.0 (fully available) | 40,000 | +40,000 to AvailableSum |
| Metric = 0.7 (degraded) | 100 | +70 to AvailableSum, +100 DegradedMins |
| Metric = 0.8 during customer restart | 5 | Subtracted from eligible, remove 4 from AvailableSum |
| Metric = null — fault confirmed (Unavailable/Degraded) | 10 | +0 to available, stays in eligible, +10 DegradedMins |
| Metric = 0% — fault or no health explanation | 10 | +0 to available, stays in eligible, +10 DegradedMins |
| Metric = null — no fault (Available/Unknown/customer) | 3,070 | Subtracted from eligible |
| Metric = 0% — during Unknown or customer health window | 10 | Subtracted from eligible |

```
EligibleMinutes  = 43,200 − 3,070 − 10 − 5 = 40,115
AvailableMinutes = 40,000 + 70 − 4 = 40,066
DegradedMinutes  = 100 + 10 + 10 = 120
AvailabilityPct  = 40,066 / 40,115 × 100 = 99.87785%
```

### Storage Account — transaction-based eligibility

Storage Account `Availability` is a transaction-success-rate metric — it is only meaningful when there are actual transactions. The tool fetches both `Availability` and `Transactions` in a single API call. For each minute:

- **Transactions > 0 and Availability > 0%:** the Availability value (0–100, normalised to 0.0–1.0) counts toward available minutes. Values below 100% count as degraded.
- **Transactions > 0 and Availability null or 0%:** recorded as a gap tick, checked via Resource Health.
- **Transactions = 0 or null:** subtracted from eligible minutes (no availability signal).

## Parameters

| Option | Short | Default | Description |
|---|---|---|---|
| `--subscriptions` | `-s` | *(required)* | One or more Azure subscription display names |
| `--kinds` | `-k` | `vm sql storage` | Resource kinds to process |
| `--resource` | `-r` | *(all)* | Filter to a single resource name |
| `--parallelism` | `-p` | *(auto)* | Max concurrent API calls (scales to CPU cores) |
| `--activity-grace-minutes` | `-g` | `10` | Post-operation grace window for supported Activity Log lifecycle events |

The reporting window is automatically set to the last 30 days. No date parameter is needed.

## Prerequisites

| Requirement | Detail |
|---|---|
| .NET SDK | 10.0 or later (build from source only) |
| Azure auth | `az login` or any method supported by `DefaultAzureCredential` |

The published binary (`GetAvailability.exe`) requires no .NET runtime — it is a Native AOT self-contained executable.

## Usage

```bash
# Build the Native AOT binary (one-time)
cd csharp/GetAvailability
dotnet publish -c Release -r win-x64   # output in bin/Release/net10.0/win-x64/publish/

# Single subscription
./GetAvailability --subscriptions POSTE-BANCOPOSTA-PRODUZIONE

# Multiple subscriptions
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO POSTE-BANCOPOSTA-PRODUZIONE

# Filter by resource kind
./GetAvailability --subscriptions POSTE-BANCOPOSTA-PRODUZIONE --kinds vm sql

# Single resource
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO --resource spiacomdgs01

# SQL database by displayed server/database name
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO --resource tabfpsql01azne/tabfpsqldb01azne

# Override the Activity Log grace window
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO --resource spocovm01a --activity-grace-minutes 15

# Or run directly without publishing
cd csharp/GetAvailability
dotnet run -- --subscriptions POSTE-BANCOPOSTA-PRODUZIONE
```

## Output

The header line shows the reporting window and total minutes:

```
Period: rolling 30 days (2026-02-16 10:34:00Z -> 2026-03-18 10:34:00Z, 43200 min)
```

Table view:

| SubscriptionName | Name | Kind | Location | Avail% | AvailMin | EligMin | DegradedMins |
|---|---|---|---|---:|---:|---:|---:|
| PRODUZIONE | `sabfpsql01azne/sabfpsqldb01azne` | AzureSqlDatabase | northeurope | 100.00 | 43200 | 43200 | |
| SVILUPPO | `spiacomdgs01` | VirtualMachine | northeurope | 99.48 | 4300 | 4322 | 22 |
| PRODUZIONE | `mystorageacct` | StorageAccount | westeurope | 99.99 | 8540 | 8541 | 1 |

A per-subscription summary is printed grouping numerically-counted resources by Kind + Location with resource count and aggregate availability. Resources excluded as `N/A` are not included in summary math. When multiple subscriptions are processed, a cross-subscription overall summary is printed at the end.

Console output also reports per-resource classification details:

```
  [spocovm01a] metric scan found 38906 gap min (null/0% availability values)
  [spocovm01a] checked against Resource Health: 38787 gap min explained as no-fault / Unknown / customer-initiated, 0 confirmed as downtime
  [spocovm01a] checked 119 still-unexplained gap min against Activity Log: 119 explained by admin lifecycle events
  [spocovm01a] eligible min = 43200 - 38787 gap min excluded by Resource Health - 119 gap min excluded by Activity Log = 4294
  [trepomndgw01a] 64 degraded metric min excluded from eligibility (customer-admin lifecycle explanation)
```

## Architecture notes

- **Single metric API call per resource.** Storage Accounts fetch 2 metrics (availability + transactions) in one call. VMs and SQL DBs fetch 1 metric each.
- **Activity Log fallback for supported lifecycle-driven resources.** Resource Health remains the primary classifier. Virtual Machines use `start`, `deallocate`, `powerOff`, and `restart`; Azure SQL Databases use `pause` and `resume`.
- **Any non-perfect minute can be customer-excused.** Nulls, 0% datapoints, and positive degraded datapoints are excluded from eligibility when Resource Health marks the interval as customer/user initiated.
- **0% = gap with nuance.** Metric values of exactly 0% are routed through Resource Health rather than blindly counted as outages. During `Unknown` or customer-initiated health windows they are treated as non-downtime (subtracted from eligible). For supported kinds, unresolved 0% minutes get one more chance through Activity Log. Only if both sources fail to explain them are they treated as real downtime.
- **Unknown ≠ fault.** Resource Health `Unknown` state (typically *"unable to determine health due to Azure Monitor issue"*) does not open a fault interval. Only `Unavailable` and `Degraded` count as faults.
- **Customer/admin-initiated awareness.** Resource Health events with `context: "Customer Initiated"`, `reasonType: "Customer Initiated"` / `"User Initiated"`, or `healthEventCause: "UserInitiated"` create customer intervals. For supported kinds, Activity Log lifecycle operations create the same effect for unresolved minutes. Any availability metric minute below 100% inside those windows is excluded from availability math.
- **Configurable grace for transition tails.** `--activity-grace-minutes` defaults to `10` and extends lifecycle-operation intervals that are known to leave trailing anomalous datapoints after the control-plane operation finishes.
- **Conservative on failure.** If a Resource Health API call fails, gaps are treated as faults to avoid hiding potential downtime.
- **Transaction-aware storage.** Zero-transaction minutes are excluded from eligibility rather than counted as unavailable, giving an accurate picture of actual storage service availability.
- **Whole-window no-signal exclusion.** If a resource produces no numeric availability datapoints across the full period, it is excluded from availability calculations and shown as `N/A`.
- **`Parallel.ForEachAsync`** for concurrent metric and health queries with configurable parallelism.
- **Ticks-based metric keying** (`long` instead of `DateTime`) — zero-allocation per data point.
- **Rolling 30-day window.** The reporting period is always the last 30 days, matching the Resource Health API retention. No date parameter is needed.
- **Native AOT** — ~15 MB standalone binary, no .NET runtime required.
