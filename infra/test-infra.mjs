import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import test from 'node:test';
const file = process.env.COMPILED_TEMPLATE;
if (!file) throw new Error('Set COMPILED_TEMPLATE to the compiled subscription ARM JSON.');
const template = JSON.parse(readFileSync(file, 'utf8'));
const module = template.resources.find(resource => resource.type === 'Microsoft.Resources/deployments');
assert.ok(module?.properties.template, 'Resource-group deployment module must exist');
const resources = module.properties.template.resources;
const find = type => resources.filter(resource => resource.type === type);

test('subscription deployment creates the tagged group and keeps passwords secure', () => {
  assert.match(template.$schema, /subscriptionDeploymentTemplate/);
  assert.equal(template.parameters.windowsAdminPassword.type.toLowerCase(), 'securestring');
  const group = template.resources.find(resource => resource.type === 'Microsoft.Resources/resourceGroups');
  assert.equal(group.tags, '[variables(\'tags\')]');
  for (const tag of ['workload','environment','deployed-by','created-at','managed-by']) {
    assert.ok(JSON.stringify(template.variables.tags).includes(`'${tag}'`), tag);
  }
  assert.equal(find('Microsoft.Compute/virtualMachines').length, 2);
  for (const vm of find('Microsoft.Compute/virtualMachines')) assert.equal(vm.identity.type, 'SystemAssigned');
});
test('every resource name derives from the environment name; nothing is tied to one subscription', () => {
  const names = Object.entries(module.properties.template.variables).filter(([key]) => /Name$/.test(key)).map(([, value]) => value);
  assert.ok(names.length >= 15);
  for (const name of names) assert.match(name, /environmentName/, name);
  assert.doesNotMatch(JSON.stringify(template), /a3c8|idpdemo-dev|10\.87\.[12]\.[04]|securitylabworks|108\.85|f9931042/);
});
test('NSGs permit only configured public HTTPS and deny all other inbound traffic', () => {
  const rules = module.properties.template.variables.httpsRules;
  assert.equal(template.parameters.allowedHttpsSources.type, 'array');
  assert.ok(!('defaultValue' in template.parameters.allowedHttpsSources), 'public HTTPS sources must be an explicit choice');
  assert.equal(find('Microsoft.Network/networkSecurityGroups').length, 2);
  assert.equal(rules[0].properties.sourceAddressPrefixes, '[parameters(\'allowedHttpsSources\')]');
  for (const rule of rules.filter(rule => rule.properties.access === 'Allow')) {
    assert.equal(rule.properties.protocol, 'Tcp');
    assert.equal(rule.properties.destinationPortRange, '443');
  }
  const deny = rules.find(rule => rule.properties.name === 'DenyOtherInbound' || rule.name === 'DenyOtherInbound');
  assert.equal(deny.properties.access, 'Deny');
  assert.equal(deny.properties.destinationPortRange, '*');
  assert.ok(deny.properties.priority > Math.max(...rules.filter(rule => rule.properties.access === 'Allow').map(rule => rule.properties.priority)));
});
test('storage and vault retain authentication and TLS; network default is an explicit parameter', () => {
  const action = module.properties.template.parameters.dataServiceDefaultAction;
  assert.deepEqual(action.allowedValues, ['Allow', 'Deny']);
  const storage = find('Microsoft.Storage/storageAccounts')[0].properties;
  assert.equal(storage.allowBlobPublicAccess, false);
  assert.equal(storage.allowSharedKeyAccess, false);
  assert.equal(storage.supportsHttpsTrafficOnly, true);
  assert.equal(storage.minimumTlsVersion, 'TLS1_2');
  assert.equal(storage.networkAcls.defaultAction, '[parameters(\'dataServiceDefaultAction\')]');
  assert.equal(storage.publicNetworkAccess, 'Enabled', 'intent must be explicit: VNet service endpoints and IP rules need public access enabled');
  const vault = find('Microsoft.KeyVault/vaults')[0].properties;
  assert.equal(vault.enableRbacAuthorization, true);
  assert.equal(vault.enableSoftDelete, true);
  assert.equal(vault.networkAcls.defaultAction, '[parameters(\'dataServiceDefaultAction\')]');
  assert.equal(vault.publicNetworkAccess, 'Enabled');
  assert.ok(!('accessPolicies' in vault));
  assert.doesNotMatch(JSON.stringify([storage.networkAcls, vault.networkAcls]), /allowedHttpsSources/, 'HTTPS sources must never feed Storage/Key Vault IP rules');
});
test('direct mode (the default) deploys no Storage, Key Vault or role assignments', () => {
  const parameter = module.properties.template.parameters.artifactTransfer;
  assert.equal(parameter.defaultValue, 'direct');
  assert.deepEqual(parameter.allowedValues, ['direct', 'storage']);
  assert.equal(template.parameters.artifactTransfer.defaultValue, 'direct');
  const conditional = [...find('Microsoft.Storage/storageAccounts'), ...find('Microsoft.Storage/storageAccounts/blobServices'),
    ...find('Microsoft.Storage/storageAccounts/blobServices/containers'), ...find('Microsoft.KeyVault/vaults'), ...find('Microsoft.Authorization/roleAssignments')];
  assert.ok(conditional.length >= 11);
  for (const resource of conditional) assert.equal(resource.condition, "[variables('useDataServices')]", `${resource.type} must be conditional`);
  assert.equal(module.properties.template.variables.useDataServices, "[equals(parameters('artifactTransfer'), 'storage')]");
});
test('the Windows handoff port is reachable only from the Windows VM, on the Linux NSG only', () => {
  const variables = module.properties.template.variables;
  const linuxRules = String(variables.linuxRules);
  assert.match(linuxRules, /concat\(variables\('httpsRules'\)/);
  assert.match(linuxRules, /'DemoHandoffFromWindows'/);
  assert.match(linuxRules, /'destinationPortRange', '8443'/);
  assert.match(linuxRules, /'sourceAddressPrefix', variables\('windowsPrivateIp'\)/);
  assert.equal((linuxRules.match(/8443/g) || []).length, 1);
  assert.doesNotMatch(JSON.stringify(variables.httpsRules), /8443/, 'the shared rule set (Windows NSG) must not expose the handoff port');
  const nsgs = Object.fromEntries(find('Microsoft.Network/networkSecurityGroups').map(nsg => [nsg.name, nsg.properties.securityRules]));
  assert.equal(nsgs["[variables('linuxNsgName')]"], "[variables('linuxRules')]");
  assert.equal(nsgs["[variables('windowsNsgName')]"], "[variables('httpsRules')]");
});
test('application data roles are resource scoped, never subscription or group scoped', () => {
  const roles = find('Microsoft.Authorization/roleAssignments');
  assert.equal(roles.length, 6);
  for (const role of roles) {
    assert.ok(role.scope);
    assert.doesNotMatch(role.scope, /resourceGroup\(\)\.id|subscription\(\)\.id/);
    assert.ok(['User','ServicePrincipal',"[parameters('operatorPrincipalType')]"].includes(role.properties.principalType));
  }
  assert.match(module.properties.template.variables.blobReader, /2a2b9908-6ea1-4ae2-8e65-a410df84e7d1/);
  assert.match(module.properties.template.variables.secretsOfficer, /b86a8fe4-44ce-4948-aee5-eccb2c155cd7/);
});
