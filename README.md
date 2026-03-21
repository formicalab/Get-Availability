# Get-Availability

[![CI](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml)
[![Release](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml)

Reports month-scoped availability for Azure Virtual Machines, Azure SQL Databases, and Azure Storage Accounts across one or more Azure subscriptions.

The observation window is selected with `--month YYYYMM` in UTC:

- past months use the full calendar month
- the current month is reported month-to-date
- the requested month cannot start more than 90 days before now

Metrics and Activity Log can support that 90-day lookback. Health History is still only applied to the overlap with its current [retention window](https://learn.microsoft.com/en-us/azure/service-health/resource-health-overview) (about 30 days).

Two equivalent implementations are provided:

| Version | Path | Runtime | Notes |
|---|---|---|---|
| **C#** | `csharp/GetAvailability/` | .NET 10 Native AOT (~15 MB standalone binary, no runtime required) | Fastest; recommended for production use |
| **PowerShell** | `get-availability.ps1` | PowerShell 7+ with `Az.Accounts` and `Az.ResourceGraph` modules | No build step; convenient for ad-hoc use |

Both versions share the same pipeline, classification rules, output format, and invariants.

For each resource, the tool answers:

- How many minutes had **suspect** availability (metric below 100% or null)?
- Of those, how many were **confirmed as platform faults** by Resource Health?
- How many were **excused** as normal operations (lifecycle activity, customer-initiated, metric issues)?
- How many remain **unresolved** after all classification attempts?
- How many minutes was it **available** (confirmed by Azure Monitor)?
- How many minutes was it **eligible** (expected to be available)?
- What is the **availability percentage** (Available ÷ Eligible × 100)?

The relationship `Suspect = Faults + Excused + Unresolved` always holds.

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
SuspectMinutes   = GapMinutes + DegradedMinutes  (total suspect from metric scan)
SuspectMinutes   = GapMinutes + DegradedMinutes + ZeroTxMinutes  (total suspect from metric scan + no-signal storage minutes)
EligibleMinutes  = TotalMinutes − ExcusedMinutes
ExcusedMinutes   = ActivityLogExcludedGapMinutes + HealthExplainedGapMinutes + MetricIssueNullMinutes + CustomerExcusedDegradedMinutes + ZeroTxMinutes
AvailableMinutes = Σ metric values above 0% (each 0.0–1.0) − CustomerExcusedDegradedAvailableSum
FaultMinutes     = PlatformFaultGapMinutes + HealthConfirmedDegradedMinutes
UnresolvedMinutes = UnresolvedZeroDowntimeMinutes + RemainingPositiveDegradedMinutes
AvailabilityPct  = AvailableMinutes / EligibleMinutes × 100
```

The invariant **Suspect = Faults + Excused + Unresolved** always holds.

- **Excused minutes** (lifecycle activity, customer-initiated, Health Unknown, metric-issue nulls, and zero-transaction storage minutes) are removed from `EligibleMinutes`.
- **Platform-fault minutes** remain in `EligibleMinutes` and contribute `0` to `AvailableMinutes`.
- **Unresolved 0% minutes** remain in `EligibleMinutes` and contribute `0` to `AvailableMinutes`.
- **Customer-excused degraded minutes** are removed from both `EligibleMinutes` and `AvailableMinutes`.
- **Zero-transaction storage minutes** count as both suspect and excused — there is no availability signal when there are no transactions, so they cannot contribute to availability calculations.
- Resources with zero eligible minutes show `N/A`.
- If the metric API returns no usable datapoints at all across the full period, the resource is excluded from availability calculations by setting `EligibleMinutes = 0` and `AvailableMinutes = 0`.

### Worked example

Consider a 30-day month for a VM (43,200 total minutes):

| Category | Minutes | Effect |
|---|---:|---|
| Metric = 1.0 (fully available) | 40,000 | +40,000 to AvailableSum |
| Metric = 0.7 (degraded, unexplained) | 100 | +70 to AvailableSum, +100 Unresolved |
| Metric = 0.8 during restart lifecycle event | 5 | +5 Excused, remove 4 from AvailableSum |
| Metric = null — explained by Activity Log | 40 | +40 Excused |
| Metric = null — explained by Health `Unknown` | 3,000 | +3,000 Excused |
| Metric = null — unresolved metric issue | 30 | +30 Excused |
| Metric = 0% — fault confirmed | 10 | +10 Faults, stays in eligible |
| Metric = 0% — unresolved | 10 | +10 Unresolved, stays in eligible |

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

### Storage Account — transaction-based eligibility

Storage Account `Availability` is a transaction-success-rate metric — it is only meaningful when there are actual transactions. The tool fetches both `Availability` and `Transactions` in a single API call. For each minute:

- **Transactions > 0 and Availability > 0%:** the Availability value (0–100, normalised to 0.0–1.0) counts toward available minutes. Values below 100% count as degraded.
- **Transactions > 0 and Availability null or 0%:** recorded as suspect minutes and investigated with the same Activity Log / Health History / fallback sequence.
- **Transactions = 0 or null:** counted as both suspect and excused — no availability signal to measure, so they are excluded from eligibility.

## Parameters

### C# (`GetAvailability.exe`)

| Option | Short | Default | Description |
|---|---|---|---|
| `--subscriptions` | `-s` | *(required)* | One or more Azure subscription display names |
| `--month` | `-m` | *(required)* | Observation month in UTC using format `YYYYMM` |
| `--kinds` | `-k` | `vm sql storage` | Resource kinds to process |
| `--resource` | `-r` | *(all)* | Filter to a single resource name |
| `--parallelism` | `-p` | *(auto)* | Max concurrent API calls (scales to CPU cores) |
| `--activity-grace-minutes` | `-g` | `10` | Post-operation grace window for supported Activity Log lifecycle events |

### PowerShell (`get-availability.ps1`)

| Parameter | Default | Description |
|---|---|---|
| `-Subscriptions` | *(required)* | One or more Azure subscription display names |
| `-Month` | *(required)* | Observation month in UTC using format `YYYYMM` |
| `-Kinds` | `vm,sql,storage` | Resource kinds to process |
| `-Resource` | *(all)* | Filter to a single resource name |
| `-Parallelism` | *(auto)* | Max concurrent API calls (scales to CPU cores, 4–16) |
| `-ActivityGraceMinutes` | `10` | Post-operation grace window for supported Activity Log lifecycle events |

Both versions enforce the same constraints: `-Month` / `--month` cannot point to a month whose first day is more than 90 days before the current UTC time.

## Prerequisites

### C# version

| Requirement | Detail |
|---|---|
| .NET SDK | 10.0 or later (build from source only) |
| Azure auth | `az login` or any method supported by `DefaultAzureCredential` |

The published binary (`GetAvailability.exe`) requires no .NET runtime — it is a Native AOT self-contained executable.

### PowerShell version

| Requirement | Detail |
|---|---|
| PowerShell | 7.0 or later (`pwsh`) |
| Az.Accounts | `Install-Module Az.Accounts` |
| Az.ResourceGraph | `Install-Module Az.ResourceGraph` |
| Azure auth | `Connect-AzAccount` (used by both Az modules and for ARM token acquisition) |

The script outputs objects to the pipeline in addition to the formatted table, so results can be piped to `Export-Csv`, `ConvertTo-Json`, or further filtered.

If Azure authentication fails, the tool prints the SDK/module exception message directly. For Azure CLI-based auth (C#), re-run `az login`; for PowerShell, re-run `Connect-AzAccount`.

## Usage

### C# version

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

### PowerShell version

```powershell
# Single subscription
./get-availability.ps1 -Subscriptions 'POSTE-BANCOPOSTA-PRODUZIONE' -Month 202603

# Multiple subscriptions
./get-availability.ps1 -Subscriptions 'POSTE-BANCOPOSTA-SVILUPPO','POSTE-BANCOPOSTA-PRODUZIONE' -Month 202603

# Filter by resource kind
./get-availability.ps1 -Subscriptions 'POSTE-BANCOPOSTA-PRODUZIONE' -Month 202603 -Kinds vm,sql

# Single resource
./get-availability.ps1 -Subscriptions 'POSTE-BANCOPOSTA-SVILUPPO' -Month 202603 -Resource spiacomdgs01

# Override the Activity Log grace window
./get-availability.ps1 -Subscriptions 'POSTE-BANCOPOSTA-SVILUPPO' -Month 202603 -Resource spocovm01a -ActivityGraceMinutes 15

# Pipe results to CSV
./get-availability.ps1 -Subscriptions 'POSTE-BANCOPOSTA-PRODUZIONE' -Month 202603 | Export-Csv availability.csv
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

Table view (Kind is abbreviated: VM, SQL, Storage):

| Subscription | Name | Kind | Location | Suspect | Faults | Excused | Unresolved | AvailMin | EligMin | Avail% |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| PRODUZIONE | `pabfpsql01azwe/pabfpsqldb01azwe` | SQL | westeurope | | | | | 40320 | 40320 | 100.00000 |
| SVILUPPO | `trepomndgw01a` | VM | northeurope | 23 | | 23 | | 14369 | 14369 | 100.00000 |
| PRODUZIONE | `pcesopcachefosa01azwe` | Storage | westeurope | 14 | | 4 | 10 | 40306 | 40316 | 99.97520 |

Column meaning:

- **Suspect** — total minutes where the availability metric was below 100%, null, or had no signal (zero-transaction storage minutes).
- **Faults** — suspect minutes confirmed as platform issues by Resource Health.
- **Excused** — suspect minutes excused from eligibility (lifecycle activity, customer-initiated, Health Unknown, metric-issue nulls, and zero-transaction storage minutes).
- **Unresolved** — suspect minutes that remained after all classification (unresolved 0% downtime + unexplained degraded).
- **AvailMin** — available minutes (sum of metric values, each 0.0–1.0).
- **EligMin** — eligible minutes (total minus excused).
- **Avail%** — availability percentage (AvailMin ÷ EligMin × 100).

The invariant **Suspect = Faults + Excused + Unresolved** holds for every row, making it easy to verify that all suspect minutes are accounted for. Columns with value 0 are shown as blank.

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
- **`Parallel.ForEachAsync`** (C#) / **`ForEach-Object -Parallel`** (PowerShell) for concurrent metric and health queries with configurable parallelism.
- **Ticks-based metric keying** (`long` instead of `DateTime`) — zero-allocation per data point in both versions.
- **`System.Text.Json`** for efficient JSON parsing in both versions — avoids large PSObject trees in PowerShell and enables AOT-safe parsing in C#.
- **Health History retention remains independent.** The observation month can extend beyond 30 days of retained Health History; only the retained overlap is checked there.
- **Native AOT** (C#) — ~15 MB standalone binary, no .NET runtime required.
- **Pipeline output** (PowerShell) — the script emits result objects after the formatted table, enabling `Export-Csv`, `ConvertTo-Json`, or further pipeline filtering.
