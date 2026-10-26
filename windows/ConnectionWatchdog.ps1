#Requires -Version 5.1
# Independent of the optional live monitor and of JDBC's timeout thread.
# This helper only reports a timeout. The owning launcher captures diagnostics
# and stops its own retained workers through its existing failure/finally path.
function New-FederatedDbWatchdog {
    param([string]$RunDirectory,[string]$RunId,[string[]]$Sites,[int]$TimeoutSeconds=180,
          [int]$OperationTimeoutSeconds=75,[int]$StatusSeconds=10,[int]$SqlPreparationTimeoutSeconds=60)
    @{Root=$RunDirectory;RunId=$RunId;Sites=$Sites;Timeout=$TimeoutSeconds;Started=@{};Ready=@{};
      OperationTimeout=$OperationTimeoutSeconds;StatusSeconds=$StatusSeconds;LastStatus=@{};Phase=@{};
      SqlPreparationTimeout=$SqlPreparationTimeoutSeconds;SqlPreparation=@{};SqlPreparationStatus=@{}}
}

function Update-FederatedSqlPreparationWatchdog($Watchdog,$Worker,[string]$Site,[DateTime]$Now) {
    $key=[string]$Worker.Role+':'+$Site
    $path=Join-Path $Watchdog.Root ('extraction/'+$Site+'/sql-prepare-state.json')
    $detail=$null
    try { $detail=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    if($null -ne $detail) {
        if($detail.runId -cne $Watchdog.RunId -or $detail.site -cne $Site -or $detail.pid -ne $Worker.Process.Id) {
            throw "Invalid SQL preparation marker identity for site_id=$Site."
        }
        if($detail.status -notin @('started','completed','failed') -or -not $detail.id -or -not $detail.startedUtc) {
            throw "Invalid SQL preparation state for site_id=$Site."
        }
        $Watchdog.SqlPreparation[$key]=$detail
    }
    # Retain the last complete snapshot if a concurrent write is incomplete.
    if(-not $Watchdog.SqlPreparation.ContainsKey($key)){return}
    $detail=$Watchdog.SqlPreparation[$key]
    if($detail.status -ne 'started'){return}
    $elapsed=[Math]::Max(0,($Now-(ConvertTo-FederatedUtc $detail.startedUtc)).TotalSeconds)
    if(-not $Watchdog.SqlPreparationStatus.ContainsKey($key) -or
        ($Now-$Watchdog.SqlPreparationStatus[$key]).TotalSeconds -ge $Watchdog.StatusSeconds) {
        $line='[{0}] Local SQL preparation: site_id={1}; {2}; wait={3}s / {4}s limit (no DB query; deadline, not ETA)' -f
            [DateTime]::Now.ToString('HH:mm:ss'),$Site,$detail.label,[Math]::Floor($elapsed),$Watchdog.SqlPreparationTimeout
        Write-Host $line
        try { [IO.File]::AppendAllText((Join-Path $Watchdog.Root 'sql-prepare-watchdog.log'),
            $line+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false))) } catch { }
        $Watchdog.SqlPreparationStatus[$key]=$Now
    }
    if($elapsed -lt $Watchdog.SqlPreparationTimeout){return}
    [IO.File]::WriteAllText((Join-Path $Watchdog.Root ('sql-prepare-timeout-'+$Site+'.json')),
        (@{site=$Site;pid=$detail.pid;runId=$detail.runId;phase=$detail.label;operationId=$detail.id;
            elapsedSeconds=[Math]::Floor($elapsed);limitSeconds=$Watchdog.SqlPreparationTimeout;state='timeout'} | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($false)))
    throw "Local SQL preparation exceeded $($Watchdog.SqlPreparationTimeout)s for site_id=$Site; phase: $($detail.label). No automatic retry. See sql-prepare-timeout-$Site.json and shutdown-thread-$($Worker.Role).txt."
}

