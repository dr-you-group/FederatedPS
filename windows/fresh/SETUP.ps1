#Requires -Version 5.1
<# Fresh offline installation. Never opens a real database. #>
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS',[switch]$SkipRStudio)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot '00_VERIFY.ps1')
& (Join-Path $PSScriptRoot '01_INSTALL_RUNTIME.ps1') -SkipRStudio:$SkipRStudio
& (Join-Path $PSScriptRoot '02_INSTALL_PACKAGES.ps1') -InstallRoot $InstallRoot
& (Join-Path $PSScriptRoot '03_VERIFY_RUNTIME.ps1') -InstallRoot $InstallRoot
& (Join-Path $PSScriptRoot '04_TEST_SYNTHETIC.ps1') -InstallRoot $InstallRoot
Write-Host 'SETUP completed. Configure HIWARE and 06_CONFIGURE_DB.ps1, then run RUN.ps1.' -ForegroundColor Green
