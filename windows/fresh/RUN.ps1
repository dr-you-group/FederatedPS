#Requires -Version 5.1
<# Real-YUHS smoke run. ODBC checks must exit normally before analysis starts. #>
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS',
    [ValidateSet('jdbc','odbc')][string]$DbBackend='odbc',
    [hashtable]$PatientLimits=@{1=2;2=2;3=2},
    [switch]$UpdatePackage)
$ErrorActionPreference='Stop'
if($UpdatePackage){ & (Join-Path $PSScriptRoot '10_UPDATE_PACKAGE.ps1') -InstallRoot $InstallRoot -DbBackend $DbBackend }
if($DbBackend -eq 'odbc'){
    & (Join-Path $PSScriptRoot 'CHECK_ODBC.ps1') -BundleRoot $PSScriptRoot -InstallRoot $InstallRoot
}
& (Join-Path $PSScriptRoot '05_RUN_YUHS.ps1') -InstallRoot $InstallRoot -Test $false `
    -DbBackend $DbBackend -Study ppi -Scenario default `
    -Methods local-only,pooled `
    -PatientLimits $PatientLimits `
    -ExtractionWorkers 1 `
    -StatusSeconds 10
