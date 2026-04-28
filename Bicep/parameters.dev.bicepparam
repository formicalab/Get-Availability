using './getavailability.bicep'

// Log Analytics workspace that stores the custom availability tables.
param logAnalyticsWorkspaceName = 'log-getavail-itn-001'

// Data Collection Endpoint used by the Function App to ingest custom logs.
param dataCollectionEndpointName = 'dce-getavail-itn-001'

// Data Collection Rule that maps the ingestion streams into the two custom tables.
param dataCollectionRuleName = 'dcr-getavail-itn-001'

// Storage account used by the Flex Consumption Function App for deployment and runtime blobs.
param storageAccountName = 'flazstgetavailitn001'

// Function App name for the scheduled Get-Availability runner.
param functionAppName = 'fn-getavail-itn-001'

// Application Insights instance wired to the Function App.
param applicationInsightsName = 'appi-getavail-itn-001'

// Toggle for private endpoints on the Storage Account and Function App.
// Keep true for the current private networking model; set false to allow public access instead.
param usePrivateEndpoints = true

// Subnet reserved for private endpoints. Used only when usePrivateEndpoints = true.
param peSubnetId = '/subscriptions/9068a229-f092-400e-8093-87e8e7d26ae1/resourceGroups/rg-alz-net-workloads-itn-001/providers/Microsoft.Network/virtualNetworks/vnet-alz-workloads-itn-001/subnets/snet-alz-pe-workloads-itn-001'

// Subnet delegated to Microsoft.App/environments for Function App VNet integration.
param fnSubnetId = '/subscriptions/9068a229-f092-400e-8093-87e8e7d26ae1/resourceGroups/rg-alz-net-workloads-itn-001/providers/Microsoft.Network/virtualNetworks/vnet-alz-workloads-itn-001/subnets/snet-alz-fn-workloads-itn-001'

// Subscription containing the shared private DNS zones. Used only when usePrivateEndpoints = true.
param dnsZonesSubscriptionId = 'c4e6c176-bf9c-4e8c-87b2-ebdceea7085f'

// Resource group containing the shared private DNS zones. Used only when usePrivateEndpoints = true.
param dnsZonesResourceGroupName = 'rg-alz-dns-hub-itn-001'

// Comma-separated subscription names monitored by the Function App.
param getavailSubscriptions = 'Flaz-Connectivity,Flaz-Management,Flaz-Identity,Flaz-Workloads'

// Existing Log Analytics workspace used as the source for Activity Log and Resource Health KQL queries.
param sourceWorkspaceId = 'f25755bb-9b46-4aac-bfae-6a10c4c18440'
