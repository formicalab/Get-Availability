/*

Get-Availability — Bicep template for Log Analytics ingestion infrastructure.

Creates a dedicated resource group containing a Log Analytics workspace,
two custom tables, a Data Collection Endpoint (DCE), and a Data Collection
Rule (DCR) for ingesting Get-Availability script results.

Validate:  az deployment sub validate  --location <region> --parameters .\parameters.dev.bicepparam
What-if:   az deployment sub what-if   --location <region> --parameters .\parameters.dev.bicepparam
Deploy:    az deployment sub create    --location <region> --parameters .\parameters.dev.bicepparam

*/

metadata name = 'Get-Availability Infrastructure'
metadata description = 'Log Analytics workspace, custom tables, DCE, and DCR for Get-Availability telemetry ingestion'

targetScope = 'subscription'

// ── Parameters ───────────────────────────────────────────────────────────────

@description('Name of the dedicated resource group to create.')
param resourceGroupName string

@description('Azure region for all resources.')
param location string

@description('Name of the Log Analytics workspace to create.')
param logAnalyticsWorkspaceName string

@description('Name of the Data Collection Endpoint.')
param dataCollectionEndpointName string

@description('Name of the Data Collection Rule.')
param dataCollectionRuleName string

// ── Resource Group ───────────────────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: {
    solution: 'Get-Availability'
  }
}

// ── Module: all resources inside the new resource group ──────────────────────

module resources 'getavailability-resources.bicep' = {
  name: 'getavailability-resources'
  scope: rg
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    dataCollectionEndpointName: dataCollectionEndpointName
    dataCollectionRuleName: dataCollectionRuleName
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output resourceGroupName string = rg.name
output logAnalyticsWorkspaceId string = resources.outputs.logAnalyticsWorkspaceId
output dceIngestionEndpoint string = resources.outputs.dceIngestionEndpoint
output dataCollectionRuleImmutableId string = resources.outputs.dataCollectionRuleImmutableId
