# Get-Availability

Reports month-scoped availability for Azure Virtual Machines, Azure SQL Databases, and Azure Storage Accounts across one or more Azure subscriptions.

The observation window is selected with `--month YYYYMM` in UTC:

- past months use the full calendar month
- the current month is reported month-to-date
- the requested month cannot start more than 90 days before now

Metrics and Activity Log can support that 90-day lookback. Health History is still only applied to the overlap with its current [retention window](https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview) (about 30 days).

Built with .NET 10 and published as a **Native AOT** self-contained executable (~15 MB, no runtime required).

For each resource, the tool answers:

- How many minutes was it **eligible** (expected to be available)?
- How many of those minutes was it **available** (confirmed by Azure Monitor)?
- What is the **availability percentage** (Available ÷ Eligible × 100)?
- How many suspect minutes were **confirmed as downtime by Resource Health**?
- How many suspect minutes remained **unexplained** after all resolution attempts?

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

- **Value = 100%** → adds `1.0` to `AvailableSum` (fully available).
- **Value > 0 and < 100%** → added to `AvailableSum` as a fractional contribution (for example `99.5% → 0.995`) and recorded as a **positive degraded suspect minute**.
- **Value = 0%** → recorded as a **0%-valued suspect minute**.
- **Value = null (missing)** → recorded as a **null suspect minute**.
- **Storage only: Transactions = 0** → counted as `ZeroTxMin` (no availability signal to measure).

Any minute with `null` or a value below `100%` is a **suspect minute**. Contiguous suspect minutes form a **suspect gap**.

### Step 3 — Investigate suspect gaps via Activity Log, then Health History when available

For every resource that has suspect minutes (`null`, `0%`, or a positive value below `100%`), the tool builds suspect gaps and investigates each suspect minute with the following precedence:

1. **Activity Log first** for supported lifecycle operations.
2. **Health History second** for the overlap with the current [Resource Health retention window](https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview) (about 30 days).
3. **Fallback rules** for any suspect minute that still remains unresolved.

