$ErrorActionPreference = 'Stop'
trap {
  if (Test-Path 'C:\idpdemo') {
    [IO.File]::WriteAllText('C:\idpdemo\bootstrap-error.log', ($_ | Format-List * -Force | Out-String))
  }
  Write-Output "DEMO_STAGE_FAILED: Windows bootstrap at $stage. Inspect protected C:\idpdemo logs; do not expose credentials."
  exit 1
}
$stage = 'directory protection'
foreach ($required in @('DemoDomain','DemoLinuxIp','DemoArtifactTransfer')) {
  if (-not (Get-Variable -Name $required -ValueOnly -ErrorAction SilentlyContinue)) { throw "Deployment variable $required was not supplied." }
}
$requiredByMode = if ($DemoArtifactTransfer -eq 'storage') { 'DemoStorage' } else { 'DemoHandoffToken' }
if (-not (Get-Variable -Name $requiredByMode -ValueOnly -ErrorAction SilentlyContinue)) { throw "Deployment variable $requiredByMode was not supplied." }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = 'C:\idpdemo'
New-Item -ItemType Directory -Force $root | Out-Null
& icacls.exe $root /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'BUILTIN\Administrators:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect Windows bootstrap directory.' }
$stage = 'IIS feature installation'
Install-WindowsFeature Web-Server,Web-Asp-Net45,Web-Net-Ext45,Web-ISAPI-Ext,Web-ISAPI-Filter,Web-Mgmt-Console | Out-Null
$stage = 'host name mapping'
$hosts = "$env:windir\System32\drivers\etc\hosts"
if (!(Select-String -LiteralPath $hosts -SimpleMatch '# idpdemo-hosts' -Quiet)) {
  $linuxNames = (@('cas','idp','hr','drupal','alumni') | ForEach-Object { "$_.$DemoDomain" }) -join ' '
  Add-Content -LiteralPath $hosts -Value "`r`n$DemoLinuxIp $linuxNames # idpdemo-hosts`r`n127.0.0.1 student.$DemoDomain # idpdemo-hosts"
}
$stage = 'handoff download'
if ($DemoArtifactTransfer -ne 'storage') {
  # Direct mode: the Linux VM serves the package over verified TLS on the private network, under a one-time secret path.
  $handoffBase = "https://idp.${DemoDomain}:8443/$DemoHandoffToken"
  Invoke-WebRequest -UseBasicParsing -Uri "$handoffBase/windows-package.tgz" -OutFile "$root\windows-package.tgz"
  Invoke-WebRequest -UseBasicParsing -Uri "$handoffBase/student-bin.zip" -OutFile "$root\student-bin.zip"
}
if ($DemoArtifactTransfer -eq 'storage') {
$token = (Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F').access_token
Invoke-WebRequest -UseBasicParsing -Headers @{Authorization="Bearer $token";'x-ms-version'='2023-11-03'} `
  -Uri "https://$DemoStorage.blob.core.windows.net/windows-handoff/windows-package.tgz" -OutFile "$root\windows-package.tgz"
$token = $null
}
& tar -xzf "$root\windows-package.tgz" -C $root
if ($LASTEXITCODE -ne 0) { throw 'Cannot extract Windows handoff.' }
if ($DemoArtifactTransfer -eq 'storage') {
$token = (Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F').access_token
Invoke-WebRequest -UseBasicParsing -Headers @{Authorization="Bearer $token";'x-ms-version'='2023-11-03'} `
  -Uri "https://$DemoStorage.blob.core.windows.net/windows-handoff/student-bin.zip" -OutFile "$root\student-bin.zip"
$token = $null
}
Expand-Archive -LiteralPath "$root\student-bin.zip" -DestinationPath "$root\app\bin" -Force
$stage = 'native SP download and installation'
$msi = "$root\shibboleth-sp-3.6.0.0-win64.msi"
$installedMarker = "$root\sp-installed.marker"
if (-not ((Test-Path -LiteralPath $installedMarker) -and (Test-Path -LiteralPath 'C:\opt\shibboleth-sp\sbin64\shibd.exe'))) {
Invoke-WebRequest -UseBasicParsing -Uri 'https://shibboleth.net/downloads/service-provider/latest/win64/shibboleth-sp-3.6.0.0-win64.msi' -OutFile $msi
if ((Get-FileHash $msi -Algorithm SHA256).Hash -ne 'fbf140f6be7a5851abb92956545ce1f9a7e1626ba4ab1c684b3cd3cf591affb4') { throw 'Native SP MSI checksum mismatch.' }
$install = Start-Process msiexec.exe -ArgumentList @('/i',$msi,'/qn','/norestart','ADDLOCAL=ALL','INSTALL_IIS7_PLUGIN=TRUE','/l*v',"$root\sp-install.log") -Wait -PassThru
if ($install.ExitCode -notin @(0,3010)) { throw "SP installation failed: $($install.ExitCode)" }
[IO.File]::WriteAllText($installedMarker, "exit=$($install.ExitCode)")
if ($install.ExitCode -eq 3010) {
  # Installed, but Windows wants a restart (shared runtime). The orchestrator restarts the VM and runs this stage again,
  # which skips this installation because the marker and shibd.exe now exist.
  Write-Output 'DEMO_RESTART_REQUIRED: the Shibboleth SP installed and Windows must restart before configuration continues.'
  Write-Output 'DEMO_STAGE_OK: restart requested; run this stage again after the restart.'
  exit 0
}
}
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
Import-Module WebAdministration
if (!(Get-WebGlobalModule | Where-Object { $_.Name -eq 'ShibNative' })) {
  $nativeModule = 'C:\opt\shibboleth-sp\lib64\shibboleth\iis7_shib.dll'
  if (!(Test-Path -LiteralPath $nativeModule)) { throw 'Verified SP installer did not install its x64 IIS module.' }
  & "$env:windir\System32\inetsrv\appcmd.exe" install module /name:ShibNative "/image:$nativeModule" /precondition:bitness64
  if ($LASTEXITCODE -ne 0) { throw 'Native IIS module registration failed.' }
}
$stage = 'transport certificate import'
$certificate = Import-PfxCertificate -FilePath "$root\transport.pfx" -CertStoreLocation Cert:\LocalMachine\My
Remove-Item -LiteralPath "$root\transport.pfx" -Force
if (!(Test-Path "$root\app\bin\StudentRecords.dll")) { throw 'Compiled StudentRecords.dll is missing from handoff. Upload the validated Windows build before retrying.' }
$stage = 'Student IIS and native SP configuration'
& "$root\app\scripts\Install-IisDemo.ps1" -GeneratedDirectory "$root\generated" `
  -SiteCertificateThumbprint $certificate.Thumbprint -HostName "student.$DemoDomain"
if ((Invoke-WebRequest -UseBasicParsing -Uri "https://student.$DemoDomain/readyz").StatusCode -ne 200) { throw 'Windows application readiness check failed.' }
Remove-Item -LiteralPath "$root\windows-package.tgz" -Force
Write-Output 'DEMO_STAGE_OK: Windows IIS/SP configured and ready; browser SAML/role/logout acceptance still required.'
