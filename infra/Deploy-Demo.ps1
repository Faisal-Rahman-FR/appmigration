#Requires -Version 7.2
<#
.SYNOPSIS
  Deploys the complete identity-migration demo (Linux CAS/IdP/apps + Windows IIS/Shibboleth SP) into any Azure
  tenant and subscription from one JSON configuration file.

.DESCRIPTION
  1. Copy infra\environment.sample.json to infra\environment.json and fill it in.
  2. Run:  pwsh -File .\infra\Deploy-Demo.ps1
  The default stage "All" runs every stage in order and records progress, so re-running the same command after a
  failure or a DNS pause resumes where it stopped. See infra\README.md.

.PARAMETER Stage
  All (default) | Preflight | Validate | Provision | Dns | Build | CertificateRequest | DnsWait | CertificateComplete |
  Windows | Verify | Status | Credentials | Stop | Start | Destroy. Validate = preflight + ARM what-if, creates nothing.
  Naming a single stage always runs it.

.PARAMETER AutoApprove
  Skips the interactive confirmation before billable resources are created.

.PARAMETER Force
  With -Stage All, reruns stages that are already recorded as complete.
#>
[CmdletBinding()]
param(
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'environment.json'),
  [ValidateSet('All','Preflight','Validate','Provision','Dns','Build','CertificateRequest','DnsWait','CertificateComplete','Windows','Verify','Status','Credentials','Stop','Start','Destroy')]
  [string]$Stage = 'All',
  [switch]$AutoApprove,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run this script from Windows PowerShell 7: it builds the Windows application and uses the Windows DNS resolver.' }

$workspace = Split-Path $PSScriptRoot -Parent
$stageOrder = @('Provision','Dns','Build','CertificateRequest','DnsWait','CertificateComplete','Windows','Verify')
$appHosts = @('cas','idp','hr','drupal','alumni','events','student')
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$safeValue = '^[A-Za-z0-9._:/@+-]*$'

