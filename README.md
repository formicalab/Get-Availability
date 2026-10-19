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
| `-HealthLeadMinutes` | `5` | Storage accounts, SQL databases and Web Apps: how many minutes before a platform health event its failures are still attributed to it |
| `-Batch` | off | Use the Metrics Batch API |
| `-BatchSize` | `10` | Batch size when `-Batch` is enabled |
| `-SourceWorkspaceId` | none | Source Log Analytics workspace for bulk Activity Log and Resource Health history |
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
2. Azure Monitor metrics are collected for every resource (granularity and aggregation depend on the kind, see [Algorithms](#algorithms)).
3. Suspect minutes are classified. Every resource kind follows its own algorithm, described in [Algorithms](#algorithms).
4. Final availability is computed from eligible minutes and available minutes.

Metric sources by resource type:

| Resource type | Metrics |
|---|---|
| Virtual Machine | `VmAvailabilityMetric` (see [Virtual machines](#virtual-machines)) |
| Azure SQL Database | `availability`, plus the connection metrics as evidence (see [Azure SQL databases](#azure-sql-databases)) |
| Storage Account | `Transactions` split by `ResponseType` (see [Storage accounts](#storage-accounts)) |
| Web App | `Requests` and `Http5xx` (see [Web Apps](#web-apps)) |

When `-SourceWorkspaceId` is set, Activity Log data is queried from Log Analytics in bulk. For every resource kind, Resource Health history from the REST API and from the workspace is combined for the whole period (see [Resource Health history](#resource-health-history)).

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

### Resource Health history

Every resource kind reads Resource Health history in exactly the same way. The REST history (about the last 30 days) and, with `-SourceWorkspaceId`, the Resource Health events of the Activity Log in the workspace are **combined for the whole period**. Neither source is complete on its own:

- The REST history can omit short events that the Activity Log still holds. The same account has returned a 22-entry history with its recent `Degraded` events and, hours later, a 9-entry history without them.
- The workspace lags behind real time and reaches back only as far as its retention.

The REST history is skipped only when a workspace is set and the whole period predates the REST retention. The two sources describe the same events, so duplicates are expected, and each algorithm is built to tolerate them. Without `-SourceWorkspaceId` only the REST history is available: short events can be missing, and periods older than about 30 days have no health evidence.

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
5. **Resource Health.** Read the combined history described in [Resource Health history](#resource-health-history). Classify every note by what it says, not by whether its state changed:

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
- Without `-SourceWorkspaceId` the Resource Health evidence is the REST history only (see [Resource Health history](#resource-health-history)): about 30 days, and short events can be missing. Older periods then rely on the metric's `Context`.

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

1. Read the Resource Health history described in [Resource Health history](#resource-health-history).
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
- Without `-SourceWorkspaceId` the Resource Health evidence is the REST history only (see [Resource Health history](#resource-health-history)): short events can be missing, and for periods older than about 30 days every failing minute is Unresolved.

### Azure SQL databases

#### What the signal means

The signal is the `availability` metric (aggregation `Minimum`, one-minute grain). It is based on connections, not on probes of the database engine:

| Value | Meaning |
|---|---|
| `100` | At least one connection attempt of the minute succeeded |
| `0` | Every connection attempt of the minute failed with a **system** error. Errors caused by the user (wrong login, firewall, application errors) do not count |
| null | No data. In practice the metric is never null: even a paused database reads `100` |

Two properties of the metric shape the algorithm:

- **A zero minute is the only downtime signal, and the metric hides partial failures.** If some connections of a minute succeed, the minute reads `100` even when others failed. Short platform events (Resource Health reports about two seconds of impact) therefore leave no trace in `availability`. The companion metrics `connection_failed` (with an `Error` dimension) and `connection_successful` show them.
- **A serverless database with auto-pause produces zero minutes by design.** The first connection to a paused database resumes it and fails with error `40613` ("database not currently available") until the resume completes. The platform logs each resume in the Activity Log as `Microsoft.Sql/servers/databases/resume` (a `Started` and a `Succeeded` event, about a minute apart) with an **all-zero correlation ID**. The metric reads `0` for the first minute and can read `100` for the following minutes while connections keep failing, so it also under-reports the length of a resume.

In a September sample of 181 databases, every one of the 375 zero minutes had error `40613` and no successful connection in the minute, and 97% of them sat inside a resume operation.

#### Step 1: collect the evidence

1. **Metric.** Read `availability` for the whole period. Count the zero and null minutes.
2. **Resume windows.** Collect the `resume` operations of the Activity Log, including the ones the platform logs itself (`Microsoft.Sql/servers/databases/resume`) and the ones triggered by a user (`.../resume/action`). Group the events of one operation by proximity: consecutive events at most 5 minutes apart belong together, and a window never exceeds 15 minutes. A window runs from the minute of its first event to one minute after the minute of its last event. Grouping by correlation ID would join every resume of the period into one window, because the platform's own events share a zero ID. A failed operation leaves a lone `Started` event that explains a single minute. Pause operations are not used: no zero minute was ever explained by a pause alone.
3. **Creation time.** Minutes before the creation time of the database are excused.
4. **Resource Health.** Read the combined history described in [Resource Health history](#resource-health-history) and turn it into windows, as for storage accounts: a window opens at an `Unavailable` or `Degraded` note and closes at the next `Available` note. Windows of customer-caused events are customer windows. A platform window starts `-HealthLeadMinutes` before the note and ends two minutes after the resolution.

#### Step 2: decide each suspect minute

Rules are applied in order; the first match wins.

| # | Rule | Verdict |
|---|---|---|
| 1 | The database did not exist yet | Excused |
| 2 | Zero or null, inside a resume window | Excused (auto-resume is the customer-configured behaviour of the serverless tier) |
| 3 | Zero, inside a customer Resource Health window | Excused |
| 4 | Zero, inside a platform Resource Health window | **Fault** |
| 5 | Null, and nothing explains it | Excused as a *metric gap* |
| 6 | Zero, and nothing explains it | **Unresolved** (counts against availability) |

Resume is decided before Resource Health on purpose: on serverless databases most `Unavailable` health events are a by-product of the resume itself.

#### Step 3: compute the result

- **Suspect** = every zero or null minute = Faults + Excused + Unresolved.
- **Faults** = minutes decided by rule 4. **Excused** = rules 1, 2, 3 and 5. **Unresolved** = rule 6.
- **Eligible minutes** = minutes in the period − Excused. Paused time stays eligible: it is not downtime, and the metric itself reads `100` there.
- **Availability %** = available minutes ÷ eligible minutes, or `N/A` when no minute is eligible.

#### Evidence for the minutes that count

For the Fault and Unresolved minutes, the narration lists the first five: the error codes of `connection_failed` with their counts, the number of successful connections of the same minute, the verdict and the Resource Health event that explained it. This needs one pair of metric calls per day that has such minutes (at most six days).

The narration also counts the Resource Health platform events that produced **no zero minute** and do not overlap a resume: brief failures that the metric does not count. With `-SourceWorkspaceId` every database is checked; without it, only the databases that already have suspect minutes can be.

#### Worked examples

| Situation | What the evidence shows | Result |
|---|---|---|
| Auto-resume of a paused serverless database | Resume `Started` 05:56:41 and `Succeeded` 05:57:11; the 05:57 minute reads `0` with three failed connections (`40613`); three successful connections follow in the next minute | Excused |
| Provisioned database, one minute with every connection failing | The minute reads `0`, `40613` three times, no successful connection, no resume, no Resource Health event | Unresolved: downtime by the definition of the metric |
| Failover with about two seconds of impact | Resource Health reports `Unavailable`; the metric stays at `100` because other connections succeeded | No suspect minute; counted as a brief platform event |
| Health event raised by a resume | `Unavailable` note overlapping a resume operation | Excused; not counted as a platform event |

#### Limits

- Treating auto-resume as expected behaviour is a policy choice: the Microsoft documentation describes the `40613` behaviour, but the documentation reviewed does not state how the SLA counts it. The resume minutes are reported separately in the narration (`auto-resume N`) so that a stricter figure can be recomputed.
- A real outage that starts in the same minutes as a resume is excused, because minutes are attributed by time only.
- Partial failures are not downtime by the definition of the metric, so they are reported but not scored.
- `-HealthLeadMinutes` (5) and the one-minute grace after a resume were validated on two subscriptions over two months.
- Without `-SourceWorkspaceId` the Activity Log and Resource Health evidence cover only what the REST APIs retain (about 30 days).

### Web Apps

#### What the signal means

A Web App has **no availability metric**. The App Service SLA (99.95% for the Basic, Standard, Premium and Isolated tiers; none for Free and Shared) measures the minutes the app is *set to running* ("Deployment Minutes": stopped time is excluded) and counts a minute as unavailable when the app has no connectivity to the Internet gateway. The closest signal a customer can observe is the HTTP traffic: the `Requests` and `Http5xx` metrics (aggregation `Total`, one-minute grain).

A **down minute** is a minute with at least one request in which **every** request failed with a 5xx (`Http5xx >= Requests`). Three kinds of minutes are deliberately not down:

- Minutes without requests cannot be judged and count as available.
- Minutes in which some requests succeeded are *partial*: they are reported, not scored.
- Minutes with only 4xx errors are client errors.

Other signals were evaluated and rejected:

| Signal | Why it is not used |
|---|---|
| `MemoryWorkingSet` (the previous signal) | It is `0` whenever the process is not running: stopped apps, Free tier, and Always On disabled after the idle timeout. In a September sample 99.95% of the 511,806 zero minutes had no request at all, so idle apps were reported as down (one subscription: 526,318 unresolved minutes, 11 of 154 apps below 50%) while real failures with the process up were invisible |
| `HealthCheckStatus` | Needs a health-check path configured on the app and has a 5-minute grain; none of the 20 apps sampled had data |
| Resource Health | In the sampled estate Web Apps had no health events since June and a REST history made of a single baseline row (`Available`, sometimes `Unknown`) |

The failures this algorithm finds are therefore mostly **application** errors (an app answering 5xx while its process is up, which the sampled failing minutes confirmed). They are what the app's users experience, but they are not necessarily the platform's fault: that is what the Unresolved and Fault columns separate.

#### Step 1: collect the evidence

1. **Hourly totals.** Read `Requests` and `Http5xx` for the whole period at one-hour grain (one call per app). An app with no request in the period is `N/A`.
2. **Minute detail.** For an app with any 5xx, read the same metrics at one-minute grain, in spans of 5 days (halved when Azure Monitor refuses a response as too large).
3. **Stopped periods and recycle windows.** Collect the `stop`, `start` and `restart` operations of the Activity Log. Events of one kind at most 5 minutes apart belong to one operation (a window never exceeds 15 minutes), because the Activity Log records each operation several times. A *recycle window* covers an operation plus `-ActivityGraceMinutes`. A *stopped period* runs from a stop to the next start or restart, or to the end of the period. With `-SourceWorkspaceId` the Activity Log is read from the workspace for all apps; without it, only for the apps that had 5xx.
4. **Creation time.** Minutes before the app was created are not eligible.
5. **Resource Health.** For an app with 5xx, read the combined history described in [Resource Health history](#resource-health-history) and turn it into windows exactly as for storage accounts. A platform window starts `-HealthLeadMinutes` before the note and ends two minutes after the resolution.

#### Step 2: decide each down minute

Rules are applied in order; the first match wins.

| # | Rule | Verdict |
|---|---|---|
| 1 | The app is stopped by the customer | Excused (the minute is not eligible) |
| 2 | Inside a recycle window of a stop, start or restart | Excused |
| 3 | Inside a customer Resource Health window | Excused |
| 4 | Inside a platform Resource Health window | **Fault** |
| 5 | Nothing explains it | **Unresolved** (counts against availability) |

#### Step 3: compute the result

- **Suspect** = every down minute = Faults + Excused + Unresolved.
- **Faults** = rule 4. **Excused** = rules 1, 2 and 3. **Unresolved** = rule 5.
- **Eligible minutes** = minutes since the app was created − every minute it was stopped (with or without traffic) − the down minutes excused by rules 2 and 3.
- **Availability %** = (eligible minutes − Faults − Unresolved) ÷ eligible minutes, or `N/A` when the app had no request or no eligible minute.
- An app on the Free or Shared tier gets its figure with a note that the SLA does not cover it.

#### Evidence for the minutes that count

For an app with down minutes the narration shows how many of its minutes with traffic were down, the three longest incidents (consecutive down minutes, at most 5 minutes apart) with their requests, verdict and Resource Health event, how many down minutes carried fewer than 5 requests, and a low-volume warning for an app with fewer than 10,000 requests in the period. Partial minutes are reported with the share of their requests that failed.

#### Worked examples

| Situation | What the evidence shows | Result |
|---|---|---|
| Idle Free-tier app, Always On disabled | No requests in the period; `MemoryWorkingSet` reads `0` | `N/A` (the previous signal reported downtime) |
| App stopped for a week by the customer | Stop and start operations in the Activity Log; no requests in between | Seven days leave the eligible minutes |
| Restart during deployment | 3 minutes with every request failing at the time of a `restart` | Excused (recycle window) |
| Always-failing internal app | 602 of 634 minutes with traffic down, 3,513 requests in the month, 573 of the down minutes with fewer than 5 requests | 98.6%, Unresolved, flagged low volume |
| Chronic partial errors | 14.8% of the requests fail, never all the requests of a minute | No down minute; reported as partial |
| Busy app, 5xx burst | 5,739 down minutes of 38,554 with traffic, no stop, no health event | 86.7%, Unresolved: the number to investigate |

In a September sample of 154 apps in one subscription, 142 had traffic, 29 had at least one down minute, and five apps held 8,057 of the 10,104 down minutes (none excused by a health window; 3 stopped, 18 recycle).

#### Limits

- A 5xx is what the customer sees, not necessarily what the platform did: an application bug counts as down. The Fault class stays rare because Resource Health rarely reports Web App events.
- A minute with a single failed request is down. Sparse apps swing widely; the low-volume warning and the count of down minutes with fewer than 5 requests show when this happens. Scoring such minutes partially was considered and rejected to keep the rule simple.
- An outage that stops requests from reaching the app leaves silent minutes, which cannot be judged.
- Only `stop`, `start` and `restart` excuse down minutes. Configuration changes and slot swaps also recycle an app, but no failing minute in the sampled data lined up with them.
- A stop that happened before the observation month is not seen, and without `-SourceWorkspaceId` an app without 5xx does not read the Activity Log: their stopped minutes stay eligible. This does not change the percentage, because a stopped app has no traffic, but it overstates the eligible minutes.
- Without `-SourceWorkspaceId` the Activity Log and Resource Health evidence cover only what the REST APIs retain (about 30 days).
