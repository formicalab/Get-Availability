# Get-Availability

[![CI](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml)
[![Release](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml)

Reports month-scoped availability for Azure Virtual Machines, Azure SQL Databases, Azure Storage Accounts, and Azure Web Apps across one or more Azure subscriptions.

Two implementations are provided:

| Version | Path | Runtime | Notes |
|---|---|---|---|
| **C#** | [`csharp/`](csharp/README.md) | .NET 10 Native AOT (~15 MB standalone binary, no runtime required) | Fastest; recommended for production use |
| **PowerShell** | `get-availability.ps1` | PowerShell 7+ with `Az.Accounts` and `Az.ResourceGraph` modules | No build step; convenient for ad-hoc use; supports Log Analytics ingestion |

Both versions share the same pipeline, classification rules, output format, and invariants.

For each resource, the tool answers:

- How many minutes had **suspect** availability (metric below 100% or null)?
- Of those, how many were **confirmed as platform faults** by Resource Health?
- How many were **excused** as normal operations (lifecycle activity, customer-initiated, metric issues)?
- How many remain **unresolved** after all classification attempts?
- What is the **availability percentage** (Available ÷ Eligible × 100)?

The relationship `Suspect = Faults + Excused + Unresolved` always holds.

## Usage

### Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 7.0 or later (`pwsh`) |
| Az.Accounts | `Install-Module Az.Accounts` |
| Az.ResourceGraph | `Install-Module Az.ResourceGraph` |
| Azure auth | `Connect-AzAccount` (used by both Az modules and for ARM token acquisition) |

If Azure authentication fails, the tool prints the module exception message directly. Re-run `Connect-AzAccount` to fix.

For the C# version prerequisites and usage, see the [C# README](csharp/README.md).

### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Subscriptions` | *(required)* | One or more Azure subscription display names |
| `-Month` | *(required)* | Observation month in UTC, format `YYYYMM` |
| `-Kinds` | `vm,sql,storage,webapp` | Resource kinds to process |
| `-Resource` | *(all)* | Filter to a single resource name |
| `-Parallelism` | *(auto)* | Max concurrent API calls (scales to CPU cores, 4–16) |
| `-ActivityGraceMinutes` | `10` | Post-operation grace window for Activity Log lifecycle events |
| `-Batch` | off | Use the regional Metrics Batch API instead of per-resource calls |
| `-BatchSize` | `10` | Max resources per batch call (1–50); implies `-Batch` |
| `-Workspace` | *(none)* | Log Analytics workspace ID (GUID). Fetches Activity Log lifecycle events from the workspace via a single bulk KQL query (faster for large estates). Resource Health uses a hybrid approach: KQL transitions cover the period beyond the REST API's ~30-day retention, while REST API transitions (curated, with corrected causes) are authoritative for the last ~30 days. Provides complete Resource Health coverage across the full observation window. |
| `-DceEndpoint` | *(none)* | Data Collection Endpoint ingestion URL. When provided together with `-DcrImmutableId`, results are sent to Log Analytics custom tables via the Azure Monitor Ingestion API. |
| `-DcrImmutableId` | *(none)* | Data Collection Rule immutable ID. Required together with `-DceEndpoint` to enable Log Analytics ingestion. |
| `-Version` | | Print version and exit |

For C# parameters, see the [C# README](csharp/README.md).

The observation window is a UTC calendar month: past months use the full calendar month, the current month is reported month-to-date. The requested month cannot start more than 90 days before the current UTC time. Metrics and Activity Log support that 90-day lookback; Health History is applied only for its overlap with the ~30-day REST API retention window. When `-Workspace` / `--workspace` is used, Health History coverage extends to the full observation period via a hybrid approach (Log Analytics for older transitions + REST API for the last ~30 days).

### Examples

```powershell
# Single subscription
./get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603

# Multiple subscriptions, filtered by kind
./get-availability.ps1 -Subscriptions 'Contoso-Development','Contoso-Production' -Month 202603 -Kinds vm,sql

# Single resource with custom grace window
./get-availability.ps1 -Subscriptions 'Contoso-Development' -Month 202603 -Resource myvm02 -ActivityGraceMinutes 15

# Batch API with custom batch size
./get-availability.ps1 -Subscriptions 'Contoso-Production','Contoso-Development' -Month 202603 -BatchSize 20

# Use Log Analytics for Activity Log + Resource Health (faster, extended retention)
./get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 -Workspace 'b233a4b7-3c43-433c-ac60-1f6ff217ddd4'

# Send results to Log Analytics custom tables
./get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 `
  -DceEndpoint 'https://dce-getavail-itn-001.italynorth-1.ingest.monitor.azure.com' `
  -DcrImmutableId 'dcr-00000000000000000000000000000000'

# Pipe results to CSV
./get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 | Export-Csv availability.csv
```

For C# examples, see the [C# README](csharp/README.md).

### Output

The header line shows the observation window and total minutes:

```
Period: month 202602 (2026-02-01 00:00:00Z -> 2026-03-01 00:00:00Z, 40320 min)
```

If the observation window extends beyond the Resource Health retention window, an explicit warning is printed:

```
WARNING: Resource Health history covers only part of this period (2026-02-16 18:54:00Z -> 2026-03-01 00:00:00Z, 17586 of 40320 min). Earlier minutes will use Activity Log and metric fallback rules.
```

When `-Workspace` is used, the 30-day warning is suppressed (hybrid coverage applies) and an informational line is printed:

```
Log Analytics workspace: b233a4b7-…-1f6ff217ddd4 (Activity Log via KQL, Resource Health via KQL + REST API hybrid)
```

Table view (Kind is abbreviated: VM, SQL, Storage, Web):

| Subscription | Name | Kind | Location | Suspect | Faults | Excused | Unresolved | AvailMin | EligMin | Avail% |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| Production | `sqlserver02/sqldb02` | SQL | westeurope | | | | | 40320 | 40320 | 100.00000 |
| Development | `devvm01a` | VM | northeurope | 23 | | 23 | | 14369 | 14369 | 100.00000 |
| Production | `storageaccount01` | Storage | westeurope | 14 | | 4 | 10 | 40306 | 40316 | 99.97520 |

Columns with value 0 are shown as blank. Resources with zero eligible minutes show `N/A`. A per-subscription summary is printed at the end, grouping resources by Kind + Location with aggregate availability. When multiple subscriptions are processed, a cross-subscription overall summary follows.

Per-resource classification narration is also printed on the console:

```
  [sqlserver01/sqldb01] metric scan found 23 suspect min across 22 suspect gaps (null or <100% availability values)
  [sqlserver01/sqldb01] checked against Activity Log: 23 suspect min explained by admin lifecycle events
  [sqlserver01/sqldb01] eligible min = 40320 - 23 gap min excluded by Activity Log = 40297
```

The PowerShell version also emits result objects to the pipeline, so output can be piped to `Export-Csv`, `ConvertTo-Json`, or further filtered.

## How it works

### Resource inventory

A KQL query against the Resource Graph `resources` table returns all matching VMs, SQL databases (excluding system `master` DBs), Storage Accounts, and Web Apps (excluding Function Apps). Server-side filters are applied when `--kinds` or `--resource` are provided.

### Metric collection

Azure Monitor is queried at PT1M granularity (one data point per minute) with retry on 429/5xx errors. Two modes are available:

- **Per-resource** (default): parallel ARM Metrics API calls, one per resource, with configurable parallelism.
- **Batch** (`--batch`): the regional [Azure Monitor Metrics Batch API](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/migrate-to-batch-api). Resources are grouped by (subscription, region, kind) and sent in configurable chunks (`--batch-size`, default 10, max 50). The batch endpoint uses a separate token scope (`https://metrics.monitor.azure.com`) and each regional endpoint is validated before fetching. Wave-based processing with GC between waves bounds memory usage.

| Resource type | Metrics | Native scale | Aggregation |
|---|---|---|---|
| Virtual Machine | `VmAvailabilityMetric` | 0.0–1.0 | Minimum |
| Azure SQL Database | `Availability` | 0–100 → normalised to 0.0–1.0 | Minimum |
| Storage Account | `Availability`, `Transactions` | 0–100 → normalised to 0.0–1.0 | Minimum, Total |
| Web App | `MemoryWorkingSet` | bytes (binary: >0 = available, 0 = stopped, null = suspect) | Average |

Each data point is classified as follows:

| Data point | Treatment |
|---|---|
| Value = 100% | Adds `1.0` to `AvailableSum` (fully available) |
| 0% < value < 100% | Fractional contribution to `AvailableSum`; recorded as a **degraded suspect minute** |
| Value = 0% | Recorded as a **0%-valued suspect minute** |
| Value = null | Recorded as a **null suspect minute** |
| Storage: Transactions = 0 | No availability signal — counted as both suspect and excused, excluded from eligibility |
| Web App: MemoryWorkingSet > 0 | App process is alive — adds `1.0` to `AvailableSum` (fully available) |
| Web App: MemoryWorkingSet = 0 | App process is stopped — recorded as a **0%-valued suspect minute** |
| Web App: MemoryWorkingSet = null | Platform cannot collect data — recorded as a **null suspect minute** |

Any minute with `null` or a value below `100%` is a **suspect minute**. Contiguous suspect minutes form a **suspect gap** (used for narration only — investigation is always minute-by-minute).

### Suspect gap investigation

For every resource with suspect minutes, the tool investigates each minute with the following precedence:

**1. Activity Log** — Lifecycle operations representing deliberate administrative action are checked:

- **All kinds**: resource creation (`*/write`) and deletion (`*/delete`) — minutes when the resource did not exist are excused (before first creation, between delete→recreate cycles, after final deletion)
- **VMs**: `start/action`, `deallocate/action`, `powerOff/action`, `restart/action`
- **SQL DBs**: `pause`, `resume`
- **Web Apps**: `stop/action`, `start/action`, `restart/action`

Matching minutes are treated as customer/admin lifecycle activity and removed from eligibility. A configurable grace window (`--activity-grace-minutes`, default 10) extends these intervals to cover trailing transition datapoints.

**2. Health History** — Resource Health transitions are converted into three interval types (below). Two data source modes are supported:

- **REST API only** (default, no `-Workspace`): The [Activity Log REST API](https://learn.microsoft.com/azure/azure-monitor/platform/rest-activity-log#retrieve-activity-log-data) and the [Resource Health REST API](https://learn.microsoft.com/en-us/rest/api/resourcehealth/availability-statuses/list?view=rest-resourcehealth-2025-05-01) (`availabilityStatuses`, API version `2025-05-01`) are queried per-resource. Resource Health API has a ~30-day retention limit.
- **Hybrid: Log Analytics + REST API** (`-Workspace` / `--workspace`): A single bulk KQL query against the `AzureActivity` table fetches Activity Log lifecycle events and Resource Health transitions for all resources at once (faster for large estates: 1 query vs. thousands of REST calls). Resource Health transitions older than the REST API's ~30-day retention cutoff come from Log Analytics (workspace retention, typically 365 days). For the last ~30 days, the REST API is always queried and its transitions take precedence — REST data is authoritative because it provides curated synthetic entries that fill coverage gaps between health incidents and retroactively corrects cause classification. The two sources are merged chronologically to form a complete health timeline. Requires the target subscriptions to have diagnostic settings sending Activity Log data to the specified workspace.

Health transition interval types:

- **Fault** (`Unavailable` / `Degraded`) — confirmed platform issues
- **Unknown** — Azure cannot determine health (typically a monitoring gap, not an outage)
- **Customer-initiated** — detected via `reasonType` (`"Customer Initiated"` / `"User Initiated"`), `context` (`"Customer Initiated"`), or `healthEventCause` (`"UserInitiated"`)

**3. Minute-by-minute classification** — Each suspect minute is classified with strict precedence:

| Condition | Effect |
|---|---|
| Health History: fault interval | Stays eligible, counts as downtime (platform fault wins even if Activity Log also matches) |
| Activity Log: lifecycle match | Excluded from eligibility |
| Health History: Unknown or customer-initiated | Excluded from eligibility (for degraded minutes, only customer-initiated excuses) |
| Remaining null | Metric issue — excluded from eligibility (missing telemetry ≠ downtime) |
| Remaining 0% | Trusted as downtime — stays eligible (explicit metric value) |
| Remaining degraded (0% < v < 100%) | Trusted as degraded availability — stays eligible |

**Conservative on failure:** if a Resource Health API call fails, Activity Log matches still apply but no remaining minutes are excused through Health History. If the Activity Log call fails, Health History plus fallback rules still apply.

### Result assembly

```
EligibleMinutes  = TotalMinutes − ExcusedMinutes
ExcusedMinutes   = ActivityLogExcluded + HealthExplained + MetricIssueNulls + CustomerExcusedDegraded + ZeroTxMinutes
AvailableMinutes = Σ metric values above 0% (each 0.0–1.0) − CustomerExcusedDegradedAvailableSum
FaultMinutes     = PlatformFaultGap + HealthConfirmedDegraded
UnresolvedMinutes = UnresolvedZeroDowntime + RemainingPositiveDegraded
AvailabilityPct  = AvailableMinutes / EligibleMinutes × 100
```

If the metric API returns no usable datapoints across the full period, the resource is excluded from availability calculations and shown as `N/A`.

### Worked example

A 30-day month for a VM (43,200 total minutes):

| Category | Minutes | Effect |
|---|---:|---|
| Metric = 1.0 (fully available) | 40,000 | +40,000 to AvailableSum |
| Metric = 0.7 (degraded, unexplained) | 100 | +70 to AvailableSum, +100 Unresolved |
| Metric = 0.8 during restart lifecycle | 5 | +5 Excused, remove 4 from AvailableSum |
| Metric = null — Activity Log match | 40 | +40 Excused |
| Metric = null — Health `Unknown` | 3,000 | +3,000 Excused |
| Metric = null — unresolved | 30 | +30 Excused (metric issue) |
| Metric = 0% — fault confirmed | 10 | +10 Faults, stays eligible |
| Metric = 0% — unresolved | 10 | +10 Unresolved, stays eligible |

```
SuspectMinutes   = (40 + 3,000 + 30 + 10 + 10) + (100 + 5) = 3,195
FaultMinutes     = 10
ExcusedMinutes   = 40 + 3,000 + 30 + 5 = 3,075
UnresolvedMinutes = 100 + 10 = 110
  check: 10 + 3,075 + 110 = 3,195 ✓

EligibleMinutes  = 43,200 − 3,075 = 40,125
AvailableMinutes = 40,000 + 70 − 4 = 40,066
AvailabilityPct  = 40,066 / 40,125 × 100 = 99.85390%
```

## Implementation notes

These notes cover performance and implementation details specific to the PowerShell version. For C# implementation notes, see the [C# README](csharp/README.md).

- **`ForEach-Object -Parallel`** for concurrent metric, Activity Log, and Resource Health queries with configurable parallelism.
- **Shared `HttpClient`** with connection pooling — avoids per-request TCP/TLS overhead; streams JSON responses directly into `System.Text.Json` without intermediate string allocation. Used for both per-resource metrics and gap investigation paths.
- **Compiled metric processor** — the ~44k-datapoint-per-resource JSON processing loop is compiled as C# via `Add-Type` and runs at native .NET speed.
- **Compiled gap processor** — `ExpandToTickSet` (interval → `HashSet<long>`) and `ClassifyGaps` (minute-by-minute classification) are also compiled via `Add-Type`.
- **Idempotent `Add-Type` guards** — each compiled C# block (`MetricProcessor`, `GapProcessor`) is independently guarded by a `PSTypeName` check so the script can be re-run within the same session.
- **HashSet-based interval containment** — suspect-minute classification pre-expands intervals into `HashSet<long>` tick sets for O(1) lookups instead of linear scans.
- **O(1) JSON property access** — `TryGetProperty` hash lookup instead of `EnumerateObject` linear scan (~44k calls per resource per month).
- **Ticks-based metric keying** — `long` instead of `DateTime` for zero-allocation per data point.
- **`System.Text.Json`** for efficient JSON parsing — avoids large PSObject trees.

## Log Analytics Ingestion (Optional)

When `-DceEndpoint` and `-DcrImmutableId` are provided, the script sends results to two Log Analytics custom tables via the [Azure Monitor Ingestion API](https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview):

| Table | Content |
|---|---|
| `GetAvailResources_CL` | Per-resource detail (one row per resource per run) |
| `GetAvailSummary_CL` | Aggregated summaries (per Kind+Location, per subscription, overall) |

Authentication uses `Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com'`, which works identically for interactive sessions (`Connect-AzAccount`) and Azure Function managed identities. Payloads are gzip-compressed and batched at 900 KB to stay within API limits.

The infrastructure (Log Analytics workspace, custom tables, DCE, DCR) is deployed via the Bicep templates in the [`Setup/`](Setup/README.md) directory.
