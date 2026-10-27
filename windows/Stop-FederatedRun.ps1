#Requires -Version 5.1
<# Explicitly stop only this run's R processes in the current Windows session. #>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param([Parameter(Mandatory=$true)][string]$RunDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RunDiagnostics.Common.ps1')
if ($env:OS -ne 'Windows_NT') { throw 'Run this command on the Windows analysis server.' }
$context=Get-RunDiagnosticContext $RunDirectory
$processes=@(Get-RunDiagnosticProcesses $context)
if (-not $processes.Count) {
    Write-Host 'No matching R workers found in this Windows session. No process was stopped.'
    return
}
foreach ($p in @(Get-RunDiagnosticStopOrder $processes)) {
    $target="$($p.Role) $($p.Name) PID=$($p.ProcessId) created=$($p.CreationUtc.ToString('o'))"
    if ($PSCmdlet.ShouldProcess($target,"Stop worker for run $($context.RunId)")) {
        if (Stop-RunDiagnosticProcess $context $p) { Write-Host "Stopped: $target" }
        else { Write-Host "Skipped: $target (already exited or identity changed)." }
    }
}
Write-Host 'Existing logs/results were preserved. RStudio and unrelated R processes were not targeted.'
