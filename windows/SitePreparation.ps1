#Requires -Version 5.1
# The caller owns every retained process handle, including workers launched
# before a failure. Its finally block drains/kills only those owned workers.
function Invoke-FederatedSitePreparation {
    param($Runtime,[string]$Project,[string]$ConfigFile,[string]$RunDirectory,
        [string[]]$Sites,[ValidateRange(1,3)][int]$MaxWorkers,[DateTime]$Deadline,[int]$ShutdownSeconds,
        $Monitor,[ref]$Workers,$DbWatchdog=$null)
    $run=Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $queue=New-Object 'Collections.Generic.Queue[string]'
    foreach($site in $Sites){$queue.Enqueue($site)}
    $active=@();$marked=@{}
    while($queue.Count -or $active.Count) {
        if([DateTime]::UtcNow -ge $Deadline){throw 'Whole-run timeout during site extraction.'}
        if($null -ne $DbWatchdog){Update-FederatedDbWatchdog $DbWatchdog $active}
        $remaining=@()
        foreach($worker in $active) {
            foreach($task in @($worker.StdoutTask,$worker.StderrTask)) {
                if($task.IsFaulted -or $task.IsCanceled){[void]$task.GetAwaiter().GetResult()}
            }
            $worker.Process.Refresh()
            $receiptPath=Join-Path $RunDirectory ($worker.Role+'/preparation-complete.json')
            if($worker.Process.HasExited) {
                Wait-FederatedWorkers @($worker) 10
                if(-not(Test-Path -LiteralPath $receiptPath)){throw "Site $($worker.Role) exited without an extraction receipt."}
                $receipt=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if($receipt.runId -cne $run.runId -or $receipt.site -cne $worker.Role -or
                    $receipt.state -cne 'extraction-complete' -or $receipt.entryName -cnotmatch '^entry-[A-Za-z0-9]+[.]ready$' -or
                    $receipt.reused -isnot [bool] -or $receipt.patients -lt 2) {
                    throw "Invalid extraction receipt for site $($worker.Role)."
                }
            } else {
                if(Test-Path -LiteralPath $receiptPath) {
                    if(-not $marked.ContainsKey($worker.Role)){$marked[$worker.Role]=[DateTime]::UtcNow}
                    if([DateTime]::UtcNow -ge $marked[$worker.Role].AddSeconds($ShutdownSeconds)) {
                        throw "Site $($worker.Role) wrote results but did not exit normally."
                    }
                }
                $remaining+=,$worker
            }
        }
        $active=$remaining
        while($queue.Count -and $active.Count -lt $MaxWorkers) {
            if([DateTime]::UtcNow -ge $Deadline){throw 'Whole-run timeout during site extraction.'}
            $site=$queue.Dequeue()
            $directory=Join-Path $RunDirectory $site
            New-Item -ItemType Directory -Path $directory | Out-Null
            $worker=Start-FederatedRWorker -Runtime $Runtime -Script (Join-Path $Project 'windows/run-baselines.R') `
                -Arguments @($ConfigFile,$site) -WorkingDirectory $Project -LogPrefix (Join-Path $directory 'run') -Role $site
            $Workers.Value+=,$worker
            $active+=,$worker
            Write-FederatedProcessMetadata $RunDirectory $Workers.Value
        }
        Update-FederatedMonitor $Monitor $Workers.Value
        if($active.Count){Start-Sleep -Milliseconds 200}
    }
    Update-FederatedMonitor $Monitor $Workers.Value -Force
}
