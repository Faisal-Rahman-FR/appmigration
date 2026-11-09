targetScope = 'subscription'

param location string
param resourceGroupName string
@description('Base name used to derive every resource name, for example idpdemo-contoso-x1y2. Storage and Key Vault names must be globally unique.')
@minLength(3)
@maxLength(20)
param environmentName string
param deployedBy string
param operatorPrincipalId string
@allowed(['User', 'ServicePrincipal', 'Group'])
param operatorPrincipalType string = 'User'
param createdAt string = utcNow()
@description('Additional tags applied to the resource group and every resource.')
param extraTags object = {}
@description('CIDRs allowed to reach public HTTPS (TCP 443). All other inbound traffic is denied.')
param allowedHttpsSources array
param vnetPrefix string = '10.87'
param linuxVmSize string = 'Standard_D4s_v5'
param windowsVmSize string = 'Standard_D2s_v5'
param linuxDataDiskGb int = 256
param linuxImageVersion string = 'latest'
param windowsImageVersion string = 'latest'
param adminUsername string = 'demooperator'
@allowed(['Allow', 'Deny'])
param dataServiceDefaultAction string = 'Allow'
param dataServiceAllowedCidrs array = []
@allowed(['direct', 'storage'])
param artifactTransfer string = 'direct'
param linuxSshPublicKey string
@secure()
param windowsAdminPassword string

var tags = union(extraTags, {
  workload: 'identity-migration-demo'
  environment: environmentName
  'deployed-by': deployedBy
  'created-at': createdAt
  'managed-by': 'idp-demo-deployment-package'
})

resource resourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module resources './resources.bicep' = {
  name: 'idp-demo-resources'
  scope: resourceGroup
  params: {
    location: location
    tags: tags
    environmentName: environmentName
    operatorPrincipalId: operatorPrincipalId
    operatorPrincipalType: operatorPrincipalType
    allowedHttpsSources: allowedHttpsSources
    vnetPrefix: vnetPrefix
    linuxVmSize: linuxVmSize
    windowsVmSize: windowsVmSize
    linuxDataDiskGb: linuxDataDiskGb
    linuxImageVersion: linuxImageVersion
    windowsImageVersion: windowsImageVersion
    adminUsername: adminUsername
    dataServiceDefaultAction: dataServiceDefaultAction
    dataServiceAllowedCidrs: dataServiceAllowedCidrs
    artifactTransfer: artifactTransfer
    linuxSshPublicKey: linuxSshPublicKey
    windowsAdminPassword: windowsAdminPassword
  }
}

output resourceGroupName string = resourceGroup.name
output linuxPublicIp string = resources.outputs.linuxPublicIp
output windowsPublicIp string = resources.outputs.windowsPublicIp
output storageAccountName string = resources.outputs.storageAccountName
output keyVaultName string = resources.outputs.keyVaultName
output linuxVmName string = resources.outputs.linuxVmName
output windowsVmName string = resources.outputs.windowsVmName
output linuxPrivateIp string = resources.outputs.linuxPrivateIp
output windowsPrivateIp string = resources.outputs.windowsPrivateIp
