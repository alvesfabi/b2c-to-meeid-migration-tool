param location string
param storageAccountName string
param peSubnetId string
param vnetId string
param tags object

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    // SFI: no public endpoints — all access goes through the private endpoint.
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
  }
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource userIdsQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'user-ids-to-process'
}

resource phoneRegistrationQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'phone-registration'
}

// Private endpoint exposes the Queue service endpoint inside the VNet.
resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-${storageAccountName}-queue'
  location: location
  tags: tags
  properties: {
    subnet: { id: peSubnetId }
    privateLinkServiceConnections: [
      {
        name: 'plsc-queue'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['queue']
        }
      }
    ]
  }
}

// DNS zone must resolve <account>.queue.<suffix> to the private IP inside the VNet.
// environment().suffixes.storageEndpoint handles sovereign clouds (e.g. Azure Government).
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.queue.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource dnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'link-b2c-migration'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetId }
    registrationEnabled: false
  }
}

// Automatically creates the DNS A-record when the private endpoint is provisioned.
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'queue-config'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output storageQueueEndpoint string = storageAccount.properties.primaryEndpoints.queue
