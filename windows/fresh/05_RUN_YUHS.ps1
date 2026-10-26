#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('jdbc','odbc')][string]$DbBackend,
    [ValidateSet('local-only','pooled','federated')][string[]]$Methods=@('federated'),
    [ValidateRange(0,2147483647)][int]$PatientLimit=0,
    [hashtable]$PatientLimits=@{},
    [string]$CacheDirectory='', [switch]$RebuildData,
    [switch]$NoProgress,
    [ValidateRange(1,3600)][int]$StatusSeconds = 15,
    [ValidateRange(1,3)][int]$ExtractionWorkers = 1,
    [bool]$Test = $true,
    [string]$Study = 'ppi',
    [ValidateSet('default','studySpecific')][string]$Scenario = 'default',
    [string[]]$Sites = @(),
    [ValidateRange(1,1000000)][int]$BlockSize = 1,
    [ValidateRange(0.000001,1.0)][double]$Alpha = 1,
    [string]$InstallRoot = 'C:\FederatedPS',
    [string]$RHome = 'C:\Program Files\R\R-4.6.1', [string]$JavaHome = '',
    [string]$ConfigDirectory = '', [string]$WorkDirectory = '', [string]$ExchangeDirectory = '',
    [ValidateRange(1,2147483647)][int]$ExchangeTimeoutSeconds = 3600,
    [ValidateRange(1,2147483647)][int]$InitialTimeoutSeconds = 21600,
    [ValidateRange(1,86400)][int]$SmallQueryTimeoutSeconds = 60,
    [ValidateRange(30,86400)][int]$ConnectionCheckTimeoutSeconds = 180,
    [ValidateRange(1,2147483647)][int]$DbQueryTimeoutSeconds = 7200,
    [ValidateRange(1,2147483647)][int]$RunTimeoutSeconds = 86400
)
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'FederatedPS\windows\Run-YUHS.ps1') @PSBoundParameters
