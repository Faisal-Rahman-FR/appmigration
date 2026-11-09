targetScope = 'resourceGroup'

param location string
param tags object
param environmentName string
param operatorPrincipalId string
@allowed(['User', 'ServicePrincipal', 'Group'])
param operatorPrincipalType string = 'User'
@description('CIDRs allowed to reach public HTTPS (TCP 443) on both VMs. All other inbound traffic is denied.')
param allowedHttpsSources array
@description('First two octets of the /16 virtual network, for example 10.87.')
param vnetPrefix string = '10.87'
param linuxVmSize string = 'Standard_D4s_v5'
param windowsVmSize string = 'Standard_D2s_v5'
param linuxDataDiskGb int = 256
param linuxImageVersion string = 'latest'
param windowsImageVersion string = 'latest'
param adminUsername string = 'demooperator'
@description('Allow keeps Storage and Key Vault reachable from any source IP (RBAC and TLS still required). Deny restricts them to the VM subnets and dataServiceAllowedCidrs.')
@allowed(['Allow', 'Deny'])
param dataServiceDefaultAction string = 'Allow'
@description('Public IPv4 addresses or CIDRs allowed when dataServiceDefaultAction is Deny. Single addresses may be given bare or as /32.')
param dataServiceAllowedCidrs array = []
@description('direct (default): no Storage account or Key Vault; artifacts reach the VMs through the VM command channel and a private peer-only handoff, so tenant policies that force those services private cannot block the deployment. storage: use a Storage account (artifacts) and Key Vault (secrets) reachable over public endpoints.')
@allowed(['direct', 'storage'])
param artifactTransfer string = 'direct'
param linuxSshPublicKey string
@secure()
param windowsAdminPassword string

var useDataServices = artifactTransfer == 'storage'
var linuxVmName = 'vm-${environmentName}-linux'
var windowsVmName = 'vm-${environmentName}-win'
var linuxNicName = 'nic-${environmentName}-linux'
var windowsNicName = 'nic-${environmentName}-win'
var linuxIpName = 'pip-${environmentName}-linux'
var windowsIpName = 'pip-${environmentName}-win'
var linuxNsgName = 'nsg-${environmentName}-linux'
var windowsNsgName = 'nsg-${environmentName}-win'
var vnetName = 'vnet-${environmentName}'
var dataDiskName = 'disk-${environmentName}-data'
var linuxOsDiskName = 'osdisk-${environmentName}-linux'
var windowsOsDiskName = 'osdisk-${environmentName}-win'
var storageAccountName = 'st${replace(environmentName, '-', '')}'
var keyVaultName = 'kv-${environmentName}'
var workspaceName = 'log-${environmentName}'
var insightsName = 'appi-${environmentName}'
var linuxPrivateIp = '${vnetPrefix}.1.4'
var windowsPrivateIp = '${vnetPrefix}.2.4'
var storageIpRules = [for cidr in dataServiceAllowedCidrs: {action: 'Allow', value: replace(cidr, '/32', '')}]
var vaultIpRules = [for cidr in dataServiceAllowedCidrs: {value: contains(cidr, '/') ? cidr : '${cidr}/32'}]

