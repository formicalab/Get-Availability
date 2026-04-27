# Plan: Ingest Get-Availability Results into Log Analytics Custom Tables

## Goal

After each run of Get-Availability, push the per-resource detail rows **and** the
aggregated summary rows into custom tables in a Log Analytics workspace so that
results can be queried with KQL, visualized in Workbooks, and trended over time.

---

## 1. Custom Tables

### Table A — `GetAvailResources_CL` (per-resource detail)

One row per resource per run. Carries the full availability breakdown.

| Column                     | Type       | Source / Notes                                           |
|----------------------------|------------|----------------------------------------------------------|
| `TimeGenerated`            | datetime   | Injected by DCR transform: `now()`                      |
| `RunId`                    | string     | GUID generated once per execution (correlates all rows)  |
| `Month`                    | string     | Observation month, e.g. `"202604"`                       |
| `PeriodStart`              | datetime   | UTC start of observation window                          |
| `PeriodEnd`                | datetime   | UTC end of observation window                            |
| `IsMonthToDate`            | boolean    | `true` if the run was mid-month                          |
| `SubscriptionName`         | string     | Azure subscription display name                          |
| `ResourceName`             | string     | Resource name                                            |
| `ResourceId`               | string     | Full ARM resource ID                                     |
| `ResourceGroup`            | string     | Resource group name                                      |
| `Kind`                     | string     | `VirtualMachine`, `AzureSqlDatabase`, `StorageAccount`, `WebApp` |
| `Location`                 | string     | Azure region                                             |
| `EligibleMinutes`          | int        | Minutes eligible for availability measurement            |
| `AvailableMinutes`         | real       | Actual available minutes (may be fractional due to degraded datapoints) |
| `SuspectMinutes`           | int        | Total suspect minutes from metric scan                   |
| `ConfirmedDowntimeMinutes` | int        | Platform-fault minutes confirmed by Resource Health      |
| `ExcusedMinutes`           | int        | Minutes excused from eligibility (lifecycle, customer, metric issues, zero-tx) |
| `UnexplainedSuspectMinutes`| int        | Suspect minutes remaining after all classification       |
| `AvailabilityPct`          | real       | Availability percentage (5 decimal places); -1 for N/A resources |

### Table B — `GetAvailSummary_CL` (aggregated summaries)

One row per aggregation group per run. Stores the subscription-level and
cross-subscription roll-ups.

| Column              | Type       | Source / Notes                                                    |
|---------------------|------------|-------------------------------------------------------------------|
| `TimeGenerated`     | datetime   | Injected by DCR transform: `now()`                               |
| `RunId`             | string     | Same GUID as the detail rows (for correlation)                    |
| `Month`             | string     | Observation month, e.g. `"202604"`                                |
| `PeriodStart`       | datetime   | UTC start of observation window                                   |
| `PeriodEnd`         | datetime   | UTC end of observation window                                     |
| `IsMonthToDate`     | boolean    | `true` if mid-month                                               |
| `SummaryLevel`      | string     | `KindLocation` / `SubscriptionTotal` / `Overall`                  |
| `SubscriptionName`  | string     | Subscription name (empty for `Overall` rows)                      |
| `Kind`              | string     | Resource kind (empty for `SubscriptionTotal` and `Overall` rows)  |
| `Location`          | string     | Azure region (empty for `SubscriptionTotal` and `Overall` rows)   |
| `ResourceCount`     | int        | Number of resources in this group                                 |
| `EligibleMinutes`   | real       | Sum of eligible minutes across resources in the group             |
| `AvailableMinutes`  | real       | Sum of available minutes across resources in the group            |
| `AvailabilityPct`   | real       | Aggregate availability percentage for the group                   |

---

## 2. Data Collection Endpoint (DCE)

A single DCE is created to provide the ingestion URL. Both tables will share
this endpoint. Network access will be set to `Enabled` (can be locked down
later with Private Link if needed).

**Resource:** `Microsoft.Insights/dataCollectionEndpoints`

---

## 3. Data Collection Rule (DCR)

A single DCR declares **two custom streams** — one per table — and routes each
stream to the corresponding custom table in the workspace.

