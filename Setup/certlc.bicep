/* 

CERTLC - Bicep file for deploying the required resources for the CERTLC solution.

Validate with: az deployment group validate --resource-group <existing resource group> -parameters .\parameters.dev.bicepparam
What-if: az deployment group what-if --resource-group <existing resource group> -parameters .\parameters.dev.bicepparam
Deploy with: az deployment group create --resource-group <existing resource group> -parameters .\parameters.dev.bicepparam

*/

metadata name = 'CertLC Infrastructure'
metadata description = 'Azure infrastructure deployment for Certificate Lifecycle Management solution with automated certificate enrollment, renewal, and monitoring'

targetScope = 'resourceGroup'

@description('The Azure region where resources will be deployed. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('The resource ID of the subnet for private endpoint connections. Format: /subscriptions/{subscriptionId}/resourceGroups/{rgName}/providers/Microsoft.Network/virtualNetworks/{vnetName}/subnets/{subnetName}')
param peSubnetId string

@description('The resource ID of the subnet for the function app VNet integration. Must be delegated to Microsoft.App/environments for Flex Consumption plans. Format: /subscriptions/{subscriptionId}/resourceGroups/{rgName}/providers/Microsoft.Network/virtualNetworks/{vnetName}/subnets/{subnetName}')
param fnSubnetId string

@description('The subscription ID where existing Private DNS Zones are located (for privatelink zones). Format: GUID')
param dnsZonesSubscriptionId string

@description('The resource group name containing existing Private DNS Zones (e.g., privatelink.blob.core.windows.net, privatelink.vaultcore.azure.net)')
param dnsZonesResourceGroupName string

@description('The name of the storage account to create. Must be globally unique, 3-24 characters, lowercase letters and numbers only. Used for function app storage and certificate lifecycle queue.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('The name of the function app to create. Must be globally unique, 2-60 characters, alphanumerics and hyphens. Hosts the queue processor and automation triggers.')
@minLength(2)
@maxLength(60)
param functionAppName string

@description('The name of the Log Analytics workspace for centralized logging and monitoring. Stores diagnostic logs, custom certificate statistics, and application telemetry.')
param logAnalyticsWorkspaceName string

@description('The name of the Application Insights instance for function app monitoring and performance tracking.')
param applicationInsightsName string

@description('The name of the Automation Account to create. 6-50 characters, alphanumerics and hyphens. Executes certificate lifecycle runbooks on hybrid workers.')
@minLength(6)
@maxLength(50)
param automationAccountName string

@description('The name of the hybrid runbook worker group. On-premises workers must be registered to this group to execute certificate operations.')
param hybridWorkerGroupName string

@description('The name of the runbook to invoke for certificate lifecycle operations. Must match the runbook name deployed to the Automation Account.')
param runbookName string

@description('The name of the Key Vault to create. Must be globally unique, 3-24 characters, alphanumerics and hyphens. Stores and manages certificates with automated lifecycle tracking.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('The name of the Data Collection Endpoint (DCE) to create. Ingestion endpoint for custom certificate statistics logs sent from automation runbooks.')
param dataCollectionEndpointName string

@description('The name of the Data Collection Rule (DCR) to create. Defines transformation and routing of certificate statistics to Log Analytics custom table.')
param dataCollectionRuleName string

@description('The Certificate Authority name for certificate enrollment. Format: CA_SERVER\\\\CA_NAME (e.g., PKI-CA01\\\\ContosoRootCA). Used by runbooks for ADCS operations.')
param automationAccountVarCA string

@description('The root folder path on hybrid workers where PFX certificates are stored. Format: UNC path or local path (e.g., \\\\\\\\fileserver\\\\certs or C:\\\\\\\\Certificates).')
param automationAccountVarPfxRootFolder string

@description('The SMTP From email address for certificate expiration notifications (e.g., certlc@contoso.com).')
param automationAccountVarSmtpFrom string

@description('The SMTP server hostname or IP address for sending email notifications (e.g., smtp.office365.com or smtp.gmail.com).')
param automationAccountVarSmtpServer string

@description('The SMTP username for authentication to the mail server. Required if the SMTP server requires authentication.')
param automationAccountVarSmtpUser string

@description('The SMTP password for authentication. Stored encrypted in Automation Account variables.')
@secure()
param automationAccountVarSmtpPassword string

@description('The start time for the certlcstats schedule. Defaults to 15 minutes from deployment time.')
param scheduleStartTime string = dateTimeAdd(utcNow('u'), 'PT15M')

/*************/
/* VARIABLES */
/*************/

// Common tags for all resources
var commonTags = {
  solution: 'CertLC'
  purpose: 'Certificate Lifecycle Management'
}

// Azure built-in role definition IDs
var roleDefinitions = {
  storageQueueDataReader: '19e7f393-937e-4f77-808e-94535e297925'
  storageQueueDataMessageSender: 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a'
  keyVaultCertificatesOfficer: 'a4417e6f-fecd-4de8-b567-7b0420556985'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  monitoringMetricsPublisher: '3913510d-42f4-4e42-8a64-420c390055eb'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueDataMessageProcessor: '8a0f0c08-91a1-4084-bc3d-661d67233fed'
  storageQueueDataContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  automationOperator: 'd3881f73-407a-4167-8283-e981cbba0404'
}

/**********************/
/* EXISTING RESOURCES */
/**********************/

// References to existing Private DNS Zones in their subscription
resource blobDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
}

resource keyVaultDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.vaultcore.azure.net'
  scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
}

resource queueDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.queue.${environment().suffixes.storage}'
  scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
}

