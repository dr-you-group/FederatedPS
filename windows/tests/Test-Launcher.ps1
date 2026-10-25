#Requires -Version 5.1
<# No R, database, Pester, or Internet needed. Run with Windows PowerShell 5.1. #>
[CmdletBinding()]
param([string]$Rscript = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
    if (-not $caught) { throw "Expected failure matching $Pattern" }
}
Assert-FederatedNames 'run01' @('site1','site2')
Assert-Throws { Assert-FederatedNames '../run' @('site1','site2') } 'alphanumeric'
Assert-Throws { Assert-FederatedNames 'run' @('site1','SITE1') } 'unique'
Assert-Throws { Assert-FederatedNames 'run' @('total','site2') } 'reserved'
Assert-Throws { Assert-FederatedNames 'run' @('aggregator','site2') } 'reserved'

$root = Join-Path ([IO.Path]::GetTempPath()) ('fedps launcher ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$child = Join-Path $root 'child with spaces.ps1'
@'
param([string]$Output, [string]$Value, [int]$Code = 0, [int]$Delay = 0)
[IO.File]::WriteAllText($Output, $Value)
if ($Delay) { Start-Sleep -Seconds $Delay }
exit $Code
'@ | Set-Content -LiteralPath $child -Encoding UTF8
$binaryName = if ($env:OS -ne 'Windows_NT') { 'pwsh' } elseif ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$executable = Join-Path $PSHOME $binaryName
$output = Join-Path $root 'received.txt'
$value = 'path with spaces and "quotes" and trailing\'

# The architecture executable must have the same PID as the R code. This test
# is automatic on the pinned Windows install and optional on other hosts.
if (-not $Rscript -and $env:OS -eq 'Windows_NT') {
    $installedR = 'C:\Program Files\R\R-4.6.1\bin\x64\Rscript.exe'
    if (Test-Path -LiteralPath $installedR -PathType Leaf) { $Rscript = $installedR }
}
if ($Rscript) {
    $rChild = Join-Path $root 'direct worker with spaces.R'
    @'
args <- commandArgs(trailingOnly = TRUE)
writeLines(c(as.character(Sys.getpid()), args[-1]), args[1])
Sys.sleep(2)
quit(save = "no", status = as.integer(args[3]))
'@ | Set-Content -LiteralPath $rChild -Encoding UTF8
    foreach($rCode in @(0,7)) {
        $rWorkers = @()
        $rOutput = Join-Path $root ("R identity $rCode.txt")
        try {
            $rWorkers += Start-FederatedRWorker -Runtime ([pscustomobject]@{Rscript=$Rscript}) `
                -Script $rChild -Arguments @($rOutput,$value,[string]$rCode,'--flag-after-script') `
                -WorkingDirectory $root -LogPrefix (Join-Path $root "R$rCode") -Role "R$rCode"
            $deadline = [DateTime]::UtcNow.AddSeconds(20)
            while (-not (Test-Path -LiteralPath $rOutput) -and [DateTime]::UtcNow -lt $deadline) {
                if ($rWorkers[0].Process.HasExited) { break }
                Start-Sleep -Milliseconds 50
            }
            if (-not (Test-Path -LiteralPath $rOutput)) { throw 'Direct R worker did not write its identity.' }
            $received = [IO.File]::ReadAllLines($rOutput)
            if ($received.Count -ne 4 -or [int]$received[0] -ne $rWorkers[0].Process.Id -or
                $received[1] -cne $value -or $received[3] -cne '--flag-after-script') {
                throw 'Direct R PID/argument test failed: an architecture wrapper may still be in use.'
            }
            if ($rCode -eq 0) { Wait-FederatedWorkers $rWorkers 20 }
            else { Assert-Throws { Wait-FederatedWorkers $rWorkers 20 } 'failed.*exit 7' }
        } finally { Stop-FederatedWorkers $rWorkers }
        if ($rWorkers[0].FinalExitCode -ne $rCode) { throw 'Direct R final exit code was lost.' }
    }
    Write-Host 'PASS: direct R interpreter PID equals Sys.getpid(); quoted script arguments and exits 0/7 verified.'
} else {
    Write-Host 'SKIP: direct R identity test (no pinned Windows R found; pass -Rscript to test an interpreter).'
}
$workers = @()
try {
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,$output,$value) $root (Join-Path $root 'roundtrip') 'roundtrip'
    Wait-FederatedWorkers $workers 30
    if ([IO.File]::ReadAllText($output) -cne $value) { throw 'Native argument roundtrip failed.' }
} finally { Stop-FederatedWorkers $workers }

# Regress the Windows PowerShell 5.1 empty ExitCode failure. Complete short
# children before asking the launcher to wait, and require actual integer codes.
foreach ($code in @(0, 7, 0, 23)) {
    $workers = @()
    try {
        $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,$output,'fast',[string]$code) $root (Join-Path $root "fast$code") "fast$code"
        if (-not $workers[0].Process.WaitForExit(30000)) { throw 'Fast worker did not exit.' }
        $actual = $workers[0].Process.ExitCode
        if ($null -eq $actual -or $actual -ne $code) { throw "Lost exit code: expected $code, got '$actual'." }
        if ($code -eq 0) { Wait-FederatedWorkers $workers 30 }
        else { Assert-Throws { Wait-FederatedWorkers $workers 30 } "failed.*exit $code" }
    } finally { Stop-FederatedWorkers $workers }
}

