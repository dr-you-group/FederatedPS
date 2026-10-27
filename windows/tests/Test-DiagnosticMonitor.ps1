#Requires -Version 5.1
# Real subprocess regressions; no database, R, JVM, Internet, or Pester needed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
. (Join-Path $PSScriptRoot '..\DiagnosticMonitor.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('fedps diagnostic ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$binaryName = if ($env:OS -ne 'Windows_NT') { 'pwsh' } elseif ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$executable = Join-Path $PSHOME $binaryName
$child = Join-Path $root 'probe.ps1'
@'
param([string]$Receipt, [string]$Token, [string]$Mode)
$value = [ordered]@{schema=1; state='checks-complete'; token=$Token; pid=$PID;
    checks=@{select1=$true;careSites=@(1,2,3)}; disconnectComplete=$true}
switch ($Mode) {
    'wrong-token' { $value.token='another-token' }
    'wrong-pid' { $value.pid=$PID+1 }
    'bad-disconnect' { $value.disconnectComplete=$false }
    'string-disconnect' { $value.disconnectComplete='true' }
    'bad-schema' { $value.schema=2 }
    'array-schema' { $value.schema=@(1,1) }
    'array-pid' { $value.pid=@($PID,$PID) }
    'missing-site' { $value.checks.careSites=@(1,3) }
    'duplicate-site' { $value.checks.careSites=@(1,1,3) }
}
if ($Mode -notin @('missing','missing-hang')) {
    $temp=$Receipt+'.tmp'
    [IO.File]::WriteAllText($temp,($value | ConvertTo-Json -Depth 4))
    Move-Item -LiteralPath $temp -Destination $Receipt
}
Write-Output 'PASS: this text must never establish completion.'
if ($Mode -eq 'error') { exit 7 }
if ($Mode -eq 'capture-error') { Start-Sleep -Milliseconds 2200; exit 7 }
if ($Mode -in @('hang','missing-hang')) { Start-Sleep -Seconds 30 }
exit 0
'@ | Set-Content -LiteralPath $child -Encoding UTF8

# Stub only optional JVM thread collection; worker lifecycle remains real.
$script:captureDelay = 0
function Invoke-FederatedDiagnosticThreadCapture($Worker, [string]$JavaHome, [string]$OutputDirectory) {
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'diagnostic-thread.txt'), 'test thread capture')
    if ($script:captureDelay) { Start-Sleep -Milliseconds $script:captureDelay }
}
$script:receiptReader = (Get-Item Function:Get-FederatedDiagnosticReceipt).ScriptBlock
$script:lateRead = $false
function Get-FederatedDiagnosticReceipt([string]$Path, [string]$Token, [int]$RuntimePid, [int[]]$CareSiteIds) {
    if ($script:lateRead) {
        # Model the exact race: initial read sees no receipt; by the following
        # HasExited check, the real child has published it and exited.
        $script:lateRead = $false
        if (-not $script:lateWorker.Process.WaitForExit(10000)) { throw 'Late receipt child did not exit.' }
        return $null
    }
    & $script:receiptReader -Path $Path -Token $Token -RuntimePid $RuntimePid -CareSiteIds $CareSiteIds
}
function Invoke-Case([string]$Mode, [string]$Failure = '') {
    $directory = Join-Path $root $Mode
    New-Item -ItemType Directory -Path $directory | Out-Null
    $receipt = Join-Path $directory 'diagnostic-status.json'
    $token = [guid]::NewGuid().ToString('N')
    $workers = @(); $caught = $false; $result = $null
    try {
        $workers += Start-FederatedWorker -Executable $executable `
            -Arguments @('-NoProfile','-File',$child,$receipt,$token,$Mode) `
            -WorkingDirectory $directory -LogPrefix (Join-Path $directory 'run') -Role diagnostic
        if ($Mode -eq 'late-receipt') { $script:lateRead = $true; $script:lateWorker = $workers[0] }
        try {
            $result = Wait-FederatedDiagnostic -Worker $workers[0] -ReceiptPath $receipt `
                -Token $token -CareSiteIds @(1,2,3) -TimeoutSeconds 5 -ExitGraceSeconds 1 `
                -OutputDirectory $directory
        } catch {
            $caught = $true
            if (-not $Failure -or $_.Exception.Message -notmatch $Failure) { throw }
        }
        if ([bool]$Failure -ne $caught) { throw "Unexpected result for $Mode (expected failure: $Failure)." }
        if (-not $workers[0].Process.HasExited) { throw "Probe $Mode was left running." }
        $saved = Get-Content -LiteralPath (Join-Path $directory 'diagnostic-outcome.json') -Raw | ConvertFrom-Json
        if (-not $saved.processExited -or $saved.nativeExitCode -ne $workers[0].Process.ExitCode) {
            throw "Outcome lost the actual exit code for $Mode."
        }
        if ($Mode -eq 'hang') {
            if (-not $result.checks_complete -or -not $result.cleanup_forced -or $result.nativeExitCode -eq 0 -or
                $workers[0].Completed -or $saved.state -cne 'checks-complete-forced-cleanup' -or
                -not (Test-Path -LiteralPath (Join-Path $directory 'diagnostic-thread.txt'))) {
                throw 'Forced cleanup was falsely represented as normal process success.'
            }
        } elseif ($Mode -in @('normal','late-receipt')) {
            if (-not $result.checks_complete -or $result.cleanup_forced -or $result.nativeExitCode -ne 0 -or
                -not $workers[0].Completed -or $saved.state -cne 'completed') { throw 'Normal completion failed.' }
        } else {
            if ($saved.state -cne 'failed') { throw "Failure was accepted for $Mode." }
            if ($Mode -in @('error','capture-error') -and ($saved.nativeExitCode -ne 7 -or $saved.cleanup_forced)) {
                throw 'A receipt overrode a natural nonzero exit.'
            }
        }
    } finally { Stop-FederatedWorkers $workers }
}
try {
    Invoke-Case normal
    Invoke-Case late-receipt
    Invoke-Case error 'native exit 7'
    Invoke-Case hang
    Invoke-Case wrong-token 'Invalid diagnostic completion receipt'
    Invoke-Case wrong-pid 'Invalid diagnostic completion receipt'
    Invoke-Case bad-disconnect 'Invalid diagnostic completion receipt'
    Invoke-Case string-disconnect 'Invalid diagnostic completion receipt'
    Invoke-Case bad-schema 'Invalid diagnostic completion receipt'
    Invoke-Case array-schema 'Invalid diagnostic completion receipt'
    Invoke-Case array-pid 'Invalid diagnostic completion receipt'
    Invoke-Case missing-site 'Invalid diagnostic completion receipt'
    Invoke-Case duplicate-site 'Invalid diagnostic completion receipt'
    Invoke-Case missing 'without a valid checks/disconnect receipt'
    Invoke-Case missing-hang 'timed out'
    $script:captureDelay = 2500
    Invoke-Case capture-error 'native exit 7'
    Write-Host 'PASS: normal exit 0, error 7, receipt then hang, exact receipt identity/checks, missing receipt, and failure during thread capture.'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
