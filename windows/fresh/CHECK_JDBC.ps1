#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BundleRoot = 'C:\FP',
    [string]$InstallRoot = 'C:\FederatedPS',
    [string]$RHome = 'C:\Program Files\R\R-4.6.1',
    [string]$JavaHome = '',
    [string]$ConfigDirectory = '',
    [ValidateRange(1,300)][int]$SmallQueryTimeoutSeconds = 60,
    [ValidateRange(15,900)][int]$TimeoutSeconds = 180,
    [ValidateSet('full','adaptive')][string]$ResponseBuffering = 'full',
    [ValidateSet('care-site-id','care-site-text','synthetic-text')][string]$ProbeMode = 'care-site-id',
    [int[]]$SiteIds,
    [string]$OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
$project = Join-Path $BundleRoot 'FederatedPS'
# Standalone diagnostic ZIP keeps tools alongside this wrapper. A fresh bundle
# may instead use the source already present inside its FederatedPS checkout.
$tool = Join-Path $PSScriptRoot 'tools\Test-JavaConnection.ps1'
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
    $tool = Join-Path $project 'windows\Test-JavaConnection.ps1'
}
if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
    throw 'Diagnostic tool missing. Extract the complete diagnostic ZIP before running CHECK_JDBC.ps1.'
}
$options = @{
    Project=$project; InstallRoot=$InstallRoot; RHome=$RHome; JavaHome=$JavaHome
    ConfigDirectory=$ConfigDirectory; SmallQueryTimeoutSeconds=$SmallQueryTimeoutSeconds
    TimeoutSeconds=$TimeoutSeconds; ResponseBuffering=$ResponseBuffering; ProbeMode=$ProbeMode
    OutputDirectory=$OutputDirectory
}
if ($PSBoundParameters.ContainsKey('SiteIds')) { $options.SiteIds=$SiteIds }
& $tool @options