resource webAppDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.azurewebsites.net'
  scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
}

resource automationAccountDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.azure-automation.net'
  scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
}

/*****************/
/* NEW RESOURCES */
/*****************/

// Storage Account
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
        queue: {
          enabled: true
        }
      }
    }
  }
  resource blobServices 'blobServices' = {
    name: 'default'
    properties: {}
  }
  resource queueServices 'queueServices' = {
    name: 'default'
    properties: {}
    resource queues 'queues' = {
      name: 'certlc'
      properties: {}
    }
  }

  tags: commonTags
}

// Private endpoint for the storage account - blob
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

// Private endpoint for the storage account - queue
resource storageAccountQueuePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: 'pe-queue-${storageAccountName}'
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
            'queue'
          ]
        }
      }
    ]
    customNetworkInterfaceName: 'nic-pe-queue-${storageAccountName}'
  }
  tags: commonTags

  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: queueDnsZone.id
          }
        }
      ]
    }
  }
}

// Log Analytics Workspace
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

// Data Collection Endpoint
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

// Custom Table for Certificate Statistics
resource customTable 'Microsoft.OperationalInsights/workspaces/tables@2022-10-01' = {
  name: 'certlc_CL'
  parent: logAnalyticsWorkspace
  properties: {
    retentionInDays: 30
    schema: {
      name: 'certlc_CL'
      columns: [
        {
          name: 'TimeGenerated'
          type: 'datetime'
        }
        {
          name: 'Thumbprint'
          type: 'string'
        }
        {
          name: 'Name'
          type: 'string'
        }
        {
          name: 'Created'
          type: 'datetime'
        }
        {
          name: 'Expires'
          type: 'datetime'
        }
        {
          name: 'Subject'
          type: 'string'
        }
        {
          name: 'Template'
          type: 'string'
        }
        {
          name: 'DNSNames'
          type: 'string'
        }
      ]
    }
  }
}

// Data Collection Rule for Certificate Statistics
resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: {
      'Custom-certlc_CL': {
        columns: [
          {
            name: 'Thumbprint'
            type: 'string'
          }
          {
            name: 'Name'
            type: 'string'
          }
          {
            name: 'Created'
            type: 'datetime'
          }
          {
            name: 'Expires'
            type: 'datetime'
          }
          {
            name: 'Subject'
            type: 'string'
          }
          {
            name: 'Template'
            type: 'string'
          }
          {
            name: 'DNSNames'
            type: 'string'
          }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspace.id
          name: 'clv2ws1'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Custom-certlc_CL'
        ]
        destinations: [
          'clv2ws1'
        ]
        transformKql: 'source | extend Created = todatetime(Created), Expires = todatetime(Expires) | extend TimeGenerated = now()'
        outputStream: 'Custom-certlc_CL'
      }
    ]
  }
  dependsOn: [
    customTable  // the DCR must be created after the custom table
  ]
  tags: commonTags
}

// Application Insights
// IMPORTANT: Deploy AFTER all Log Analytics operations are complete to avoid "Workspace not active" errors
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
    // Force serial deployment: Log Analytics → Custom Table → DCR → Automation Account → Diagnostics → App Insights
    // This ensures the workspace backend is fully active before App Insights connects
    automationAccountDiagnostics  // Wait for diagnostic settings which write to workspace
    keyVaultDiagnostics
  ]
  tags: commonTags
}

// Flexible Consumption Plan for the function app
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

