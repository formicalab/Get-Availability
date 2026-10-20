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
| `-TopImpact` | `10` | How many resources the closing "most impact" section lists (`0` turns it off) |
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

The console output includes the observation window, any Resource Health coverage warning, a per-resource table, aggregated summaries and, at the end, the resources with the most impact. The PowerShell version also emits objects to the pipeline so you can export to CSV or JSON.

Resources with zero eligible minutes are shown as `N/A`.

#### Resources with most impact

The last section ranks, across all subscriptions, the resources that lost the most minutes (eligible minutes minus available minutes). Because every summary is the sum of those minutes, the lost minutes are also the weight of the resource in the aggregate figures. Each resource takes a header line (its availability, the lost minutes and its share of all the lost minutes) and one line per cause, the heaviest first:

```
 3. tmonrenvm01azne  (VM, northeurope, POSTE-BANCOPOSTA-SVILUPPO)
    99,99305% available: lost 3,00 of 43.186 eligible min (3,7% of all lost minutes)
           3,00 min  platform fault  Resource Health 'Remote disk disconnected' - at 2026-09-20 10:32Z
```

A cause line gives the minutes it cost, the verdict that counts against availability (`platform fault` or `unresolved`; excused minutes are not shown, they are not a loss), what happened with its evidence, and where it happened (start times, three at most; when a cause has several occurrences each one also shows its length):

- VMs: the Resource Health note of the fault, the metric Context, or "zero availability that nothing explains" for an unresolved zero;
- SQL databases: the Resource Health event or its absence, with the failed connections summed by error code and the successful connections of the same minutes;
- storage accounts: storage is scored per hour, not as minutes down (an hour loses failed / counted requests x 60 min), so the header reads "failure rate worth N min" and a `note:` says how many failing minutes that is worth. A cause gives the failing minutes that count and the failed requests, the span and number of incidents (runs of failing minutes) when there are several, the largest incidents with their start, and the Resource Health event or its absence;
- Web Apps: the down minutes that count, with their incidents and failed requests, and the Resource Health event or its absence.

`note:` lines follow when the figure rests on little data (low volume, many down minutes with fewer than 5 requests, a tier outside the SLA, incomplete minute detail). The size of the list is set with `-TopImpact`.

## How it works

1. The resource inventory comes from Azure Resource Graph.
2. Each resource kind is measured from its own Azure Monitor signal and turned into *suspect minutes* (minutes that may count against availability).
3. Every suspect minute is attributed with the Activity Log and Resource Health (VMs and SQL databases also use the metric itself), and ends as a fault, an excused minute or an unresolved minute.
4. Availability is computed from the eligible minutes and the available minutes.

