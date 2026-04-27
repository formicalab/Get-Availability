# Get-Availability

[![CI](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml)
[![Release](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml)

Reports month-scoped availability for Azure Virtual Machines, Azure SQL Databases, Azure Storage Accounts, and Azure Web Apps across one or more Azure subscriptions.

No build step; runs as a standalone PowerShell 7 script or as an Azure Function on a schedule. Supports optional Log Analytics ingestion for dashboarding.

> A legacy C# (Native AOT) implementation is preserved in [`Old/`](Old/README.md) but is not actively maintained.

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
| `-SourceWorkspaceId` | *(none)* | Log Analytics workspace ID (GUID) used as a source for historical Activity Log and Resource Health data. Not the ingestion target. Fetches lifecycle events via a single bulk KQL query (faster for large estates). Resource Health uses a hybrid approach: KQL transitions cover the period beyond the REST API's ~30-day retention, while REST API transitions (curated, with corrected causes) are authoritative for the last ~30 days. |
| `-DceEndpoint` | *(none)* | Data Collection Endpoint ingestion URL. When provided together with `-DcrImmutableId`, results are sent to Log Analytics custom tables via the Azure Monitor Ingestion API. |
| `-DcrImmutableId` | *(none)* | Data Collection Rule immutable ID. Required together with `-DceEndpoint` to enable Log Analytics ingestion. |
| `-Version` | | Print version and exit |

The observation window is a UTC calendar month: past months use the full calendar month, the current month is reported month-to-date. The requested month cannot start more than 90 days before the current UTC time. Metrics and Activity Log support that 90-day lookback; Health History is applied only for its overlap with the ~30-day REST API retention window. When `-SourceWorkspaceId` / `--workspace` is used, Health History coverage extends to the full observation period via a hybrid approach (Log Analytics for older transitions + REST API for the last ~30 days).

### Examples

```powershell
# Single subscription
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603

# Multiple subscriptions, filtered by kind
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Development','Contoso-Production' -Month 202603 -Kinds vm,sql

# Single resource with custom grace window
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Development' -Month 202603 -Resource myvm02 -ActivityGraceMinutes 15

# Batch API with custom batch size
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production','Contoso-Development' -Month 202603 -BatchSize 20

# Use Log Analytics for Activity Log + Resource Health (faster, extended retention)
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 -SourceWorkspaceId 'b233a4b7-3c43-433c-ac60-1f6ff217ddd4'

# Send results to Log Analytics custom tables
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 `
  -DceEndpoint 'https://dce-getavail-itn-001.italynorth-1.ingest.monitor.azure.com' `
  -DcrImmutableId 'dcr-00000000000000000000000000000000'

# Pipe results to CSV
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 | Export-Csv availability.csv
```

### Output

The header line shows the observation window and total minutes:

```
Period: month 202602 (2026-02-01 00:00:00Z -> 2026-03-01 00:00:00Z, 40320 min)
```

If the observation window extends beyond the Resource Health retention window, an explicit warning is printed:

```
WARNING: Resource Health history covers only part of this period (2026-02-16 18:54:00Z -> 2026-03-01 00:00:00Z, 17586 of 40320 min). Earlier minutes will use Activity Log and metric fallback rules.
```

When `-SourceWorkspaceId` is used, the 30-day warning is suppressed (hybrid coverage applies) and an informational line is printed:

```
Log Analytics source workspace: b233a4b7-…-1f6ff217ddd4 (Activity Log via KQL, Resource Health via KQL + REST API hybrid)
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

- **REST API only** (default, no `-SourceWorkspaceId`): The [Activity Log REST API](https://learn.microsoft.com/azure/azure-monitor/platform/rest-activity-log#retrieve-activity-log-data) and the [Resource Health REST API](https://learn.microsoft.com/en-us/rest/api/resourcehealth/availability-statuses/list?view=rest-resourcehealth-2025-05-01) (`availabilityStatuses`, API version `2025-05-01`) are queried per-resource. Resource Health API has a ~30-day retention limit.
- **Hybrid: Log Analytics + REST API** (`-SourceWorkspaceId` / `--workspace`): A single bulk KQL query against the `AzureActivity` table fetches Activity Log lifecycle events and Resource Health transitions for all resources at once (faster for large estates: 1 query vs. thousands of REST calls). Resource Health transitions older than the REST API's ~30-day retention cutoff come from Log Analytics (workspace retention, typically 365 days). For the last ~30 days, the REST API is always queried and its transitions take precedence — REST data is authoritative because it provides curated synthetic entries that fill coverage gaps between health incidents and retroactively corrects cause classification. The two sources are merged chronologically to form a complete health timeline. Requires the target subscriptions to have diagnostic settings sending Activity Log data to the specified workspace.

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

The infrastructure is deployed via the Bicep template in [`Bicep/`](Bicep/). The template creates the full stack (Log Analytics workspace, custom tables, DCE, DCR, Storage Account, Function App, Application Insights, Private Endpoints, and RBAC) and **auto-wires all Function App settings** — after deployment and `func publish`, the function runs with no manual configuration.

## Infrastructure Deployment

### What it deploys

The Bicep template deploys the following resources into the target resource group:

| # | Resource | Purpose |
|---|----------|--------|
| 1 | **Log Analytics Workspace** | Stores availability data in custom tables; enables KQL queries and Workbooks |
| 2 | **Custom Table `GetAvailResources_CL`** | Per-resource availability detail (one row per resource per run) |
| 3 | **Custom Table `GetAvailSummary_CL`** | Aggregated summaries (per Kind+Location, per subscription, overall) |
| 4 | **Data Collection Endpoint (DCE)** | Ingestion URL for the Azure Monitor Ingestion API |
| 5 | **Data Collection Rule (DCR)** | Routes two custom streams to the corresponding tables with `TimeGenerated` injection |
| 6 | **Storage Account** | Backing store for the Function App (deployment blobs) |
| 7 | **Flex Consumption Plan** | Serverless hosting plan for the Function App |
| 8 | **Function App** | Runs the Get-Availability script on a schedule with system-assigned managed identity |
| 9 | **Application Insights** | Monitoring and telemetry for the Function App (Entra-only auth) |
| 10 | **Private Endpoint (Storage blob)** | Private connectivity for the Function App to its backing storage |
| 11 | **Private Endpoint (Function App sites)** | Private connectivity for publishing and management |

RBAC role assignments are created automatically:

| Principal | Role | Scope | Why |
|-----------|------|-------|-----|
| Function App | Monitoring Metrics Publisher | DCR | Ingest custom logs via the Azure Monitor Ingestion API |
| Function App | Monitoring Metrics Publisher | Application Insights | Send telemetry when local auth is disabled |
| Function App | Storage Blob Data Owner | Storage Account | Flex Consumption plan deployment blobs |

### Deployment prerequisites

- **Azure CLI** with Bicep support (`az bicep version`)
- **Contributor** role on the target resource group
- A **subnet** delegated to `Microsoft.App/environments` for the Function App VNet integration
- A **subnet** for private endpoints
- Existing **Private DNS Zones** for `privatelink.blob.core.windows.net` and `privatelink.azurewebsites.net`

### Bicep parameters

Configured in `Bicep/parameters.dev.bicepparam`:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `location` | Azure region (defaults to resource group location) | `italynorth` |
| `logAnalyticsWorkspaceName` | Log Analytics workspace name | `log-getavail-itn-001` |
| `dataCollectionEndpointName` | Data Collection Endpoint name | `dce-getavail-itn-001` |
| `dataCollectionRuleName` | Data Collection Rule name | `dcr-getavail-itn-001` |
| `storageAccountName` | Storage account for the Function App | `stgetavailitn001` |
| `functionAppName` | Function App name | `fn-getavail-itn-001` |
| `applicationInsightsName` | Application Insights name | `appi-getavail-itn-001` |
| `fnSubnetId` | Subnet resource ID for Function App VNet integration | `/subscriptions/.../subnets/snet-fn` |
| `peSubnetId` | Subnet resource ID for private endpoints | `/subscriptions/.../subnets/snet-pe` |
| `dnsZonesSubscriptionId` | Subscription ID containing Private DNS Zones | `00000000-0000-...` |
| `dnsZonesResourceGroupName` | Resource group containing Private DNS Zones | `rg-dns-001` |
| `getavailSubscriptions` | Comma-separated subscription names/IDs to monitor | `Contoso-Production,Contoso-Dev` |
| `getavailKinds` | Resource kinds to monitor (default: `vm,sql,storage,webapp`) | `vm,sql` |
| `sourceWorkspaceId` | Log Analytics workspace ID for Activity Log / Resource Health queries (optional) | `f25755bb-...` |
| `timerSchedule` | CRON expression for the timer trigger (default: `0 0 6 1 * *` — 6 AM on the 1st of every month) | `0 0 8 1 * *` |

### Deploy

This is a **resource-group scoped** deployment. Create the resource group first, then deploy:

```powershell
# Create resource group (one-time)
az group create --name rg-getavail-itn-001 --location italynorth --tags solution=Get-Availability

# Validate
az deployment group validate --resource-group rg-getavail-itn-001 --parameters Bicep/parameters.dev.bicepparam

# What-if (dry run)
az deployment group what-if --resource-group rg-getavail-itn-001 --parameters Bicep/parameters.dev.bicepparam

# Deploy
az deployment group create --resource-group rg-getavail-itn-001 --parameters Bicep/parameters.dev.bicepparam
```

### Post-deployment: cross-subscription Reader role

The Bicep template creates RBAC assignments within the deployment resource group (Metrics Publisher, Storage Blob Data Owner). However, the function also needs **Reader** access on every subscription listed in `getavailSubscriptions` so that `Get-AzSubscription` and `Search-AzGraph` can enumerate and query resources there.

After deployment, retrieve the managed identity principal ID and assign **Reader** on each target subscription:

```powershell
# Get the Function App managed identity principal ID
$principalId = (az functionapp identity show `
    --name fn-getavail-itn-001 `
    --resource-group rg-getavail-itn-001 `
    --query principalId -o tsv)

# Assign Reader on each subscription in getavailSubscriptions
$subscriptions = @('Flaz-Connectivity', 'Flaz-Management', 'Flaz-Identity', 'Flaz-Workloads')
foreach ($sub in $subscriptions) {
    $subId = az account show --subscription $sub --query id -o tsv
    az role assignment create --assignee $principalId --role Reader --scope "/subscriptions/$subId"
}
```

> **Note:** You only need to do this once per subscription (or when the managed identity is recreated). The Workloads subscription (where the Function App lives) may already have Reader via inheritance — include it for completeness.

If `sourceWorkspaceId` points to a Log Analytics workspace (e.g. a Sentinel workspace for Activity Log / Resource Health queries), the managed identity also needs **Log Analytics Reader** on that workspace:

```powershell
# Assign Log Analytics Reader on the source workspace (if used)
az role assignment create --assignee $principalId --role "Log Analytics Reader" `
    --scope "<source-workspace-resource-id>"
```

### Auto-wired app settings

The Bicep template configures the Function App with all required settings — values are resolved from sibling resources at deploy time:

| App Setting | Bicep source | Used by `run.ps1` |
|---|---|---|
| `DCE_ENDPOINT` | DCE ingestion endpoint | `$env:DCE_ENDPOINT` |
| `DCR_IMMUTABLE_ID` | DCR immutable ID | `$env:DCR_IMMUTABLE_ID` |
| `SOURCE_WORKSPACE_ID` | `sourceWorkspaceId` parameter | `$env:SOURCE_WORKSPACE_ID` |
| `GETAVAIL_SUBSCRIPTIONS` | `getavailSubscriptions` parameter | `$env:GETAVAIL_SUBSCRIPTIONS` |
| `GETAVAIL_KINDS` | `getavailKinds` parameter | `$env:GETAVAIL_KINDS` |
| `TIMER_SCHEDULE` | `timerSchedule` parameter | *(timer trigger via `%TIMER_SCHEDULE%`)* |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | App Insights connection string | *(Functions runtime)* |

The template also configures CORS to allow `https://portal.azure.com`, so you can test-run the function directly from the Azure Portal.

### Deployment outputs

Outputs are available for reference or cross-stack integration:

| Output | Description |
|--------|-------------|
| `logAnalyticsWorkspaceId` | Workspace resource ID |
| `dceIngestionEndpoint` | DCE ingestion URL |
| `dataCollectionRuleImmutableId` | DCR immutable ID |
| `functionAppId` | Function App resource ID |
| `applicationInsightsId` | Application Insights resource ID |
| `storageAccountId` | Storage Account resource ID |

```powershell
# Retrieve outputs
$outputs = (az deployment group show --resource-group rg-getavail-itn-001 --name getavailability --query properties.outputs -o json | ConvertFrom-Json)
$outputs.dceIngestionEndpoint.value
$outputs.dataCollectionRuleImmutableId.value
```

### Publishing the Function App

The `get-availability.ps1` script lives inside the function app folder (`Functions/GetAvail/`) and is deployed alongside the function code. All app settings (`DCE_ENDPOINT`, `DCR_IMMUTABLE_ID`, `SOURCE_WORKSPACE_ID`, `GETAVAIL_SUBSCRIPTIONS`, `GETAVAIL_KINDS`) are auto-wired by Bicep — after `func publish` the function is ready to run with no manual configuration.

```powershell
# Save required modules (one-time or when upgrading)
Save-Module -Name Az.Accounts     -Path Functions/GetAvail/Modules -Repository PSGallery -Force
Save-Module -Name Az.ResourceGraph -Path Functions/GetAvail/Modules -Repository PSGallery -Force

# Publish (from the Functions/GetAvail directory)
cd Functions/GetAvail
func azure functionapp publish fn-getavail-itn-001 --powershell
```