// Function App
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
      AutomationAccountName: automationAccount.name
      HybridWorkerGroupName: hybridWorkerGroupName
      RunbookName: runbookName
      ResourceGroupName: resourceGroup().name
      AzureWebJobsStorage__credential: 'managedidentity'
      AzureWebJobsStorage__blobServiceUri: storageAccount.properties.primaryEndpoints.blob
      AzureWebJobsStorage__queueServiceUri: storageAccount.properties.primaryEndpoints.queue
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
      APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsights.properties.ConnectionString
    }
  }
  dependsOn: [
    storageAccountBlobPrivateEndpoint // create the function only after the PEs for the storage account are ready
    storageAccountQueuePrivateEndpoint
  ]
  tags: commonTags
}

// Private endpoint for the function app
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

// Automation Account with its managed identity
resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: false
    sku: {
      name: 'Basic'
    }
  }
  dependsOn: [
    dataCollectionRule
    dataCollectionEndpoint
  ]
  tags: commonTags
  // variables
  resource automationAccountVariables 'variables@2024-10-23' = {
    name: 'certlc-ca'
    properties: {
      value: '"${replace(automationAccountVarCA, '\\', '\\\\')}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesPfxRootFolder 'variables@2024-10-23' = {
    name: 'certlc-pfxrootfolder'
    properties: {
      value: '"${replace(automationAccountVarPfxRootFolder, '\\', '\\\\')}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesSmtpFrom 'variables@2024-10-23' = {
    name: 'certlc-smtpfrom'
    properties: {
      value: '"${replace(automationAccountVarSmtpFrom, '\\', '\\\\')}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesSmtpServer 'variables@2024-10-23' = {
    name: 'certlc-smtpserver'
    properties: {
      value: '"${replace(automationAccountVarSmtpServer, '\\', '\\\\')}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesSmtpUser 'variables@2024-10-23' = {
    name: 'certlc-smtpuser'
    properties: {
      value: '"${replace(automationAccountVarSmtpUser, '\\', '\\\\')}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesSmtpPassword 'variables@2024-10-23' = {
    name: 'certlc-smtppassword'
    properties: {
      value: '"${replace(automationAccountVarSmtpPassword, '\\', '\\\\')}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesKeyVault 'variables@2024-10-23' = {
    name: 'certlc-stats-keyvault'
    properties: {
      value: '"${keyVault.name}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesImmutableId 'variables@2024-10-23' = {
    name: 'certlc-stats-immutableid'
    properties: {
      value: '"${dataCollectionRule.properties.immutableId}"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesStreamName 'variables@2024-10-23' = {
    name: 'certlc-stats-streamname'
    properties: {
      value: '"Custom-certlc_CL"'
      isEncrypted: true
    }
  }
  resource automationAccountVariablesIngestionUrl 'variables@2024-10-23' = {
    name: 'certlc-stats-ingestionurl'
    properties: {
      value: '"${dataCollectionEndpoint.properties.logsIngestion.endpoint}"'
      isEncrypted: true
    }
  }
  
  // Runbook: certlc
  resource runbookCertLC 'runbooks@2024-10-23' = {
    name: 'certlc'
    location: location
    properties: {
      runbookType: 'PowerShell'
      logProgress: false
      logVerbose: false
      description: 'Certificate lifecycle management runbook for enrollment, renewal, and revocation'
      runtimeEnvironment: 'PowerShell-7.2'
    }
    tags: commonTags
  }
  
  // Runbook: certlcstats
  resource runbookCertLCStats 'runbooks@2024-10-23' = {
    name: 'certlcstats'
    location: location
    properties: {
      runbookType: 'PowerShell'
      logProgress: false
      logVerbose: false
      description: 'Certificate statistics collection runbook for monitoring and reporting'
      runtimeEnvironment: 'PowerShell-7.2'
    }
    tags: commonTags
  }

  // Schedule for certlcstats runbook - runs every hour
  // Note: Schedule is created but NOT linked to runbook initially (disabled state)
  // To enable: Link the schedule to the runbook in Azure Portal or via Azure CLI
  resource scheduleCertLCStats 'schedules@2024-10-23' = {
    name: 'schedule-certlcstats-hourly'
    properties: {
      description: 'Runs certlcstats runbook every hour to collect certificate statistics (manually link to enable)'
      startTime: scheduleStartTime
      frequency: 'Hour'
      interval: 1
      timeZone: 'UTC'
    }
  }

  // Uncomment to automatically link schedule to runbook (enables automatic execution on hybrid worker group)
  // resource jobScheduleCertLCStats 'jobSchedules@2024-10-23' = {
  //   name: guid(automationAccount.id, 'certlcstats-schedule')
  //   properties: {
  //     runbook: {
  //       name: runbookCertLCStats.name
  //     }
  //     schedule: {
  //       name: scheduleCertLCStats.name
  //     }
  //     runOn: hybridWorkerGroupName  // Execute on hybrid worker group (not Azure sandbox)
  //   }
  // }
}

// Hybrid Worker Group
resource hybridWorkerGroup 'Microsoft.Automation/automationAccounts/hybridRunbookWorkerGroups@2023-11-01' = {
  name: hybridWorkerGroupName
  parent: automationAccount
  properties: {
    // Hybrid worker group properties - workers will be added separately
  }
}

// Private endpoint for the Automation Account - Webhook
resource automationAccountPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: 'pe-webhook-${automationAccountName}'
  location: location
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${automationAccountName}'
        properties: {
          privateLinkServiceId: automationAccount.id
          groupIds: [
            'Webhook'
          ]
        }
      }
    ]
    customNetworkInterfaceName: 'nic-pe-webhook-${automationAccountName}'
  }
  tags: commonTags

  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: automationAccountDnsZone.id
          }
        }
      ]
    }
  }
}