function Write-FederatedDbWatchdogLine($Watchdog,[string]$Text) {
    $line='[{0}] {1}' -f [DateTime]::Now.ToString('HH:mm:ss'),$Text
    Write-Host $line
    try { [IO.File]::AppendAllText((Join-Path $Watchdog.Root 'db-startup-watchdog.log'),
        $line+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false))) } catch { }
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
            # This phase precedes the first JDBC connection. It must be guarded
            # even without a DB startup marker, or after an earlier DB is ready.
            Update-FederatedSqlPreparationWatchdog $Watchdog $worker $site $Now
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
                Write-FederatedDbWatchdogLine $Watchdog "DB ready: site_id=$site; connection and checks passed. Starting clinical extraction."
                continue
            }
            # Explicit Now keeps deadline tests deterministic; production uses UTC.
            $elapsed=($Now-(ConvertTo-FederatedUtc $start.startedUtc)).TotalSeconds
            $phase='Opening JDBC database connection (no later phase available)'
            $phaseElapsed=$null
            $phasePath=Join-Path $directory 'db-startup-phase.json'
            try {
                $detail=Get-Content -LiteralPath $phasePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if($detail.runId -ceq $start.runId -and $detail.pid -eq $start.pid -and $detail.site -ceq $site -and
                    [string]$detail.startedUtc -ceq [string]$start.startedUtc){
                    $Watchdog.Phase[$key]=$detail
                }
            } catch { } # Phase snapshot is optional and may be mid-write.
            if($Watchdog.Phase.ContainsKey($key)) {
                $detail=$Watchdog.Phase[$key];$phase=[string]$detail.phase
                if($detail.PSObject.Properties['phaseStartedUtc']) {
                    try { $phaseElapsed=[Math]::Max(0,($Now-(ConvertTo-FederatedUtc $detail.phaseStartedUtc)).TotalSeconds) } catch { }
                }
            }
            # SmallQueryTimeout may be as low as 1s. The connection still gets
            # its configured 30s login deadline plus a bounded 15s margin.
            $phaseLimit=if($phase -like 'Opening *connection*'){[Math]::Max(45,$Watchdog.OperationTimeout)}else{$Watchdog.OperationTimeout}
            if(-not $Watchdog.LastStatus.ContainsKey($key) -or
                ($Now-$Watchdog.LastStatus[$key]).TotalSeconds -ge $Watchdog.StatusSeconds) {
                $phaseText=if($null -eq $phaseElapsed){'unknown'}else{[string][Math]::Floor($phaseElapsed)+'s / '+$phaseLimit+'s limit'}
                Write-FederatedDbWatchdogLine $Watchdog ("DB startup: site_id=$site; phase=$phase; phase wait=$phaseText; total="+[Math]::Floor($elapsed)+"s / $($Watchdog.Timeout)s limit (deadline, not ETA)")
                $Watchdog.LastStatus[$key]=$Now
            }
            $operationExpired=$null -ne $phaseElapsed -and $phaseElapsed -ge $phaseLimit
            if($elapsed -lt $Watchdog.Timeout -and -not $operationExpired){continue}
            $reason=if($operationExpired){"DB operation exceeded $($phaseLimit)s"}else{"DB startup exceeded $($Watchdog.Timeout)s"}
            $message="$reason for site_id=$site; last phase: $phase. JDBC did not finish connection/self-check/CARE_SITE validation. No automatic retry. See $directory and shutdown-thread-$($worker.Role).txt."
            [IO.File]::WriteAllText((Join-Path $Watchdog.Root ('db-startup-timeout-'+$site+'.json')),
                (@{site=$site;pid=$start.pid;runId=$start.runId;phase=$phase;elapsedSeconds=[Math]::Floor($elapsed);
                    phaseElapsedSeconds=$phaseElapsed;operationLimitSeconds=$phaseLimit;
                    limitSeconds=$Watchdog.Timeout;state='timeout'} | ConvertTo-Json),
                (New-Object Text.UTF8Encoding($false)))
            throw $message
        }
    }
}