For supported resource kinds, the tool first queries the [Activity Log REST API](https://learn.microsoft.com/azure/azure-monitor/platform/rest-activity-log#retrieve-activity-log-data) for the same observation window and the exact resource ID. It only looks for lifecycle operations that represent deliberate administrative action:

- **Virtual Machines**
  - `Microsoft.Compute/virtualMachines/start/action`
  - `Microsoft.Compute/virtualMachines/deallocate/action`
  - `Microsoft.Compute/virtualMachines/powerOff/action`
  - `Microsoft.Compute/virtualMachines/restart/action`
- **Azure SQL Databases**
  - `Microsoft.Sql/servers/databases/pause`
  - `Microsoft.Sql/servers/databases/resume`

If one of those operations overlaps the affected minute, that minute is treated as **customer/admin lifecycle activity** and is removed from eligibility unless Health History later confirms that the same minute was actually a platform fault. A short post-operation grace window is also applied to lifecycle operations that commonly leave trailing transition datapoints after the control-plane event finishes. The grace window is configurable through `--activity-grace-minutes` and defaults to `10` minutes.

For the part of the observation window still covered by Resource Health retention, the tool then queries the [Resource Health REST API](https://learn.microsoft.com/en-us/rest/api/resourcehealth/availability-statuses/list?view=rest-resourcehealth-2025-05-01) (`availabilityStatuses`, API version `2025-05-01`) and converts the result into:

- **fault intervals** (`Unavailable` / `Degraded`)
- **Unknown intervals** (Azure cannot determine health, typically monitoring issues)
- **customer-initiated intervals**

Classification rules are then applied minute-by-minute inside each suspect gap:

- **Platform fault wins.** If Health History says the minute is in a fault interval, it stays eligible and counts against availability even if Activity Log also shows a lifecycle event.
- **Activity Log lifecycle match** → excluded from eligibility.
- **Health History `Unknown` or customer-initiated**:
  - valid explanation for `null` and `0%` suspect minutes, so they are excluded from eligibility
  - valid explanation for positive degraded datapoints only when Health History says customer-initiated
- **Remaining `null` suspect minute** → treated as a metric issue and excluded from eligibility.
- **Remaining `0%` suspect minute** → treated as downtime and kept in eligibility.
- **Remaining `0% < value < 100%` suspect minute** → trusted as degraded availability and kept in eligibility.

This distinction is deliberate:

- unresolved `null` usually means missing telemetry, so it does not count as downtime
- unresolved `0%` is still an explicit metric value, so it is treated as downtime

If the requested month extends beyond the current Health History retention, only the retained overlap uses Health History. Older suspect minutes fall back directly to Activity Log and the metric-based rules above.


States that are **not** considered platform faults (close any open fault interval):

| Health state | Rationale |
|---|---|
| `Available` | Resource confirmed healthy |
| `Unknown` | Azure cannot determine health — typically says *"unable to determine health due to Azure Monitor issue"*. A monitoring gap, not a confirmed outage. |
| Customer-initiated | Deliberate stop/deallocate/restart — detected via `reasonType`, `context`, or `healthEventCause` fields |

Customer-initiated Resource Health events are detected via multiple API fields for robustness:
- `reasonType`: `"Customer Initiated"` or `"User Initiated"`
- `context`: `"Customer Initiated"`
- `healthEventCause`: `"UserInitiated"`

If the Resource Health API call fails for a resource while Health History should have been available, the tool is conservative and does **not** excuse suspect gap minutes through Health History. Activity Log matches still apply, and all remaining minutes fall back directly to the metric-based rules above. If the Activity Log call fails, the tool continues with Health History plus the fallback rules.

### Step 4 — Assemble results

```
EligibleMinutes  = TotalMinutes − ActivityLogExcludedGapMinutes − HealthExplainedGapMinutes − MetricIssueNullMinutes − CustomerExcusedDegradedMinutes − ZeroTxMinutes
AvailableMinutes = Σ metric values above 0% (each 0.0–1.0) − CustomerExcusedDegradedAvailableSum
ConfirmedDowntimeMinutes = PlatformFaultGapMinutes + HealthConfirmedDegradedMinutes
UnexplainedMinutes = UnresolvedZeroDowntimeMinutes + RemainingPositiveDegradedMinutes
AvailabilityPct  = AvailableMinutes / EligibleMinutes × 100
```

- **Activity-explained gap minutes** are removed from `EligibleMinutes`.
- **Health-explained gap minutes** (`Unknown` or customer-initiated) are removed from `EligibleMinutes`.
- **Metric-issue null minutes** are removed from `EligibleMinutes`.
- **Platform-fault gap minutes** remain in `EligibleMinutes` and contribute `0` to `AvailableMinutes`.
- **Unresolved 0% gap minutes** remain in `EligibleMinutes` and contribute `0` to `AvailableMinutes`.
- **Customer-excused degraded minutes** are removed from both `EligibleMinutes` and `AvailableMinutes`.
- **Zero-transaction storage minutes** are removed from `EligibleMinutes` (no availability signal when there are no transactions).
- **ConfirmedDowntimeMinutes** counts suspect minutes that Resource Health explicitly confirms as platform issues.
- **UnexplainedMinutes** counts suspect minutes that still reduce confidence in the availability result after fallback classification, specifically unresolved `0%` minutes and remaining positive degraded datapoints.
- Resources with zero eligible minutes show `N/A`.
- If the metric API returns no usable datapoints at all across the full period, the resource is excluded from availability calculations by setting `EligibleMinutes = 0` and `AvailableMinutes = 0`.

### Worked example

Consider a 30-day month for a VM (43,200 total minutes):

| Category | Minutes | Effect |
|---|---:|---|
| Metric = 1.0 (fully available) | 40,000 | +40,000 to AvailableSum |
| Metric = 0.7 (degraded, unexplained) | 100 | +70 to AvailableSum, +100 UnexplainedMins |
| Metric = 0.8 during restart lifecycle event | 5 | Subtracted from eligible, remove 4 from AvailableSum |
| Metric = null — explained by Activity Log | 40 | Subtracted from eligible |
| Metric = null — explained by Health `Unknown` | 3,000 | Subtracted from eligible |
| Metric = null — unresolved metric issue | 30 | Subtracted from eligible |
| Metric = 0% — fault confirmed | 10 | +0 to available, stays in eligible, +10 ConfirmedDowntimeMins |
| Metric = 0% — unresolved | 10 | +0 to available, stays in eligible, +10 UnexplainedMins |

```
EligibleMinutes  = 43,200 − 40 − 3,000 − 30 − 5 = 40,125
AvailableMinutes = 40,000 + 70 − 4 = 40,066
ConfirmedDowntimeMinutes = 10
UnexplainedMinutes = 100 + 10 = 110
AvailabilityPct  = 40,066 / 40,125 × 100 = 99.85390%
```

### Storage Account — transaction-based eligibility

Storage Account `Availability` is a transaction-success-rate metric — it is only meaningful when there are actual transactions. The tool fetches both `Availability` and `Transactions` in a single API call. For each minute:

- **Transactions > 0 and Availability > 0%:** the Availability value (0–100, normalised to 0.0–1.0) counts toward available minutes. Values below 100% count as degraded.
- **Transactions > 0 and Availability null or 0%:** recorded as suspect minutes and investigated with the same Activity Log / Health History / fallback sequence.
- **Transactions = 0 or null:** subtracted from eligible minutes (no availability signal).

## Parameters

| Option | Short | Default | Description |
|---|---|---|---|
| `--subscriptions` | `-s` | *(required)* | One or more Azure subscription display names |
| `--month` | `-m` | *(required)* | Observation month in UTC using format `YYYYMM` |
| `--kinds` | `-k` | `vm sql storage` | Resource kinds to process |
| `--resource` | `-r` | *(all)* | Filter to a single resource name |
| `--parallelism` | `-p` | *(auto)* | Max concurrent API calls (scales to CPU cores) |
| `--activity-grace-minutes` | `-g` | `10` | Post-operation grace window for supported Activity Log lifecycle events |

`--month` cannot point to a month whose first day is more than 90 days before the current UTC time.

## Prerequisites

| Requirement | Detail |
|---|---|
| .NET SDK | 10.0 or later (build from source only) |
| Azure auth | `az login` or any method supported by `DefaultAzureCredential` |

The published binary (`GetAvailability.exe`) requires no .NET runtime — it is a Native AOT self-contained executable.

If Azure authentication fails, the tool prints the SDK exception message directly. For Azure CLI-based auth, re-run `az login` and retry if the message indicates the cached login is no longer valid.

## Usage

```bash
# Build the Native AOT binary (one-time)
cd csharp/GetAvailability
dotnet publish -c Release -r win-x64   # output in bin/Release/net10.0/win-x64/publish/

# Single subscription
./GetAvailability --subscriptions POSTE-BANCOPOSTA-PRODUZIONE --month 202603

# Multiple subscriptions
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO POSTE-BANCOPOSTA-PRODUZIONE --month 202603

# Filter by resource kind
./GetAvailability --subscriptions POSTE-BANCOPOSTA-PRODUZIONE --month 202603 --kinds vm sql

# Single resource
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO --month 202603 --resource spiacomdgs01

# SQL database by displayed server/database name
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO --month 202603 --resource tabfpsql01azne/tabfpsqldb01azne

# Override the Activity Log grace window
./GetAvailability --subscriptions POSTE-BANCOPOSTA-SVILUPPO --month 202603 --resource spocovm01a --activity-grace-minutes 15

# Or run directly without publishing
cd csharp/GetAvailability
dotnet run -- --subscriptions POSTE-BANCOPOSTA-PRODUZIONE --month 202603
```

## Output

The header line shows the observation window and total minutes:

```
Period: month 202602 (2026-02-01 00:00:00Z -> 2026-03-01 00:00:00Z, 40320 min)
```

If the requested month is only partially covered by the current Resource Health retention window, the tool prints an explicit warning immediately after the period line:

```
WARNING: Resource Health history covers only part of this period (2026-02-16 18:54:00Z -> 2026-03-01 00:00:00Z, 17586 of 40320 min). Earlier minutes will use Activity Log and metric fallback rules.
```

If none of the observation window is covered by retained Resource Health history, the tool instead prints:

```
WARNING: Resource Health history does not cover this period. All suspect minutes will use Activity Log and metric fallback rules.
```

Table view:

| SubscriptionName | Name | Kind | Location | Avail% | AvailMin | EligMin | ConfirmedDownMin | UnexplainedMin |
|---|---|---|---|---:|---:|---:|---:|---:|
| PRODUZIONE | `pabfpsql01azwe/pabfpsqldb01azwe` | AzureSqlDatabase | westeurope | 100.00000 | 40320 | 40320 | | |
| SVILUPPO | `trepomndgw01a` | VirtualMachine | northeurope | 100.00000 | 14369 | 14369 | | |
| PRODUZIONE | `pcesopcachefosa01azwe` | StorageAccount | westeurope | 99.97520 | 40306 | 40316 | | 10 |

A per-subscription summary is printed grouping numerically-counted resources by Kind + Location with resource count and aggregate availability. Resources excluded as `N/A` are not included in summary math. When multiple subscriptions are processed, a cross-subscription overall summary is printed at the end.

Console output also reports per-resource classification details:

```
  [tabfpsql01azne/tabfpsqldb01azne] metric scan found 23 suspect min across 22 suspect gaps (null or <100% availability values)
  [tabfpsql01azne/tabfpsqldb01azne] checked against Activity Log: 23 suspect min explained by admin lifecycle events
  [tabfpsql01azne/tabfpsqldb01azne] eligible min = 40320 - 23 gap min excluded by Activity Log = 40297
```

## Architecture notes

- **Single metric API call per resource.** Storage Accounts fetch 2 metrics (availability + transactions) in one call. VMs and SQL DBs fetch 1 metric each.
- **Activity Log first, Health History second.** Supported lifecycle operations are checked first, but Health History platform faults still win if both overlap the same suspect minute.
- **Suspect gaps are only a narration layer.** Investigation still happens minute-by-minute inside each suspect gap, so mixed-cause gaps are handled correctly.
- **Unresolved `null` and unresolved `0%` are not treated the same.** Remaining `null` minutes are metric issues and excluded from eligibility; remaining `0%` minutes are trusted as downtime.
- **Unknown ≠ fault.** Resource Health `Unknown` state (typically *"unable to determine health due to Azure Monitor issue"*) does not open a fault interval. It only excuses `null` and `0%` suspect minutes.
- **Customer/admin-initiated awareness.** Resource Health events with `context: "Customer Initiated"`, `reasonType: "Customer Initiated"` / `"User Initiated"`, or `healthEventCause: "UserInitiated"` create customer intervals. For supported kinds, Activity Log lifecycle operations create the same effect. Positive degraded datapoints inside those windows are excluded from availability math.
- **Configurable grace for transition tails.** `--activity-grace-minutes` defaults to `10` and extends lifecycle-operation intervals that are known to leave trailing anomalous datapoints after the control-plane operation finishes.
- **Month-based observation period.** The tool now accepts `--month YYYYMM` and can inspect months whose first day is within the last 90 days.
- **Explicit Health History coverage warnings.** When the requested month is only partially or not at all covered by retained Resource Health history, the report header says so and clarifies that older suspect minutes fall back to Activity Log plus metric-based rules.
- **Conservative on failure.** If a Resource Health API call fails for a period where Health History should exist, Activity Log matches still apply, but no remaining suspect minutes are excused through Health History.
- **Transaction-aware storage.** Zero-transaction minutes are excluded from eligibility rather than counted as unavailable, giving an accurate picture of actual storage service availability.
- **Whole-window no-signal exclusion.** If the metric API returns no usable datapoints across the full period, the resource is excluded from availability calculations and shown as `N/A`.
- **`Parallel.ForEachAsync`** for concurrent metric and health queries with configurable parallelism.
- **Ticks-based metric keying** (`long` instead of `DateTime`) — zero-allocation per data point.
- **Health History retention remains independent.** The observation month can extend beyond 30 days of retained Health History; only the retained overlap is checked there.
- **Native AOT** — ~15 MB standalone binary, no .NET runtime required.