# Large stdout and stderr must drain concurrently without truncation/deadlock.
$noisy = Join-Path $root 'noisy.ps1'
@'
$text = 'x' * 262144
[Console]::Out.Write($text)
[Console]::Error.Write($text)
exit 0
'@ | Set-Content -LiteralPath $noisy -Encoding UTF8
$workers = @()
try {
    $prefix = Join-Path $root 'noisy'
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$noisy) $root $prefix 'noisy'
    Wait-FederatedWorkers $workers 30
    if ($workers[0].StdoutStream.CanWrite -or $workers[0].StderrStream.CanWrite) {
        throw 'Completed log writers must be closed before callers read their logs.'
    }
    foreach ($stream in @('stdout','stderr')) {
        if (([IO.File]::ReadAllText("$prefix.$stream.log")).Length -ne 262144) { throw "Truncated $stream log." }
    }
} finally { Stop-FederatedWorkers $workers }

# A missing code is indeterminate, never success and never a fabricated zero.
$fakeProcess = [pscustomobject]@{ HasExited = $true; ExitCode = $null }
$fakeProcess | Add-Member ScriptMethod Refresh {}
$fakeProcess | Add-Member ScriptMethod WaitForExit {}
$done = [System.Threading.Tasks.Task]::FromResult(0)
$fake = [pscustomobject]@{ Role = 'missing'; Process = $fakeProcess; LogPrefix = 'missing'; Completed = $false;
    StdoutTask = $done; StderrTask = $done; StdoutStream = [IO.Stream]::Null; StderrStream = [IO.Stream]::Null }
Assert-Throws { Wait-FederatedWorkers @($fake) 1 } 'No exit code.*Completion cannot be verified'

$workers = @()
try {
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,$output,'slow','0','30') $root (Join-Path $root 'slow') 'slow'
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,(Join-Path $root 'failed.txt'),'fail','7') $root (Join-Path $root 'failed') 'failed'
    $ownedIds = @($workers | ForEach-Object { $_.Process.Id })
    Assert-Throws { Wait-FederatedWorkers $workers 30 } 'failed.*exit 7'
} finally { Stop-FederatedWorkers $workers }
foreach ($idValue in $ownedIds) {
    if (Get-Process -Id $idValue -ErrorAction SilentlyContinue) { throw 'An owned worker was not stopped after failure.' }
}

# A wrapper-like child must not survive cleanup of its retained parent. Only
# this test's descendants are targeted; the main test process stays alive.
if ($env:OS -eq 'Windows_NT') {
$treeParent = Join-Path $root 'tree parent.ps1'
@'
param([string]$Executable, [string]$Heartbeat)
$code = "`$until=[DateTime]::UtcNow.AddSeconds(20);while([DateTime]::UtcNow -lt `$until){[IO.File]::WriteAllText('" + $Heartbeat.Replace("'","''") + "',[DateTime]::UtcNow.Ticks.ToString());Start-Sleep -Milliseconds 100}"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
$descendant = Start-Process -FilePath $Executable -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -PassThru
$descendant.WaitForExit()
'@ | Set-Content -LiteralPath $treeParent -Encoding UTF8
$heartbeat = Join-Path $root 'descendant heartbeat.txt'
$workers = @()
try {
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$treeParent,$executable,$heartbeat) $root (Join-Path $root 'tree') 'tree'
    $deadline=[DateTime]::UtcNow.AddSeconds(20)
    while(-not(Test-Path -LiteralPath $heartbeat) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    if(-not(Test-Path -LiteralPath $heartbeat)){throw 'Descendant did not start.'}
} finally { Stop-FederatedWorkers $workers }
Start-Sleep -Milliseconds 100
$stoppedHeartbeat=[IO.File]::ReadAllText($heartbeat)
Start-Sleep -Milliseconds 500
if([IO.File]::ReadAllText($heartbeat) -cne $stoppedHeartbeat){throw 'Owned descendant continued running after cleanup.'}
if($null -eq $workers[0].FinalExitCode){throw 'Terminated worker final exit code was not retained.'}
Write-Host 'PASS: Windows owned-process-tree cleanup stops a wrapper descendant.'
} else {
    Write-Host 'SKIP: Windows taskkill /T process-tree regression (requires Windows).'
}
$workers = @()
try {
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,$output,'slow','0','30') $root (Join-Path $root 'timeout') 'timeout'
    Assert-Throws { Wait-FederatedWorkers $workers 1 } 'timed out'
} finally { Stop-FederatedWorkers $workers }
Write-Host "PASS: identifiers, argument roundtrip, fast/zero/nonzero/missing exit codes, dual-pipe logs, cleanup and timeout. Logs: $root"
