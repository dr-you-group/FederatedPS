#Requires -Version 5.1
<# Run an R script from the repository root using the offline block CCD library. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Script,
      [string[]]$ScriptArguments = @(),
      [string]$InstallRoot = 'C:\FederatedPS',
      [string]$RHome = 'C:\Program Files\R\R-4.6.1', [string]$JavaHome = '')
. (Join-Path $PSScriptRoot 'Common.ps1')
$runtime = Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
$project = Get-FederatedProject
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'verify.R'), $project)
Push-Location -LiteralPath $project
try {
    $scriptPath = (Resolve-Path -LiteralPath $Script).Path
    Invoke-FederatedR $runtime.Rscript (@($scriptPath) + $ScriptArguments)
} finally { Pop-Location }