var httpsRules = [
  {
    name: 'ApprovedClientHttps'
    properties: {
      priority: 100
      access: 'Allow'
      direction: 'Inbound'
      protocol: 'Tcp'
      sourceAddressPrefixes: allowedHttpsSources
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'DemoPeerHttps'
    properties: {
      priority: 110
      access: 'Allow'
      direction: 'Inbound'
      protocol: 'Tcp'
      sourceAddressPrefixes: [linuxPrivateIp, windowsPrivateIp]
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
    }
  }
  {
    name: 'DenyOtherInbound'
    properties: {
      priority: 200
      access: 'Deny'
      direction: 'Inbound'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
]

// One-time Windows -> Linux handoff download in direct mode (TLS on 8443, served only while a stage runs). Peer only, never public.
var linuxRules = concat(httpsRules, [
  {
    name: 'DemoHandoffFromWindows'
    properties: {
      priority: 120
      access: 'Allow'
      direction: 'Inbound'
      protocol: 'Tcp'
      sourceAddressPrefix: windowsPrivateIp
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '8443'
    }
  }
])

resource linuxNsg 'Microsoft.Network/networkSecurityGroups@2026-05-01' = {
  name: linuxNsgName
  location: location
  tags: tags
  properties: {securityRules: linuxRules}
}
resource windowsNsg 'Microsoft.Network/networkSecurityGroups@2026-05-01' = {
  name: windowsNsgName
  location: location
  tags: tags
  properties: {securityRules: httpsRules}
}
resource vnet 'Microsoft.Network/virtualNetworks@2026-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {addressPrefixes: ['${vnetPrefix}.0.0/16']}
    subnets: [
      {
        name: 'linux'
        properties: {
          addressPrefix: '${vnetPrefix}.1.0/24'
          networkSecurityGroup: {id: linuxNsg.id}
          serviceEndpoints: [{service: 'Microsoft.Storage'}, {service: 'Microsoft.KeyVault'}]
          defaultOutboundAccess: false
        }
      }
      {
        name: 'windows'
        properties: {
          addressPrefix: '${vnetPrefix}.2.0/24'
          networkSecurityGroup: {id: windowsNsg.id}
          serviceEndpoints: [{service: 'Microsoft.Storage'}, {service: 'Microsoft.KeyVault'}]
          defaultOutboundAccess: false
        }
      }
    ]
  }
}
resource linuxIp 'Microsoft.Network/publicIPAddresses@2026-05-01' = {
  name: linuxIpName
  location: location
  tags: tags
  sku: {name: 'Standard'}
  properties: {publicIPAllocationMethod: 'Static', publicIPAddressVersion: 'IPv4'}
}
resource windowsIp 'Microsoft.Network/publicIPAddresses@2026-05-01' = {
  name: windowsIpName
  location: location
  tags: tags
  sku: {name: 'Standard'}
  properties: {publicIPAllocationMethod: 'Static', publicIPAddressVersion: 'IPv4'}
}
resource linuxNic 'Microsoft.Network/networkInterfaces@2026-05-01' = {
  name: linuxNicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [{
      name: 'primary'
      properties: {
        primary: true
        privateIPAllocationMethod: 'Static'
        privateIPAddress: linuxPrivateIp
        subnet: {id: '${vnet.id}/subnets/linux'}
        publicIPAddress: {id: linuxIp.id}
      }
    }]
  }
}
resource windowsNic 'Microsoft.Network/networkInterfaces@2026-05-01' = {
  name: windowsNicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [{
      name: 'primary'
      properties: {
        primary: true
        privateIPAllocationMethod: 'Static'
        privateIPAddress: windowsPrivateIp
        subnet: {id: '${vnet.id}/subnets/windows'}
        publicIPAddress: {id: windowsIp.id}
      }
    }]
  }
}
resource dataDisk 'Microsoft.Compute/disks@2026-10-02' = {
  name: dataDiskName
  location: location
  tags: tags
  sku: {name: 'StandardSSD_LRS'}
  properties: {creationData: {createOption: 'Empty'}, diskSizeGB: linuxDataDiskGb}
}
resource linux 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: linuxVmName
  location: location
  tags: tags
  identity: {type: 'SystemAssigned'}
  properties: {
    hardwareProfile: {vmSize: linuxVmSize}
    networkProfile: {networkInterfaces: [{id: linuxNic.id}]}
    securityProfile: {securityType: 'TrustedLaunch', uefiSettings: {secureBootEnabled: true, vTpmEnabled: true}}
    osProfile: {
      computerName: 'idpdemo-linux'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: {publicKeys: [{path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: linuxSshPublicKey}]}
        patchSettings: {patchMode: 'ImageDefault'}
      }
    }
    storageProfile: {
      imageReference: {publisher: 'Canonical', offer: '0001-com-ubuntu-server-jammy', sku: '22_04-lts-gen2', version: linuxImageVersion}
      osDisk: {name: linuxOsDiskName, createOption: 'FromImage', diskSizeGB: 128, managedDisk: {storageAccountType: 'StandardSSD_LRS'}, deleteOption: 'Detach'}
      dataDisks: [{name: dataDisk.name, lun: 0, createOption: 'Attach', managedDisk: {id: dataDisk.id}, deleteOption: 'Detach'}]
    }
    diagnosticsProfile: {bootDiagnostics: {enabled: true}}
  }
}
resource windows 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: windowsVmName
  location: location
  tags: tags
  identity: {type: 'SystemAssigned'}
  properties: {
    hardwareProfile: {vmSize: windowsVmSize}
    networkProfile: {networkInterfaces: [{id: windowsNic.id}]}
    securityProfile: {securityType: 'TrustedLaunch', uefiSettings: {secureBootEnabled: true, vTpmEnabled: true}}
    osProfile: {
      computerName: 'idpdemo-win'
      adminUsername: adminUsername
      adminPassword: windowsAdminPassword
      windowsConfiguration: {provisionVMAgent: true, enableAutomaticUpdates: true}
    }
    storageProfile: {
      imageReference: {publisher: 'MicrosoftWindowsServer', offer: 'WindowsServer', sku: '2022-datacenter-g2', version: windowsImageVersion}
      osDisk: {name: windowsOsDiskName, createOption: 'FromImage', diskSizeGB: 128, managedDisk: {storageAccountType: 'StandardSSD_LRS'}, deleteOption: 'Detach'}
    }
    diagnosticsProfile: {bootDiagnostics: {enabled: true}}
  }
}
resource storage 'Microsoft.Storage/storageAccounts@2026-09-01' = if (useDataServices) {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {name: 'Standard_LRS'}
  properties: {
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    networkAcls: {
      defaultAction: dataServiceDefaultAction
      bypass: 'None'
      ipRules: storageIpRules
      virtualNetworkRules: [
        {id: '${vnet.id}/subnets/linux', action: 'Allow'}
        {id: '${vnet.id}/subnets/windows', action: 'Allow'}
      ]
    }
  }
}
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2026-09-01' = if (useDataServices) {
  parent: storage
  name: 'default'
  properties: {deleteRetentionPolicy: {enabled: true, days: 7}}
}
resource artifacts 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-09-01' = if (useDataServices) {
  parent: blobService
  name: 'artifacts'
  properties: {publicAccess: 'None'}
}
resource handoff 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-09-01' = if (useDataServices) {
  parent: blobService
  name: 'windows-handoff'
  properties: {publicAccess: 'None'}
}
resource vault 'Microsoft.KeyVault/vaults@2026-05-15' = if (useDataServices) {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {family: 'A', name: 'standard'}
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    networkAcls: {
      defaultAction: dataServiceDefaultAction
      bypass: 'None'
      ipRules: vaultIpRules
      virtualNetworkRules: [{id: '${vnet.id}/subnets/linux'}, {id: '${vnet.id}/subnets/windows'}]
    }
  }
}
resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {sku: {name: 'PerGB2018'}, retentionInDays: 30, workspaceCapping: {dailyQuotaGb: 1}}
}
resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: insightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {Application_Type: 'web', WorkspaceResourceId: workspace.id}
}

var blobContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var blobReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var secretsOfficer = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
resource operatorStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useDataServices) {
  name: guid(storage.id, operatorPrincipalId, blobContributor)
  scope: storage
  properties: {principalId: operatorPrincipalId, principalType: operatorPrincipalType, roleDefinitionId: blobContributor}
}
resource operatorVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useDataServices) {
  name: guid(vault.id, operatorPrincipalId, secretsOfficer)
  scope: vault
  properties: {principalId: operatorPrincipalId, principalType: operatorPrincipalType, roleDefinitionId: secretsOfficer}
}
resource linuxArtifactRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useDataServices) {
  name: guid(artifacts.id, linux.id, blobReader)
  scope: artifacts
  properties: {principalId: linux.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: blobReader}
}
resource linuxHandoffWrite 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useDataServices) {
  name: guid(handoff.id, linux.id, blobContributor)
  scope: handoff
  properties: {principalId: linux.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: blobContributor}
}
resource windowsHandoffRead 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useDataServices) {
  name: guid(handoff.id, windows.id, blobReader)
  scope: handoff
  properties: {principalId: windows.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: blobReader}
}
resource linuxVaultWrite 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useDataServices) {
  name: guid(vault.id, linux.id, secretsOfficer)
  scope: vault
  properties: {principalId: linux.identity.principalId, principalType: 'ServicePrincipal', roleDefinitionId: secretsOfficer}
}

output linuxPublicIp string = linuxIp.properties.ipAddress
output windowsPublicIp string = windowsIp.properties.ipAddress
output storageAccountName string = useDataServices ? storageAccountName : ''
output keyVaultName string = useDataServices ? keyVaultName : ''
output linuxVmName string = linux.name
output windowsVmName string = windows.name
output linuxPrivateIp string = linuxPrivateIp
output windowsPrivateIp string = windowsPrivateIp
