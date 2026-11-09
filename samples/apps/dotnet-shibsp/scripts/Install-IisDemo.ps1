#Requires -RunAsAdministrator
#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$GeneratedDirectory,
  [Parameter(Mandatory=$true)][string]$SiteCertificateThumbprint,
  [string]$SitePath='C:\inetpub\student-demo',
  [string]$SpRoot='C:\opt\shibboleth-sp',
  [string]$SpServiceName='',
  [string]$HostName='student.demo.test'
)
$ErrorActionPreference='Stop'
Import-Module WebAdministration
$source=Split-Path $PSScriptRoot -Parent
if (!(Test-Path "$source\bin\StudentRecords.dll")) { throw 'Build with Windows MSBuild first. This setup script does not restore packages.' }
if (!(Test-Path "$SpRoot\sbin64\shibd.exe")) { throw 'Install verified x64 Shibboleth SP MSI first, including its native IIS module.' }
if (!(Get-WebGlobalModule | Where-Object { $_.Name -match 'Shib' })) { throw 'Shibboleth native IIS module missing. Repair/register it using the SP installer.' }
if (Get-Website | Where-Object {$_.Id -eq 2 -and $_.Name -ne 'StudentDemo'}) { throw 'Site ID2 is occupied. Match a dedicated site ID in shibboleth2.xml before continuing.' }
New-Item -ItemType Directory -Force $SitePath | Out-Null
foreach($item in @('bin','Views','App_Data','Global.asax','Web.config')) { Copy-Item "$source\$item" $SitePath -Recurse -Force }
[xml]$config=Get-Content "$SitePath\Web.config"
$config.configuration.appSettings.SetAttribute('file','Web.Demo.config')
$config.Save("$SitePath\Web.config")
Copy-Item "$GeneratedDirectory\windows\Web.Demo.config" "$SitePath\Web.Demo.config" -Force
Copy-Item "$GeneratedDirectory\windows\shibboleth2.xml" "$SpRoot\etc\shibboleth\shibboleth2.xml" -Force
Copy-Item "$source\shibboleth\attribute-map.xml" "$SpRoot\etc\shibboleth\attribute-map.xml" -Force
[xml]$demoConfig = Get-Content -LiteralPath "$GeneratedDirectory\windows\Web.Demo.config"
$demoScope = [string]($demoConfig.appSettings.add | Where-Object { $_.key -eq 'DemoScope' }).value
$idpEntityId = [string]($demoConfig.appSettings.add | Where-Object { $_.key -eq 'IdpEntityId' }).value
if (!$demoScope -or !$idpEntityId) { throw 'Generated DemoScope and IdpEntityId settings are required.' }
[xml]$idpMetadata = Get-Content -LiteralPath "$GeneratedDirectory\idp-metadata.xml"
$namespaces = New-Object System.Xml.XmlNamespaceManager($idpMetadata.NameTable)
$namespaces.AddNamespace('md','urn:oasis:names:tc:SAML:2.0:metadata')
$namespaces.AddNamespace('shibmd','urn:mace:shibboleth:metadata:1.0')
$descriptor = $idpMetadata.SelectSingleNode('/md:EntityDescriptor/md:IDPSSODescriptor',$namespaces)
if (!$descriptor -or $idpMetadata.DocumentElement.GetAttribute('entityID') -ne $idpEntityId) { throw 'Generated IdP metadata does not match the configured issuer.' }
$scopes = $descriptor.SelectNodes('md:Extensions/shibmd:Scope',$namespaces)
if ($scopes.Count -eq 0) {
  if ($idpMetadata.GetElementsByTagName('Signature','http://www.w3.org/2000/09/xmldsig#').Count -gt 0) { throw 'Cannot migrate signed metadata; obtain corrected signed metadata from its issuer.' }
  $extensions = $descriptor.SelectSingleNode('md:Extensions',$namespaces)
  if (!$extensions) {
    $extensions = $idpMetadata.CreateElement('Extensions','urn:oasis:names:tc:SAML:2.0:metadata')
    [void]$descriptor.PrependChild($extensions)
  }
  $scope = $idpMetadata.CreateElement('shibmd','Scope','urn:mace:shibboleth:metadata:1.0')
  $scope.SetAttribute('regexp','false')
  $scope.InnerText = $demoScope
  [void]$extensions.AppendChild($scope)
} elseif ($scopes.Count -ne 1 -or $scopes[0].InnerText -ne $demoScope -or $scopes[0].GetAttribute('regexp') -ne 'false') {
  throw 'IdP metadata must authorize exactly the configured literal demo scope.'
}
$idpMetadata.Save("$SpRoot\etc\shibboleth\idp-metadata.xml")
foreach($file in @('student.key','student.crt')) { Copy-Item "$GeneratedDirectory\tls\$file" "$SpRoot\etc\shibboleth\$file" -Force }
$services=@(Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^shibd(?:_.*)?$' })
if ($SpServiceName) { $services=@($services | Where-Object { $_.Name -eq $SpServiceName }) }
if ($services.Count -ne 1) { throw 'Expected one installed shibd service (often shibd_Default). Supply -SpServiceName to disambiguate.' }
$service=$services[0]
$keyAcl=New-Object System.Security.AccessControl.FileSecurity
$keyAcl.SetAccessRuleProtection($true,$false)
$admins=New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$system=New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
foreach($identity in @($admins,$system)) {
  $rule=New-Object System.Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')
  $keyAcl.AddAccessRule($rule)
}
$serviceIdentity = switch ($service.StartName) {
  'LocalSystem' { 'NT AUTHORITY\SYSTEM' }
  'NT AUTHORITY\NetworkService' { 'NT AUTHORITY\NETWORK SERVICE' }
  'NT AUTHORITY\LocalService' { 'NT AUTHORITY\LOCAL SERVICE' }
  default { $service.StartName }
}
$keyAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($serviceIdentity,'Read','Allow')))
Set-Acl -Path "$SpRoot\etc\shibboleth\student.key" -AclObject $keyAcl
Import-Certificate -FilePath "$GeneratedDirectory\tls\ca.crt" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
if (!(Test-Path IIS:\AppPools\StudentDemo)) { New-WebAppPool StudentDemo | Out-Null }
Set-ItemProperty IIS:\AppPools\StudentDemo managedRuntimeVersion v4.0
Set-ItemProperty IIS:\AppPools\StudentDemo managedPipelineMode Integrated
Set-ItemProperty IIS:\AppPools\StudentDemo enable32BitAppOnWin64 $false
$sharedRuntime = Join-Path $env:ProgramFiles 'Shibboleth\SP\lib'
if (!(Test-Path -LiteralPath (Join-Path $sharedRuntime 'shibsp3_6.dll'))) { throw 'Shibboleth 3.6 shared x64 runtime is missing.' }
$workerPath = $sharedRuntime + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
$environmentFilter = "system.applicationHost/applicationPools/add[@name='StudentDemo']/environmentVariables"
if (Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$environmentFilter/add[@name='PATH']" -Name value) {
  Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$environmentFilter/add[@name='PATH']" -Name value -Value $workerPath
} else {
  Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $environmentFilter -Name '.' -Value @{name='PATH';value=$workerPath}
}
if (!(Test-Path IIS:\Sites\StudentDemo)) {
  New-Website -Name StudentDemo -Id 2 -PhysicalPath $SitePath -ApplicationPool StudentDemo -IPAddress '*' -Port 443 -HostHeader $HostName -Ssl | Out-Null
}
Set-WebBinding -Name StudentDemo -BindingInformation "*:443:$HostName" -PropertyName sslFlags -Value 1
(Get-WebBinding -Name StudentDemo -Protocol https).AddSslCertificate($SiteCertificateThumbprint,'My')
Set-WebConfigurationProperty -PSPath IIS:\ -Location StudentDemo -Filter system.webServer/security/authentication/anonymousAuthentication -Name enabled -Value $true
& icacls.exe $SitePath /grant 'IIS AppPool\StudentDemo:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Application ACL assignment failed.' }
& "$SpRoot\sbin64\shibd.exe" -check -config "$SpRoot\etc\shibboleth\shibboleth2.xml" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Shibboleth configuration validation failed. IIS has not been declared ready.' }
Restart-Service -Name $service.Name
if ((Get-WebAppPoolState StudentDemo).Value -eq 'Stopped') {
  Start-WebAppPool StudentDemo
} else {
  Restart-WebAppPool StudentDemo
}
Write-Host 'Configured. Verify native module uses server variables (not headers), HTTPS metadata, login and spoof resistance before exposure.'
