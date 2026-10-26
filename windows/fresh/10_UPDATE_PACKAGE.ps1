#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS')
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Assert-FreshWindows
Assert-FreshNoR
Test-FreshManifest $PSScriptRoot
& (Join-Path $PSScriptRoot 'FederatedPS\windows\Update-FederatedPs.ps1') -InstallRoot $InstallRoot `
    -JavaHome (Get-FreshJavaHome)
Write-Host 'PASS: installed FederatedPs now matches the JDBC probe patch. Run RUN.ps1.' -ForegroundColor Green
