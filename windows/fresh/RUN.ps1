#Requires -Version 5.1
<# Real-YUHS smoke run. Override per-site caps without editing this file. #>
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS',
    [hashtable]$PatientLimits=@{1=2;2=2;3=2},
    [switch]$UpdatePackage)
$ErrorActionPreference='Stop'
if($UpdatePackage){ & (Join-Path $PSScriptRoot '10_UPDATE_PACKAGE.ps1') -InstallRoot $InstallRoot }
& (Join-Path $PSScriptRoot '03_VERIFY_RUNTIME.ps1') -InstallRoot $InstallRoot
& (Join-Path $PSScriptRoot '05_RUN_YUHS.ps1') -InstallRoot $InstallRoot -Test $false `
    -Study ppi -Scenario default `
    -Methods local-only,pooled `
    -PatientLimits $PatientLimits `
    -ExtractionWorkers 1 `
    -StatusSeconds 10
