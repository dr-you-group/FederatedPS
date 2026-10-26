#Requires -Version 5.1
[CmdletBinding()]
param([string]$BundleRoot='C:\FP', [string]$JavaHome='',
      [ValidateRange(5,120)][int]$TimeoutSeconds=30,
      [string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$tool=Join-Path $PSScriptRoot 'tools\Test-JvmLifecycle.ps1'
if(-not(Test-Path -LiteralPath $tool -PathType Leaf)) {
    $tool=Join-Path $BundleRoot 'FederatedPS\windows\Test-JvmLifecycle.ps1'
}
if(-not(Test-Path -LiteralPath $tool -PathType Leaf)) {
    throw 'JVM baseline tool missing. Extract the complete diagnostic ZIP before running CHECK_JVM.ps1.'
}
& $tool -BundleRoot $BundleRoot -JavaHome $JavaHome -TimeoutSeconds $TimeoutSeconds -OutputDirectory $OutputDirectory
