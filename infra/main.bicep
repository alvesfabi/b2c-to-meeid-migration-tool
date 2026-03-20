targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Name of the resource group to create.')
param resourceGroupName string = 'rg-b2c-migration'

@description('Storage account name (3-24 lowercase alphanumeric, globally unique).')
param storageAccountName string

@description('Number of worker VMs to deploy.')
param vmCount int = 4

@description('VM size for each worker node. Standard_B2s (2 vCPU / 4 GB) is sufficient for HTTP-bound workloads.')
param vmSize string = 'Standard_B2s'

@description('Local admin username for the VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key used for VM admin access (recommended over password auth).')
@secure()
param adminSshPublicKey string

param tags object = {
  project: 'b2c-migration'
  managedBy: 'bicep'
}

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  scope: rg
  params: {
    location: location
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  scope: rg
  params: {
    location: location
    storageAccountName: storageAccountName
    peSubnetId: network.outputs.peSubnetId
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

// One VM module invocation per worker; modules share the same RG scope so the
// vm module can reference the storage account via 'existing' to scope role assignments.
module workers 'modules/vm.bicep' = [for i in range(0, vmCount): {
  scope: rg
  params: {
    location: location
    vmName: 'vm-b2c-worker${i + 1}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    workersSubnetId: network.outputs.workersSubnetId
    storageAccountName: storage.outputs.storageAccountName
    tags: tags
  }
}]

output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.storageAccountName
output storageQueueEndpoint string = storage.outputs.storageQueueEndpoint
output bastionName string = network.outputs.bastionName