function Write-Step([string]$Message) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message) -ForegroundColor Cyan }
function Write-Note([string]$Message) { Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Caution([string]$Message) { Write-Host "WARNING: $Message" -ForegroundColor Yellow }
function Get-OptionalValue($Object, [string]$Name, $Default) {
  if ($null -eq $Object) { return $Default }
  $property = $Object.PSObject.Properties[$Name]
  if (-not $property -or $null -eq $property.Value) { return $Default }
  if ($property.Value -is [string] -and $property.Value.Trim() -eq '') { return $Default }
  return $property.Value
}
function Test-Ipv4Cidr([string]$Value) {
  if ($Value -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(/(\d{1,2}))?$') { return $false }
  foreach ($i in 1..4) { if ([int]$Matches[$i] -gt 255) { return $false } }
  if ($Matches[6] -and [int]$Matches[6] -gt 32) { return $false }
  return $true
}
function Hide-Secrets([string]$Text) {
  $Text = [regex]::Replace($Text, 'eyJ[A-Za-z0-9._-]{20,}', '[token]')
  return [regex]::Replace($Text, '(?i)(password|secret|key)(["''\s:=]+)[^\s"'']{6,}', '$1$2[hidden]')
}

# ---------------------------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------------------------
function Get-DemoConfig {
  if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath`nCopy infra\environment.sample.json to infra\environment.json, fill it in, and run again."
  }
  $raw = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
  $problems = New-Object System.Collections.Generic.List[string]
  $cfg = [ordered]@{
    TenantId = [string](Get-OptionalValue $raw 'tenantId' '')
    SubscriptionId = [string](Get-OptionalValue $raw 'subscriptionId' '')
    Location = ([string](Get-OptionalValue $raw 'location' '')).ToLowerInvariant()
    ResourceGroup = [string](Get-OptionalValue $raw 'resourceGroupName' '')
    Prefix = ([string](Get-OptionalValue $raw 'namePrefix' 'idpdemo')).ToLowerInvariant()
    Suffix = ([string](Get-OptionalValue $raw 'uniqueSuffix' '')).ToLowerInvariant()
    Domain = ([string](Get-OptionalValue $raw 'domain' '')).ToLowerInvariant()
    DeployedBy = [string](Get-OptionalValue $raw 'deployedBy' '')
    OperatorObjectId = [string](Get-OptionalValue $raw 'operatorObjectId' '')
    OperatorPrincipalType = [string](Get-OptionalValue $raw 'operatorPrincipalType' 'User')
  }
  $dns = Get-OptionalValue $raw 'dns' $null
  $cfg.DnsMode = [string](Get-OptionalValue $dns 'mode' 'manual')
  $cfg.DnsWaitMinutes = [int](Get-OptionalValue $dns 'waitMinutes' 60)
  $zone = Get-OptionalValue $dns 'azureDnsZone' $null
  $cfg.DnsZoneName = ([string](Get-OptionalValue $zone 'zoneName' '')).ToLowerInvariant()
  $cfg.DnsZoneGroup = [string](Get-OptionalValue $zone 'resourceGroup' '')
  $cfg.DnsZoneSubscription = [string](Get-OptionalValue $zone 'subscriptionId' $cfg.SubscriptionId)
  $tls = Get-OptionalValue $raw 'tls' $null
  $cfg.AcceptTerms = [bool](Get-OptionalValue $tls 'acceptLetsEncryptTerms' $false)
  $cfg.AcmeEmail = [string](Get-OptionalValue $tls 'contactEmail' '')
  $network = Get-OptionalValue $raw 'network' $null
  $cfg.HttpsSources = @(Get-OptionalValue $network 'allowedHttpsSources' @())
  $cfg.VnetPrefix = [string](Get-OptionalValue $network 'vnetPrefix' '10.87')
  $cfg.DataAction = [string](Get-OptionalValue $network 'dataServiceDefaultAction' 'Allow')
  $cfg.ArtifactTransfer = [string](Get-OptionalValue $raw 'artifactTransfer' 'direct')
  $cfg.DataCidrs = @(Get-OptionalValue $network 'dataServiceAllowedCidrs' @())
  $compute = Get-OptionalValue $raw 'compute' $null
  $cfg.AdminUsername = [string](Get-OptionalValue $compute 'adminUsername' 'demooperator')
  $cfg.LinuxSize = [string](Get-OptionalValue $compute 'linuxVmSize' 'Standard_D4s_v5')
  $cfg.WindowsSize = [string](Get-OptionalValue $compute 'windowsVmSize' 'Standard_D2s_v5')
  $cfg.DataDiskGb = [int](Get-OptionalValue $compute 'linuxDataDiskGb' 256)
  $cfg.LinuxImage = [string](Get-OptionalValue $compute 'linuxImageVersion' 'latest')
  $cfg.WindowsImage = [string](Get-OptionalValue $compute 'windowsImageVersion' 'latest')
  $options = Get-OptionalValue $raw 'options' $null
  $cfg.RunTests = [bool](Get-OptionalValue $options 'runBrowserTests' $true)
  $cfg.FailOnTestFailure = [bool](Get-OptionalValue $options 'failOnTestFailure' $false)
  $cfg.Tags = @{}
  $tagSource = Get-OptionalValue $raw 'tags' $null
  if ($tagSource) { foreach ($property in $tagSource.PSObject.Properties) { $cfg.Tags[$property.Name] = [string]$property.Value } }

  if ($cfg.TenantId -notmatch $guidPattern -or $cfg.TenantId -match '^0{8}-') { $problems.Add('tenantId must be your tenant GUID.') }
  if ($cfg.SubscriptionId -notmatch $guidPattern -or $cfg.SubscriptionId -match '^0{8}-') { $problems.Add('subscriptionId must be your subscription GUID.') }
  if ($cfg.Location -notmatch '^[a-z0-9]{3,30}$') { $problems.Add('location must be an Azure region name such as eastus.') }
  if ($cfg.ResourceGroup -notmatch '^[A-Za-z0-9._()-]{1,89}[A-Za-z0-9_()-]$') { $problems.Add('resourceGroupName is missing or invalid.') }
  if ($cfg.Prefix -notmatch '^[a-z]([a-z0-9]|-(?!-)){0,12}[a-z0-9]$') { $problems.Add('namePrefix must be 2-14 lowercase letters, digits or single hyphens, starting with a letter.') }
  if ($cfg.Suffix -and $cfg.Suffix -notmatch '^[a-z0-9]{3,5}$') { $problems.Add('uniqueSuffix must be 3-5 lowercase letters or digits (leave blank to generate one).') }
  if ($cfg.Domain -notmatch '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$' -or $cfg.Domain.Length -gt 100) {
    $problems.Add('domain must be a DNS name you control, for example demo.contoso.com.')
  } elseif ($cfg.Domain -match '(^|\.)example\.(com|org|net)$|(^|\.)invalid$|(^|\.)test$') {
    $problems.Add('domain still contains a placeholder. Use a real domain you control; a public certificate is issued for *.<domain>.')
  } elseif ($cfg.Domain -match '(^|\.)(onmicrosoft\.com|microsoftonline\.com|azurewebsites\.net|cloudapp\.azure\.com|cloudapp\.net|trafficmanager\.net|azurefd\.net|windows\.net)$') {
    $problems.Add('domain is a Microsoft-owned name (such as onmicrosoft.com). You cannot create DNS records or obtain a public certificate for it. Use a registered domain or subdomain you control, for example demo.contoso.com.')
  }
  if ($cfg.DnsMode -notin @('manual','azureDns')) { $problems.Add('dns.mode must be manual or azureDns.') }
  if ($cfg.DnsWaitMinutes -lt 5 -or $cfg.DnsWaitMinutes -gt 720) { $problems.Add('dns.waitMinutes must be between 5 and 720.') }
  if ($cfg.DnsMode -eq 'azureDns') {
    if (-not $cfg.DnsZoneName -or -not $cfg.DnsZoneGroup) { $problems.Add('dns.azureDnsZone.zoneName and resourceGroup are required when dns.mode is azureDns.') }
    elseif ($cfg.Domain -ne $cfg.DnsZoneName -and -not $cfg.Domain.EndsWith(".$($cfg.DnsZoneName)")) { $problems.Add('domain must equal or be a subdomain of dns.azureDnsZone.zoneName.') }
    if ($cfg.DnsZoneSubscription -notmatch $guidPattern) { $problems.Add('dns.azureDnsZone.subscriptionId must be a GUID.') }
  }
  if (-not $cfg.AcceptTerms) { $problems.Add('tls.acceptLetsEncryptTerms must be true. You must accept the Let''s Encrypt Subscriber Agreement (https://letsencrypt.org/repository/) before a certificate is requested for you.') }
  if ($cfg.AcmeEmail -and $cfg.AcmeEmail -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { $problems.Add('tls.contactEmail is not a valid email address.') }
  if ($cfg.HttpsSources.Count -eq 0) { $problems.Add('network.allowedHttpsSources is required: list the IPv4 addresses/CIDRs allowed to browse the demo, or "0.0.0.0/0" for anyone.') }
  foreach ($source in $cfg.HttpsSources) { if (-not (Test-Ipv4Cidr ([string]$source))) { $problems.Add("network.allowedHttpsSources entry '$source' is not an IPv4 address or CIDR.") } }
  if ($cfg.VnetPrefix -notmatch '^(10\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)|172\.(1[6-9]|2\d|3[01])|192\.168)$') { $problems.Add('network.vnetPrefix must be the first two octets of a private /16, for example 10.87.') }
  if ($cfg.ArtifactTransfer -notin @('direct','storage')) { $problems.Add('artifactTransfer must be direct or storage.') }
  if ($cfg.DataAction -notin @('Allow','Deny')) { $problems.Add('network.dataServiceDefaultAction must be Allow or Deny.') }
  if ($cfg.DataAction -eq 'Deny' -and $cfg.DataCidrs.Count -eq 0) { $problems.Add('network.dataServiceAllowedCidrs must list your public IPs when dataServiceDefaultAction is Deny (the script itself needs data-plane access).') }
  foreach ($cidr in $cfg.DataCidrs) { if (-not (Test-Ipv4Cidr ([string]$cidr))) { $problems.Add("network.dataServiceAllowedCidrs entry '$cidr' is not an IPv4 address or CIDR.") } }
  if ($cfg.AdminUsername -notmatch '^[a-z][a-z0-9_-]{2,19}$' -or $cfg.AdminUsername -in @('admin','administrator','root')) { $problems.Add('compute.adminUsername must be 3-20 lowercase characters and not a reserved name.') }
  foreach ($size in @($cfg.LinuxSize,$cfg.WindowsSize)) { if ($size -notmatch '^Standard_[A-Za-z0-9_]+$') { $problems.Add("VM size '$size' is invalid.") } }
  if ($cfg.DataDiskGb -lt 128 -or $cfg.DataDiskGb -gt 4096) { $problems.Add('compute.linuxDataDiskGb must be between 128 and 4096.') }
  foreach ($image in @($cfg.LinuxImage,$cfg.WindowsImage)) { if ($image -notmatch '^(latest|\d+(\.\d+){1,3})$') { $problems.Add("Image version '$image' must be latest or a numeric version.") } }
  if ($cfg.OperatorObjectId -and $cfg.OperatorObjectId -notmatch $guidPattern) { $problems.Add('operatorObjectId must be a GUID.') }
  if ($cfg.OperatorPrincipalType -notin @('User','ServicePrincipal','Group')) { $problems.Add('operatorPrincipalType must be User, ServicePrincipal or Group.') }
  if ($cfg.OperatorPrincipalType -ne 'User' -and -not $cfg.OperatorObjectId) { $problems.Add('operatorObjectId is required when operatorPrincipalType is not User.') }
  if ($cfg.DeployedBy -and $cfg.DeployedBy -notmatch '^[A-Za-z0-9 ._@+-]{1,64}$') { $problems.Add('deployedBy contains unsupported characters.') }
  foreach ($tag in $cfg.Tags.GetEnumerator()) {
    if ($tag.Key -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$' -or $tag.Value -notmatch '^[A-Za-z0-9 ._:@/+=-]{0,256}$') { $problems.Add("Tag '$($tag.Key)' has unsupported characters.") }
  }
  if ($problems.Count -gt 0) { throw ("Invalid configuration in ${ConfigPath}:`n - " + ($problems -join "`n - ")) }
  return [pscustomobject]$cfg
}

$cfg = Get-DemoConfig
$stateRoot = Join-Path $PSScriptRoot ".state\$($cfg.SubscriptionId.Substring(0,8))-$($cfg.ResourceGroup)"
$stateFile = Join-Path $stateRoot 'state.json'
$parametersFile = Join-Path $stateRoot 'parameters.json'

# ---------------------------------------------------------------------------------------------------------------
# Protected state (credentials, progress). Never committed or uploaded; the source archive excludes it.
# ---------------------------------------------------------------------------------------------------------------
function Protect-State {
  New-Item -ItemType Directory -Force $stateRoot | Out-Null
  $acl = [Security.AccessControl.DirectorySecurity]::new()
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User,
    [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
  }
  [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($stateRoot), $acl)
}
function Get-State {
  if (Test-Path -LiteralPath $stateFile) { return (Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json -AsHashtable) }
  return @{ version = 1; stages = @{} }
}
function Save-State { [IO.File]::WriteAllText($stateFile, ($script:State | ConvertTo-Json -Depth 10)) }
function Set-StageComplete([string]$Name) { $script:State.stages[$Name] = @{ completedUtc = [DateTime]::UtcNow.ToString('o') }; Save-State }
function Test-StageComplete([string]$Name) { return $script:State.stages.ContainsKey($Name) }

Protect-State
$script:State = Get-State
if (-not $script:State.ContainsKey('uniqueSuffix')) {
  $suffix = if ($cfg.Suffix) { $cfg.Suffix } else { -join (1..4 | ForEach-Object { 'abcdefghijklmnopqrstuvwxyz0123456789'[(Get-Random -Maximum 36)] }) }
  $script:State.uniqueSuffix = $suffix
  $script:State.createdAtUtc = [DateTime]::UtcNow.ToString('o')
  Save-State
} elseif ($cfg.Suffix -and $cfg.Suffix -ne $script:State.uniqueSuffix) {
  throw "uniqueSuffix '$($cfg.Suffix)' differs from the suffix '$($script:State.uniqueSuffix)' already used for this environment. Resource names cannot change after deployment."
}

$environmentName = "$($cfg.Prefix)-$($script:State.uniqueSuffix)"
$useStorage = $cfg.ArtifactTransfer -eq 'storage'
if (-not $script:State.ContainsKey('handoffToken')) {
  # Unguessable path segment for the private Windows handoff (direct mode); 40 hex characters.
  $script:State.handoffToken = -join ([Security.Cryptography.RandomNumberGenerator]::GetBytes(20) | ForEach-Object { $_.ToString('x2') })
  Save-State
}

# Settings baked into deployed resources cannot change on resume. Before any stage has completed they may still be edited.
$fingerprint = @{ domain = $cfg.Domain; vnetPrefix = $cfg.VnetPrefix; location = $cfg.Location; prefix = $cfg.Prefix; artifactTransfer = $cfg.ArtifactTransfer }
if (-not $script:State.ContainsKey('fingerprint') -or $script:State.stages.Count -eq 0) {
  $script:State.fingerprint = $fingerprint
  Save-State
} else {
  $changed = @($fingerprint.Keys | Where-Object { $script:State.fingerprint[$_] -ne $fingerprint[$_] })
  if ($changed.Count -gt 0 -and $Stage -notin @('Destroy','Status','Credentials','Stop','Start')) {
    throw "Configuration changed since this environment was deployed: $($changed -join ', ').`nThese settings are baked into the deployed resources. Restore the original values, or run -Stage Destroy and deploy again."
  }
}
$names = [pscustomobject]@{
  Environment = $environmentName
  LinuxVm = "vm-$environmentName-linux"
  WindowsVm = "vm-$environmentName-win"
  Storage = "st$($environmentName -replace '-','')"
  Vault = "kv-$environmentName"
  Deployment = "idpdemo-$environmentName"
  LinuxPrivateIp = "$($cfg.VnetPrefix).1.4"
  WindowsPrivateIp = "$($cfg.VnetPrefix).2.4"
}
if ($names.Environment.Length -gt 20 -or $names.Environment -match '--') { throw "Derived environment name '$($names.Environment)' is invalid; shorten namePrefix." }

# ---------------------------------------------------------------------------------------------------------------
# Azure CLI helpers. Every call names the subscription explicitly; the default CLI context is never changed.
# ---------------------------------------------------------------------------------------------------------------
function Invoke-Azure([string[]]$Arguments) {
  $operation = $Arguments[0..([Math]::Min(2,$Arguments.Count-1))] -join ' '
  $audit = Join-Path $stateRoot 'deploy-audit.log'
  [IO.File]::AppendAllText($audit, "$([DateTime]::UtcNow.ToString('o')) | $operation | started`n")
  $result = & az @Arguments
  $exitCode = $LASTEXITCODE
  [IO.File]::AppendAllText($audit, "$([DateTime]::UtcNow.ToString('o')) | $operation | $(if ($exitCode -eq 0) {'succeeded'} else {'failed'})`n")
  if ($exitCode -ne 0) { throw "Azure CLI failed: $operation" }
  return ($result -join "`n")
}
function Invoke-AzureRetry([string[]]$Arguments, [int]$Attempts = 20, [int]$DelaySeconds = 30) {
  for ($attempt = 1; ; $attempt++) {
    try { return Invoke-Azure $Arguments }
    catch {
      if ($attempt -ge $Attempts) { throw }
      Write-Note "Waiting for Azure to propagate access (attempt $attempt of $Attempts)..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}
function ConvertTo-TagArguments($Tags) { return @($Tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) }

function Connect-Tenant {
  Write-Step "Checking Azure sign-in for tenant $($cfg.TenantId)"
  $account = $null
  try { $account = (& az account show --subscription $cfg.SubscriptionId -o json 2>$null) -join "`n" | ConvertFrom-Json } catch { $account = $null }
  if ($LASTEXITCODE -ne 0 -or -not $account -or $account.tenantId -ne $cfg.TenantId) {
    Write-Note 'Not signed in to that tenant/subscription; starting az login.'
    & az login --tenant $cfg.TenantId --only-show-errors -o none
    if ($LASTEXITCODE -ne 0) { throw 'az login failed.' }
    $account = (Invoke-Azure @('account','show','--subscription',$cfg.SubscriptionId,'-o','json')) | ConvertFrom-Json
  }
  if ($account.id -ne $cfg.SubscriptionId) { throw 'The signed-in context does not expose the configured subscription.' }
  if ($account.tenantId -ne $cfg.TenantId) { throw "Subscription $($cfg.SubscriptionId) belongs to tenant $($account.tenantId), not $($cfg.TenantId)." }
  if ($account.state -ne 'Enabled') { throw "Subscription state is '$($account.state)'; it must be Enabled." }
  $script:Account = $account
  Write-Note "Subscription: $($account.name) ($($account.id)); signed in as $($account.user.name)"
}

# ---------------------------------------------------------------------------------------------------------------
# Preflight: everything that can be checked before any billable resource exists
# ---------------------------------------------------------------------------------------------------------------
function Find-MSBuild {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere)) { return $null }
  $found = & $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
  if ($found) { return $found }
  return $null
}
function Test-Prerequisites {
  Write-Step 'Checking local tools'
  foreach ($tool in @('az','tar','ssh-keygen')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required tool '$tool' was not found on PATH." }
  }
  $studentDll = Join-Path $workspace 'samples\apps\dotnet-shibsp\bin\StudentRecords.dll'
  $script:MSBuild = Find-MSBuild
  if ($script:MSBuild) { Write-Note "MSBuild: $script:MSBuild" }
  elseif (Test-Path -LiteralPath $studentDll) { Write-Caution 'MSBuild was not found; the existing prebuilt StudentRecords.dll will be uploaded as-is.' }
  else { throw 'Visual Studio / Build Tools MSBuild is required to compile the Framework 4.8 Student app. Install "Build Tools for Visual Studio 2022" with the ".NET desktop build tools" workload, then retry.' }
}
function Get-VmSkuVerdict($VmSkus, [string]$Size, [string]$Location) {
  $sku = @($VmSkus | Where-Object { $_.name -eq $Size }) | Select-Object -First 1
  if (-not $sku) {
    return [pscustomobject]@{ Error = "VM size $Size does not exist in $Location. Check the spelling, or choose another size or region."; Family = $null; Cores = 0 }
  }
  # A Zone restriction only blocks availability-zone placement; this deployment is regional, so only a Location restriction matters.
  $blocked = @($sku.restrictions | Where-Object { $_.type -eq 'Location' })
  if ($blocked.Count -gt 0) {
    $reason = ($blocked | ForEach-Object { $_.reasonCode } | Select-Object -First 1)
    return [pscustomobject]@{
      Error = "VM size $Size is blocked for your subscription in $Location ($reason). This is an access restriction on the subscription, not a quota shortage. Set a different 'location' in the configuration (the Azure SKU API shows which regions are open), choose another size under 'compute', or ask the subscription owner or Microsoft support to lift the restriction."
      Family = $null; Cores = 0
    }
  }
  $cores = [int](($sku.capabilities | Where-Object { $_.name -eq 'vCPUs' }).value)
  return [pscustomobject]@{ Error = $null; Family = $sku.family; Cores = $cores }
}
function Test-SubscriptionReadiness {
  Write-Step 'Registering required resource providers'
  foreach ($namespace in @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage','Microsoft.KeyVault','Microsoft.OperationalInsights','Microsoft.Insights')) {
    $state = (Invoke-Azure @('provider','show','--subscription',$cfg.SubscriptionId,'--namespace',$namespace,'--query','registrationState','-o','tsv')).Trim()
    if ($state -ne 'Registered') {
      Write-Note "Registering $namespace (currently $state)"
      Invoke-Azure @('provider','register','--subscription',$cfg.SubscriptionId,'--namespace',$namespace,'--wait','--only-show-errors') | Out-Null
    }
  }
  $missingSizes = @()
  foreach ($vm in @(@{ Name = $names.LinuxVm; Size = $cfg.LinuxSize }, @{ Name = $names.WindowsVm; Size = $cfg.WindowsSize })) {
    $present = $script:GroupExists -and (& az vm show --subscription $cfg.SubscriptionId --resource-group $cfg.ResourceGroup --name $vm.Name --query name -o tsv 2>$null)
    if (-not $present) { $missingSizes += $vm.Size }
  }
  if ($missingSizes.Count -eq 0) { Write-Note 'Both VMs already exist; skipping the capacity and quota check.'; return }
  Write-Step "Checking VM size availability and quota in $($cfg.Location)"
  $usage = (Invoke-Azure @('vm','list-usage','--subscription',$cfg.SubscriptionId,'--location',$cfg.Location,'-o','json')) | ConvertFrom-Json
  # The full SKU list is required: 'az vm list-skus' hides sizes restricted for the subscription, so it cannot explain them.
  $skuUrl = "https://management.azure.com/subscriptions/$($cfg.SubscriptionId)/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location eq '$($cfg.Location)'"
  $vmSkus = @(((Invoke-Azure @('rest','--method','get','--url',$skuUrl,'-o','json')) | ConvertFrom-Json).value | Where-Object { $_.resourceType -eq 'virtualMachines' })
  $needByFamily = @{}
  $totalCores = 0
  foreach ($size in $missingSizes) {
    $verdict = Get-VmSkuVerdict $vmSkus $size $cfg.Location
    if ($verdict.Error) { throw $verdict.Error }
    $needByFamily[$verdict.Family] = [int]$needByFamily[$verdict.Family] + $verdict.Cores
    $totalCores += $verdict.Cores
  }
  foreach ($family in $needByFamily.Keys) {
    $entry = $usage | Where-Object { $_.name.value -eq $family } | Select-Object -First 1
    if ($entry -and ([int]$entry.limit - [int]$entry.currentValue) -lt $needByFamily[$family]) {
      throw "Insufficient $($entry.name.localizedValue) quota in $($cfg.Location): need $($needByFamily[$family]) vCPUs, $([int]$entry.limit - [int]$entry.currentValue) available. Request a quota increase or choose another region/size."
    }
  }
  $regional = $usage | Where-Object { $_.name.value -eq 'cores' } | Select-Object -First 1
  if ($regional -and ([int]$regional.limit - [int]$regional.currentValue) -lt $totalCores) {
    throw "Insufficient total regional vCPU quota in $($cfg.Location): need $totalCores, $([int]$regional.limit - [int]$regional.currentValue) available."
  }
  Write-Note "Quota OK: $totalCores vCPUs required"
}
function Test-NamesAndGroup {
  Write-Step 'Checking resource group and globally unique names'
  $groupExists = (Invoke-Azure @('group','exists','--subscription',$cfg.SubscriptionId,'--name',$cfg.ResourceGroup,'-o','tsv')).Trim() -eq 'true'
  $script:GroupExists = $groupExists
  if ($groupExists) {
    $group = (Invoke-Azure @('group','show','--subscription',$cfg.SubscriptionId,'--name',$cfg.ResourceGroup,'-o','json')) | ConvertFrom-Json
    if ($group.location -ne $cfg.Location) { throw "Resource group $($cfg.ResourceGroup) already exists in $($group.location); configuration says $($cfg.Location)." }
    Write-Note "Resource group $($cfg.ResourceGroup) already exists and will be reused."
  }
  if (-not $useStorage) { return }
  $storageFree = (Invoke-Azure @('storage','account','check-name','--subscription',$cfg.SubscriptionId,'--name',$names.Storage,'--query','nameAvailable','-o','tsv')).Trim() -eq 'true'
  if (-not $storageFree) {
    $mine = $groupExists -and (& az storage account show --subscription $cfg.SubscriptionId --resource-group $cfg.ResourceGroup --name $names.Storage --query name -o tsv 2>$null)
    if (-not $mine) { throw "Storage account name $($names.Storage) is taken. Set a different namePrefix or uniqueSuffix in the configuration." }
  }
  $bodyFile = Join-Path $stateRoot 'vault-name-check.json'
  [IO.File]::WriteAllText($bodyFile, (@{ name = $names.Vault; type = 'Microsoft.KeyVault/vaults' } | ConvertTo-Json -Compress))
  try {
    $vaultFree = (Invoke-Azure @('rest','--method','post','--url',"https://management.azure.com/subscriptions/$($cfg.SubscriptionId)/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2022-07-01",'--body',"@$bodyFile",'--query','nameAvailable','-o','tsv')).Trim() -eq 'true'
  } finally { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
  if (-not $vaultFree) {
    $mine = $groupExists -and (& az keyvault show --subscription $cfg.SubscriptionId --resource-group $cfg.ResourceGroup --name $names.Vault --query name -o tsv 2>$null)
    if (-not $mine) { throw "Key Vault name $($names.Vault) is taken or soft-deleted. Change namePrefix/uniqueSuffix, or purge the soft-deleted vault." }
  }
}
function Test-DnsZone {
  if ($cfg.DnsMode -ne 'azureDns') { return }
  Write-Step "Checking Azure DNS zone $($cfg.DnsZoneName)"
  Invoke-Azure @('network','dns','zone','show','--subscription',$cfg.DnsZoneSubscription,'--resource-group',$cfg.DnsZoneGroup,'--name',$cfg.DnsZoneName,'--query','name','-o','tsv') | Out-Null
}
function Resolve-Operator {
  if ($cfg.OperatorObjectId) { $script:OperatorId = $cfg.OperatorObjectId }
  else {
    $id = (& az ad signed-in-user show --query id -o tsv 2>$null)
    if ($LASTEXITCODE -eq 0 -and $id -match $guidPattern) { $script:OperatorId = $id.Trim() }
    elseif ($useStorage) {
      throw 'Cannot resolve your Entra object ID (signed in as a service principal or guest without directory read access, or your Graph token needs a fresh az login). Set operatorObjectId (and operatorPrincipalType) in the configuration.'
    } else {
      # Direct mode creates no role assignments, so the object ID is unused; do not make a Graph sign-in challenge block deployment.
      $script:OperatorId = '00000000-0000-0000-0000-000000000000'
      Write-Note 'Could not read your Entra object ID (not needed in direct mode); continuing.'
    }
  }
  if ($cfg.DeployedBy) { $script:DeployedBy = $cfg.DeployedBy }
  else {
    $name = (& az ad signed-in-user show --query userPrincipalName -o tsv 2>$null)
    $script:DeployedBy = if ($LASTEXITCODE -eq 0 -and $name) { $name.Trim() } else { 'idp-demo-operator' }
  }
}
function Test-ActionAllowed($Permissions, [string]$Action) {
  # Azure RBAC wildcards: '*' matches anything; 'Microsoft.Authorization/*/write' matches within segments. Case-insensitive.
  $isMatch = {
    param([string]$Pattern, [string]$Value)
    $regex = '^' + [regex]::Escape($Pattern).Replace('\*', '.*') + '$'
    return [regex]::IsMatch($Value, $regex, 'IgnoreCase')
  }
  foreach ($block in @($Permissions)) {
    $allowed = @($block.actions | Where-Object { $_ -and (& $isMatch $_ $Action) })
    if ($allowed.Count -eq 0) { continue }
    $denied = @($block.notActions | Where-Object { $_ -and (& $isMatch $_ $Action) })
    if ($denied.Count -eq 0) { return $true }
  }
  return $false
}
function Get-CallerPermissions([string]$Scope) {
  $url = "https://management.azure.com$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
  return @(((Invoke-Azure @('rest','--method','get','--url',$url,'-o','json')) | ConvertFrom-Json).value)
}
function Test-DeploymentPermissions {
  Write-Step $(if ($useStorage) { 'Checking that you can deploy and create role assignments (required by storage mode)' } else { 'Checking that you can deploy resources' })
  $subScope = "/subscriptions/$($cfg.SubscriptionId)"
  $resourceScope = if ($script:GroupExists) { "$subScope/resourceGroups/$($cfg.ResourceGroup)" } else { $subScope }
  $subPermissions = Get-CallerPermissions $subScope
  $resourcePermissions = if ($resourceScope -eq $subScope) { $subPermissions } else { Get-CallerPermissions $resourceScope }
  $checks = @(
    @{ Action = 'Microsoft.Resources/deployments/write'; Scope = $subScope; Permissions = $subPermissions },
    @{ Action = 'Microsoft.Compute/virtualMachines/write'; Scope = $resourceScope; Permissions = $resourcePermissions }
  )
  # Direct mode deploys no role assignments, so Contributor is enough; storage mode needs them for the managed identities and the operator.
  if ($useStorage) { $checks += @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Scope = $resourceScope; Permissions = $resourcePermissions } }
  foreach ($check in $checks) {
    if (Test-ActionAllowed $check.Permissions $check.Action) { continue }
    $who = if ($script:OperatorId) { $script:OperatorId } elseif ($cfg.OperatorObjectId) { $cfg.OperatorObjectId } else { '<your-object-id>' }
    if ($check.Action -notmatch 'roleAssignments') {
      throw "You lack permission '$($check.Action)' at $($check.Scope). Contributor on the subscription (or Owner) is required to deploy."
    }
    throw ("You lack permission '$($check.Action)' at $($check.Scope).`n" +
      "Storage mode creates resources AND role assignments, which needs Owner, or Contributor plus User Access Administrator (or Role Based Access Control Administrator). Direct mode (artifactTransfer: direct) does not.`n" +
      "Ask a subscription owner to run ONE of:`n" +
      "  Subscription-wide:  az role assignment create --assignee $who --role 'User Access Administrator' --scope $subScope`n" +
      "  Narrower:           create resource group '$($cfg.ResourceGroup)' in '$($cfg.Location)', then grant you User Access Administrator (or Owner) on that group only,`n" +
      "                      keeping your existing Contributor role on the subscription:`n" +
      "                      az role assignment create --assignee $who --role 'User Access Administrator' --scope $subScope/resourceGroups/$($cfg.ResourceGroup)`n" +
      "Then rerun. (Find your object ID with: az ad signed-in-user show --query id -o tsv)")
  }
  Write-Note 'Permissions OK.'
}
function Invoke-Preflight {
  Test-Prerequisites
  Connect-Tenant
  Resolve-Operator
  Test-NamesAndGroup
  Test-DeploymentPermissions
  Test-SubscriptionReadiness
  Test-DnsZone
  Write-Step 'Preflight passed'
}

# ---------------------------------------------------------------------------------------------------------------
# Provision
# ---------------------------------------------------------------------------------------------------------------
function Initialize-Credentials {
  $key = Join-Path $stateRoot 'operator_ed25519'
  if (-not (Test-Path -LiteralPath $key)) {
    & ssh-keygen -q -t ed25519 -f $key -N '' -C 'idp-demo-operator'
    if ($LASTEXITCODE -ne 0) { throw 'SSH key generation failed.' }
  }
  if (-not $script:State.ContainsKey('windowsAdminPassword')) {
    $script:State.windowsAdminPassword = 'Aa1!' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))
    Save-State
  }
}
function Write-ParametersFile {
  $values = [ordered]@{
    location = @{ value = $cfg.Location }
    resourceGroupName = @{ value = $cfg.ResourceGroup }
    environmentName = @{ value = $names.Environment }
    deployedBy = @{ value = $script:DeployedBy }
    operatorPrincipalId = @{ value = $script:OperatorId }
    operatorPrincipalType = @{ value = $cfg.OperatorPrincipalType }
    createdAt = @{ value = $script:State.createdAtUtc }
    extraTags = @{ value = $cfg.Tags }
    allowedHttpsSources = @{ value = @($cfg.HttpsSources | ForEach-Object { [string]$_ }) }
    vnetPrefix = @{ value = $cfg.VnetPrefix }
    linuxVmSize = @{ value = $cfg.LinuxSize }
    windowsVmSize = @{ value = $cfg.WindowsSize }
    linuxDataDiskGb = @{ value = $cfg.DataDiskGb }
    linuxImageVersion = @{ value = $cfg.LinuxImage }
    windowsImageVersion = @{ value = $cfg.WindowsImage }
    adminUsername = @{ value = $cfg.AdminUsername }
    dataServiceDefaultAction = @{ value = $cfg.DataAction }
    dataServiceAllowedCidrs = @{ value = @($cfg.DataCidrs | ForEach-Object { [string]$_ }) }
    artifactTransfer = @{ value = $cfg.ArtifactTransfer }
    linuxSshPublicKey = @{ value = (Get-Content -Raw -LiteralPath (Join-Path $stateRoot 'operator_ed25519.pub')).Trim() }
    windowsAdminPassword = @{ value = $script:State.windowsAdminPassword }
  }
  $document = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $values }
  [IO.File]::WriteAllText($parametersFile, ($document | ConvertTo-Json -Depth 10))
}
function Confirm-Deployment {
  Write-Host ''
  Write-Host '  Deployment plan' -ForegroundColor White
  Write-Host "    Tenant:            $($cfg.TenantId)"
  Write-Host "    Subscription:      $($script:Account.name) ($($cfg.SubscriptionId))"
  Write-Host "    Resource group:    $($cfg.ResourceGroup) ($($cfg.Location))$(if ($script:GroupExists) {' - already exists, will be reused'})"
  if ($useStorage) {
    Write-Host "    Resource names:    $($names.Environment) (storage $($names.Storage), vault $($names.Vault))"
  } else {
    Write-Host "    Resource names:    $($names.Environment) (no Storage account or Key Vault: direct artifact transfer)"
  }
  Write-Host "    Compute:           Linux $($cfg.LinuxSize) + Windows Server $($cfg.WindowsSize), $($cfg.DataDiskGb) GiB data disk, 2 static public IPs"
  Write-Host "    Public HTTPS from: $($cfg.HttpsSources -join ', ')"
  if ($useStorage) { Write-Host "    Storage/Key Vault: default network action $($cfg.DataAction); Entra RBAC + TLS required either way" }
  Write-Host "    DNS / TLS:         *.$($cfg.Domain) via Let's Encrypt, DNS mode '$($cfg.DnsMode)'"
  Write-Host '    Cost:              two always-on VMs, disks, IPs, storage and telemetry bill continuously until stopped/deleted.'
  Write-Host '    Not included:      high availability, automated backups, automatic certificate renewal.'
  Write-Host ''
  if ($AutoApprove) { Write-Note 'Approval granted by -AutoApprove.'; return }
  $answer = Read-Host "Type the resource group name ($($cfg.ResourceGroup)) to approve creating these billable resources"
  if ($answer -ne $cfg.ResourceGroup) { throw 'Deployment not approved. Nothing was created.' }
}
function Get-ModifyPolicyNames {
  # Best effort: names of Azure Policy definitions that rewrote resources in this group recently (shown to whoever grants an exemption).
  try {
    $events = (Invoke-Azure @('monitor','activity-log','list','--subscription',$cfg.SubscriptionId,'--resource-group',$cfg.ResourceGroup,'--offset','1d','-o','json')) | ConvertFrom-Json
    $found = foreach ($event in ($events | Where-Object { $_.operationName.value -eq 'Microsoft.Authorization/policies/modify/action' })) {
      $raw = $event.properties.policies
      foreach ($policy in @(if ($raw -is [string]) { $raw | ConvertFrom-Json } else { $raw })) {
        if ($policy.policyDefinitionName) { "$($policy.policyDefinitionName) (assignment $($policy.policyAssignmentName))" }
      }
    }
    return @($found | Sort-Object -Unique)
  } catch { return @() }
}
function Test-DataServiceAccess {
  Write-Step 'Checking that Key Vault and Storage accept connections'
  $vaultAccess = (Invoke-Azure @('keyvault','show','--subscription',$cfg.SubscriptionId,'--resource-group',$cfg.ResourceGroup,'--name',$names.Vault,'--query','properties.publicNetworkAccess','-o','tsv')).Trim()
  $storageAccess = (Invoke-Azure @('storage','account','show','--subscription',$cfg.SubscriptionId,'--resource-group',$cfg.ResourceGroup,'--name',$names.Storage,'--query','publicNetworkAccess','-o','tsv')).Trim()
  $blocked = @()
  if ($vaultAccess -eq 'Disabled') { $blocked += "Key Vault $($names.Vault)" }
  if ($storageAccess -eq 'Disabled') { $blocked += "Storage account $($names.Storage)" }
  if ($blocked.Count -eq 0) { Write-Note 'Public network access is enabled on both (Entra RBAC and TLS still required).'; return }
  $policies = @(Get-ModifyPolicyNames)
  $policyText = if ($policies.Count -gt 0) { "Policies that modified these resources: $($policies -join '; ')." } else { 'See the activity log entries named Microsoft.Authorization/policies/modify/action in the resource group.' }
  throw ("Public network access is DISABLED on: $($blocked -join ', ').`n" +
    "The template requests it enabled, so your tenant is overriding it, almost certainly an Azure Policy with a Modify effect (re-enabling it by hand is reverted immediately).`n$policyText`n" +
    "This deployment needs both reachable: this workstation uploads the build artifacts and the VMs read them over VNet service endpoints, which do not work when public access is disabled.`n" +
    "Choose one: (1) ask the tenant's policy owner for an exemption on resource group '$($cfg.ResourceGroup)' for those policies, then rerun this command (it resumes), " +
    "or (2) use a subscription or tenant that does not enforce this policy.`n" +
    "The resource group was created and is billing; remove it with -Stage Destroy if you will not continue.")
}
function Complete-Provision($Outputs) {
  if ($useStorage -and ($Outputs.storageAccountName.value -ne $names.Storage -or $Outputs.keyVaultName.value -ne $names.Vault)) {
    throw 'Deployed resource names differ from the names computed by this script; refusing to continue.'
  }
  $script:State.publicIps = @{ linux = $Outputs.linuxPublicIp.value; windows = $Outputs.windowsPublicIp.value }
  Save-State
  if ($useStorage) {
    Test-DataServiceAccess
    Write-Step 'Storing the Windows administrator password in Key Vault'
    $secretFile = Join-Path $stateRoot 'windows-admin.tmp'
    try {
      [IO.File]::WriteAllText($secretFile, $script:State.windowsAdminPassword)
      Invoke-AzureRetry @('keyvault','secret','set','--subscription',$cfg.SubscriptionId,'--vault-name',$names.Vault,
        '--name','windows-admin-password','--file',$secretFile,'--only-show-errors','-o','none') | Out-Null
    } finally { Remove-Item -LiteralPath $secretFile -Force -ErrorAction SilentlyContinue }
  } else {
    Write-Note 'Direct mode: no Key Vault; the Windows administrator password stays in the protected state folder (shown by -Stage Credentials).'
  }
  Write-Step 'Tagging OS disks'
  $groupTags = (Invoke-Azure @('group','show','--subscription',$cfg.SubscriptionId,'--name',$cfg.ResourceGroup,'--query','tags','-o','json')) | ConvertFrom-Json
  foreach ($disk in @("osdisk-$($names.Environment)-linux","osdisk-$($names.Environment)-win")) {
    $diskId = "/subscriptions/$($cfg.SubscriptionId)/resourceGroups/$($cfg.ResourceGroup)/providers/Microsoft.Compute/disks/$disk"
    Invoke-Azure (@('tag','update','--subscription',$cfg.SubscriptionId,'--resource-id',$diskId,'--operation','Merge','--tags') + (ConvertTo-TagArguments $groupTags) + @('--only-show-errors','-o','none')) | Out-Null
  }
}
function Invoke-WhatIf {
  Initialize-Credentials
  Write-ParametersFile
  Write-Step 'Previewing the deployment with ARM what-if (nothing is created)'
  $preview = Invoke-Azure @('deployment','sub','what-if','--subscription',$cfg.SubscriptionId,'--name',$names.Deployment,'--location',$cfg.Location,
    '--template-file',(Join-Path $PSScriptRoot 'main.bicep'),'--parameters',"@$parametersFile",'--no-pretty-print','-o','json')
  [IO.File]::WriteAllText((Join-Path $stateRoot 'what-if-result.json'), $preview)
  $summary = $preview | ConvertFrom-Json
  if ($summary.status -ne 'Succeeded' -or $summary.error) { throw 'ARM what-if did not succeed; see what-if-result.json in the state directory.' }
  $byType = @($summary.changes) | Group-Object changeType | ForEach-Object { "$($_.Count) $($_.Name)" }
  Write-Note "What-if: $($byType -join ', ')"
}
function Get-PriorProvisionOutputs {
  # A previous run whose ARM deployment succeeded but whose post-provision steps failed can resume without redeploying.
  if ($Force) { return $null }
  $file = Join-Path $stateRoot 'provision-result.json'
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  try { $prior = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json } catch { return $null }
  # A deployment made by an older script version had no mode setting and always included Storage and Key Vault.
  $deployedMode = if ($script:State.ContainsKey('armArtifactTransfer')) { $script:State.armArtifactTransfer } else { 'storage' }
  if ($deployedMode -ne $cfg.ArtifactTransfer) { return $null }
  if ($prior.properties.provisioningState -eq 'Succeeded' -and $prior.properties.outputs.storageAccountName) { return $prior.properties.outputs }
  return $null
}
function Invoke-Provision {
  $prior = Get-PriorProvisionOutputs
  if ($prior) {
    Write-Note 'The ARM deployment already succeeded earlier; resuming the post-provision steps (use -Force to redeploy the template).'
    Complete-Provision $prior
    Write-Note "Linux public IP $($script:State.publicIps.linux); Windows public IP $($script:State.publicIps.windows)"
    return
  }
  Invoke-WhatIf
  Write-Step 'Creating Azure resources (about 5-10 minutes)'
  $result = Invoke-Azure @('deployment','sub','create','--subscription',$cfg.SubscriptionId,'--name',$names.Deployment,'--location',$cfg.Location,
    '--template-file',(Join-Path $PSScriptRoot 'main.bicep'),'--parameters',"@$parametersFile",'-o','json')
  [IO.File]::WriteAllText((Join-Path $stateRoot 'provision-result.json'), $result)
  $parsed = $result | ConvertFrom-Json
  if ($parsed.properties.provisioningState -ne 'Succeeded') { throw 'ARM deployment did not succeed.' }
  $script:State.armArtifactTransfer = $cfg.ArtifactTransfer
  Save-State
  Complete-Provision $parsed.properties.outputs
  Write-Note "Linux public IP $($script:State.publicIps.linux); Windows public IP $($script:State.publicIps.windows)"
}

# ---------------------------------------------------------------------------------------------------------------
# Guest scripts: configuration is delivered as a validated preamble, never interpolated into the script body
# ---------------------------------------------------------------------------------------------------------------
function New-Preamble([System.Collections.IDictionary]$Variables, [string]$Shell) {
  $lines = foreach ($entry in $Variables.GetEnumerator()) {
    $value = [string]$entry.Value
    if ($value -notmatch $safeValue) { throw "Value for $($entry.Key) contains unsupported characters." }
    if ($Shell -eq 'bash') { "export $($entry.Key)='$value'" } else { "`$$($entry.Key) = '$value'" }
  }
  return (($lines -join "`n") + "`n")
}
function Get-GuestVariables([string]$Shell) {
  $transfer = $cfg.ArtifactTransfer
  $storage = if ($transfer -eq 'storage') { $names.Storage } else { '' }
  $vault = if ($transfer -eq 'storage') { $names.Vault } else { '' }
  if ($Shell -eq 'bash') {
    return [ordered]@{
      DEMO_DOMAIN = $cfg.Domain; DEMO_ARTIFACT_TRANSFER = $transfer; DEMO_STORAGE = $storage; DEMO_VAULT = $vault
      DEMO_HANDOFF_TOKEN = $script:State.handoffToken
      DEMO_LINUX_IP = $names.LinuxPrivateIp; DEMO_WINDOWS_IP = $names.WindowsPrivateIp
      DEMO_ACME_EMAIL = $cfg.AcmeEmail; DEMO_RUN_BROWSER_TESTS = $(if ($cfg.RunTests) { '1' } else { '0' })
    }
  }
  return [ordered]@{ DemoDomain = $cfg.Domain; DemoArtifactTransfer = $transfer; DemoStorage = $storage; DemoHandoffToken = $script:State.handoffToken; DemoLinuxIp = $names.LinuxPrivateIp }
}
function Invoke-HostPayload([string]$Vm, [string]$Shell, [string]$Payload, [string]$Label) {
  $commandId = if ($Shell -eq 'bash') { 'RunShellScript' } else { 'RunPowerShellScript' }
  $payloadFile = Join-Path $stateRoot "payload-$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllText($payloadFile, $Payload, [Text.UTF8Encoding]::new($false))
    $json = $null
    for ($attempt = 1; $attempt -le 4; $attempt++) {
      try {
        $json = Invoke-Azure @('vm','run-command','invoke','--subscription',$cfg.SubscriptionId,'--resource-group',$cfg.ResourceGroup,
          '--name',$Vm,'--command-id',$commandId,'--scripts',"@$payloadFile",'-o','json')
        break
      } catch {
        if ($attempt -eq 4) { throw }
        Write-Note "VM agent not ready or busy; retrying in 60 seconds (attempt $attempt of 3)."
        Start-Sleep -Seconds 60
      }
    }
  } finally { Remove-Item -LiteralPath $payloadFile -Force -ErrorAction SilentlyContinue }
  $resultFile = Join-Path $stateRoot "$Label-$Vm-result.json"
  [IO.File]::WriteAllText($resultFile, $json)
  $messages = (($json | ConvertFrom-Json).value | ForEach-Object { $_.message }) -join "`n"
  if ($messages -match 'DEMO_STAGE_FAILED' -or $messages -notmatch 'DEMO_STAGE_OK') {
    $tail = ($messages -split "`n" | Select-Object -Last 25) -join "`n"
    throw "Guest stage '$Label' failed on $Vm. Restricted response: $resultFile`n$(Hide-Secrets $tail)"
  }
  return $messages
}
function Invoke-Host([string]$Vm, [string]$ScriptName) {
  $shell = if ($ScriptName.EndsWith('.sh')) { 'bash' } else { 'powershell' }
  $body = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "scripts\$ScriptName")) -replace "`r`n", "`n"
  $preamble = New-Preamble (Get-GuestVariables $shell) $shell
  if ($shell -eq 'bash') {
    $firstBreak = $body.IndexOf("`n")
    $payload = $body.Substring(0, $firstBreak + 1) + $preamble + $body.Substring($firstBreak + 1)
  } else { $payload = $preamble + $body }
  $messages = Invoke-HostPayload $Vm $shell $payload $script:CurrentStage
  Write-Note "$script:CurrentStage completed on $Vm."
  return $messages
}

# Direct mode: files reach the Linux VM through the VM command channel (no Storage account, no Key Vault, nothing public).
# Chunks are written at explicit offsets, so a retried chunk is harmless, and the final SHA-256 must match.
$uploadChunkBytes = 90KB   # payload is ~125 KB; the command channel silently drops scripts somewhere above ~143 KB (measured), so stay well below
$uploadDirectory = '/var/tmp/idpdemo-upload'
function New-UploadChunkScript([string]$Name, [long]$Offset, [byte[]]$Bytes, [string]$Directory = '/var/tmp/idpdemo-upload') {
  $b64 = [Convert]::ToBase64String($Bytes)
  $data = ([regex]::Matches($b64, '.{1,76}') | ForEach-Object { $_.Value }) -join "`n"
  $preamble = New-Preamble ([ordered]@{ DEMO_UPLOAD_DIR = $Directory; DEMO_UPLOAD_NAME = $Name; DEMO_UPLOAD_OFFSET = [string]$Offset }) 'bash'
  $body = @'
mkdir -p "$DEMO_UPLOAD_DIR"
chmod 700 "$DEMO_UPLOAD_DIR"
file="$DEMO_UPLOAD_DIR/$DEMO_UPLOAD_NAME"
if [ "$DEMO_UPLOAD_OFFSET" -eq 0 ]; then : > "$file"; fi
base64 -d <<'DEMO_DATA' | dd of="$file" bs=64K iflag=fullblock oflag=seek_bytes seek="$DEMO_UPLOAD_OFFSET" conv=notrunc status=none
'@
  return "#!/bin/bash`nset -euo pipefail`numask 077`n$preamble$body`n$data`nDEMO_DATA`n" + 'echo "DEMO_STAGE_OK: $(stat -c %s "$file") bytes present"' + "`n"
}
function New-UploadVerifyScript([string]$Name, [string]$Sha256, [long]$Size, [string]$Directory = '/var/tmp/idpdemo-upload') {
  $preamble = New-Preamble ([ordered]@{ DEMO_UPLOAD_DIR = $Directory; DEMO_UPLOAD_NAME = $Name; DEMO_UPLOAD_SHA256 = $Sha256; DEMO_UPLOAD_SIZE = [string]$Size }) 'bash'
  $body = @'
file="$DEMO_UPLOAD_DIR/$DEMO_UPLOAD_NAME"
actual=$(sha256sum "$file" | cut -d' ' -f1)
size=$(stat -c %s "$file")
if [ "$actual" = "$DEMO_UPLOAD_SHA256" ] && [ "$size" = "$DEMO_UPLOAD_SIZE" ]; then
  echo "DEMO_STAGE_OK: $DEMO_UPLOAD_NAME verified ($size bytes, sha256 matches)"
else
  echo "DEMO_STAGE_FAILED: $DEMO_UPLOAD_NAME is $size bytes with a different hash" >&2
  exit 1
fi
'@
  return "#!/bin/bash`nset -euo pipefail`n$preamble$body`n"
}
function Send-FileToLinux([string]$Path, [string]$Name) {
  $size = (Get-Item -LiteralPath $Path).Length
  $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  $chunks = [Math]::Max(1, [Math]::Ceiling($size / $uploadChunkBytes))
  $stream = [IO.File]::OpenRead($Path)
  try {
    $buffer = New-Object byte[] $uploadChunkBytes
    $offset = 0L
    $index = 0
    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
      $index++
      $chunk = New-Object byte[] $read
      [Array]::Copy($buffer, $chunk, $read)
      Write-Note "Uploading $Name (chunk $index of $chunks, $([Math]::Round($size / 1KB)) KB total)"
      Invoke-HostPayload $names.LinuxVm 'bash' (New-UploadChunkScript $Name $offset $chunk $uploadDirectory) "Upload-$Name" | Out-Null
      $offset += $read
    }
  } finally { $stream.Dispose() }
  Invoke-HostPayload $names.LinuxVm 'bash' (New-UploadVerifyScript $Name $hash $size $uploadDirectory) "Verify-$Name" | Out-Null
}

# ---------------------------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------------------------
function Build-StudentApp {
  if (-not $script:MSBuild) { $script:MSBuild = Find-MSBuild }
  $project = Join-Path $workspace 'samples\apps\dotnet-shibsp\StudentRecords.csproj'
  if ($script:MSBuild) {
    Write-Step 'Compiling the ASP.NET Framework 4.8 Student app'
    & $script:MSBuild $project /restore /p:Configuration=Release /v:minimal /nologo
    if ($LASTEXITCODE -ne 0) { throw 'Student application build failed.' }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $workspace 'samples\apps\dotnet-shibsp\bin\StudentRecords.dll'))) { throw 'StudentRecords.dll was not produced.' }
}
function New-SourceArchive([string]$Root, [string]$Archive) {
  & tar -czf $Archive --exclude=.state --exclude=.local --exclude=node_modules --exclude=results --exclude=playwright-report --exclude=test-results `
    --exclude=bin --exclude=obj --exclude=target --exclude='environment*.json' -C $Root samples infra
  if ($LASTEXITCODE -ne 0) { throw 'Source archive creation failed.' }
  $leaks = @(& tar -tzf $Archive | Where-Object { $_ -match '\.state/|\.local/|environment[^/]*\.json|operator_ed25519|parameters\.json' })
  if ($leaks.Count -gt 0) { throw "Source archive unexpectedly contains protected files: $($leaks -join ', ')" }
}
function Publish-Artifacts {
  Write-Step $(if ($useStorage) { 'Packaging and uploading source to Storage' } else { 'Packaging source and sending it to the Linux VM' })
  $archive = Join-Path $stateRoot 'source.tgz'
  New-SourceArchive $workspace $archive
  $bin = Join-Path $workspace 'samples\apps\dotnet-shibsp\bin'
  $binaryArchive = Join-Path $stateRoot 'student-bin.zip'
  Compress-Archive -Path "$bin\*" -DestinationPath $binaryArchive -Force
  if (-not $useStorage) {
    Send-FileToLinux $archive 'source.tgz'
    Send-FileToLinux $binaryArchive 'student-bin.zip'
    return
  }
  foreach ($upload in @(@{ container = 'artifacts'; name = 'source.tgz'; file = $archive }, @{ container = 'windows-handoff'; name = 'student-bin.zip'; file = $binaryArchive })) {
    Invoke-AzureRetry @('storage','blob','upload','--subscription',$cfg.SubscriptionId,'--auth-mode','login','--account-name',$names.Storage,
      '--container-name',$upload.container,'--name',$upload.name,'--file',$upload.file,'--overwrite','true','--only-show-errors','-o','none') | Out-Null
  }
}
function Invoke-Build {
  Build-StudentApp
  Publish-Artifacts
  Write-Step 'Building Linux images and running unit/fixture checks on the Linux VM (15-30 minutes)'
  Invoke-Host $names.LinuxVm 'bootstrap-linux.sh' | Out-Null
}

# ---------------------------------------------------------------------------------------------------------------
# DNS and certificates
# ---------------------------------------------------------------------------------------------------------------
function Get-RelativeName([string]$Fqdn, [string]$Zone) {
  if ($Fqdn -eq $Zone) { return '@' }
  return $Fqdn.Substring(0, $Fqdn.Length - $Zone.Length - 1)
}
function Add-AzureDnsRecord([string]$Fqdn, [string]$Type, [string]$Value) {
  $relative = Get-RelativeName $Fqdn $cfg.DnsZoneName
  $common = @('--subscription',$cfg.DnsZoneSubscription,'--resource-group',$cfg.DnsZoneGroup,'--zone-name',$cfg.DnsZoneName,'--name',$relative)
  $existing = $null
  try { $existing = (& az network dns record-set $Type.ToLowerInvariant() show @common -o json 2>$null) -join "`n" } catch { $existing = $null }
  if ($LASTEXITCODE -eq 0 -and $existing) {
    $set = $existing | ConvertFrom-Json
    if ($Type -eq 'A') {
      $addresses = @($set.aRecords | ForEach-Object { $_.ipv4Address })
      if ($addresses -contains $Value -and $addresses.Count -eq 1) { Write-Note "$Fqdn already points to $Value"; return }
      throw "DNS record $Fqdn already exists with different content ($($addresses -join ', ')). Remove or correct it, then rerun; existing records are never overwritten."
    }
    if (@($set.txtRecords | ForEach-Object { $_.value -join '' }) -contains $Value) { return }
  }
  $valueArgument = if ($Type -eq 'A') { @('--ipv4-address',$Value) } else { @('--value',$Value) }
  Invoke-Azure (@('network','dns','record-set',$Type.ToLowerInvariant(),'add-record') + $common + $valueArgument + @('--only-show-errors','-o','none')) | Out-Null
  Write-Note "Created $Type $Fqdn"
}
function Get-ARecordPlan {
  $linux = $script:State.publicIps.linux; $windows = $script:State.publicIps.windows
  return @($appHosts | ForEach-Object { [pscustomobject]@{ Name = "$_.$($cfg.Domain)"; Address = $(if ($_ -eq 'student') { $windows } else { $linux }) } })
}
function Invoke-Dns {
  $plan = Get-ARecordPlan
  if ($cfg.DnsMode -eq 'azureDns') {
    Write-Step "Creating A records in Azure DNS zone $($cfg.DnsZoneName)"
    foreach ($record in $plan) { Add-AzureDnsRecord $record.Name 'A' $record.Address }
    return
  }
  Write-Step 'Create these DNS A records at your DNS provider (propagation can proceed while the build runs)'
  Write-Host ''
  $plan | Format-Table @{ n = 'Record'; e = { $_.Name } }, @{ n = 'Type'; e = { 'A' } }, @{ n = 'Value'; e = { $_.Address } } -AutoSize | Out-Host
  Write-Note 'If your DNS provider appends the zone name automatically, enter only the part before it.'
}
function Wait-DnsRecords($Checks, [int]$Minutes) {
  $deadline = (Get-Date).AddMinutes($Minutes)
  $pending = @($Checks)
  while ($true) {
    $still = @()
    foreach ($check in $pending) {
      $found = $false
      foreach ($server in @('1.1.1.1','8.8.8.8')) {
        $answers = @(Resolve-DnsName -Name $check.Name -Type $check.Type -Server $server -DnsOnly -ErrorAction SilentlyContinue)
        if ($check.Type -eq 'A') { $found = [bool]($answers | Where-Object { $_.Type -eq 'A' -and $_.IPAddress -eq $check.Expected }) }
        else { $found = [bool]($answers | Where-Object { $_.Type -eq 'TXT' -and (($_.Strings -join '') -eq $check.Expected) }) }
        if ($found) { break }
      }
      if (-not $found) { $still += $check }
    }
    if ($still.Count -eq 0) { Write-Note 'All required DNS records are visible.'; return }
    $list = ($still | ForEach-Object { "$($_.Type) $($_.Name)" }) -join '; '
    if ((Get-Date) -gt $deadline) {
      throw "DNS records still not visible after $Minutes minutes: $list`nCreate them, then rerun the same command; completed stages are skipped."
    }
    Write-Note "Waiting for DNS ($($still.Count) pending): $list"
    Start-Sleep -Seconds 20
  }
}
function Invoke-CertificateRequest {
  Write-Step "Requesting a Let's Encrypt wildcard certificate order for *.$($cfg.Domain)"
  $output = Invoke-Host $names.LinuxVm 'certificate-request.sh'
  if ($output -match "TXT value:\s*'?(?<value>[A-Za-z0-9_-]{20,})'?") { $value = $Matches['value'] }
  else { throw 'The ACME client did not report a TXT challenge value; inspect the restricted result file.' }
  $script:State.acme = @{ txtName = "_acme-challenge.$($cfg.Domain)"; txtValue = $value }
  Save-State
  if ($cfg.DnsMode -eq 'azureDns') {
    Write-Step 'Publishing the ACME challenge TXT record in Azure DNS'
    Add-AzureDnsRecord $script:State.acme.txtName 'TXT' $value
  } else {
    Write-Step 'Create this DNS TXT record now'
    Write-Host ''
    Write-Host "    Name:  $($script:State.acme.txtName)"
    Write-Host "    Type:  TXT"
    Write-Host "    Value: $value"
    Write-Host ''
    Write-Note "If your DNS provider appends the zone automatically, use the name without the trailing zone. The value must not change."
  }
}
function Invoke-DnsWait {
  if (-not $script:State.ContainsKey('acme')) { throw 'No ACME challenge is recorded; run the CertificateRequest stage first.' }
  Write-Step 'Waiting for the A records and the ACME TXT record to resolve publicly'
  $checks = @(Get-ARecordPlan | ForEach-Object { @{ Name = $_.Name; Type = 'A'; Expected = $_.Address } })
  $checks += @{ Name = $script:State.acme.txtName; Type = 'TXT'; Expected = $script:State.acme.txtValue }
  Wait-DnsRecords $checks $cfg.DnsWaitMinutes
}
function Invoke-CertificateComplete {
  Write-Step 'Issuing the certificate, starting all services and staging the Windows handoff'
  Invoke-Host $names.LinuxVm 'certificate-complete.sh' | Out-Null
  if ($cfg.DnsMode -eq 'azureDns' -and $script:State.ContainsKey('acme')) {
    $relative = Get-RelativeName $script:State.acme.txtName $cfg.DnsZoneName
    & az network dns record-set txt delete --subscription $cfg.DnsZoneSubscription --resource-group $cfg.DnsZoneGroup --zone-name $cfg.DnsZoneName --name $relative --yes --only-show-errors 2>$null
    Write-Note 'Removed the ACME challenge TXT record.'
  } elseif ($cfg.DnsMode -eq 'manual') {
    Write-Note "You can now delete the TXT record $($script:State.acme.txtName)."
  }
}
function Wait-VmAgent([string]$Vm) {
  # After a restart the VM agent takes a minute or two before it accepts commands.
  for ($attempt = 1; $attempt -le 20; $attempt++) {
    try { Invoke-HostPayload $Vm 'powershell' 'Write-Output DEMO_STAGE_OK' 'AgentReady' | Out-Null; return } catch { Start-Sleep -Seconds 30 }
  }
  throw "$Vm did not become reachable through the VM agent after the restart."
}
function Confirm-StudentBinaryOnLinux {
  # Direct mode serves student-bin.zip from the Linux VM; re-send it if it is missing (for example after an older cleanup).
  $probe = "#!/bin/bash`nif [ -s $uploadDirectory/student-bin.zip ]; then echo 'DEMO_STAGE_OK: present'; else echo 'DEMO_STAGE_OK: missing'; fi`n"
  $result = Invoke-HostPayload $names.LinuxVm 'bash' $probe 'StudentBinaryCheck'
  if ($result -match 'DEMO_STAGE_OK: present') { return }
  Write-Note 'The Windows application binaries are missing on the Linux VM; sending them again.'
  Build-StudentApp
  $binaryArchive = Join-Path $stateRoot 'student-bin.zip'
  Compress-Archive -Path (Join-Path $workspace 'samples\apps\dotnet-shibsp\bin\*') -DestinationPath $binaryArchive -Force
  Send-FileToLinux $binaryArchive 'student-bin.zip'
}
function Invoke-WindowsBootstrapOnce {
  if ($useStorage) { return (Invoke-Host $names.WindowsVm 'bootstrap-windows.ps1') }
  Confirm-StudentBinaryOnLinux
  # Direct mode: the Linux VM serves the handoff package (private network, verified TLS, secret path) only while Windows needs it,
  # and the staged package, which contains the SP private key, is deleted afterwards even if the Windows stage fails.
  Write-Note 'Starting the private handoff server on the Linux VM.'
  $script:CurrentStage = 'HandoffServe'
  Invoke-Host $names.LinuxVm 'handoff-serve.sh' | Out-Null
  try {
    $script:CurrentStage = 'Windows'
    $output = Invoke-Host $names.WindowsVm 'bootstrap-windows.ps1'
  } finally {
    $script:CurrentStage = 'HandoffCleanup'
    try { Invoke-Host $names.LinuxVm 'handoff-stop.sh' | Out-Null }
    catch { Write-Caution "Could not stop the handoff server or delete the staged package on the Linux VM: $($_.Exception.Message)" }
    $script:CurrentStage = 'Windows'
  }
  return $output
}
function Invoke-WindowsSetup {
  Write-Step 'Installing IIS and the native Shibboleth SP, then configuring the Student app'
  for ($pass = 1; $pass -le 2; $pass++) {
    $output = Invoke-WindowsBootstrapOnce
    if ($output -notmatch 'DEMO_RESTART_REQUIRED') { return }
    Write-Step 'The Shibboleth SP installer requires a Windows restart; restarting the Windows VM, then repeating this stage'
    Invoke-Azure @('vm','restart','--subscription',$cfg.SubscriptionId,'--resource-group',$cfg.ResourceGroup,'--name',$names.WindowsVm,'--only-show-errors','-o','none') | Out-Null
    Wait-VmAgent $names.WindowsVm
  }
  throw 'Windows still requested a restart after the second pass; inspect C:\idpdemo\sp-install.log on the Windows VM.'
}
function Invoke-Verify {
  Write-Step 'Verifying readiness of all six endpoints and running the browser tests'
  $output = Invoke-Host $names.LinuxVm 'verify.sh'
  $summary = @($output -split "`n" | Where-Object { $_ -match '^DEMO_TESTS_(SUMMARY|FAILED):' } | ForEach-Object { ($_ -replace '^DEMO_TESTS_[A-Z]+:\s*', '').Trim() })
  $exit = if ($output -match 'DEMO_TESTS_EXIT=(\d+)') { [int]$Matches[1] } else { $null }
  $script:State.verify = @{ utc = [DateTime]::UtcNow.ToString('o'); testsExitCode = $exit; lines = $summary }
  Save-State
  if ($cfg.RunTests) {
    if ($exit -eq 0) { Write-Host '    Browser tests: all passed.' -ForegroundColor Green }
    else {
      Write-Caution 'Some browser tests failed (the environment is deployed and all six endpoints are ready):'
      $summary | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
      if ($cfg.FailOnTestFailure) { throw 'Browser tests failed and options.failOnTestFailure is true.' }
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------------------------------------------
function Show-Status {
  Write-Step "Status of $($cfg.ResourceGroup)"
  foreach ($vm in @($names.LinuxVm,$names.WindowsVm)) {
    $power = & az vm get-instance-view --subscription $cfg.SubscriptionId --resource-group $cfg.ResourceGroup --name $vm --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv 2>$null
    Write-Host ("    {0,-40} {1}" -f $vm, $(if ($power) { $power } else { 'not found' }))
  }
  foreach ($app in $appHosts) {
    $url = "https://$app.$($cfg.Domain)/readyz"
    try { $code = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 15).StatusCode } catch { $code = "unreachable ($($_.Exception.Message.Split("`n")[0]))" }
    Write-Host ("    {0,-45} {1}" -f $url, $code)
  }
}
function Show-Credentials {
  Write-Caution 'The synthetic test-user passwords will be printed to this console.'
  if ($useStorage) {
    $json = Invoke-Azure @('keyvault','secret','show','--subscription',$cfg.SubscriptionId,'--vault-name',$names.Vault,'--name','synthetic-test-users','--query','value','-o','tsv')
  } else {
    # Direct mode keeps the passwords only on the Linux VM; read them through the VM command channel.
    $script:CurrentStage = 'Credentials'
    $payload = "#!/bin/bash`nset -euo pipefail`ncat /srv/idpdemo/source/samples/.local/test-users.json`necho`necho DEMO_STAGE_OK`n"
    $messages = Invoke-HostPayload $names.LinuxVm 'bash' $payload 'Credentials'
    Remove-Item -LiteralPath (Join-Path $stateRoot "Credentials-$($names.LinuxVm)-result.json") -Force -ErrorAction SilentlyContinue
    if ($messages -notmatch '(?s)(\{.*\})') { throw 'The Linux VM did not return the test-user list; has the Build stage completed?' }
    $json = $Matches[1]
  }
  $users = $json | ConvertFrom-Json
  $users.PSObject.Properties | ForEach-Object { Write-Host ("    {0,-8} {1}" -f $_.Name, $_.Value) }
  Write-Note 'Sign in with the short name (alice), not alice@demo.test.'
  if ($useStorage) { Write-Note "The Windows admin password is Key Vault secret 'windows-admin-password' in $($names.Vault)." }
  else {
    Write-Caution "Windows administrator ($($cfg.AdminUsername)) password, from the protected state file:"
    Write-Host "    $($script:State.windowsAdminPassword)"
  }
}
function Invoke-VmPower([string]$Action) {
  foreach ($vm in @($names.LinuxVm,$names.WindowsVm)) {
    Write-Step "$Action $vm"
    Invoke-Azure @('vm',$Action,'--subscription',$cfg.SubscriptionId,'--resource-group',$cfg.ResourceGroup,'--name',$vm,'--only-show-errors','-o','none') | Out-Null
  }
  if ($Action -eq 'deallocate') { Write-Note 'VMs are Stopped (deallocated). Disks and public IPs (and Storage/Key Vault, if used) still incur charges.' }
  else { Write-Note 'Public IPs are static, so DNS remains valid. Services restart automatically (Docker restart policies / IIS).' }
}
function Invoke-Destroy {
  Write-Caution "This permanently deletes resource group $($cfg.ResourceGroup) and every resource in it, including all demo data."
  $answer = Read-Host "Type the resource group name ($($cfg.ResourceGroup)) to delete everything"
  if ($answer -ne $cfg.ResourceGroup) { throw 'Not confirmed. Nothing was deleted.' }
  Invoke-Azure @('group','delete','--subscription',$cfg.SubscriptionId,'--name',$cfg.ResourceGroup,'--yes') | Out-Null
  $deleted = & az keyvault list-deleted --subscription $cfg.SubscriptionId --query "[?name=='$($names.Vault)'].name" -o tsv 2>$null
  if ($deleted) {
    Invoke-Azure @('keyvault','purge','--subscription',$cfg.SubscriptionId,'--name',$names.Vault,'--location',$cfg.Location,'--only-show-errors') | Out-Null
    Write-Note 'Purged the soft-deleted Key Vault so its name can be reused.'
  }
  if (Test-Path -LiteralPath $stateFile) { Remove-Item -LiteralPath $stateFile -Force }
  Write-Note 'Resource group deleted. Remove DNS records you created, and local state under infra\.state if no longer needed.'
}
function Show-Summary {
  $domain = $cfg.Domain
  Write-Host ''
  Write-Host '  Demo environment' -ForegroundColor Green
  Write-Host "    CAS (IdP, protocol CAS 3.0)   https://cas.$domain/cas/login"
  Write-Host "    Shibboleth IdP (SAML)         https://idp.$domain/idp/"
  Write-Host "    UC-01 HR Self-Service         https://hr.$domain"
  Write-Host "    UC-04 Drupal (samlauth)       https://drupal.$domain/saml/login"
  Write-Host "    UC-05 Alumni Directory        https://alumni.$domain"
  Write-Host "    UC-06 Campus Events (cPanel)  https://events.$domain/admin/"
  Write-Host "    UC-03 Student Records (IIS)   https://student.$domain/Student/Profile"
  Write-Host ''
  Write-Host '  Sign-in: short user name (alice, bob, carol, dave, erin, frank, grace). Passwords are random:'
  Write-Host "    pwsh -File .\infra\Deploy-Demo.ps1 -ConfigPath '$ConfigPath' -Stage Credentials$(if ($useStorage) { "     (or Key Vault secret synthetic-test-users in $($names.Vault))" })"
  Write-Host ''
  Write-Host '  Operate:'
  Write-Host "    -Stage Status | Stop (deallocate both VMs) | Start | Destroy"
  Write-Host '    Stop deallocates the VMs only; disks and public IPs (and Storage/Key Vault, if used) continue to bill. Destroy removes everything.'
  if ($script:State.ContainsKey('verify') -and $script:State.verify.testsExitCode -ne 0 -and $cfg.RunTests) {
    Write-Host ''
    Write-Caution 'The last browser-test run had failures; see the Verify output above and the Known issues section of infra\README.md.'
  }
  Write-Host ''
  Write-Host "  State and credentials (protected): $stateRoot"
}

# ---------------------------------------------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------------------------------------------
$stageActions = @{
  Provision = { Invoke-Provision }
  Dns = { Invoke-Dns }
  Build = { Invoke-Build }
  CertificateRequest = { Invoke-CertificateRequest }
  DnsWait = { Invoke-DnsWait }
  CertificateComplete = { Invoke-CertificateComplete }
  Windows = { Invoke-WindowsSetup }
  Verify = { Invoke-Verify }
}
function Invoke-DeploymentStage([string]$Name) {
  $script:CurrentStage = $Name
  & $stageActions[$Name]
  Set-StageComplete $Name
}

switch ($Stage) {
  'Preflight' { Invoke-Preflight }
  'Validate' { Invoke-Preflight; Invoke-WhatIf; Write-Step 'Validation complete. Nothing was created.' }
  'Status' { Connect-Tenant; Show-Status }
  'Credentials' { Connect-Tenant; Show-Credentials }
  'Stop' { Connect-Tenant; Invoke-VmPower 'deallocate' }
  'Start' { Connect-Tenant; Invoke-VmPower 'start' }
  'Destroy' { Connect-Tenant; Invoke-Destroy }
  'All' {
    Invoke-Preflight
    foreach ($name in $stageOrder) {
      if (-not $Force -and (Test-StageComplete $name)) { Write-Note "$name already completed (use -Force to rerun)."; continue }
      if ($name -eq 'Provision' -and -not (Get-PriorProvisionOutputs)) { Confirm-Deployment }
      Invoke-DeploymentStage $name
    }
    Show-Summary
  }
  default {
    Invoke-Preflight
    if ($Stage -eq 'Provision' -and -not (Get-PriorProvisionOutputs)) { Confirm-Deployment }
    if ($Stage -ne 'Provision' -and -not $script:State.ContainsKey('publicIps')) { throw 'No provisioned environment is recorded for this configuration. Run the Provision stage first.' }
    Invoke-DeploymentStage $Stage
    Show-Summary
  }
}
