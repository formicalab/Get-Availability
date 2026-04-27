/*

Get-Availability — Resource module deployed into the dedicated resource group.

Creates: Log Analytics workspace, two custom tables (GetAvailResources_CL,
GetAvailSummary_CL), Data Collection Endpoint, and Data Collection Rule.

This file is invoked as a module from getavailability.bicep and should not
be deployed directly.

*/

// ── Parameters ───────────────────────────────────────────────────────────────

param location string
param logAnalyticsWorkspaceName string
param dataCollectionEndpointName string
param dataCollectionRuleName string

// ── Variables ────────────────────────────────────────────────────────────────

var commonTags = {
  solution: 'Get-Availability'
}

// ── Log Analytics Workspace ──────────────────────────────────────────────────

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
  tags: commonTags
}

// ── Custom Table: GetAvailResources_CL (per-resource detail) ─────────────────

resource resourcesTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: 'GetAvailResources_CL'
  parent: logAnalyticsWorkspace
  properties: {
    retentionInDays: 30
    schema: {
      name: 'GetAvailResources_CL'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'RunId', type: 'string' }
        { name: 'Month', type: 'string' }
        { name: 'PeriodStart', type: 'dateTime' }
        { name: 'PeriodEnd', type: 'dateTime' }
        { name: 'IsMonthToDate', type: 'boolean' }
        { name: 'SubscriptionName', type: 'string' }
        { name: 'ResourceName', type: 'string' }
        { name: 'ResourceId', type: 'string' }
        { name: 'ResourceGroup', type: 'string' }
        { name: 'Kind', type: 'string' }
        { name: 'Location', type: 'string' }
        { name: 'EligibleMinutes', type: 'int' }
        { name: 'AvailableMinutes', type: 'real' }
        { name: 'SuspectMinutes', type: 'int' }
        { name: 'ConfirmedDowntimeMinutes', type: 'int' }
        { name: 'ExcusedMinutes', type: 'int' }
        { name: 'UnexplainedSuspectMinutes', type: 'int' }
        { name: 'AvailabilityPct', type: 'real' }
      ]
    }
  }
}

// ── Custom Table: GetAvailSummary_CL (aggregated summaries) ──────────────────

resource summaryTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: 'GetAvailSummary_CL'
  parent: logAnalyticsWorkspace
  properties: {
    retentionInDays: 30
    schema: {
      name: 'GetAvailSummary_CL'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'RunId', type: 'string' }
        { name: 'Month', type: 'string' }
        { name: 'PeriodStart', type: 'dateTime' }
        { name: 'PeriodEnd', type: 'dateTime' }
        { name: 'IsMonthToDate', type: 'boolean' }
        { name: 'SummaryLevel', type: 'string' }
        { name: 'SubscriptionName', type: 'string' }
        { name: 'Kind', type: 'string' }
        { name: 'Location', type: 'string' }
        { name: 'ResourceCount', type: 'int' }
        { name: 'EligibleMinutes', type: 'real' }
        { name: 'AvailableMinutes', type: 'real' }
        { name: 'AvailabilityPct', type: 'real' }
      ]
    }
  }
}

// ── Data Collection Endpoint ─────────────────────────────────────────────────

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dataCollectionEndpointName
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
  tags: commonTags
}

// ── Data Collection Rule (two streams, one per table) ────────────────────────

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id

    // Stream declarations — columns sent by the script (no TimeGenerated; injected by transform)
    streamDeclarations: {
      'Custom-GetAvailResources_CL': {
        columns: [
          { name: 'RunId', type: 'string' }
          { name: 'Month', type: 'string' }
          { name: 'PeriodStart', type: 'string' }
          { name: 'PeriodEnd', type: 'string' }
          { name: 'IsMonthToDate', type: 'boolean' }
          { name: 'SubscriptionName', type: 'string' }
          { name: 'ResourceName', type: 'string' }
          { name: 'ResourceId', type: 'string' }
          { name: 'ResourceGroup', type: 'string' }
          { name: 'Kind', type: 'string' }
          { name: 'Location', type: 'string' }
          { name: 'EligibleMinutes', type: 'int' }
          { name: 'AvailableMinutes', type: 'real' }
          { name: 'SuspectMinutes', type: 'int' }
          { name: 'ConfirmedDowntimeMinutes', type: 'int' }
          { name: 'ExcusedMinutes', type: 'int' }
          { name: 'UnexplainedSuspectMinutes', type: 'int' }
          { name: 'AvailabilityPct', type: 'real' }
        ]
      }
      'Custom-GetAvailSummary_CL': {
        columns: [
          { name: 'RunId', type: 'string' }
          { name: 'Month', type: 'string' }
          { name: 'PeriodStart', type: 'string' }
          { name: 'PeriodEnd', type: 'string' }
          { name: 'IsMonthToDate', type: 'boolean' }
          { name: 'SummaryLevel', type: 'string' }
          { name: 'SubscriptionName', type: 'string' }
          { name: 'Kind', type: 'string' }
          { name: 'Location', type: 'string' }
          { name: 'ResourceCount', type: 'int' }
          { name: 'EligibleMinutes', type: 'real' }
          { name: 'AvailableMinutes', type: 'real' }
          { name: 'AvailabilityPct', type: 'real' }
        ]
      }
    }

    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspace.id
          name: 'workspace'
        }
      ]
    }

    dataFlows: [
      {
        streams: [ 'Custom-GetAvailResources_CL' ]
        destinations: [ 'workspace' ]
        transformKql: 'source | extend TimeGenerated = now(), PeriodStart = todatetime(PeriodStart), PeriodEnd = todatetime(PeriodEnd)'
        outputStream: 'Custom-GetAvailResources_CL'
      }
      {
        streams: [ 'Custom-GetAvailSummary_CL' ]
        destinations: [ 'workspace' ]
        transformKql: 'source | extend TimeGenerated = now(), PeriodStart = todatetime(PeriodStart), PeriodEnd = todatetime(PeriodEnd)'
        outputStream: 'Custom-GetAvailSummary_CL'
      }
    ]
  }
  dependsOn: [
    resourcesTable
    summaryTable
  ]
  tags: commonTags
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output dceIngestionEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId
