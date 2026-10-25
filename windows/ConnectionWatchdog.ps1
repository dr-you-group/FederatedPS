#Requires -Version 5.1
# Independent of the optional live monitor and of JDBC's timeout thread.
# This helper only reports a timeout. The owning launcher captures diagnostics
# and stops its own retained workers through its existing failure/finally path.
function New-FederatedDbWatchdog {
    param([string]$RunDirectory,[string]$RunId,[string[]]$Sites,[int]$TimeoutSeconds=180)
    @{Root=$RunDirectory;RunId=$RunId;Sites=$Sites;Timeout=$TimeoutSeconds;Started=@{};Ready=@{}}
}

function Update-FederatedDbWatchdog {
    param($Watchdog,[object[]]$Workers,[DateTime]$Now=[DateTime]::UtcNow)
    if($null -eq $Watchdog){return}
    foreach($worker in $Workers) {
        $worker.Process.Refresh()
        if($worker.Process.HasExited){continue}
        $sites=if($worker.Role -eq 'baselines'){@($Watchdog.Sites)}elseif($worker.Role -cin $Watchdog.Sites){@($worker.Role)}else{@()}
        foreach($site in $sites) {
            $key=[string]$worker.Role+':'+[string]$site
            if($Watchdog.Ready.ContainsKey($key)){continue}
            $directory=Join-Path $Watchdog.Root ('extraction/'+$site)
            $path=Join-Path $directory 'db-startup-start.json'
            if(-not $Watchdog.Started.ContainsKey($key)) {
                if(-not(Test-Path -LiteralPath $path)){continue}
                $record=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                if($record.runId -cne $Watchdog.RunId -or $record.site -cne $site -or $record.pid -ne $worker.Process.Id) {
                    throw "Invalid DB startup marker identity for site_id=$site."
                }
                $Watchdog.Started[$key]=$record
            }
            $start=$Watchdog.Started[$key]
            $readyPath=Join-Path $directory 'db-startup-ready.json'
            if(Test-Path -LiteralPath $readyPath) {
                $ready=Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if($ready.runId -cne $start.runId -or $ready.site -cne $site -or $ready.pid -ne $start.pid -or
                    [string]$ready.startedUtc -cne [string]$start.startedUtc -or $ready.state -cne 'checks-passed') {
                    throw "Invalid DB startup completion marker for site_id=$site."
                }
                $Watchdog.Ready[$key]=$true
                continue
            }
            # Explicit Now keeps deadline tests deterministic; production uses UTC.
            $elapsed=($Now-(ConvertTo-FederatedUtc $start.startedUtc)).TotalSeconds
            if($elapsed -lt $Watchdog.Timeout){continue}
            $phase='Opening JDBC database connection (no later phase available)'
            $phasePath=Join-Path $directory 'db-startup-phase.json'
            try {
                $detail=Get-Content -LiteralPath $phasePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if($detail.runId -ceq $start.runId -and $detail.pid -eq $start.pid -and $detail.site -ceq $site){$phase=[string]$detail.phase}
            } catch { } # Phase snapshot is optional and may be mid-write.
            $message="DB startup exceeded $($Watchdog.Timeout)s for site_id=$site; last phase: $phase. JDBC did not finish connection/self-check/CARE_SITE validation. No clinical SQL is retried. See $directory and shutdown-thread-$($worker.Role).txt."
            [IO.File]::WriteAllText((Join-Path $Watchdog.Root ('db-startup-timeout-'+$site+'.json')),
                (@{site=$site;pid=$start.pid;runId=$start.runId;phase=$phase;elapsedSeconds=[Math]::Floor($elapsed);limitSeconds=$Watchdog.Timeout;state='timeout'} | ConvertTo-Json),
                (New-Object Text.UTF8Encoding($false)))
            throw $message
        }
    }
}
