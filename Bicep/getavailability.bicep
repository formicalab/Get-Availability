/*

Get-Availability — Bicep template for the complete Get-Availability infrastructure.

Creates a Log Analytics workspace, custom tables, DCE, DCR, Storage Account,
Flex Consumption Function App (with auto-wired app settings), Application Insights,
Private Endpoints, and RBAC role assignments.

Validate:  az deployment group validate --resource-group <rg> --parameters .\parameters.dev.bicepparam
What-if:   az deployment group what-if  --resource-group <rg> --parameters .\parameters.dev.bicepparam
Deploy:    az deployment group create   --resource-group <rg> --parameters .\parameters.dev.bicepparam

*/

metadata name = 'Get-Availability Infrastructure'
metadata description = 'Complete infrastructure for the Get-Availability solution: Log Analytics, DCE, DCR, Function App, App Insights, Private Endpoints, and RBAC'

// ── Parameters ───────────────────────────────────────────────────────────────

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Name of the Log Analytics workspace to create.')
param logAnalyticsWorkspaceName string

@description('Name of the Data Collection Endpoint.')
param dataCollectionEndpointName string

@description('Name of the Data Collection Rule.')
param dataCollectionRuleName string

@description('Name of the Storage Account for the Function App. Must be globally unique, 3-24 characters, lowercase letters and numbers only.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Name of the Function App. Must be globally unique, 2-60 characters, alphanumerics and hyphens.')
@minLength(2)
@maxLength(60)
param functionAppName string

@description('Name of the Application Insights instance for Function App monitoring.')
param applicationInsightsName string

@description('Subnet resource ID for Function App VNet integration. Must be delegated to Microsoft.App/environments.')
param fnSubnetId string

@description('Subnet resource ID for Private Endpoints.')
param peSubnetId string

@description('Subscription ID containing existing Private DNS Zones.')
param dnsZonesSubscriptionId string

@description('Resource group name containing existing Private DNS Zones.')
param dnsZonesResourceGroupName string

@description('Comma-separated list of Azure subscription names or IDs to monitor (written to GETAVAIL_SUBSCRIPTIONS app setting).')
param getavailSubscriptions string

@description('Comma-separated resource kinds to monitor. Default: vm,sql,storage,webapp')
param getavailKinds string = 'vm,sql,storage,webapp'

@description('Log Analytics workspace customer ID used as source for Activity Log and Resource Health queries (SOURCE_WORKSPACE_ID app setting). Leave empty to skip.')
param sourceWorkspaceId string = ''

@description('CRON expression for the timer trigger schedule. Default: 6 AM on the 1st of every month (0 0 6 1 * *).')
param timerSchedule string = '0 0 6 1 * *'

// ── Variables ────────────────────────────────────────────────────────────────

var commonTags = {
  solution: 'Get-Availability'
}

// Azure built-in role definition IDs
var roleDefinitions = {
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
}

// ── Existing Private DNS Zones ───────────────────────────────────────────────

resource blobDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
}

resource webAppDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.azurewebsites.net'
  scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
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
  kind: 'Direct'
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id

    // Stream declarations — columns sent by the script (no TimeGenerated; injected by transform)
    streamDeclarations: {
      'Custom-GetAvailResources_CL': {
        columns: [
          { name: 'RunId', type: 'string' }
          { name: 'Month', type: 'string' }
          { name: 'PeriodStart', type: 'datetime' }
          { name: 'PeriodEnd', type: 'datetime' }
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
          { name: 'PeriodStart', type: 'datetime' }
          { name: 'PeriodEnd', type: 'datetime' }
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
        transformKql: 'source | extend TimeGenerated = now()'
        outputStream: 'Custom-GetAvailResources_CL'
      }
      {
        streams: [ 'Custom-GetAvailSummary_CL' ]
        destinations: [ 'workspace' ]
        transformKql: 'source | extend TimeGenerated = now()'
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

// ── Storage Account ──────────────────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    defaultToOAuthAuthentication: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    publicNetworkAccess: 'Disabled'
    encryption: {
      services: {
        blob: {
          enabled: true
        }
      }
    }
  }
  resource blobServices 'blobServices' = {
    name: 'default'
    properties: {}
  }
  tags: commonTags
}

// ── Private Endpoint: Storage Account (blob) ─────────────────────────────────

resource storageAccountBlobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: 'pe-blob-${storageAccountName}'
  location: location
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${storageAccountName}'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
    customNetworkInterfaceName: 'nic-pe-${storageAccountName}'
  }
  tags: commonTags

  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: blobDnsZone.id
          }
        }
      ]
    }
  }
}

// ── Application Insights ─────────────────────────────────────────────────────

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    DisableLocalAuth: true
  }
  dependsOn: [
    dataCollectionRule // Ensure workspace backend is fully active before App Insights connects
  ]
  tags: commonTags
}

// ── Flex Consumption Plan ────────────────────────────────────────────────────

resource flexServicePlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: 'asp-${functionAppName}'
  location: location
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
  tags: commonTags
}

// ── Function App ─────────────────────────────────────────────────────────────

resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: flexServicePlan.id
    httpsOnly: true
    virtualNetworkSubnetId: fnSubnetId
    publicNetworkAccess: 'Disabled'
    siteConfig: {
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
      }
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}azure-webjobs-hosts'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'powerShell'
        version: '7.4'
      }
    }
  }
  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      // Function App infrastructure
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__blobServiceUri: storageAccount.properties.primaryEndpoints.blob
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
      APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString

      // Get-Availability configuration — auto-wired from Bicep resources
      GETAVAIL_SUBSCRIPTIONS: getavailSubscriptions
      GETAVAIL_KINDS: getavailKinds
      DCE_ENDPOINT: dataCollectionEndpoint.properties.logsIngestion.endpoint
      DCR_IMMUTABLE_ID: dataCollectionRule.properties.immutableId
      SOURCE_WORKSPACE_ID: sourceWorkspaceId
      TIMER_SCHEDULE: timerSchedule
    }
  }
  dependsOn: [
    storageAccountBlobPrivateEndpoint // Create function only after storage PE is ready
  ]
  tags: commonTags
}

// ── Private Endpoint: Function App (sites) ───────────────────────────────────

resource functionAppPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: 'pe-sites-${functionAppName}'
  location: location
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${functionAppName}'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [
            'sites'
          ]
        }
      }
    ]
    customNetworkInterfaceName: 'nic-pe-${functionAppName}'
  }
  tags: commonTags

  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: webAppDnsZone.id
          }
        }
      ]
    }
  }
}

// ── RBAC Role Assignments ────────────────────────────────────────────────────

// Function App → Monitoring Metrics Publisher → DCR (ingest custom logs)
resource functionAppDcrPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppDcrPublisher')
  scope: dataCollectionRule
  properties: {
    description: 'Function App -> Monitoring Metrics Publisher -> DCR'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.monitoringMetricsPublisher
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function App → Monitoring Metrics Publisher → Application Insights (Entra-only telemetry)
resource functionAppAppiPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppAppiPublisher')
  scope: applicationInsights
  properties: {
    description: 'Function App -> Monitoring Metrics Publisher -> Application Insights'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.monitoringMetricsPublisher
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function App → Storage Blob Data Owner → Storage Account (Flex Consumption deployment blobs)
resource functionAppStorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppStorageBlobDataOwner')
  scope: storageAccount
  properties: {
    description: 'Function App -> Storage Blob Data Owner -> Storage Account'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.storageBlobDataOwner
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output dceIngestionEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId
output functionAppId string = functionApp.id
output applicationInsightsId string = applicationInsights.id
output storageAccountId string = storageAccount.id
