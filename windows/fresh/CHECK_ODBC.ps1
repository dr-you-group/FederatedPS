#Requires -Version 5.1
[CmdletBinding()]
param([string]$BundleRoot=$PSScriptRoot,[string]$InstallRoot='C:\FederatedPS',
    [string]$RHome='C:\Program Files\R\R-4.6.1',[string]$JavaHome='',
    [string]$ConfigDirectory='',[int[]]$SiteIds=@(),
    [ValidateSet('both','native','production')][string]$Mode='both',
    [ValidateRange(1,300)][int]$LoginTimeoutSeconds=30,
    [ValidateRange(15,900)][int]$TimeoutSeconds=180,[string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$project=Join-Path $BundleRoot 'FederatedPS'
$options=@{Project=$project;InstallRoot=$InstallRoot;RHome=$RHome;JavaHome=$JavaHome;
    ConfigDirectory=$ConfigDirectory;Mode=$Mode;LoginTimeoutSeconds=$LoginTimeoutSeconds;
    TimeoutSeconds=$TimeoutSeconds;OutputDirectory=$OutputDirectory}
if($PSBoundParameters.ContainsKey('SiteIds')){$options.SiteIds=$SiteIds}
& (Join-Path $project 'windows\Test-OdbcConnection.ps1') @options
