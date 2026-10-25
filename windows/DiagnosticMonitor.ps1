#Requires -Version 5.1
# This completion protocol is ONLY for the disposable, read-only connection
# probe. Analysis workers must still exit normally and pass result verification.
Set-StrictMode -Version Latest

function Get-FederatedDiagnosticReceipt {
    param([string]$Path, [string]$Token, [int]$RuntimePid, [int[]]$CareSiteIds)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $receipt = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('schema','state','token','pid','checks','disconnectComplete')) {
            if (-not $receipt.PSObject.Properties[$name]) { throw "Missing $name." }
        }
        if ($null -eq $receipt.schema -or $receipt.schema -is [array] -or
            $receipt.schema -is [string] -or $receipt.schema -is [bool] -or $receipt.schema -ne 1 -or
            $receipt.state -isnot [string] -or $receipt.state -cne 'checks-complete' -or
            $receipt.token -isnot [string] -or $receipt.token -cne $Token -or
            $null -eq $receipt.pid -or $receipt.pid -is [array] -or
            $receipt.pid -is [string] -or $receipt.pid -is [bool] -or $receipt.pid -ne $RuntimePid -or
            $receipt.disconnectComplete -isnot [bool] -or -not $receipt.disconnectComplete) {
            throw 'Schema, identity, state, or disconnect confirmation differs.'
        }
        if (-not $receipt.checks.PSObject.Properties['select1'] -or
            -not $receipt.checks.PSObject.Properties['careSites'] -or
            $receipt.checks.select1 -isnot [bool] -or -not $receipt.checks.select1) {
            throw 'SELECT 1 was not confirmed.'
        }
        $actual = @($receipt.checks.careSites)
        if ($actual.Count -ne $CareSiteIds.Count) { throw 'CARE_SITE count differs.' }
        foreach ($idValue in $actual) {
            if ($null -eq $idValue -or $idValue -is [string] -or $idValue -is [bool] -or
                $idValue -lt 1 -or $idValue -gt [int]::MaxValue -or $idValue -ne [Math]::Floor($idValue)) {
                throw 'CARE_SITE IDs must be positive integers.'
            }
        }
        if ((@($actual | Sort-Object) -join ',') -cne (@($CareSiteIds | Sort-Object) -join ',')) {
            throw 'CARE_SITE IDs differ from this probe configuration.'
        }
        return $receipt
    } catch { throw "Invalid diagnostic completion receipt: $($_.Exception.Message)" }
}