| Stream                            | Target Table             |
|-----------------------------------|--------------------------|
| `Custom-GetAvailResources_CL`    | `GetAvailResources_CL`   |
| `Custom-GetAvailSummary_CL`      | `GetAvailSummary_CL`     |

Each stream has a `transformKql` that injects `TimeGenerated = now()` and
performs any necessary type coercion (e.g. `todatetime()` on the period
timestamps).

---

## 4. Bicep File: `getavailability.bicep`

The Bicep file uses `targetScope = 'subscription'` so it can create its own
dedicated resource group. It receives parameters for the resource group name,
Log Analytics workspace name, region, DCE name, and DCR name.

It creates (in order):

1. Resource group (dedicated to Get-Availability telemetry)
2. Log Analytics workspace (inside the new resource group)
3. Custom table `GetAvailResources_CL` (child of the workspace)
4. Custom table `GetAvailSummary_CL` (child of the workspace)
5. Data Collection Endpoint
6. Data Collection Rule (with `dependsOn` on both tables and the DCE)

Because the scope is `subscription`, the resource group is created via a
top-level `resource` declaration, and all other resources are deployed via a
Bicep module (or nested `module` with `scope: resourceGroup(...)`) targeting
the newly created resource group.

Deployment command changes accordingly:
```powershell
# Subscription-scoped deployment (no --resource-group flag)
az deployment sub create --location <region> --parameters .\parameters.dev.bicepparam
```

The Bicep file outputs:
- Resource group name
- Log Analytics workspace ID
- DCE ingestion endpoint URL
- DCR immutable ID
- DCR stream names (for the caller / script to use when posting data)

---

## 5. Implementation Steps (for later)

- [ ] **Step 1:** Write `getavailability.bicep` with resource group + Log Analytics workspace + custom tables + DCE + DCR
  - `targetScope = 'subscription'`
  - Create the resource group first, then deploy all other resources into it
    (using a Bicep module scoped to the new resource group)
- [ ] **Step 2:** Update `parameters.dev.bicepparam`:
  - Change the `using` directive from `'./certlc.bicep'` → `'./getavailability.bicep'`
  - Remove **all** CertLC-specific parameters:
    - `peSubnetId`, `fnSubnetId` (no private endpoints or function apps)
    - `dnsZonesSubscriptionId`, `dnsZonesResourceGroupName` (no private DNS)
    - `storageAccountName`, `functionAppName`, `applicationInsightsName` (not used)
    - `automationAccountName`, `hybridWorkerGroupName`, `runbookName` (not used)
    - `keyVaultName` (not used)
    - All `automationAccountVar*` parameters (not used)
  - Add **all** parameters required by `getavailability.bicep`:
    - `resourceGroupName` — name of the dedicated resource group to create
    - `location` — Azure region for all resources
    - `logAnalyticsWorkspaceName` — name of the Log Analytics workspace to create
    - `dataCollectionEndpointName` — name for the DCE
    - `dataCollectionRuleName` — name for the DCR
  - The resulting file should be minimal, e.g.:
    ```bicepparam
    using './getavailability.bicep'
    param resourceGroupName = 'rg-getavail-itn-001'
    param location = 'italynorth'
    param logAnalyticsWorkspaceName = 'log-getavail-itn-001'
    param dataCollectionEndpointName = 'dce-getavail-itn-001'
    param dataCollectionRuleName = 'dcr-getavail-itn-001'
    ```
- [ ] **Step 3:** Add new **optional** parameters to `get-availability.ps1`:
  - `-DceEndpoint [string]` — DCE logs ingestion URL (from Bicep output `dceIngestionEndpoint`)
  - `-DcrImmutableId [string]` — DCR immutable ID (from Bicep output `dataCollectionRuleImmutableId`)
  - Both are optional; ingestion happens **only** when both are provided
  - When omitted, the script behaves exactly as today (console output only)
  - Add validation: if one is supplied without the other, throw an error
  - Use a `$sendToLogAnalytics = $DceEndpoint -and $DcrImmutableId` flag to guard all
    ingestion code paths — zero overhead when ingestion is not requested
