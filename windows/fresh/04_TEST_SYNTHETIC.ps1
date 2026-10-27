#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS')
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot '05_RUN_YUHS.ps1') -InstallRoot $InstallRoot -Test $true `
    -Study ppi -Scenario default -Methods local-only,pooled `
    -PatientLimits @{1=200;2=100;3=300} -ExtractionWorkers 1 -StatusSeconds 10