// Private endpoint for the Automation Account - DSCAndHybridWorker
resource automationAccountPrivateEndpointDSCAndHybridWorker 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: 'pe-dscandhybridworker-${automationAccountName}'
  location: location
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-dscandhybridworker-${automationAccountName}'
        properties: {
          privateLinkServiceId: automationAccount.id
          groupIds: [
            'DSCAndHybridWorker'
          ]
        }
      }
    ]
    customNetworkInterfaceName: 'nic-pe-dscandhybridworker-${automationAccountName}'
  }
  tags: commonTags

  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: automationAccountDnsZone.id
          }
        }
      ]
    }
  }
}

// Diagnostic Settings for Automation Account
resource automationAccountDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${automationAccountName}'
  scope: automationAccount
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'JobLogs'
        enabled: true
      }
      {
        category: 'JobStreams'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// KeyVault
resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: true
    publicNetworkAccess: 'Disabled'
  }
  tags: commonTags
}

// Private endpoint for the KeyVault
resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: 'pe-vault-${keyVaultName}'
  location: location
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pls-${keyVaultName}'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
    customNetworkInterfaceName: 'nic-pe-${keyVaultName}'
  }
  tags: commonTags

  resource privateDnsZoneGroup 'privateDnsZoneGroups' = {
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: keyVaultDnsZone.id
          }
        }
      ]
    }
  }
}

// Diagnostic Settings for Key Vault
resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${keyVaultName}'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
      }
      {
        category: 'AzurePolicyEvaluationDetails'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Event Grid System Topic for the KeyVault
resource keyVaultEventGridSystemTopic 'Microsoft.EventGrid/systemTopics@2025-02-15' = {
  name: 'egst-${keyVaultName}'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    source: keyVault.id
    topicType: 'Microsoft.KeyVault.Vaults'
  }
  tags: commonTags
}

// Event Grid subscription for the KeyVault to the queue
// This subscription filters only the CertificateNearExpiry events and sends them to the storage queue
resource keyVaultEventGridSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: keyVaultEventGridSystemTopic
  name: 'egs-${keyVaultEventGridSystemTopic.name}'
  properties: {
    destination: {
      endpointType: 'StorageQueue'
      properties: {
        resourceId: storageAccount.id
        queueName: 'certlc'
        queueMessageTimeToLiveInSeconds: 86400 // 1 day
      }
    }
    eventDeliverySchema: 'CloudEventSchemaV1_0'
    filter: {
      includedEventTypes: [
        'Microsoft.KeyVault.CertificateNearExpiry'
      ]
      isSubjectCaseSensitive: false
    }
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440 // 1 day
    }
  }
}

// Azure Monitor Workbook for Certificate Statistics
resource workbookCertLCStats 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'certlcstats')
  location: location
  kind: 'shared'
  properties: {
    displayName: 'certlcstats'
    serializedData: '{"version":"Notebook/1.0","items":[],"styleSettings":{},"$schema":"https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json"}'
    category: 'workbook'
    sourceId: logAnalyticsWorkspace.id
  }
  dependsOn: [
    applicationInsights  // Wait for App Insights to ensure workspace is fully active
  ]
  tags: commonTags
}

