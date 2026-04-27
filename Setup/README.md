# Get-Availability Setup

This directory contains the Bicep infrastructure-as-code templates for deploying the Log Analytics ingestion infrastructure used by the Get-Availability script.

For a complete solution overview, pipeline description, and usage, see the [main README](../README.md).

## What it deploys

The Bicep template deploys the following resources into the target resource group:

| # | Resource | Purpose |
|---|----------|--------|
| 1 | **Log Analytics Workspace** | Stores availability data in custom tables; enables KQL queries and Workbooks |
| 2 | **Custom Table `GetAvailResources_CL`** | Per-resource availability detail (one row per resource per run) |
| 3 | **Custom Table `GetAvailSummary_CL`** | Aggregated summaries (per Kind+Location, per subscription, overall) |
| 4 | **Data Collection Endpoint (DCE)** | Ingestion URL for the Azure Monitor Ingestion API |
| 5 | **Data Collection Rule (DCR)** | Routes two custom streams to the corresponding tables with `TimeGenerated` injection |

## Prerequisites

- **Azure CLI** with Bicep support (`az bicep version`)
- **Contributor** role on the target resource group
- After deployment, the identity running the script needs **Monitoring Metrics Publisher** role on the DCR

## Parameters

Configured in `parameters.dev.bicepparam`:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `location` | Azure region for all resources (defaults to resource group location) | `italynorth` |
| `logAnalyticsWorkspaceName` | Name of the Log Analytics workspace | `log-getavail-itn-001` |
| `dataCollectionEndpointName` | Name of the Data Collection Endpoint | `dce-getavail-itn-001` |
| `dataCollectionRuleName` | Name of the Data Collection Rule | `dcr-getavail-itn-001` |

## Deployment

This is a **resource-group scoped** deployment. Create the resource group first, then deploy:

```powershell
# Create resource group (one-time)
az group create --name rg-getavail-itn-001 --location italynorth --tags solution=Get-Availability

# Validate
az deployment group validate --resource-group rg-getavail-itn-001 --parameters .\parameters.dev.bicepparam

# What-if (dry run)
az deployment group what-if --resource-group rg-getavail-itn-001 --parameters .\parameters.dev.bicepparam

# Deploy
az deployment group create --resource-group rg-getavail-itn-001 --parameters .\parameters.dev.bicepparam
```

## Outputs

After deployment, retrieve the values needed by the script:

| Output | Description |
|--------|-------------|
| `logAnalyticsWorkspaceId` | Workspace resource ID |
| `dceIngestionEndpoint` | DCE ingestion URL (pass to `-DceEndpoint`) |
| `dataCollectionRuleImmutableId` | DCR immutable ID (pass to `-DcrImmutableId`) |

```powershell
# Retrieve outputs
$outputs = (az deployment group show --resource-group rg-getavail-itn-001 --name getavailability --query properties.outputs -o json | ConvertFrom-Json)
$outputs.dceIngestionEndpoint.value
$outputs.dataCollectionRuleImmutableId.value
```

## Post-Deployment: RBAC

Grant the caller identity **Monitoring Metrics Publisher** on the DCR:

```powershell
az role assignment create `
  --assignee <user-or-managed-identity-id> `
  --role "Monitoring Metrics Publisher" `
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg-name>/providers/Microsoft.Insights/dataCollectionRules/<dcr-name>"
```

## Using with the script

Once deployed, pass the DCE endpoint and DCR immutable ID to the script:

```powershell
# Interactive
./get-availability.ps1 -Subscriptions 'MySub' -Month 202604 `
  -DceEndpoint 'https://dce-getavail-itn-001.italynorth-1.ingest.monitor.azure.com' `
  -DcrImmutableId 'dcr-00000000000000000000000000000000'

# From an Azure Function (managed identity — same parameters, auth is automatic)
./get-availability.ps1 -Subscriptions 'MySub' -Month 202604 `
  -DceEndpoint $env:DCE_ENDPOINT `
  -DcrImmutableId $env:DCR_IMMUTABLE_ID
```

When `-DceEndpoint` and `-DcrImmutableId` are omitted, the script produces console output only (no ingestion).

## Files

| File | Description |
|------|-------------|
| `getavailability.bicep` | Bicep template (resource-group scoped: workspace, tables, DCE, DCR) |
| `parameters.dev.bicepparam` | Parameter file for dev environment |
| `certlc.bicep` | CertLC infrastructure (separate solution, not related to Get-Availability) |
| `PLAN-log-analytics-ingestion.md` | Implementation plan for the ingestion feature |