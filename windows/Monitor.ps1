#Requires -Version 5.1
# Observability only: never change or terminate a worker from this file.
function ConvertTo-FederatedUtc($Value) {
    # PS 7 can deserialize ISO dates into DateTime; PS 5.1 keeps strings.
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}
function Get-FederatedElapsedSeconds([DateTime]$Now, [DateTime]$Since) {
    # An event can be written while this refresh reads earlier roles. Never
    # display negative ages if clocks move or a just-written timestamp is ahead.
    [Math]::Max(0, [Math]::Floor(($Now-$Since).TotalSeconds))
}
function New-FederatedLogCursor([string]$Path, [bool]$Tail = $false) {
    [pscustomobject]@{ Path=$Path; Offset=[long]0; Pending=''; Decoder=[Text.Encoding]::UTF8.GetDecoder(); Tail=$Tail }
}
function Read-FederatedAppend($Cursor, [switch]$Final) {
    if (-not [IO.File]::Exists($Cursor.Path)) { return }
    $file = $null
    try {
        # The reader must share WRITE as well as READ with the live log writer.
        $file = [IO.File]::Open($Cursor.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($Cursor.Tail) {
            $Cursor.Offset = [Math]::Max(0, $file.Length - 32768)
            $Cursor.Tail = $false
        }
        if ($file.Length -lt $Cursor.Offset) {
            $Cursor.Offset=[long]0; $Cursor.Pending=''; $Cursor.Decoder.Reset()
        }
        [void]$file.Seek($Cursor.Offset, [IO.SeekOrigin]::Begin)
        $bytes = New-Object byte[] 65536
        $count = $file.Read($bytes, 0, $bytes.Length)
        $Cursor.Offset += $count
        $chars = New-Object char[] 65538
        $n = $Cursor.Decoder.GetChars($bytes, 0, $count, $chars, 0, $false)
        $text=$Cursor.Pending
        if ($n -gt 0) { $text += (-join $chars[0..($n-1)]) }
        $parts = [regex]::Split($text, '\r?\n')
        $Cursor.Pending = $parts[-1]
        for ($i=0; $i -lt $parts.Length-1; $i++) { $parts[$i] }
        # Very long native output must not grow the monitor's memory without bound.
        if ($Cursor.Pending.Length -gt 65536 -or ($Final -and $file.Position -eq $file.Length)) {
            if ($Cursor.Pending.Length) { $Cursor.Pending; $Cursor.Pending='' }
        }
    } catch [IO.IOException] { } finally { if ($null -ne $file) { $file.Dispose() } }
}
function New-FederatedMonitor {
    param([string]$RunDirectory, [string[]]$Roles, [switch]$NoProgress,
          [switch]$ReadOnly, [int]$StatusSeconds=15)
    $states=@()
    foreach($role in $Roles) {
        $dir=Join-Path $RunDirectory $role
        $states += [pscustomobject]@{ Role=$role; Event=$null; LastEvent=$null; StageSince=[DateTime]::UtcNow;
            Stdout=(New-FederatedLogCursor (Join-Path $dir 'run.stdout.log') $ReadOnly.IsPresent);
            Stderr=(New-FederatedLogCursor (Join-Path $dir 'run.stderr.log') $ReadOnly.IsPresent);
            Events=(New-FederatedLogCursor (Join-Path $dir 'progress.jsonl') $ReadOnly.IsPresent);
            LastCpu=$null; LastCpuAt=$null; LastProcessId=$null; Cpu='?';
            ProcessState='not observed'; ObservedExitCode=$null; LastText='' }
    }
    [pscustomobject]@{ Root=$RunDirectory; States=$states; Started=[DateTime]::UtcNow;
        LastRefresh=[DateTime]::MinValue; LastStatus=[DateTime]::MinValue;
        NoProgress=$NoProgress.IsPresent; ReadOnly=$ReadOnly.IsPresent; StatusSeconds=$StatusSeconds; Disabled=$false }
}
function Write-FederatedMonitorLine($Monitor, [string]$Line) {
    $entry='[{0}] {1}' -f ([DateTime]::Now.ToString('HH:mm:ss')), $Line
    Write-Host $entry
    if (-not $Monitor.ReadOnly -and -not $Monitor.Disabled) {
        try {
            [IO.File]::AppendAllText((Join-Path $Monitor.Root 'monitor.log'), $entry+[Environment]::NewLine,
                (New-Object Text.UTF8Encoding($false)))
        } catch {
            $Monitor.Disabled=$true
            Write-Warning 'Combined monitor log unavailable; computation continues with per-role logs.'
        }
    }
}
function Write-FederatedProcessMetadata([string]$RunDirectory, [object[]]$Workers) {
    try {
    $entries=@()
    foreach($worker in $Workers) {
        if ($worker.PSObject.Properties['Process']) {
            $started=$worker.Process.StartTime
            $entries += [ordered]@{role=$worker.Role; pid=$worker.Process.Id;
                startUtc=$(if($null -ne $started){$started.ToUniversalTime().ToString('o')}else{$null})}
        }
    }
    [IO.File]::WriteAllText((Join-Path $RunDirectory 'processes.json'), (ConvertTo-Json -InputObject @($entries)),
        (New-Object Text.UTF8Encoding($false)))
    } catch { Write-Warning 'Process metadata unavailable; computation continues.' }
}
function Get-FederatedProgressDisplay($Event, [bool]$AllowEta=$true) {
    $percent=-1; $eta=-1; $description='No stage event yet; overall ETA unknown'
    if ($null -ne $Event) {
        $description="$($Event.stage): $($Event.detail)"
        if ($null -ne $Event.total -and $null -ne $Event.completed -and $Event.total -gt 0) {
            $percent=[int][Math]::Floor([Math]::Min(100,[Math]::Max(0,100.0*$Event.completed/$Event.total)))
            $description += " | $percent% ($($Event.completed)/$($Event.total) $($Event.unit))"
        }
        if ($AllowEta -and $null -ne $Event.etaSeconds -and $Event.etaSeconds -ge 0 -and
            $Event.unit -eq 'coordinates in this sweep') {
            $eta=[int][Math]::Min(2147483647,[Math]::Ceiling($Event.etaSeconds))
            $description += " | current-sweep ETA ~${eta}s"
        } else { $description += ' | ETA unknown' }
    }
    [pscustomobject]@{ Percent=$percent; Eta=$eta; Text=$description }
}
function Update-FederatedMonitor {
    param($Monitor, [object[]]$Workers=@(), [switch]$Force, [switch]$Final)
    if ($null -eq $Monitor -or $Monitor.Disabled) { return }
    $now=[DateTime]::UtcNow
    if (-not $Force -and ($now-$Monitor.LastRefresh).TotalSeconds -lt 1) { return }
    $Monitor.LastRefresh=$now
    try {
        $statusDue=$Force -or ($now-$Monitor.LastStatus).TotalSeconds -ge $Monitor.StatusSeconds
        $index=0; $finished=0
        foreach($s in $Monitor.States) {
            $index++
            foreach($stream in @('Stdout','Stderr')) {
                foreach($line in @(Read-FederatedAppend $s.$stream -Final:$Final)) {
                    if ($line.Length) {
                        Write-FederatedMonitorLine $Monitor "[$($s.Role)][$($stream.ToLowerInvariant())] $line"
                    }
                }
            }
            foreach($line in @(Read-FederatedAppend $s.Events -Final:$Final)) {
                try { $event=$line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                if (-not $event.PSObject.Properties['kind'] -or -not $event.PSObject.Properties['stage']) { continue }
                $s.LastEvent=ConvertTo-FederatedUtc $event.timestamp
                if ($event.kind -eq 'wait') { $s.LastText=$event.detail; continue }
                # All SQL extraction steps use stage=extract. The detail and
                # completed fields distinguish CARE_SITE from the cohort query.
                if ($null -eq $s.Event -or $s.Event.stage -ne $event.stage -or
                    $s.Event.detail -ne $event.detail -or $s.Event.completed -ne $event.completed) {
                    $s.StageSince=$s.LastEvent
                }
                $s.Event=$event; $s.LastText=''
            }
            $now=[DateTime]::UtcNow
            $worker=@($Workers | Where-Object { $_.Role -eq $s.Role })
            $process=$null
            $s.Cpu='?'
            if ($null -ne $s.ObservedExitCode) { $s.ProcessState="exited($($s.ObservedExitCode))" }
            elseif ($s.Role -eq 'verification' -and $null -eq $s.Event -and $null -eq $s.LastProcessId) {
                $s.ProcessState=if($Final){'not started'}else{'not started (awaiting model roles)'}
            } elseif ($Final) { $s.ProcessState='not observed after cleanup' }
            else { $s.ProcessState='not observed (not started/exited/legacy)' }
            if ($worker.Count -and $worker[0].PSObject.Properties['Process']) { $process=$worker[0].Process }
            $finalExit=$null
            if ($worker.Count -and $worker[0].PSObject.Properties['FinalExitCode']) {
                $finalExit=$worker[0].FinalExitCode
            }
            if ($null -ne $finalExit) {
                $s.ObservedExitCode=$finalExit
                $s.ProcessState="exited($finalExit)"
                $s.LastCpuAt=$null
            } elseif ($null -ne $process) {
                try {
                    $process.Refresh()
                    $runtimePid=$null
                    if ($null -ne $s.Event -and $s.Event.PSObject.Properties['pid']) { $runtimePid=$s.Event.pid }
                    # Older Rscript.exe launchers own a wrapper, not the Rterm
                    # that writes progress. Never label wrapper CPU as R CPU.
                    if ($null -ne $runtimePid -and $runtimePid -ne $process.Id) {
                        $s.ProcessState="runtime PID=$runtimePid not verified (launcher PID=$($process.Id))"
                        $s.LastCpuAt=$null
                    } elseif ($process.HasExited) {
                        $s.ObservedExitCode=$process.ExitCode
                        $s.ProcessState="exited($($process.ExitCode))"
                        $s.LastCpuAt=$null
                    }
                    else {
                        if ($s.LastProcessId -ne $process.Id) { $s.LastCpuAt=$null }
                        $s.LastProcessId=$process.Id
                        $s.ProcessState="alive PID=$($process.Id)"
                        $cpuTime=$process.TotalProcessorTime
                        if ($null -ne $cpuTime) {
                            $cpu=$cpuTime.TotalSeconds
                            if ($null -ne $s.LastCpuAt -and ($now-$s.LastCpuAt).TotalSeconds -gt 0) {
                                $s.Cpu=('{0:F1}%' -f ([Math]::Max(0,100*($cpu-$s.LastCpu)/($now-$s.LastCpuAt).TotalSeconds)))
                            }
                            $s.LastCpu=$cpu; $s.LastCpuAt=$now
                        }
                    }
                } catch { $s.ProcessState='process unavailable'; $s.LastCpuAt=$null }
            } else { $s.LastCpuAt=$null }
            if ($s.ProcessState.StartsWith('exited(')) { $finished++ }
            $logAt=$null
            foreach($c in @($s.Stdout,$s.Stderr)) {
                if ([IO.File]::Exists($c.Path)) {
                    $at=[IO.File]::GetLastWriteTimeUtc($c.Path)
                    if ($null -eq $logAt -or $at -gt $logAt) { $logAt=$at }
                }
            }
            $now=[DateTime]::UtcNow
            $logAge=if($null -eq $logAt){'?'}else{[string](Get-FederatedElapsedSeconds $now $logAt)+'s'}
            $eventAge=if($null -eq $s.LastEvent){'?'}else{[string](Get-FederatedElapsedSeconds $now $s.LastEvent)+'s'}
            $allowEta=($null -ne $s.LastEvent -and ($now-$s.LastEvent).TotalSeconds -lt 10 -and
                -not $s.LastText -and $s.ProcessState.StartsWith('alive'))
            $view=Get-FederatedProgressDisplay $s.Event $allowEta
            $line="[$($s.Role)] $($s.ProcessState); CPU(core)=$($s.Cpu); last log=${logAge}; last event=${eventAge}; step elapsed=$(Get-FederatedElapsedSeconds $now $s.StageSince)s | $($view.Text)"
            if ($s.LastText) { $line += " | $($s.LastText)" }
            if ($statusDue) { Write-FederatedMonitorLine $Monitor $line }
            if (-not $Monitor.NoProgress) {
                Write-Progress -Id (100+$index) -ParentId 100 -Activity $s.Role -Status $view.Text `
                    -CurrentOperation "$($s.ProcessState); CPU(core)=$($s.Cpu); last log=${logAge}" `
                    -PercentComplete $view.Percent -SecondsRemaining $view.Eta
            }
        }
        $now=[DateTime]::UtcNow
        if ($statusDue) {
            Write-FederatedMonitorLine $Monitor "Elapsed=$(Get-FederatedElapsedSeconds $now $Monitor.Started)s; overall ETA unknown. Alive/CPU/log age do not prove SQL is advancing."
            $Monitor.LastStatus=$now
        }
        if (-not $Monitor.NoProgress) {
            Write-Progress -Id 100 -Activity 'FederatedPS - overall duration unknown' `
                -Status "$finished/$($Monitor.States.Count) processes exited; elapsed=$(Get-FederatedElapsedSeconds $now $Monitor.Started)s" `
                -PercentComplete -1 -SecondsRemaining -1
        }
    } catch {
        $Monitor.Disabled=$true
        Write-Warning 'Live monitor disabled after an I/O/display error. Computation continues; inspect per-role log files.'
    }
}
function Complete-FederatedMonitor($Monitor) {
    if ($null -eq $Monitor -or $Monitor.NoProgress) { return }
    for($i=1;$i -le $Monitor.States.Count;$i++) { Write-Progress -Id (100+$i) -Activity $Monitor.States[$i-1].Role -Completed }
    Write-Progress -Id 100 -Activity 'FederatedPS' -Completed
}
