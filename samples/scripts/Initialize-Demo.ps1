#Requires -Version 7.2
[CmdletBinding()]
param([string]$EnvironmentFile = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (Test-Path '.local\demo.env') { throw 'Already initialized. Preserve .local and database volumes together; do not silently rotate credentials.' }
New-Item -ItemType Directory -Force '.local\tls' | Out-Null
$origins = @{}
Get-Content '.env.sample' | Where-Object { $_ -match '^([A-Z_]+)=(.*)$' } | ForEach-Object {
  $k,$v = $_ -split '=',2; $origins[$k] = $v
}
if ($EnvironmentFile) {
  Get-Content $EnvironmentFile | Where-Object { $_ -match '^([A-Z_]+)=(.*)$' } | ForEach-Object { $k,$v = $_ -split '=',2; $origins[$k] = $v }
}
foreach ($key in $origins.Keys) { [Environment]::SetEnvironmentVariable($key,$origins[$key],'Process') }
$rsa = [System.Security.Cryptography.RSA]::Create(3072)
$req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=Princeton Synthetic Demo CA',$rsa,[System.Security.Cryptography.HashAlgorithmName]::SHA256,[System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
$req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true,$false,0,$true))
$req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign,$true))
$ca = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddYears(2))
[IO.File]::WriteAllText("$root\.local\tls\ca.crt",$ca.ExportCertificatePem())
[IO.File]::WriteAllText("$root\.local\tls\ca.key",$rsa.ExportPkcs8PrivateKeyPem())
$names = @('gateway','idp-signing','idp-encryption','drupal','student')
foreach ($name in $names) {
  $key = [System.Security.Cryptography.RSA]::Create(3072)
  $leafReq = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$name Demo",$key,[System.Security.Cryptography.HashAlgorithmName]::SHA256,[System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
  $leafReq.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false,$false,0,$true))
  $leafReq.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(([System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature -bor [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment),$true))
  if ($name -eq 'gateway') {
    $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
    foreach($k in @('CAS_ORIGIN','IDP_ORIGIN','HR_ORIGIN','DRUPAL_ORIGIN','ALUMNI_ORIGIN','STUDENT_ORIGIN')) { $san.AddDnsName(([Uri]$origins[$k]).DnsSafeHost) }
    $leafReq.CertificateExtensions.Add($san.Build())
    $eku=[System.Security.Cryptography.OidCollection]::new(); [void]$eku.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
    $leafReq.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku,$false))
  }
  $serial = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(16)
  $leaf = $leafReq.Create($ca,[DateTimeOffset]::UtcNow.AddDays(-1),[DateTimeOffset]::UtcNow.AddYears(1),$serial)
  [IO.File]::WriteAllText("$root\.local\tls\$name.crt",$leaf.ExportCertificatePem())
  [IO.File]::WriteAllText("$root\.local\tls\$name.key",$key.ExportPkcs8PrivateKeyPem())
  $key.Dispose()
}
$rsa.Dispose()
node scripts\configure.mjs
if ($LASTEXITCODE -ne 0) { throw 'Configuration generation failed.' }
Write-Host 'Generated .local only. Protect its ACLs and trust .local\tls\ca.crt on demo browsers/Windows IIS. Never commit it.'
