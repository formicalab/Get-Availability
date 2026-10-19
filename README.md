# Get-Availability

[![CI](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/ci.yml)
[![Release](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml/badge.svg)](https://github.com/formicalab/Get-Availability/actions/workflows/release.yml)

Get-Availability reports month-scoped availability for Azure Virtual Machines, Azure SQL Databases, Azure Storage Accounts, and Azure Web Apps across one or more Azure subscriptions.

It runs either as a standalone PowerShell 7.6 script or as a timer-triggered Azure Function. Log Analytics ingestion is optional.

For each resource, the tool reports:

- suspect minutes
- confirmed platform faults
- excused minutes
- unresolved minutes
- availability percentage

The relationship `Suspect = Faults + Excused + Unresolved` always holds.

## Run the script

### Prerequisites

| Requirement | Detail |
|---|---|
| PowerShell | 7.6 or later (`pwsh`) |
| Az.Accounts | `Install-Module Az.Accounts` |
| Az.ResourceGraph | `Install-Module Az.ResourceGraph` |
| Azure sign-in | `Connect-AzAccount` |

### Key parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-Subscriptions` | required | Azure subscription display names to inspect |
| `-Month` | required | Observation month in UTC, format `YYYYMM` |
| `-Kinds` | `vm,sql,storage,webapp` | Resource kinds to include |
| `-Resource` | all | Limit the run to one resource |
| `-Parallelism` | auto | Max concurrent API calls |
| `-ActivityGraceMinutes` | `10` | Grace window after lifecycle events |
| `-FaultWindowMinutes` | `30` | VMs only: how long a platform health note can explain suspect minutes the metric does not attribute itself |
| `-HealthLeadMinutes` | `5` | Storage accounts only: how many minutes before a platform health event its server failures are still attributed to it |
| `-Batch` | off | Use the Metrics Batch API |
| `-BatchSize` | `10` | Batch size when `-Batch` is enabled |
| `-SourceWorkspaceId` | none | Source Log Analytics workspace for bulk Activity Log and older Resource Health history |
| `-DceEndpoint` | none | Data Collection Endpoint for ingestion |
| `-DcrImmutableId` | none | Data Collection Rule immutable ID for ingestion |
| `-Version` | off | Print version and exit |

The observation window is a UTC calendar month. Past months use the full month; the current month is month-to-date. Metric and Activity Log collection support a 90-day lookback. Resource Health REST history is shorter, so `-SourceWorkspaceId` is the way to extend coverage beyond the last ~30 days.

### Examples

```powershell
# Single subscription
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603

# Multiple subscriptions, filtered by kind
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Development','Contoso-Production' -Month 202603 -Kinds vm,sql

# Single resource with a custom grace window
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Development' -Month 202603 -Resource myvm02 -ActivityGraceMinutes 15

# Use Log Analytics as the source for Activity Log and older Resource Health history
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 -SourceWorkspaceId 'b233a4b7-3c43-433c-ac60-1f6ff217ddd4'

# Send results to Log Analytics custom tables
./Functions/GetAvail/get-availability.ps1 -Subscriptions 'Contoso-Production' -Month 202603 `
  -DceEndpoint 'https://dce-getavail-itn-001.italynorth-1.ingest.monitor.azure.com' `
  -DcrImmutableId 'dcr-00000000000000000000000000000000'
```

### Output

The console output includes the observation window, any Resource Health coverage warning, a per-resource table, and aggregated summaries. The PowerShell version also emits objects to the pipeline so you can export to CSV or JSON.

Resources with zero eligible minutes are shown as `N/A`.

## Classification model

1. Resource inventory comes from Azure Resource Graph.
2. Azure Monitor metrics are collected: one-minute granularity for VMs, Azure SQL databases and Web Apps; request counts by response type for storage accounts.
3. Suspect minutes are classified. Virtual machines and storage accounts follow the algorithms described in [Algorithms](#algorithms); the other kinds follow the precedence below.
4. Final availability is computed from eligible minutes and available minutes.

Metric sources by resource type:

| Resource type | Metrics |
|---|---|
| Virtual Machine | `VmAvailabilityMetric` (see [Virtual machines](#virtual-machines)) |
| Azure SQL Database | `Availability` |
| Storage Account | `Transactions` split by `ResponseType` (see [Storage accounts](#storage-accounts)) |
| Web App | `MemoryWorkingSet` |

For Azure SQL Databases and Web Apps (until their dedicated algorithms are documented under [Algorithms](#algorithms)), classification precedence is strict:

1. Platform faults from Resource Health remain eligible downtime.
2. Matching lifecycle events are excused.
3. Resource Health `Unknown` or customer-initiated periods are excused.
4. Remaining nulls are treated as metric issues and excused.
5. Remaining zero or degraded values count against availability.

When `-SourceWorkspaceId` is set, Activity Log data and older Resource Health history are queried from Log Analytics in bulk, while the most recent Resource Health history still comes from the REST API and remains authoritative.

## Log Analytics ingestion

When `-DceEndpoint` and `-DcrImmutableId` are both supplied, the script sends results through the Azure Monitor Ingestion API into:

| Table | Content |
|---|---|
| `GetAvailResources_CL` | Per-resource results |
| `GetAvailSummary_CL` | Aggregated summaries |

Payloads are gzip-compressed and batched to stay within ingestion limits.

## Deploy to Azure

The Bicep template in [Bicep/](Bicep/) deploys the complete Azure-hosted stack:

- Log Analytics workspace and custom tables
- Data Collection Endpoint and Data Collection Rule
- Storage account
- Flex Consumption Function App
- Application Insights
- RBAC assignments for ingestion and storage access
- Optional private endpoints for the storage account and Function App

The Function App settings are auto-wired from the deployed resources, so after infrastructure deployment and `func publish` no manual app-setting step is required.

### Networking modes

The template now supports two network modes controlled by `usePrivateEndpoints`:

| `usePrivateEndpoints` | Behavior |
|---|---|
| `true` | Preserves the current deployment model: creates storage and Function App private endpoints, uses the private endpoint subnet and shared private DNS zones, and keeps public access disabled on those resources |
| `false` | Skips private endpoints and DNS zone references, and keeps the storage account and Function App publicly reachable |

### Deployment prerequisites

- Azure CLI with Bicep support
- Contributor on the target resource group
- A subnet delegated to `Microsoft.App/environments` for `fnSubnetId`
- If `usePrivateEndpoints = true`: a private endpoint subnet and existing private DNS zones for blob storage and Azure Websites

### Parameters

See [Bicep/parameters.dev.bicepparam](Bicep/parameters.dev.bicepparam) for a commented example. The main parameters are:

| Parameter | Purpose |
|---|---|
| `logAnalyticsWorkspaceName` | Log Analytics workspace name |
| `dataCollectionEndpointName` | Data Collection Endpoint name |
| `dataCollectionRuleName` | Data Collection Rule name |
| `storageAccountName` | Storage account for the Function App |
| `functionAppName` | Function App name |
| `applicationInsightsName` | Application Insights instance |
| `usePrivateEndpoints` | Toggle between private networking and public reachability |
| `fnSubnetId` | Delegated subnet for Function App VNet integration |
| `peSubnetId` | Private endpoint subnet when private endpoints are enabled |
| `dnsZonesSubscriptionId` | Subscription containing shared private DNS zones |
| `dnsZonesResourceGroupName` | Resource group containing shared private DNS zones |
| `getavailSubscriptions` | Comma-separated subscriptions to monitor |
| `getavailKinds` | Resource kinds to monitor |
| `getavailBatch` | Use regional Metrics Batch API requests (default: `true`) |
| `getavailBatchSize` | Maximum resources per batch request (default: `10`) |
| `sourceWorkspaceId` | Optional source workspace for Activity Log and Resource Health history |
| `timerSchedule` | CRON expression for the timer trigger |

### Deploy the infrastructure

```powershell
# Create resource group (one time)
az group create --name rg-getavail-itn-001 --location italynorth --tags solution=Get-Availability

# Validate
az deployment group validate --resource-group rg-getavail-itn-001 --parameters Bicep/parameters.dev.bicepparam

# What-if
az deployment group what-if --resource-group rg-getavail-itn-001 --parameters Bicep/parameters.dev.bicepparam

# Deploy
az deployment group create --resource-group rg-getavail-itn-001 --parameters Bicep/parameters.dev.bicepparam
```

### Post-deployment access

The Function App managed identity needs:

- `Reader` on each subscription listed in `getavailSubscriptions`
- `Log Analytics Reader` on the `sourceWorkspaceId` workspace when that feature is used

Example:

```powershell
$principalId = az functionapp identity show `
  --name fn-getavail-itn-001 `
  --resource-group rg-getavail-itn-001 `
  --query principalId -o tsv

$subscriptions = @('Flaz-Connectivity', 'Flaz-Management', 'Flaz-Identity', 'Flaz-Workloads')
foreach ($sub in $subscriptions) {
  $subId = az account show --subscription $sub --query id -o tsv
  az role assignment create --assignee $principalId --role Reader --scope "/subscriptions/$subId"
}

az role assignment create --assignee $principalId --role 'Log Analytics Reader' `
  --scope '<source-workspace-resource-id>'
```

### Publish the Function App

```powershell
# Save required modules (one time or when upgrading)
Save-Module -Name Az.Accounts -Path Functions/GetAvail/Modules -Repository PSGallery -Force
Save-Module -Name Az.ResourceGraph -Path Functions/GetAvail/Modules -Repository PSGallery -Force

# Publish
cd Functions/GetAvail
func azure functionapp publish fn-getavail-itn-001 --powershell
```

## Algorithms

This section describes, step by step, how each resource kind is turned into the numbers in the results table. Every algorithm answers the same question for each suspect minute: *did this minute count against availability, and why?*

### Virtual machines

#### What the signal means

The signal is `VmAvailabilityMetric` (aggregation `Minimum`, one-minute grain):

| Value | Meaning |
|---|---|
| `1` | The VM is running and available |
| `0` | The VM is unavailable: stopped, rebooting, or shut down from inside the guest |
| null | The state is unknown. A VM stopped from the portal, CLI or PowerShell stops emitting the metric at once |

The metric has a `Context` dimension that says who caused the state: `Platform` (Azure), `User` (the customer) or `Unknown`. It reports the VM as the host sees it. It does not see a hung guest, an unreachable application or a network-path problem, so a VM that is up but unreachable still reads `1`.

A minute that is not `1` is a **suspect minute**. The algorithm decides, for every suspect minute, whether it is a fault, is excused, or stays unresolved.

#### Step 1: collect the evidence

1. **Metric.** Read the unsplit series. It is the base signal: every minute is available, null, zero or fractional.
2. **Context.** Only if the VM has zero minutes, read the metric again split by `Context` and tag each zero minute with the contexts that report zero (`Platform`, `User`, `Unknown`). A zero with no `Context` information is `Unknown`.
3. **Power-state guard.** If every minute of the period is suspect and the VM is currently `stopped` or `deallocated`, the whole period is excused and the VM is reported as `N/A`.
4. **Activity Log.** Collect start, deallocate, power-off and restart operations, with all non-failed statuses (`Start`, `Accept`, `Success`). The first event marks when the affected minutes begin, so none of the statuses can be dropped. Events are grouped by operation and correlation ID; each group becomes a lifecycle window from its first event to its last event plus one minute plus `-ActivityGraceMinutes`. Overlapping windows are merged. The period before the VM's creation time is a separate *did not exist* window.
5. **Resource Health.** Read the REST history (about the last 30 days) and, when `-SourceWorkspaceId` is set, the workspace history for older periods. Classify every note by what it says, not by whether its state changed:

| Class | Examples | Role |
|---|---|---|
| Customer | Stopping and deallocating, Started by user, Rebooted by user, Machine crashed | Carries a state forward |
| Platform outage | Redeploying due to host failure, VM Network dataplane down, Unavailable | Carries a state forward |
| Planned, Spot eviction, Unknown, Recovery | Planned maintenance, Low priority machine preempted, Unknown, Available, Live Migration Succeeded | Carries a state forward |
| Evidence only | Root Cause Analysis, `Down: ... unavailable for 15 minutes`, Accelerated Networking notes, degraded hardware or performance notes | Never decides a minute |

A note classified as *evidence only* is kept for context but never starts or changes a state. In particular, the `Down: ... unavailable for 15 minutes` note is raised after the VM went down, so it cannot supersede the action that took it down, and Accelerated Networking and live-migration-succeeded notes are not outages even though Azure labels them `Unplanned`.

#### Step 2: decide each suspect minute

Rules are applied in order; the first match wins.

| # | Rule | Verdict |
|---|---|---|
| 1 | The VM did not exist yet | Excused |
| 2 | Zero, and `Context` includes `Platform` | **Fault** |
| 3 | Zero, and `Context` is `User` only | Excused (customer) |
| 4 | Inside a lifecycle window | Excused (lifecycle operation) |
| 5 | Null, directly continuing a minute already explained as customer-caused | Excused (the gap is explained by what started it) |
| 6 | A platform-outage note within `-FaultWindowMinutes` before the minute, with no customer action since | **Fault** |
| 7 | The latest note is Customer, Planned or Spot eviction, or is Unknown and the minute is null | Excused |
| 8 | Null, and nothing explains it | Excused as a *metric gap* |
| 9 | Zero or fractional, and nothing explains it | **Unresolved** (counts against availability) |

Three details matter in practice:

- A `Recovery` or `Unknown` note logged seconds after a platform-outage note does not hide it (rule 6). Only a later customer action does.
- A measured zero is attributed before lifecycle windows are consulted (rules 2 and 3), so a platform failure that happens during a customer restart is still a fault.
- Rule 8 is deliberately generous: a missing sample is not evidence of downtime. The console narration lists metric gaps separately so they stay visible.

#### Step 3: compute the result

- **Suspect** = every non-`1` minute = Faults + Excused + Unresolved.
- **Faults** = minutes decided by rules 2 and 6.
- **Excused** = minutes decided by rules 1, 3, 4, 5, 7 and 8.
- **Unresolved** = minutes decided by rule 9.
- **Eligible minutes** = minutes in the period − Excused.
- **Availability %** = available minutes ÷ eligible minutes, or `N/A` when no minute is eligible. Fractional minutes contribute their value.

#### Worked examples

| Situation | What the evidence shows | Result |
|---|---|---|
| Host failure | One zero minute with `Context = Platform`, and a "Redeploying due to host failure" note seconds earlier | 1 fault minute |
| Daily start and stop by the customer | Zero minutes with `Context = User`, lifecycle windows around the operations, then nulls while the VM is deallocated | All excused; the nulls continue the customer stop |
| Weekend deallocation after an Accelerated Networking note | The note is evidence only; the customer stop explains the nulls | Excused, no fault |
| VM stopped by the customer for most of the month | Thousands of zero minutes with `Context = User` | Excused; availability is computed over the minutes the VM was meant to run |
| Network dataplane down with no metric impact | A platform-outage note but every metric minute is `1` | No suspect minute, so no fault |

#### Limits

- Faults are only as good as the evidence: a platform event that leaves the metric at `1` is not counted.
- Rule 6 can count null minutes that happen to fall inside the window after a platform note.
- `-FaultWindowMinutes` and `-ActivityGraceMinutes` are tunables; the defaults (30 and 10) were validated on a limited set of subscriptions.
- Resource Health REST history covers about 30 days. Older periods rely on the metric's `Context` and on `-SourceWorkspaceId`.

### Storage accounts

#### What the signal means

The portal's storage `Availability` metric is the share of billable requests that succeeded, but its `Minimum` aggregation is the *worst single series* of the minute (one `ApiName`, `Authentication` and `GeoType` combination), whatever its volume. A single failed request can therefore turn a whole minute into 0%, and a quiet account looks much worse than a busy one with the same failure count. The algorithm does not use it. It follows the definition of the [Azure Storage SLA](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services): the **error rate of an hour** is failed requests ÷ counted requests, and availability is 100% minus the average error rate over the hours of the period. An hour with no traffic has a 0% error rate, so idle time counts as available.

Requests are read from `Transactions` split by `ResponseType`, and only three response types are requested:

| Response type | Role |
|---|---|
| `Success` | Counted |
| `ServerOtherError`, `ServerTimeoutError` | Counted and **failed** |
| `ServerBusyError`, client throttling errors | Not requested: throttling is excluded from the score, as in the SLA |
| `NetworkError`, `ClientOtherError`, authentication and authorization errors | Not requested: caused by the client, excluded from the score |

#### Step 1: hourly error rates (every account)

One call per account returns the counted and failed requests of every hour of the period. This single series gives the score; the rest of the algorithm only explains it.

#### Step 2: find the failing minutes (accounts with failures)

For the accounts that had at least one failed request, read the per-minute counts of the periods that contain failures (one call per day when there are few, otherwise 10-day spans). A **failing minute** is a minute with at least one failed request. Its *share* is failed ÷ counted requests of that minute.

#### Step 3: attribute each failing minute to Resource Health

1. Read the Resource Health history: the REST API (about the last 30 days) and, with `-SourceWorkspaceId`, the workspace for the whole period. The two are combined because the REST history can omit short events that the Activity Log still holds.
2. A **window** opens at a `Degraded` or `Unavailable` note and closes at the next `Available` note (an event that never resolves explains at most 30 minutes). Windows of notes caused by the customer, such as `Throttled`, are *customer windows*. Windows that touch are merged.
3. Resource Health raises its event a few minutes after the first failed requests, so a window is widened: it starts `-HealthLeadMinutes` before the note and ends two minutes after the resolution.
4. Each failing minute is decided in this order:

| # | Rule | Verdict |
|---|---|---|
| 1 | The account did not exist yet | Not eligible (hours before creation are left out) |
| 2 | Inside a platform window | **Fault** |
| 3 | Inside a customer window | Excused |
| 4 | Anything else | **Unresolved** |

Both Fault and Unresolved count against availability: a failed request is a failed request whether or not Azure reported it. The split tells an operator, or an SRE agent, which failures Azure already acknowledged. Excused requests leave both the failed and the counted totals of their hour.

#### Step 4: compute the result

- **Suspect** = failing minutes = Faults + Excused + Unresolved.
- **Eligible minutes** = minutes in the period since the account was created.
- **Availability %** = 100 − average hourly error rate over the eligible hours, after removing the excused requests. **Available minutes** = eligible minutes × availability %.
- An account with no counted request in the period is reported as `N/A`.
- An account with fewer than 10,000 counted requests in the period is flagged **low volume** in the narration: a handful of failed requests can then move the percentage a lot.

The narration also lists the largest incidents (failing minutes less than six minutes apart): when it started, how many requests failed out of how many, the peak share of a minute, the verdict, and the Resource Health event and summary that explained it.

#### Worked examples

| Situation | What the evidence shows | Result |
|---|---|---|
| Storage backend incident | 1,312 server timeouts in one minute of a busy account; Resource Health raises `Degraded` two minutes later and resolves it after seven | Fault. The minutes before the event are included thanks to `-HealthLeadMinutes` |
| Background noise | 1 to 10 timeouts among tens of thousands of requests, no health event | Unresolved, but each minute costs a few thousandths of a percent |
| Busy account, one failed request | The `Availability` metric can read 0% for the minute; the request is one among tens of thousands | Hourly error rate of a few thousandths of a percent at most |
| Throttling | `ServerBusyError` and client throttling in the thousands | Not part of the score |
| Idle weekends | No requests for days | Hours count as available (SLA rule) |
| Account with a handful of requests | Two requests, both failing, in some hours | Real error rate, flagged low volume |

#### Limits

- Failures that do not reach the `Server*` response types are not counted, including requests that time out on the client side.
- Resource Health events that cause no failed request are not counted.
- A failing minute is attributed by time only: a platform event and an unrelated failure in the same window are both Faults.
- `-HealthLeadMinutes` (5) and the two-minute grace after resolution were validated on a limited set of subscriptions.
- Resource Health REST history covers about 30 days; older periods need `-SourceWorkspaceId`, otherwise every failing minute is Unresolved.

The algorithms for Azure SQL databases and Web Apps will be added here.
