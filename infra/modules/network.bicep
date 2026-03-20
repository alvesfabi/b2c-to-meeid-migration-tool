param location string
param tags object

// NAT Gateway gives VMs controlled outbound internet without public IPs.
// Workers need this to reach graph.microsoft.com and login.microsoftonline.com.
resource natGatewayPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-nat-b2c-migration'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: 'ng-b2c-migration'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [{ id: natGatewayPip.id }]
    idleTimeoutInMinutes: 4
  }
}

// Block all inbound internet; allow all intra-VNet and outbound HTTPS (Graph API via NAT GW).
resource nsgWorkers 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-workers'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-ssh-from-bastion'
        properties: {
          priority: 90
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '10.0.3.0/26'
          sourcePortRange: '*'
          destinationAddressPrefix: '10.0.1.0/24'
          destinationPortRange: '22'
        }
      }
      {
        name: 'deny-inbound-internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-b2c-migration'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
  }
}

// Subnets must be deployed sequentially when referencing the same parent VNet.
resource workersSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'workers'
  properties: {
    addressPrefix: '10.0.1.0/24'
    networkSecurityGroup: { id: nsgWorkers.id }
    natGateway: { id: natGateway.id }
  }
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'private-endpoints'
  properties: {
    addressPrefix: '10.0.2.0/24'
    // Required: disabling network policies allows private endpoint NICs to receive UDR/NSG.
    privateEndpointNetworkPolicies: 'Disabled'
  }
  dependsOn: [workersSubnet]
}

// Azure Bastion subnet — name must be exactly 'AzureBastionSubnet'.
resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'AzureBastionSubnet'
  properties: {
    addressPrefix: '10.0.3.0/26'
  }
  dependsOn: [peSubnet]
}

// Public IP for Azure Bastion (required).
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-bastion-b2c-migration'
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Azure Bastion — provides secure SSH access to VMs without public IPs (SFI compliant).
resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'bas-b2c-migration'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: { id: bastionSubnet.id }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output workersSubnetId string = workersSubnet.id
output peSubnetId string = peSubnet.id
output bastionName string = bastion.name
