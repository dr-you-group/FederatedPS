#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'FederatedPS\windows\Test-YUHS-Connection.ps1') -InstallRoot $InstallRoot
