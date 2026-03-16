param location string
param vmName string
param vmSize string
param adminUsername string
@secure()
param adminSshPublicKey string
param workersSubnetId string
// Storage account name (not ID) is needed to create the 'existing' resource for role assignment scope.
param storageAccountName string
param tags object

var storageQueueDataContributorRoleDefId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'

// cloud-init: installs .NET 8 runtime on first boot.
// Requires outbound HTTPS — provided by the NAT Gateway on the workers subnet.
// Alternative: bake .NET into a custom VM image to avoid the internet dependency.
var cloudInit = base64('''#!/bin/bash
set -e
wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/ms-prod.deb
dpkg -i /tmp/ms-prod.deb
apt-get update -y
apt-get install -y dotnet-runtime-8.0
''')

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    // No public IP — workers are accessed via Azure Bastion or internal connectivity.
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: workersSubnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
        // Delete the OS disk when the VM is deleted to avoid orphaned resources.
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
  }
}

// Reference the storage account to scope the role assignment.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Grant the VM's system-assigned managed identity permission to read/dequeue from the storage queues.
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Deterministic GUID scoped to: storage account + VM name + role
  name: guid(storageAccount.id, vmName, storageQueueDataContributorRoleDefId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      storageQueueDataContributorRoleDefId
    )
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output vmName string = vm.name
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output vmPrincipalId string = vm.identity.principalId
