#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$NoProgress,
    [bool]$Test = $true,
    [string]$Study = 'ppi',
    [ValidateSet('default','studySpecific')][string]$Scenario = 'default',
    [string[]]$Sites = @('severance','gangnam','yongin'),
    [ValidateRange(1,1000000)][int]$BlockSize = 1,
    [ValidateRange(0.000001,1.0)][double]$Alpha = 1,
    [string]$InstallRoot = 'C:\FederatedPS',
    [string]$RHome = 'C:\Program Files\R\R-4.6.1', [string]$JavaHome = '',
    [string]$ConfigDirectory = '', [string]$WorkDirectory = '', [string]$ExchangeDirectory = '',
    [ValidateRange(1,2147483647)][int]$ExchangeTimeoutSeconds = 3600,
    [ValidateRange(1,2147483647)][int]$RunTimeoutSeconds = 86400
)
$ErrorActionPreference = 'Stop'
# Pass the effective default explicitly: PSBoundParameters omits defaults.
$forward = @{} + $PSBoundParameters
$forward['Test'] = $Test
& (Join-Path $PSScriptRoot 'Run-FederatedPS.ps1') -Mode Database -Dataset YUHS @forward