function Invoke-FederatedDiagnosticThreadCapture {
    param($Worker, [string]$JavaHome, [string]$OutputDirectory)
    # The caller owns the retained process handle. Never discover a process from
    # a saved PID, and do not include connection settings in the thread dump.
    $Worker.Process.Refresh()
    if ($Worker.Process.HasExited) { return }
    $destination = Join-Path $OutputDirectory 'diagnostic-thread.txt'
    try {
        $jcmd = if ($JavaHome) { Join-Path $JavaHome 'bin\jcmd.exe' } else { '' }
        if (-not $jcmd -or -not (Test-Path -LiteralPath $jcmd -PathType Leaf)) {
            throw 'jcmd.exe is unavailable; no JVM thread dump was collected.'
        }
        Write-Host 'Capturing diagnostic JVM threads before cleanup (up to 15 seconds)...'
        Invoke-RunDiagnosticThreadDump -Jcmd $jcmd -RuntimePid $Worker.Process.Id `
            -OutputFile $destination -TimeoutSeconds 15
    } catch {
        [IO.File]::WriteAllText($destination, $_.Exception.Message, (New-Object Text.UTF8Encoding($false)))
        Write-Warning $_.Exception.Message
    }
}

function Stop-FederatedDiagnosticWorker($Worker) {
    $Worker.Process.Refresh()
    if ($Worker.Process.HasExited) { return $false }
    # This direct R/JVM probe has no analysis descendants. Process.Kill targets
    # only its retained native handle. Unlike taskkill, it has a distinct forced
    # exit code (-1 on Windows; 137 for the Linux regression-test process).
    $killSucceeded = $false
    try { $Worker.Process.Kill(); $killSucceeded = $true }
    catch {
        $Worker.Process.Refresh()
        if (-not $Worker.Process.HasExited) { throw }
    }
    if (-not $Worker.Process.WaitForExit(10000)) { throw 'Diagnostic process did not exit after cleanup.' }
    $Worker.FinalExitCode = $Worker.Process.ExitCode
    $forcedCode = if ($env:OS -eq 'Windows_NT') { -1 } else { 137 }
    return ($killSucceeded -and $Worker.FinalExitCode -eq $forcedCode)
}

function Complete-FederatedDiagnosticLogs($Worker) {
    $tasks = [Threading.Tasks.Task[]]@($Worker.StdoutTask, $Worker.StderrTask)
    if (-not [Threading.Tasks.Task]::WaitAll($tasks, 5000)) {
        throw 'Diagnostic process exited, but its output pipes did not close within 5 seconds.'
    }
    [void]$Worker.StdoutTask.GetAwaiter().GetResult()
    [void]$Worker.StderrTask.GetAwaiter().GetResult()
    $Worker.StdoutStream.Flush(); $Worker.StderrStream.Flush()
    $Worker.StdoutStream.Dispose(); $Worker.StderrStream.Dispose()
}

function Wait-FederatedDiagnostic {
    param($Worker, [string]$ReceiptPath, [string]$Token, [int[]]$CareSiteIds,
          [ValidateRange(1,86400)][int]$TimeoutSeconds,
          [ValidateRange(1,60)][int]$ExitGraceSeconds = 10,
          [string]$OutputDirectory, [string]$JavaHome = '', $Monitor = $null)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $receiptTime = $null; $captured = $false
    $outcome = [pscustomobject][ordered]@{
        schema = 1; state = 'running'; checks_complete = $false; cleanup_forced = $false
        processExited = $false; nativeExitCode = $null; pid = $Worker.Process.Id; error = $null
    }
    try {
        while ($true) {
            if ($null -ne $Monitor) { Update-FederatedMonitor $Monitor @($Worker) }
            foreach ($task in @($Worker.StdoutTask, $Worker.StderrTask)) {
                if ($task.IsFaulted -or $task.IsCanceled) { [void]$task.GetAwaiter().GetResult() }
            }
            if (-not $outcome.checks_complete) {
                $receipt = Get-FederatedDiagnosticReceipt -Path $ReceiptPath -Token $Token `
                    -RuntimePid $Worker.Process.Id -CareSiteIds $CareSiteIds
                if ($null -ne $receipt) {
                    $outcome.checks_complete = $true
                    $receiptTime = [DateTime]::UtcNow
                    Write-Host 'Connection checks and explicit disconnect are confirmed; waiting for the R process to exit.'
                }
            }
            $Worker.Process.Refresh()
            if ($Worker.Process.HasExited) {
                $outcome.processExited = $true
                $outcome.nativeExitCode = $Worker.Process.ExitCode
                $Worker.FinalExitCode = $outcome.nativeExitCode
                if ($null -eq $outcome.nativeExitCode -or $outcome.nativeExitCode -ne 0) {
                    throw "Diagnostic process failed (native exit $($outcome.nativeExitCode))."
                }
                if (-not $outcome.checks_complete) {
                    # R may atomically publish the receipt and exit between the
                    # first read and HasExited. Re-read after observing exit.
                    $receipt = Get-FederatedDiagnosticReceipt -Path $ReceiptPath -Token $Token `
                        -RuntimePid $Worker.Process.Id -CareSiteIds $CareSiteIds
                    if ($null -eq $receipt) { throw 'Diagnostic process exited without a valid checks/disconnect receipt.' }
                    $outcome.checks_complete = $true
                }
                Complete-FederatedDiagnosticLogs $Worker
                $Worker.Completed = $true
                $outcome.state = 'completed'
                return $outcome
            }
            if ($outcome.checks_complete -and [DateTime]::UtcNow -ge $receiptTime.AddSeconds($ExitGraceSeconds)) {
                Invoke-FederatedDiagnosticThreadCapture $Worker $JavaHome $OutputDirectory
                $captured = $true
                # A native failure during thread capture remains a failure even
                # when the check receipt was valid. Never replace that code.
                $Worker.Process.Refresh()
                if ($Worker.Process.HasExited) { continue }
                $outcome.cleanup_forced = Stop-FederatedDiagnosticWorker $Worker
                if (-not $outcome.cleanup_forced) { continue }
                $outcome.processExited = $Worker.Process.HasExited
                $outcome.nativeExitCode = $Worker.FinalExitCode
                if (-not $outcome.processExited) { throw 'Diagnostic process remains alive after cleanup.' }
                Complete-FederatedDiagnosticLogs $Worker
                $outcome.state = 'checks-complete-forced-cleanup'
                Write-Warning "Connection checks and disconnect completed, but the diagnostic R process required forced cleanup (native exit $($outcome.nativeExitCode)). Its shutdown remains unresolved; see diagnostic-thread.txt."
                return $outcome
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "Connection diagnostic timed out after $TimeoutSeconds seconds without verified completion and process exit."
            }
            Start-Sleep -Milliseconds 100
        }
    } catch {
        $failure = $_
        $outcome.state = 'failed'; $outcome.error = $failure.Exception.Message
        try {
            $Worker.Process.Refresh()
            if (-not $Worker.Process.HasExited) {
                if (-not $captured) { Invoke-FederatedDiagnosticThreadCapture $Worker $JavaHome $OutputDirectory }
                $outcome.cleanup_forced = Stop-FederatedDiagnosticWorker $Worker
            }
        } catch { $outcome.error += " Cleanup failed: $($_.Exception.Message)" }
        throw $failure
    } finally {
        $Worker.Process.Refresh()
        $outcome.processExited = $Worker.Process.HasExited
        if ($outcome.processExited) {
            $outcome.nativeExitCode = $Worker.Process.ExitCode
            $Worker.FinalExitCode = $outcome.nativeExitCode
        }
        [IO.File]::WriteAllText((Join-Path $OutputDirectory 'diagnostic-outcome.json'),
            ($outcome | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    }
}
