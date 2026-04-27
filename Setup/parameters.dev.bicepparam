using './getavailability.bicep'

// Network Configuration
param peSubnetId = '/subscriptions/9068a229-f092-400e-8093-87e8e7d26ae1/resourceGroups/rg-alz-net-workloads-itn-001/providers/Microsoft.Network/virtualNetworks/vnet-alz-workloads-itn-001/subnets/snet-alz-pe-workloads-itn-001'
param fnSubnetId = '/subscriptions/9068a229-f092-400e-8093-87e8e7d26ae1/resourceGroups/rg-alz-net-workloads-itn-001/providers/Microsoft.Network/virtualNetworks/vnet-alz-workloads-itn-001/subnets/snet-alz-fn-workloads-itn-001'

// DNS Configuration
param dnsZonesSubscriptionId = 'c4e6c176-bf9c-4e8c-87b2-ebdceea7085f'
param dnsZonesResourceGroupName = 'rg-alz-dns-hub-itn-001'

// Resource Names
param storageAccountName = 'flazstcertlcitn001'
param functionAppName = 'flazfn-certlc-itn-001'
param logAnalyticsWorkspaceName = 'log-certlc-itn-001'
param applicationInsightsName = 'appi-certlc-itn-001'
param automationAccountName = 'aa-certlc-itn-001'
param hybridWorkerGroupName = 'hwg-certlc-itn-001'
param runbookName = "certlc"
param keyVaultName = 'flazkv-certlc-itn-001'
param dataCollectionEndpointName = 'dce-certlc-itn-001'
param dataCollectionRuleName = 'dcr-certlc-itn-001'

// Automation account variables
param automationAccountVarCA = 'flazdc03.lab.formicalab.casa\\SubCA' // Name of the CA to use (for the automation account variable)
param automationAccountVarPfxRootFolder = 'C:\\PFX_Repo' // Name of the folder to use (for the automation account variable)
param automationAccountVarSmtpFrom = 'certlc@formicalab.casa' // SMTP From address to use (for the automation account variable)
param automationAccountVarSmtpServer = 'mail.smtp2go.com' // SMTP Server to use (for the automation account variable)
param automationAccountVarSmtpUser = 'certlc' // SMTP User to use (for the automation account variable)
param automationAccountVarSmtpPassword = '<pasword>' // SMTP Password to use (for the automation account variable)
