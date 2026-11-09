#Requires -Version 7.2
[CmdletBinding()]
param([string]$EnvironmentFile='')
$ErrorActionPreference='Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
docker info --format '{{.OSType}}'
if ($LASTEXITCODE -ne 0) { throw 'Linux Docker engine unavailable. Start it separately; this script does not install or start Docker.' }
if (!(Test-Path '.local\demo.env')) { & "$PSScriptRoot\Initialize-Demo.ps1" -EnvironmentFile $EnvironmentFile }
docker compose --env-file .local\demo.env up --build -d
if ($LASTEXITCODE -ne 0) { throw 'Compose start failed; inspect logs. No readiness claim is made.' }
docker compose --env-file .local\demo.env ps
Write-Host 'Services launched. Check healthy state and run separately approved validation; Windows IIS setup is separate.'