- [ ] **Step 4:** Add a helper function `Send-ToLogAnalytics` in `get-availability.ps1`:
  - Uses the **Azure Monitor Ingestion** REST API
    (`POST https://{dce-endpoint}/dataCollectionRules/{dcr-immutableId}/streams/{streamName}?api-version=2023-01-01`)
  - **Authentication — dual execution context:**
    The script runs in two environments and must acquire an Azure Monitor token in both:
    1. **Interactive** (`az login` / `Connect-AzAccount`): use `Get-AzAccessToken`
       with `-ResourceUrl 'https://monitor.azure.com'`, same pattern as the existing
       ARM token acquisition in Step 2
    2. **Azure Function** (managed identity): the `Az.Accounts` module is available in
       the PowerShell worker; `Connect-AzAccount -Identity` is typically run at function
       startup (or by the host), so `Get-AzAccessToken` works identically — no code change
       needed for this path
    Implementation: acquire the monitor token once near the top of the ingestion block
    (right after the existing ARM token), using the same `Get-AzAccessToken` +
    `SecureString` handling pattern already in the script:
    ```powershell
    $rawMonitor = (Get-AzAccessToken -ResourceUrl 'https://monitor.azure.com').Token
    $monitorToken = ($rawMonitor -is [securestring]) `
        ? ($rawMonitor | ConvertFrom-SecureString -AsPlainText) : [string]$rawMonitor
    $rawMonitor = $null
    ```
  - Accepts: endpoint URL, DCR immutable ID, stream name, bearer token, and an array of
    PSObjects (the payload)
  - Serializes the array to JSON with `ConvertTo-Json -Depth 5 -Compress`
  - Sets `Content-Type: application/json` and `Content-Encoding: gzip` (gzip the body for efficiency)
  - Handles the Ingestion API's 1 MB per call limit: if the payload exceeds ~900 KB, split into batches
  - Returns nothing on success (204); throws on failure with status code and body
- [ ] **Step 5:** Build and send the **per-resource detail** payload after Step 8 (output):
  - Generate a `$runId = [guid]::NewGuid().ToString()` once per execution
  - Map each `$eligByRes` entry to a hashtable matching the `Custom-GetAvailResources_CL` stream schema:
    ```
    @{
        RunId                    = $runId
        Month                    = $normalizedMonth
        PeriodStart              = $utcStart.ToString('o')
        PeriodEnd                = $utcEnd.ToString('o')
        IsMonthToDate            = $isMonthToDate
        SubscriptionName         = $elig.SubscriptionName
        ResourceName             = $elig.Name
        ResourceId               = $elig.ResourceId
        ResourceGroup            = $elig.ResourceGroupName
        Kind                     = $elig.Kind
        Location                 = $elig.Location
        EligibleMinutes          = $elig.EligibleMinutes
        AvailableMinutes         = $elig.AvailableMinutes
        SuspectMinutes           = $elig.SuspectMinutes
        ConfirmedDowntimeMinutes = $elig.ConfirmedDowntimeMinutes
        ExcusedMinutes           = $elig.ExcusedMinutes
        UnexplainedSuspectMinutes= $elig.UnexplainedSuspectMinutes
        AvailabilityPct          = if ($elig.AvailabilityPct -eq 'N/A') { -1 } else { [double]$elig.AvailabilityPct }
    }
    ```
  - Call `Send-ToLogAnalytics` with stream name `Custom-GetAvailResources_CL`
- [ ] **Step 6:** Build and send the **summary** payload:
  - Reuse the same grouping logic already in `Write-SubscriptionSummaries` to produce rows:
    - One row per Kind+Location per subscription (`SummaryLevel = 'KindLocation'`)
    - One row per subscription total (`SummaryLevel = 'SubscriptionTotal'`)
    - One overall row across all subscriptions (`SummaryLevel = 'Overall'`, only if >1 subscription)
  - Each row is a hashtable matching the `Custom-GetAvailSummary_CL` stream schema
  - Call `Send-ToLogAnalytics` with stream name `Custom-GetAvailSummary_CL`
- [ ] **Step 7:** Add RBAC: the caller identity needs **Monitoring Metrics Publisher** role on the DCR
  - Document this in the script help text and in the Bicep file comments
  - The Bicep file should optionally accept a principal ID to assign the role (or leave it as a manual step)
- [ ] **Step 8:** Rewrite `Setup/README.md` for Get-Availability (replace CertLC content):
  - **Remove entirely** all CertLC-specific content:
    - Title, description, and solution overview references to CertLC
    - Prerequisites: VNet/subnet requirements, Private DNS Zones, Hybrid Worker VM
    - RBAC section: Owner role, Private DNS Zone Contributor, all CertLC role assignment tables
    - Resources Created: all 16 CertLC resources (Storage Account, Function App, Automation Account,
      Key Vault, Event Grid, Private Endpoints, DNS Zone Groups, Workbook, etc.)
    - Parameters table: all CertLC parameters (peSubnetId, fnSubnetId, dnsZones*, storage*, function*,
      automation*, keyVault*, automationAccountVar*, scheduleStartTime)
    - Post-Deployment Steps: hybrid worker registration, runbook upload, certlcstats schedule,
      function app deployment, CA permissions, workbook customization, end-to-end testing
    - Security Notes section (CertLC-specific)
    - Manual Configuration (on-premises CA) section
    - Files section listing `certlc.bicep`
  - **Replace with** Get-Availability infrastructure content:
    - Title: "Get-Availability Setup" (or similar)
    - Purpose: deploys custom Log Analytics tables, DCE, and DCR for ingesting
      Get-Availability script results
    - Prerequisites: Contributor role on the subscription (to create the resource
      group and resources), Monitoring Metrics Publisher on the DCR for the caller identity
    - Deployment commands: subscription-scoped (`az deployment sub create --location <region>
      --parameters .\parameters.dev.bicepparam`) — no `--resource-group` flag
    - Resources Created: 6 resources — 1 resource group, 1 Log Analytics workspace,
      2 custom tables, 1 DCE, 1 DCR
    - Parameters table: `resourceGroupName`, `location`, `logAnalyticsWorkspaceName`,
      `dataCollectionEndpointName`, `dataCollectionRuleName`
    - Outputs: DCE ingestion endpoint, DCR immutable ID
    - Post-Deployment: how to use `-DceEndpoint` / `-DcrImmutableId` with the script
    - Files section listing `getavailability.bicep`, `parameters.dev.bicepparam`, and this README

---

## Design Decisions & Rationale

- **Two tables** instead of one: the per-resource table has ~17 columns with
  detailed investigation fields that don't apply to summaries. The summary
  table has `SummaryLevel`, `ResourceCount` etc. that don't apply to individual
  resources. Separate tables keep KQL queries cleaner and avoid wide sparse rows.
- **RunId + Month** as correlation keys: allows querying "latest run for month
  X" or "all runs for month X" (useful when mid-month runs are repeated).
- **AvailabilityPct as real (-1 for N/A):** avoids a string column that would
  complicate numeric KQL queries. -1 signals excluded resources.
- **Single DCR with two streams:** reduces resource count and keeps routing
  in one place. The Ingestion API supports specifying the stream name per call.
- **`TimeGenerated` via DCR transform:** standard Log Analytics pattern;
  the script doesn't need to supply it.
- **PowerShell-only implementation:** the ingestion feature targets the
  PowerShell script (`get-availability.ps1`). The C# version is not updated
  for this feature.
- **Strictly optional ingestion:** when `-DceEndpoint` and `-DcrImmutableId` are
  omitted, zero ingestion code runs. No token is acquired, no payloads are built,
  no REST calls are made. Console output is always produced regardless.
- **Dual execution context (interactive + Azure Function):** the script already
  depends on `Az.Accounts`. Both `az login` (interactive) and managed-identity
  (Azure Function) contexts expose `Get-AzAccessToken`, so the same code path
  acquires the `https://monitor.azure.com` bearer token in both environments.
  No conditional logic or separate auth path is needed.
- **REST API over SDK:** using the Azure Monitor Ingestion REST API directly
  (with `Invoke-RestMethod`) avoids adding a PowerShell module dependency.
  Authentication reuses the existing `Az.Accounts` session via `Get-AzAccessToken`.
- **Subscription-scoped Bicep with dedicated resource group:** the Bicep creates
  its own resource group so the deployment is self-contained — no pre-existing
  resource group or workspace is needed. The deployer only needs Contributor
  on the subscription. This also keeps Get-Availability telemetry resources
  isolated from other workloads.
