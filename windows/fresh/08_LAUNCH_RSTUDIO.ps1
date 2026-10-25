#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'FederatedPS\windows\Launch-RStudio.ps1') -InstallRoot $InstallRoot
