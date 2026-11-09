#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
Switches the Student site between the demo Shibboleth IdP and Microsoft Entra ID (SAML) without rebuilding.
Run after Install-IisDemo.ps1. The first switch to Entra backs up the legacy configuration; -Mode shibboleth restores it.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('entra','shibboleth')][string]$Mode,
  [string]$TenantId,
  [string]$AppId,
  [string]$TenantDomain,
  [Parameter(Mandatory=$true)][string]$HostName,
  [string]$SitePath='C:\inetpub\student-demo',
  [string]$SpRoot='C:\opt\shibboleth-sp',
  [string]$BackupPath='C:\idpdemo\backup-legacy-auth',
  [string]$SourcePath='C:\idpdemo\app'
)
$ErrorActionPreference='Stop'
Import-Module WebAdministration
$etc="$SpRoot\etc\shibboleth"
$demoConfig="$SitePath\Web.Demo.config"
$guid='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$service=@(Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^shibd(?:_.*)?$' })
if ($service.Count -ne 1) { throw 'Expected one shibd service.' }

if ($Mode -eq 'entra') {
  if ($TenantId -notmatch $guid -or $AppId -notmatch $guid) { throw 'TenantId and AppId must be GUIDs.' }
  if ($TenantDomain -notmatch '^[a-z0-9.-]+\.[a-z]+$') { throw 'TenantDomain must be a DNS name.' }
  if (!(Test-Path "$BackupPath\shibboleth2.xml")) {
    New-Item -ItemType Directory -Force $BackupPath | Out-Null
    foreach($f in @("$etc\shibboleth2.xml","$etc\attribute-map.xml",$demoConfig)) { Copy-Item $f $BackupPath -Force }
  }
  $origin="https://$HostName"
  $xml=(Get-Content "$SourcePath\shibboleth\shibboleth2.entra.xml.template" -Raw).
    Replace('@@STUDENT_HOST@@',$HostName).Replace('@@STUDENT_ORIGIN@@',$origin).Replace('@@TENANT_ID@@',$TenantId).Replace('@@APP_ID@@',$AppId)
  if ($xml -match '@@') { throw 'Unreplaced placeholder in rendered shibboleth2.xml.' }
  [IO.File]::WriteAllText("$etc\shibboleth2.xml",$xml,(New-Object Text.UTF8Encoding($false)))
  Copy-Item "$SourcePath\shibboleth\attribute-map.entra.xml" "$etc\attribute-map.xml" -Force
  [xml]$settings=Get-Content $demoConfig
  foreach($pair in @(@('IdpEntityId',"https://sts.windows.net/$TenantId/"),@('AuthMode','entra'),@('TenantDomain',$TenantDomain))) {
    $node=$settings.appSettings.add | Where-Object { $_.key -eq $pair[0] }
    if ($node) { $node.SetAttribute('value',$pair[1]) }
    else { $n=$settings.CreateElement('add'); $n.SetAttribute('key',$pair[0]); $n.SetAttribute('value',$pair[1]); [void]$settings.appSettings.AppendChild($n) }
  }
  $settings.Save($demoConfig)
} else {
  if (!(Test-Path "$BackupPath\shibboleth2.xml")) { throw 'No legacy backup found; nothing to restore.' }
  Copy-Item "$BackupPath\shibboleth2.xml","$BackupPath\attribute-map.xml" $etc -Force
  Copy-Item "$BackupPath\Web.Demo.config" $demoConfig -Force
}
& "$SpRoot\sbin64\shibd.exe" -check -config "$etc\shibboleth2.xml" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'shibd configuration validation failed; IIS not restarted.' }
Restart-Service -Name $service[0].Name
Restart-WebAppPool StudentDemo
Write-Host "Student site is now in $Mode mode."