Steps 2 and 3 are different for each resource kind, and each algorithm is described only in [Algorithms](#algorithms): [virtual machines](#virtual-machines), [Azure SQL databases](#azure-sql-databases), [storage accounts](#storage-accounts) and [Web Apps](#web-apps). With `-SourceWorkspaceId` the Activity Log and the Resource Health events are read in bulk from Log Analytics (see [Resource Health history](#resource-health-history)).

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

The template supports two network modes controlled by `usePrivateEndpoints`:

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

Downtime is binary, as in the Microsoft SLA, where a minute is either down or not. A minute is **suspect** when the metric is `0` or null. The algorithm decides, for every suspect minute, whether it is a fault, is excused, or stays unresolved. A fractional value (above `0` and below `1`) is not downtime: the VM still had connectivity in part of the minute. Those minutes stay eligible and available, and the console reports how many there were.

#### Step 1: collect the evidence

1. **Metric.** Read the unsplit series. It is the base signal: every minute is available, null, zero or fractional (fractional minutes are only counted, never classified).
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
| 9 | Zero, and nothing explains it | **Unresolved** (counts against availability) |

Three details matter in practice:

- A `Recovery` or `Unknown` note logged seconds after a platform-outage note does not hide it (rule 6). Only a later customer action does.
- A measured zero is attributed before lifecycle windows are consulted (rules 2 and 3), so a platform failure that happens during a customer restart is still a fault.
- Rule 8 is deliberately generous: a missing sample is not evidence of downtime. The console narration lists metric gaps separately so they stay visible.

#### Step 3: compute the result

- **Suspect** = every zero or null minute = Faults + Excused + Unresolved.
- **Faults** = minutes decided by rules 2 and 6.
- **Excused** = minutes decided by rules 1, 3, 4, 5, 7 and 8.
- **Unresolved** = minutes decided by rule 9.
- **Eligible minutes** = minutes in the period − Excused.
- **Downtime** = Faults + Unresolved.
- **Availability %** = (Eligible − Downtime) ÷ Eligible × 100, or `N/A` when no minute is eligible.

This is the SLA formula, `Uptime Percentage = (Maximum Available Minutes − Downtime) ÷ Maximum Available Minutes × 100`, with the eligible minutes as *Maximum Available Minutes*. The script's **Availability %** is that Uptime Percentage.

#### Differences from the official SLA

The [Online Services SLA](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services) defines Virtual Machines downtime as a minute with no connectivity to the VM, and Uptime Percentage as `(Maximum Available Minutes − Downtime) ÷ Maximum Available Minutes × 100`. The script follows that formula, but it cannot see what Microsoft sees, so it differs in these ways:

| Official SLA | This script | Why |
|---|---|---|
| Downtime is a minute with no connectivity to the VM | Downtime is a minute where `VmAvailabilityMetric` is `0` | Azure gives customers no connectivity measure. The metric is the host's view of the VM: it misses a hung guest or a network-path problem, and it can differ from what the SLA would count |
| Microsoft decides which minutes are caused by the platform and which are excluded (maintenance, customer actions, throttling) | The script attributes each minute from the metric `Context`, the Activity Log and Resource Health, with a grace window (`-ActivityGraceMinutes`) and a fault window (`-FaultWindowMinutes`) | Microsoft's internal telemetry and its cause attribution are not available to customers, so the script uses heuristics on the public evidence |
| A minute the platform cannot measure is not discussed | A null minute that nothing explains is excused as a *metric gap* | A missing sample is not evidence of downtime. The console lists these minutes so they stay visible |
| Only platform-caused downtime counts | A zero minute that nothing explains is **Unresolved** and counts as downtime | The script cannot tell who caused it, so it is conservative and keeps the minute visible in the report. Unresolved minutes are reported separately from Faults |
| The SLA depends on the deployment: zones, availability sets, dedicated host groups, or a single instance with Premium or Standard disks | Each VM is measured on its own, with no class distinction | Redundancy and disk type are out of scope for now. A VM in an availability set or zone is still scored as a single VM |
| Uptime Percentage is pooled per subscription | Results are reported per subscription and region, and each VM has its own figure | The report needs a regional split, and one subscription can hold VMs in several regions |
| Compares the result with the SLA target and defines service credits | No comparison with a target | Not in scope: the script reports the measured availability only |
| Maximum Available Minutes counts the minutes the VM is deployed and running | Eligible minutes = period minutes − Excused minutes (before creation, customer stops, lifecycle operations, planned events) | The metric and the Activity Log show only the customer-caused and planned stops they can see |
| A partial minute is not discussed | A fractional metric value is not downtime and the minute stays available | The SLA counts only a minute with no connectivity, so a partly available minute is not downtime. The console reports how many there were |

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

The portal's storage `Availability` metric is the share of billable requests that succeeded, but its `Minimum` aggregation is the *worst single series* of the minute (one `ApiName`, `Authentication` and `GeoType` combination), whatever its volume. A single failed request can therefore turn a whole minute into 0%, and a quiet account looks much worse than a busy one with the same failure count. The algorithm does not use it. It follows the definition of the [Azure Storage SLA](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services): the **Error Rate of an hour** is failed requests ÷ counted requests, and availability is the Uptime Percentage: 100% minus the Average Error Rate, the sum of the hourly Error Rates divided by the hours of the Applicable Period (here, the period of the run). An hour with no traffic has a 0% Error Rate, so idle time counts as available.

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
- **A paused database is not operational, but the metric does not say so.** It reads `100` for every paused minute. The SLA counts only the minutes a database has been *operational* (its Deployment Minutes), so those minutes must leave the denominator. A serverless database bills no compute while it is paused, and the `app_cpu_billed` metric then has no value, which tells the paused minutes apart.

In a September sample of 181 databases, every one of the 375 zero minutes had error `40613` and no successful connection in the minute, and 97% of them sat inside a resume operation.

#### Step 1: collect the evidence

1. **Metric.** Read `availability` for the whole period. Count the zero and null minutes.
2. **Resume windows.** Collect the `resume` operations of the Activity Log, including the ones the platform logs itself (`Microsoft.Sql/servers/databases/resume`) and the ones triggered by a user (`.../resume/action`). Group the events of one operation by proximity: consecutive events at most 5 minutes apart belong together, and a window never exceeds 15 minutes. A window runs from the minute of its first event to one minute after the minute of its last event. Grouping by correlation ID would join every resume of the period into one window, because the platform's own events share a zero ID. A failed operation leaves a lone `Started` event that explains a single minute. Pause operations are not used to explain zero minutes: no zero minute was ever explained by a pause alone.
3. **Failover windows.** Collect the `failover` operations of the Activity Log (`.../failover/action`), which the customer starts. They are grouped into windows like the resume operations.
4. **Creation time.** Minutes before the creation time of the database are not Deployment Minutes.
5. **Billed compute (serverless databases only, SKU name containing `_S_`).** Read `app_cpu_billed` (aggregation `Total`, one-minute grain). A run of at least 5 consecutive minutes without a value is a pause. Shorter holes are gaps in the telemetry, not pauses. The latest 15 minutes of a period that ends now have no data yet and are not judged. The zero minutes that count against availability (Faults and Unresolved) are never treated as paused, so a failure cannot hide as a pause.
6. **Resource Health.** Read the combined history described in [Resource Health history](#resource-health-history) and turn it into windows, as for storage accounts: a window opens at an `Unavailable` or `Degraded` note and closes at the next `Available` note. Windows of customer-caused events are customer windows, and windows of planned maintenance (reason `Planned`, or details saying "planned maintenance") are planned windows. A platform window starts `-HealthLeadMinutes` before the note and ends two minutes after the resolution.

#### Step 2: decide each suspect minute

Rules are applied in order; the first match wins.

| # | Rule | Verdict |
|---|---|---|
| 1 | The database did not exist yet | Not a Deployment Minute |
| 2 | Zero or null, inside a resume window | Excused (auto-resume is the customer-configured behaviour of the serverless tier) |
| 3 | Zero, inside a failover window | Excused (the customer's own operation) |
| 4 | Zero, inside a customer Resource Health window | Excused |
| 5 | Zero, inside a planned-maintenance Resource Health window | Excused (the SLA's Scheduled Downtime) |
| 6 | Zero, inside a platform Resource Health window | **Fault** |
| 7 | Null, and nothing explains it | Excused as a *metric gap* |
| 8 | Zero, and nothing explains it | **Unresolved** (counts against availability) |

Resume is decided before Resource Health on purpose: on serverless databases most `Unavailable` health events are a by-product of the resume itself.

#### Step 3: compute the result

- **Suspect** = every zero or null minute = Faults + Excused + Unresolved (the minutes before creation are in the Excused column).
- **Faults** = minutes decided by rule 6. **Excused** = rules 1, 2, 3, 4, 5 and 7. **Unresolved** = rule 8.
- **Eligible minutes** are the SLA's *Maximum Available Minutes* (the database's *Deployment Minutes*) = minutes in the period − minutes before creation − paused minutes. Every other excused minute stays eligible: the SLA excludes those from Downtime, not from the denominator.
- **Downtime** = Faults + Unresolved.
- **Availability %** is the Uptime Percentage = (Eligible − Downtime) ÷ Eligible × 100, or `N/A` when no minute is eligible.

#### Differences from the official SLA

The [Online Services SLA](https://www.microsoft.com/licensing/docs/view/Service-Level-Agreements-SLA-for-Online-Services) defines Azure SQL Database downtime as a minute in which all continuous connection attempts fail, and the Uptime Percentage as `(Maximum Available Minutes − Downtime) ÷ Maximum Available Minutes × 100`, with Maximum Available Minutes the sum of the Deployment Minutes of the Databases of a subscription. The script follows that formula. It differs in these ways:

| Official SLA | This script | Why |
|---|---|---|
| A minute is unavailable when all connection attempts of the minute fail | A minute is down when the `availability` metric reads `0` (every attempt failed with a system error) | The metric follows the same definition. It is the closest measure a customer can read |
| Microsoft decides which downtime is excluded (customer operations, Scheduled Downtime, throttling, faulty input) | The script uses the Activity Log (resume, failover) and Resource Health (customer, planned) to excuse minutes | Microsoft's internal attribution is not available to customers. Changes of the service objective (scaling) are `databases/write` events like the many configuration writes of the same name, so they cannot be told apart and are not excused unless Resource Health says they were customer-caused |
| Scheduled Downtime needs a notice of 5 days | A Resource Health note of planned maintenance counts as Scheduled Downtime, without checking the notice | The notice is not visible to customers. Resource Health only says that the event was planned |
| A paused database is not operational and is not a Deployment Minute | Serverless databases: the minutes without billed compute (runs of at least 5) leave the denominator. The SLA text never mentions serverless or auto-pause, so this is an interpretation of "operational" | Azure Monitor has no pause state. The billed-compute metric is the only per-minute signal. Provisioned databases never pause |
| Zero minutes are downtime unless excluded | A zero minute that nothing explains is **Unresolved** and counts as downtime | The script cannot tell who caused it, so it is conservative. Unresolved minutes are reported apart from Faults |
| Maximum Available Minutes are summed over the Databases of a subscription | Minutes are summed per subscription and region | The report needs a regional split, and one subscription can hold databases in several regions |
| The Applicable Period of pay-as-you-go services is the 30 days up to the incident | The period is a calendar month (UTC) | A monthly report is what the script produces |
| Service levels depend on the tier and on zone redundancy, with Service Credits | No comparison with a target | Not in scope: the script reports the measured availability only |
| The SLA covers Azure SQL Database only | The inventory excludes the system database and dedicated SQL pools (Azure Synapse). Managed Instance is a separate service and is not read | Their SLAs are different |
| Geo-replication RPO and RTO | Not measured | Azure Monitor does not expose them |

#### Evidence for the minutes that count

For the Fault and Unresolved minutes, the narration lists the first five: the error codes of `connection_failed` with their counts, the number of successful connections of the same minute, the verdict and the Resource Health event that explained it. This needs one pair of metric calls per day that has such minutes (at most six days).

The narration also counts the Resource Health platform events that produced **no zero minute** and do not overlap a resume or a failover: brief failures that the metric does not count. Planned maintenance is not counted. With `-SourceWorkspaceId` every database is checked; without it, only the databases that already have suspect minutes can be.

#### Worked examples

| Situation | What the evidence shows | Result |
|---|---|---|
| Auto-resume of a paused serverless database | Resume `Started` 05:56:41 and `Succeeded` 05:57:11; the 05:57 minute reads `0` with three failed connections (`40613`); three successful connections follow in the next minute | Excused |
| Provisioned database, one minute with every connection failing | The minute reads `0`, `40613` three times, no successful connection, no resume, no Resource Health event | Unresolved: downtime by the definition of the metric |
| Failover with about two seconds of impact | Resource Health reports `Unavailable`; the metric stays at `100` because other connections succeeded | No suspect minute; counted as a brief platform event |
| Health event raised by a resume | `Unavailable` note overlapping a resume operation | Excused; not counted as a platform event |
| Monthly maintenance of the platform | One zero minute with error `40613`; the Resource Health note says "unavailable due to planned maintenance" | Excused (Scheduled Downtime) |
| Serverless database that pauses every night | `app_cpu_billed` has no value for about 12 hours a day, the metric reads `100` | Those minutes are not Deployment Minutes; in one sample databases were paused 49% to 98% of the month |
| One minute without billed compute in a running database | A hole of 1 to 3 minutes in the telemetry | Not a pause (a pause is at least 5 minutes) |

#### Limits

- Treating auto-resume as expected behaviour is a policy choice: the Microsoft documentation describes the `40613` behaviour, but the documentation reviewed does not state how the SLA counts it. The resume minutes are reported separately in the narration (`auto-resume N`) so that a stricter figure can be recomputed.
- Treating a paused serverless database as not operational is also an interpretation: the SLA does not mention serverless. Counting those minutes as available instead would raise the eligible minutes and leave the downtime unchanged.
- A real outage that starts in the same minutes as a resume, a failover or a planned-maintenance note is excused, because minutes are attributed by time only.
- A failover is excused only when the Activity Log holds it. A failover started inside Azure (not by the customer) is a platform event and is attributed through Resource Health.
- A change of the service objective is not excused unless Resource Health reports it as customer-caused (see the table above).
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
| `MemoryWorkingSet` | It is `0` whenever the process is not running: stopped apps, Free tier, and Always On disabled after the idle timeout. In a September sample 99.95% of the 511,806 zero minutes had no request at all, so idle apps would be reported as down (in one subscription: 526,318 unresolved minutes, 11 of 154 apps below 50%) while real failures with the process up would be invisible |
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
| Idle Free-tier app, Always On disabled | No requests in the period; `MemoryWorkingSet` reads `0` | `N/A` (`MemoryWorkingSet` would report downtime) |
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
