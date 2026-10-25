#Requires -Version 5.1
<# Update only the pure-R FederatedPs package; reuse Cyclops and all dependencies. #>
[CmdletBinding()]
param([string]$InstallRoot='C:\FederatedPS', [string]$RHome='C:\Program Files\R\R-4.6.1', [string]$JavaHome='')
. (Join-Path $PSScriptRoot 'Common.ps1')
$sessionId=(Get-Process -Id $PID).SessionId
$busy=@(Get-Process -Name R,Rgui,Rterm,Rscript,rsession -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })
if ($busy.Count) {
    $busy | Select-Object Id,ProcessName | Format-Table -AutoSize | Out-Host
    throw 'R processes remain in this Windows session (an idle RStudio session also counts). Save and close R/RStudio; use Stop-FederatedRun.ps1 -RunDirectory for a failed run. No processes were stopped.'
}
$runtime=Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
$project=Get-FederatedProject
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'update-package.R'),$project,$runtime.Library)
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'verify.R'),$project)
Write-Host 'PASS: FederatedPs updated. Cyclops, JDBC and other dependencies were not rebuilt.'
