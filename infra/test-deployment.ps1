#Requires -Version 7.2
<#
  Offline tests for the deployment package (no Azure calls, nothing is created):
  configuration validation, guest-script variable contracts, payload assembly and source-archive hygiene.
    pwsh -NoProfile -File .\infra\test-deployment.ps1
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Deploy-Demo.ps1'
$workspace = Split-Path $PSScriptRoot -Parent
$failures = 0
function Assert-That([string]$Name, [bool]$Condition, [string]$Detail = '') {
  if ($Condition) { Write-Host "  ok    $Name" -ForegroundColor Green }
  else { Write-Host "  FAIL  $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
Assert-That 'Deploy-Demo.ps1 parses without errors' ($errors.Count -eq 0)
$safeValue = '^[A-Za-z0-9._:/@+-]*$'
foreach ($name in 'Test-Ipv4Cidr','New-Preamble','Get-RelativeName','Hide-Secrets','Get-GuestVariables','New-SourceArchive','Get-OptionalValue','Get-VmSkuVerdict','Test-ActionAllowed','Get-PriorProvisionOutputs','New-UploadChunkScript','New-UploadVerifyScript') {
  $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $node) { throw "Function $name not found in Deploy-Demo.ps1" }
  Invoke-Expression $node.Extent.Text
}

Write-Host 'Pure helpers'
Assert-That 'CIDR accepts 0.0.0.0/0, a /32 and a bare address' ((Test-Ipv4Cidr '0.0.0.0/0') -and (Test-Ipv4Cidr '203.0.113.7/32') -and (Test-Ipv4Cidr '203.0.113.7'))
Assert-That 'CIDR rejects bad octets, prefixes and text' (-not ((Test-Ipv4Cidr '300.1.1.1') -or (Test-Ipv4Cidr '10.0.0.0/33') -or (Test-Ipv4Cidr 'Internet') -or (Test-Ipv4Cidr '1.2.3')))
Assert-That 'Relative DNS names are computed against the zone' ((Get-RelativeName 'cas.demo.contoso.com' 'contoso.com') -eq 'cas.demo' -and (Get-RelativeName 'contoso.com' 'contoso.com') -eq '@')
$sample = '{"flag":false,"zero":0,"blank":"  ","text":"x","list":[]}' | ConvertFrom-Json
Assert-That 'False and 0 are preserved; blanks and missing values use defaults' (((Get-OptionalValue $sample 'flag' $true) -eq $false) -and ((Get-OptionalValue $sample 'zero' 60) -eq 0) -and ((Get-OptionalValue $sample 'blank' 'd') -eq 'd') -and ((Get-OptionalValue $sample 'missing' 'd') -eq 'd') -and ((Get-OptionalValue $null 'x' 'd') -eq 'd') -and ((Get-OptionalValue $sample 'text' 'd') -eq 'x'))
Assert-That 'Secrets and tokens are masked in diagnostics' ((Hide-Secrets 'password=Sup3rSecretValue token eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.abcdefghijk') -notmatch 'Sup3rSecret|eyJhbGci')
$bash = New-Preamble ([ordered]@{ DEMO_DOMAIN = 'demo.contoso.com'; DEMO_ACME_EMAIL = '' }) 'bash'
Assert-That 'Bash preamble exports quoted variables' ($bash -eq "export DEMO_DOMAIN='demo.contoso.com'`nexport DEMO_ACME_EMAIL=''`n")
$injected = $false
try { New-Preamble ([ordered]@{ DEMO_DOMAIN = "x'; rm -rf /; '" }) 'bash' | Out-Null } catch { $injected = $true }
Assert-That 'Preamble rejects shell metacharacters' $injected

Write-Host 'VM size availability (fixtures shaped like the Azure SKU API)'
$fixture = @(
  [pscustomobject]@{ name = 'Standard_OK'; family = 'standardOKFamily'; capabilities = @([pscustomobject]@{ name = 'vCPUs'; value = '4' }); restrictions = @() },
  [pscustomobject]@{ name = 'Standard_ZoneOnly'; family = 'standardZFamily'; capabilities = @([pscustomobject]@{ name = 'vCPUs'; value = '2' }); restrictions = @([pscustomobject]@{ type = 'Zone'; reasonCode = 'NotAvailableForSubscription' }) },
  [pscustomobject]@{ name = 'Standard_Blocked'; family = 'standardBFamily'; capabilities = @([pscustomobject]@{ name = 'vCPUs'; value = '4' }); restrictions = @([pscustomobject]@{ type = 'Location'; reasonCode = 'NotAvailableForSubscription' }, [pscustomobject]@{ type = 'Zone'; reasonCode = 'NotAvailableForSubscription' }) }
)
$ok = Get-VmSkuVerdict $fixture 'Standard_OK' 'eastus'
Assert-That 'An unrestricted size passes with its family and vCPU count' (-not $ok.Error -and $ok.Family -eq 'standardOKFamily' -and $ok.Cores -eq 4)
$zone = Get-VmSkuVerdict $fixture 'Standard_ZoneOnly' 'eastus'
Assert-That 'A zone-only restriction does not block a regional deployment' (-not $zone.Error -and $zone.Cores -eq 2)
$blocked = Get-VmSkuVerdict $fixture 'Standard_Blocked' 'eastus'
Assert-That 'A location restriction is reported as blocked for the subscription (not "not offered")' ($blocked.Error -match 'blocked for your subscription in eastus \(NotAvailableForSubscription\)' -and $blocked.Error -notmatch 'not offered')
$missing = Get-VmSkuVerdict $fixture 'Standard_Nope' 'eastus'
Assert-That 'An unknown size is reported as nonexistent' ($missing.Error -match 'does not exist in eastus')
Assert-That 'An empty SKU list is handled' ((Get-VmSkuVerdict @() 'Standard_OK' 'eastus').Error -match 'does not exist')

Write-Host 'RBAC permission evaluation (fixtures shaped like the Azure permissions API)'
$contributor = @([pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Authorization/*/Delete','Microsoft.Authorization/*/Write','Microsoft.Authorization/elevateAccess/Action','Microsoft.Blueprint/blueprintAssignments/write') })
$owner = @([pscustomobject]@{ actions = @('*'); notActions = @() })
$uaaPlusContributor = $contributor + @([pscustomobject]@{ actions = @('Microsoft.Authorization/*'); notActions = @() })
$rbacAdmin = @([pscustomobject]@{ actions = @('Microsoft.Authorization/roleAssignments/write','Microsoft.Authorization/roleAssignments/delete'); notActions = @() })
Assert-That 'Contributor can deploy and create VMs but NOT role assignments' ((Test-ActionAllowed $contributor 'Microsoft.Compute/virtualMachines/write') -and (Test-ActionAllowed $contributor 'Microsoft.Resources/deployments/write') -and -not (Test-ActionAllowed $contributor 'Microsoft.Authorization/roleAssignments/write'))
Assert-That 'Owner can create role assignments' (Test-ActionAllowed $owner 'Microsoft.Authorization/roleAssignments/write')
Assert-That 'Contributor plus User Access Administrator can create role assignments' (Test-ActionAllowed $uaaPlusContributor 'Microsoft.Authorization/roleAssignments/write')
Assert-That 'Role Based Access Control Administrator can, and nothing else' ((Test-ActionAllowed $rbacAdmin 'Microsoft.Authorization/roleAssignments/write') -and -not (Test-ActionAllowed $rbacAdmin 'Microsoft.Compute/virtualMachines/write'))
Assert-That 'Matching is case-insensitive and empty permissions deny' ((Test-ActionAllowed $owner 'microsoft.authorization/roleassignments/WRITE') -and -not (Test-ActionAllowed @() 'Microsoft.Compute/virtualMachines/write'))

Write-Host 'Resume after a partly failed provision'
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) "idpdemo-resume-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $stateRoot | Out-Null
try {
  $Force = $false
  $cfg = [pscustomobject]@{ ArtifactTransfer = 'direct' }
  $script:State = @{ armArtifactTransfer = 'direct' }
  Assert-That 'No prior result means a normal deployment' ($null -eq (Get-PriorProvisionOutputs))
  [IO.File]::WriteAllText((Join-Path $stateRoot 'provision-result.json'), '{"properties":{"provisioningState":"Failed","outputs":{"storageAccountName":{"value":"x"}}}}')
  Assert-That 'A failed ARM deployment is never resumed' ($null -eq (Get-PriorProvisionOutputs))
  [IO.File]::WriteAllText((Join-Path $stateRoot 'provision-result.json'), '{"properties":{"provisioningState":"Succeeded","outputs":{"storageAccountName":{"value":""},"keyVaultName":{"value":""}}}}')
  Assert-That 'A succeeded ARM deployment of the same mode resumes from its recorded outputs' ($null -ne (Get-PriorProvisionOutputs))
  $script:State = @{}
  Assert-That 'A deployment from an older script version (storage implied) is not reused for direct mode' ($null -eq (Get-PriorProvisionOutputs))
  $cfg = [pscustomobject]@{ ArtifactTransfer = 'storage' }
  Assert-That 'It is reused when the configuration is storage mode' ($null -ne (Get-PriorProvisionOutputs))
  $cfg = [pscustomobject]@{ ArtifactTransfer = 'direct' }; $script:State = @{ armArtifactTransfer = 'direct' }
  $Force = $true
  Assert-That '-Force always redeploys the template' ($null -eq (Get-PriorProvisionOutputs))
  $Force = $false
  [IO.File]::WriteAllText((Join-Path $stateRoot 'provision-result.json'), 'not json')
  Assert-That 'A corrupt result file is ignored, not fatal' ($null -eq (Get-PriorProvisionOutputs))
} finally { Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host 'Chunked file upload through generated scripts (executed in bash, no Azure)'
$bashExe = $null
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($gitCommand) { $candidate = Join-Path (Split-Path (Split-Path $gitCommand.Source)) 'bin\bash.exe'; if (Test-Path $candidate) { $bashExe = $candidate } }
if (-not $bashExe) { Write-Host '  skip  Git Bash not found; upload round-trip not executed' -ForegroundColor Yellow }
else {
  $workName = "idpdemo-upload-test-$([guid]::NewGuid().ToString('N'))"
  $remoteDir = "/tmp/$workName"
  $localDir = (& $bashExe -c "cygpath -w '$remoteDir'").Trim()
  $source = Join-Path ([IO.Path]::GetTempPath()) "$workName.bin"
  try {
    $random = New-Object byte[] 400003   # deliberately not a multiple of the chunk size
    [Random]::new(42).NextBytes($random)
    [IO.File]::WriteAllBytes($source, $random)
    $hash = (Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $size = $random.Length
    $chunkSize = 100000
    $chunks = for ($offset = 0; $offset -lt $size; $offset += $chunkSize) {
      $length = [Math]::Min($chunkSize, $size - $offset)
      $bytes = New-Object byte[] $length; [Array]::Copy($random, $offset, $bytes, 0, $length)
      @{ Offset = [long]$offset; Bytes = $bytes }
    }
    $run = { param([string]$Text) $Text | & $bashExe 2>&1 | Out-String }
    $ok = $true
    foreach ($chunk in $chunks) { if ((& $run (New-UploadChunkScript 'file.bin' $chunk.Offset $chunk.Bytes $remoteDir)) -notmatch 'DEMO_STAGE_OK') { $ok = $false } }
    Assert-That 'Every chunk script runs and reports success' $ok
    Assert-That 'The reassembled file is byte-identical (sha256)' ((Get-FileHash (Join-Path $localDir 'file.bin') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $hash)
    Assert-That 'The verify script accepts the correct hash and size' ((& $run (New-UploadVerifyScript 'file.bin' $hash $size $remoteDir)) -match 'DEMO_STAGE_OK')
    # A retried chunk (az retries after a transient failure) must not corrupt the file.
    [void](& $run (New-UploadChunkScript 'file.bin' $chunks[2].Offset $chunks[2].Bytes $remoteDir))
    Assert-That 'Re-sending a middle chunk leaves the file identical' ((Get-FileHash (Join-Path $localDir 'file.bin') -Algorithm SHA256).Hash.ToLowerInvariant() -eq $hash)
    Assert-That 'The verify script rejects a wrong hash' ((& $run (New-UploadVerifyScript 'file.bin' ('0' * 64) $size $remoteDir)) -match 'DEMO_STAGE_FAILED')
    Assert-That 'The verify script rejects a wrong size' ((& $run (New-UploadVerifyScript 'file.bin' $hash ($size + 1) $remoteDir)) -match 'DEMO_STAGE_FAILED')
    $fullChunk = New-Object byte[] 92160; [Random]::new(7).NextBytes($fullChunk)
    $payloadLength = (New-UploadChunkScript 'x.bin' 0 $fullChunk '/var/tmp/idpdemo-upload').Length
    Assert-That "A full 90 KB chunk stays under the measured ~143 KB command-channel limit ($payloadLength characters)" ($payloadLength -lt 140000)
    $badName = $false; try { New-UploadChunkScript 'a b;rm.bin' 0 ([byte[]](1)) | Out-Null } catch { $badName = $true }
    Assert-That 'A file name with shell metacharacters is rejected' $badName
  } finally {
    Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
    if ($localDir) { Remove-Item -LiteralPath $localDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

Write-Host 'Guest script contracts'
$cfg = [pscustomobject]@{ Domain = 'demo.contoso.com'; AcmeEmail = 'ops@contoso.com'; RunTests = $true; ArtifactTransfer = 'direct' }
$script:State = @{ handoffToken = '0123456789abcdef0123456789abcdef01234567' }
$names = [pscustomobject]@{ Storage = 'stidpdemox1y2'; Vault = 'kv-idpdemo-x1y2'; LinuxPrivateIp = '10.87.1.4'; WindowsPrivateIp = '10.87.2.4' }
$bashKeys = @((Get-GuestVariables 'bash').Keys)
$psKeys = @((Get-GuestVariables 'powershell').Keys)
$git = Get-Command git -ErrorAction SilentlyContinue
$gitBash = if ($git) { Join-Path (Split-Path (Split-Path $git.Source)) 'bin\bash.exe' } else { $null }
foreach ($file in Get-ChildItem (Join-Path $PSScriptRoot 'scripts') -Filter *.sh) {
  $text = ([IO.File]::ReadAllText($file.FullName)) -replace "`r`n", "`n"
  $used = [regex]::Matches($text, '\bDEMO_[A-Z_]+\b') | ForEach-Object Value | Where-Object { $_ -notmatch '^DEMO_(STAGE_|TESTS)' } | Sort-Object -Unique
  $missing = @($used | Where-Object { $_ -notin $bashKeys })
  Assert-That "$($file.Name) uses only supplied variables" ($missing.Count -eq 0) ($missing -join ', ')
  Assert-That "$($file.Name) has no tenant-specific values" ($text -notmatch 'securitylabworks|a3c8|f9931042|4e272b78|108\.85\.|10\.87\.[12]\.[04]\b')
  $firstBreak = $text.IndexOf("`n")
  $payload = $text.Substring(0, $firstBreak + 1) + (New-Preamble (Get-GuestVariables 'bash') 'bash') + $text.Substring($firstBreak + 1)
  Assert-That "$($file.Name) keeps its shebang as line 1 after the preamble" ($payload.StartsWith('#!/bin/bash'))
  if ($gitBash -and (Test-Path $gitBash)) {
    $payload | & $gitBash -n 2>&1 | Out-Null
    Assert-That "$($file.Name) passes bash -n with the preamble" ($LASTEXITCODE -eq 0)
  }
}
$windowsText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'scripts\bootstrap-windows.ps1'))
$usedWindows = [regex]::Matches($windowsText, '\$Demo[A-Za-z]+') | ForEach-Object { $_.Value.TrimStart('$') } | Sort-Object -Unique
Assert-That 'bootstrap-windows.ps1 uses only supplied variables' (@($usedWindows | Where-Object { $_ -notin $psKeys }).Count -eq 0) (($usedWindows | Where-Object { $_ -notin $psKeys }) -join ', ')
Assert-That 'bootstrap-windows.ps1 has no tenant-specific values' ($windowsText -notmatch 'securitylabworks|a3c8|f9931042|4e272b78|10\.87\.[12]\.[04]\b')
$windowsErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput((New-Preamble (Get-GuestVariables 'powershell') 'powershell') + $windowsText, [ref]$null, [ref]$windowsErrors)
Assert-That 'bootstrap-windows.ps1 parses with the preamble' ($windowsErrors.Count -eq 0)

Write-Host 'Source archive hygiene'
$root = Join-Path ([IO.Path]::GetTempPath()) "idpdemo-archive-$([guid]::NewGuid().ToString('N'))"
try {
  foreach ($dir in 'samples\.local\tls','samples\apps\a\bin','samples\tests\node_modules\x','samples\tests\results','infra\.state\env1') { New-Item -ItemType Directory -Force (Join-Path $root $dir) | Out-Null }
  foreach ($file in 'samples\keep.txt','infra\keep.ps1','infra\environment.sample.json','samples\.local\tls\private.key','samples\apps\a\bin\a.dll',
    'samples\tests\node_modules\x\i.js','samples\tests\results\r.json','infra\.state\env1\parameters.json','infra\.state\env1\operator_ed25519','infra\environment.json','infra\environment.contoso.json') {
    [IO.File]::WriteAllText((Join-Path $root $file), 'x')
  }
  $archive = Join-Path $root 'out.tgz'
  New-SourceArchive $root $archive
  $entries = @(& tar -tzf $archive)
  Assert-That 'Archive keeps source files' (($entries -match 'samples/keep.txt') -and ($entries -match 'infra/keep.ps1'))
  Assert-That 'Archive excludes state, credentials, local config and build output' (@($entries | Where-Object { $_ -match '\.state|\.local|environment(\.|[^/]*)json|bin/|node_modules|results' }).Count -eq 0)
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
$realArchive = Join-Path ([IO.Path]::GetTempPath()) "idpdemo-real-$([guid]::NewGuid().ToString('N')).tgz"
try {
  New-SourceArchive $workspace $realArchive
  Assert-That 'The real workspace archive passes the leak check' $true
} catch { Assert-That 'The real workspace archive passes the leak check' $false $_.Exception.Message }
finally { Remove-Item -LiteralPath $realArchive -Force -ErrorAction SilentlyContinue }

Write-Host 'Configuration validation (offline; each case must report exactly its own problem)'
$base = [ordered]@{
  tenantId = '11111111-2222-3333-4444-555555555555'; subscriptionId = '66666666-7777-8888-9999-000000000000'
  location = 'westus3'; resourceGroupName = 'rg-test'; domain = 'demo.contoso.com'
  tls = @{ acceptLetsEncryptTerms = $true }; network = @{ allowedHttpsSources = @('203.0.113.7/32') }
}
$allFragments = @('placeholder','Microsoft-owned name','acceptLetsEncryptTerms must be true','allowedHttpsSources is required','not an IPv4 address or CIDR','dataServiceAllowedCidrs must list',
  'azureDnsZone.zoneName and resourceGroup are required','subdomain of dns.azureDnsZone.zoneName','namePrefix must be','private /16','unsupported characters','tenantId must be your tenant GUID',
  'dns.waitMinutes must be','operatorObjectId is required when operatorPrincipalType')
function Test-Case([string]$Name, [scriptblock]$Mutate, [string]$Expected) {
  $config = $base | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable
  & $Mutate $config
  $path = Join-Path ([IO.Path]::GetTempPath()) "idpdemo-config-$([guid]::NewGuid().ToString('N')).json"
  try {
    [IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 6))
    $output = ((& pwsh -NoProfile -File $script -ConfigPath $path -Stage Preflight 2>&1 | Out-String) -replace '\s+\|\s+', ' ') -replace '\s+', ' '
    $reported = @($allFragments | Where-Object { $output -match [regex]::Escape($_) })
    Assert-That $Name ($reported.Count -eq 1 -and $reported[0] -eq $Expected) "(reported: $($reported -join ' | ')) $output"
  } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}
Test-Case 'Placeholder domain is rejected' { param($c) $c.domain = 'demo.example.com' } 'placeholder'
Test-Case 'Microsoft-owned domain is rejected' { param($c) $c.domain = 'MngEnv123.onmicrosoft.com' } 'Microsoft-owned name'
Test-Case 'Let''s Encrypt terms must be accepted' { param($c) $c.tls.acceptLetsEncryptTerms = $false } 'acceptLetsEncryptTerms must be true'
Test-Case 'HTTPS sources are mandatory' { param($c) $c.network.allowedHttpsSources = @() } 'allowedHttpsSources is required'
Test-Case 'Invalid CIDR is rejected' { param($c) $c.network.allowedHttpsSources = @('300.1.1.1') } 'not an IPv4 address or CIDR'
Test-Case 'Deny without allowed IPs is rejected' { param($c) $c.network.dataServiceDefaultAction = 'Deny' } 'dataServiceAllowedCidrs must list'
Test-Case 'Azure DNS mode needs a zone' { param($c) $c.dns = @{ mode = 'azureDns' } } 'azureDnsZone.zoneName and resourceGroup are required'
Test-Case 'Domain must sit under the Azure DNS zone' { param($c) $c.dns = @{ mode = 'azureDns'; azureDnsZone = @{ zoneName = 'fabrikam.com'; resourceGroup = 'rg-dns' } } } 'subdomain of dns.azureDnsZone.zoneName'
Test-Case 'Over-long name prefix is rejected' { param($c) $c.namePrefix = 'identitymigrationdemo' } 'namePrefix must be'
Test-Case 'Public network prefix is rejected' { param($c) $c.network.vnetPrefix = '8.8' } 'private /16'
Test-Case 'Impossible private octet is rejected' { param($c) $c.network.vnetPrefix = '10.999' } 'private /16'
Test-Case 'Zero wait time is rejected instead of defaulted' { param($c) $c.dns = @{ waitMinutes = 0 } } 'dns.waitMinutes must be'
Test-Case 'Service-principal operator needs an object ID' { param($c) $c.operatorPrincipalType = 'ServicePrincipal' } 'operatorObjectId is required when operatorPrincipalType'
Test-Case 'Tag values are sanitized' { param($c) $c.tags = @{ owner = 'a & b' } } 'unsupported characters'
Test-Case 'Tenant ID must be a GUID' { param($c) $c.tenantId = 'contoso.onmicrosoft.com' } 'tenantId must be your tenant GUID'

if ($failures -gt 0) { Write-Host "`n$failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll deployment-package checks passed." -ForegroundColor Green
