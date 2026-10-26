#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS')
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Assert-FreshWindows
Assert-FreshNoR
# Package updates operate on the current source without a bundle hash gate.
& (Join-Path $PSScriptRoot 'FederatedPS\windows\Update-FederatedPs.ps1') -InstallRoot $InstallRoot `
    -JavaHome (Get-FreshJavaHome)
Write-Host 'PASS: installed FederatedPs includes JDBC probe and SQL preparation fixes. Run RUN.ps1.' -ForegroundColor Green
