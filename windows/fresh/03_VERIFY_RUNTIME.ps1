#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS',[ValidateRange(10,300)][int]$TimeoutSeconds=60)
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Invoke-FreshRenderCheck -Root $PSScriptRoot -InstallRoot $InstallRoot -TimeoutSeconds $TimeoutSeconds