// Role Assignment: Grant the Event Grid System Topic the "Storage Queue Data Reader" role on the Storage Account
// this role allows Event Grid to read messages from the queue
resource eventGridStorageQueueDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'eventGridStorageQueueDataReader')
  scope: storageAccount
  properties: {
    description: 'EventGrid SystemTopic -> Storage Queue Data Reader -> Storage Account'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.storageQueueDataReader
    )
    principalId: keyVaultEventGridSystemTopic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Event Grid System Topic the "Storage Queue Data Message Sender" role on the Storage Account
// this role allows Event Grid to send messages to the queue
resource eventGridStorageQueueDataMessageSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'eventGridStorageQueueDataMessageSender')
  scope: storageAccount
  properties: {
    description: 'EventGrid SystemTopic -> Storage Queue Data Message Sender -> Storage Account'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.storageQueueDataMessageSender
    )
    principalId: keyVaultEventGridSystemTopic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Automation Account the "Key Vault Certificates Officer" role on the KeyVault
// this role allows the automation account to create and manage certificates in the KeyVault
resource automationAccountKeyVaultCertificatesOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'automationAccountKeyVaultCertificatesOfficer')
  scope: keyVault
  properties: {
    description: 'Automation Account -> Key Vault Certificates Officer -> Key Vault'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.keyVaultCertificatesOfficer
    )
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Automation Account the "Key Vault Secrets Officer" role on the KeyVault
// this role allows the automation account to create and manage secrets (private keys of the certificates) in the KeyVault
resource automationAccountKeyVaultSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'automationAccountKeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    description: 'Automation Account -> Key Vault Secrets Officer -> Key Vault'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.keyVaultSecretsOfficer
    )
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Automation Account the "Reader" role on the Automation Account
// This may seem strange, but it is required for the hybrid worker (that uses the automation account's identity) to read the automation account variables
resource automationAccountReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'automationAccountReader')
  scope: automationAccount
  properties: {
    description: 'Automation Account -> Reader -> Automation Account (self)'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.reader
    )
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Automation Account the "Monitoring Metrics Publisher" role on the DCR
// (this is to allow the automation account to write custom logs to the DCR)
resource automationAccountMonitoringMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'automationAccountMonitoringMetricsPublisher')
  scope: dataCollectionRule
  properties: {
    description: 'Automation Account -> Monitoring Metrics Publisher -> DCR'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.monitoringMetricsPublisher
    )
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Function App the "Storage Blob Data Owner" role on the Storage Account
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

// Role Assignment: Grant the Function App the "Storage Queue Data Message Processor" role on the Storage Account
resource functionAppStorageQueueDataMessageProcessor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppStorageQueueDataMessageProcessor')
  scope: storageAccount
  properties: {
    description: 'Function App -> Storage Queue Data Message Processor -> Storage Account'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.storageQueueDataMessageProcessor
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Function App the "Storage Queue Data Contributor" role on the Storage Account
resource functionAppStorageQueueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppStorageQueueDataContributor')
  scope: storageAccount
  properties: {
    description: 'Function App -> Storage Queue Data Contributor -> Storage Account'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.storageQueueDataContributor
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Function App the "Reader" role on the Automation Account
// (this is to allow the function app to read automation account information and trigger runbooks)
resource functionAppAutomationAccountReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppAutomationAccountReader')
  scope: automationAccount
  properties: {
    description: 'Function App -> Reader -> Automation Account'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.reader
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Function App the "Automation Operator" role on the Automation Account
// (this is to allow the function app to start runbook jobs)
resource functionAppAutomationOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppAutomationOperator')
  scope: automationAccount
  properties: {
    description: 'Function App -> Automation Operator -> Automation Account'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleDefinitions.automationOperator
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role Assignment: Grant the Function App the "Monitoring Metrics Publisher" role on the Application Insights instance
// (this is to instrument the function app with App Insights)
resource functionAppMonitoringMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(subscription().id, resourceGroup().id, 'functionAppMonitoringMetricsPublisher')
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

// Output all resource IDs and important properties
output storageAccountId string = storageAccount.id
output storageAccountQueueUri string = storageAccount.properties.primaryEndpoints.queue
output automationAccountId string = automationAccount.id
output keyVaultId string = keyVault.id
output functionAppId string = functionApp.id
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output applicationInsightsId string = applicationInsights.id
output dceIngestionEndpoint string = dataCollectionEndpoint.properties.logsIngestion.endpoint
@secure()
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId
