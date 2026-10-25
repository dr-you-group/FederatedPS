#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
. (Join-Path $PSScriptRoot '..\Monitor.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('fps monitor '+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'site1') -Force | Out-Null
$path=Join-Path $root 'site1\run.stdout.log'
$writer=[IO.File]::Open($path,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try {
    $cursor=New-FederatedLogCursor $path
    # Split a multibyte character and a line across separate writes/reads.
    $bytes=[Text.Encoding]::UTF8.GetBytes(([string][char]0xC138)+'verance'+"`n")
    $writer.Write($bytes,0,1);$writer.Flush()
    if (@(Read-FederatedAppend $cursor).Count) { throw 'Partial UTF-8 line emitted.' }
    $writer.Write($bytes,1,$bytes.Length-1);$writer.Flush()
    $lines=@(Read-FederatedAppend $cursor)
    if ($lines.Count -ne 1 -or $lines[0] -cne (([string][char]0xC138)+'verance')) { throw 'Lost UTF-8 output or file-sharing failure.' }
    if (@(Read-FederatedAppend $cursor).Count) { throw 'Duplicate output.' }
} finally { $writer.Dispose() }
$m=New-FederatedMonitor $root @('site1') -NoProgress
$event=[ordered]@{kind='progress';stage='fitting';detail='CCD sweep 1';completed=4;total=10;
    unit='coordinates in this sweep';etaSeconds=6;timestamp=[DateTime]::UtcNow.ToString('o')}
$eventPath=Join-Path $root 'site1\progress.jsonl'
$line=ConvertTo-Json $event -Compress
[IO.File]::WriteAllText($eventPath,$line.Substring(0,10))
Update-FederatedMonitor $m -Force
if ($null -ne $m.States[0].Event -or $m.Disabled) { throw 'Partial event broke monitoring.' }
[IO.File]::AppendAllText($eventPath,$line.Substring(10)+"`n")
Update-FederatedMonitor $m -Force
$view=Get-FederatedProgressDisplay $m.States[0].Event
if ($m.Disabled -or $view.Percent -ne 40 -or $view.Eta -ne 6) { throw 'Current sweep percent/ETA failed.' }
if ((Get-FederatedProgressDisplay $m.States[0].Event $false).Eta -ne -1) { throw 'Stale ETA must be unknown.' }
$event.unit='extraction steps (not time)'
if ((Get-FederatedProgressDisplay ([pscustomobject]$event)).Eta -ne -1) { throw 'SQL step count is not a duration estimate.' }

# Regression: changing SQL detail inside stage=extract starts a new step clock.
$event.kind='stage'; $event.stage='extract'; $event.detail='CARE_SITE lookup'; $event.completed=0
$event.timestamp=[DateTime]::UtcNow.AddSeconds(-60).ToString('o')
[IO.File]::AppendAllText($eventPath,(ConvertTo-Json $event -Compress)+"`n")
Update-FederatedMonitor $m -Force
$event.detail='Building cohorts'; $event.completed=6
$event.timestamp=[DateTime]::UtcNow.AddSeconds(-5).ToString('o')
[IO.File]::AppendAllText($eventPath,(ConvertTo-Json $event -Compress)+"`n")
Update-FederatedMonitor $m -Force
if ($m.States[0].StageSince -ne (ConvertTo-FederatedUtc $event.timestamp)) {
    throw 'Extraction substep retained the entire extraction elapsed time.'
}
$event.detail='Fetching cohorts'
$event.timestamp=[DateTime]::UtcNow.ToString('o')
[IO.File]::AppendAllText($eventPath,(ConvertTo-Json $event -Compress)+"`n")
Update-FederatedMonitor $m -Force
if ($m.States[0].StageSince -ne (ConvertTo-FederatedUtc $event.timestamp)) {
    throw 'A detail-only SQL substep change did not reset its clock.'
}

# A file/event written after a refresh starts must never produce negative ages.
$event.timestamp=[DateTime]::UtcNow.AddSeconds(10).ToString('o')
$event.detail='Future timestamp fixture'
[IO.File]::AppendAllText($eventPath,(ConvertTo-Json $event -Compress)+"`n")
[IO.File]::SetLastWriteTimeUtc($path,[DateTime]::UtcNow.AddSeconds(10))
Update-FederatedMonitor $m -Force
$clockLog=[IO.File]::ReadAllText((Join-Path $root 'monitor.log'))
if ($clockLog -match '(last log|last event|step elapsed|Elapsed)=-[0-9]') {
    throw 'A refresh emitted a negative elapsed time.'
}

# Never infer R worker CPU from a legacy Rscript wrapper with a different PID.
$event.pid=4243
$event.timestamp=[DateTime]::UtcNow.ToString('o')
[IO.File]::AppendAllText($eventPath,(ConvertTo-Json $event -Compress)+"`n")
$fake=[pscustomobject]@{Id=4242; HasExited=$false; TotalProcessorTime=[TimeSpan]::FromSeconds(9)}
$fake | Add-Member ScriptMethod Refresh {}
Update-FederatedMonitor $m @([pscustomobject]@{Role='site1';Process=$fake}) -Force
if ($m.Disabled -or $m.States[0].Cpu -ne '?' -or $m.States[0].ProcessState -notmatch 'runtime PID=4243 not verified') {
    throw 'Legacy wrapper CPU was presented as the real R worker CPU.'
}

# Cleanup disposes handles. A captured final exit code must survive that cleanup.
$disposed=[pscustomobject]@{}
$disposed | Add-Member ScriptMethod Refresh { throw 'Disposed process accessed.' }
Update-FederatedMonitor $m @([pscustomobject]@{Role='site1';Process=$disposed;FinalExitCode=7}) -Force -Final
if ($m.Disabled -or $m.States[0].ProcessState -ne 'exited(7)' -or $m.States[0].Cpu -ne '?') {
    throw 'Final exit state was lost or disposed handles were read.'
}
Update-FederatedMonitor $m -Force -Final
if ($m.States[0].ProcessState -ne 'exited(7)') { throw 'Known exit code disappeared on final refresh.' }
$waiting=New-FederatedMonitor $root @('verification') -NoProgress
Update-FederatedMonitor $waiting -Force
if ($waiting.States[0].ProcessState -ne 'not started (awaiting model roles)') { throw 'Verification scheduling state is ambiguous.' }
Update-FederatedMonitor $waiting -Force -Final
if ($waiting.States[0].ProcessState -ne 'not started') { throw 'Final verification state still claims to be waiting.' }
[IO.File]::WriteAllText($eventPath,'')

$child=Join-Path $root 'child.ps1'
@'
[Console]::Out.WriteLine('live stdout')
[Console]::Error.WriteLine('live stderr')
Start-Sleep -Seconds 4
exit 7
'@ | Set-Content $child
$binary=if($env:OS -ne 'Windows_NT'){'pwsh'}elseif($PSVersionTable.PSEdition -eq 'Core'){'pwsh.exe'}else{'powershell.exe'}
$workers=@()
try {
    $workers+=Start-FederatedWorker (Join-Path $PSHOME $binary) @('-NoProfile','-File',$child) $root (Join-Path $root 'site1\run') 'site1'
    Write-FederatedProcessMetadata $root $workers
    $m=New-FederatedMonitor $root @('site1') -NoProgress
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    $live=$false
    while([DateTime]::UtcNow -lt $deadline -and -not $workers[0].Process.HasExited) {
        Update-FederatedMonitor $m $workers
        $text=[IO.File]::ReadAllText((Join-Path $root 'monitor.log'))
        if($text -match 'live stdout' -and $text -match 'live stderr') {$live=$true;break}
        Start-Sleep -Milliseconds 100
    }
    if(-not $live -or $workers[0].Process.HasExited) { throw 'Short log lines were buffered until process exit.' }
    $caught=$false
    try { Wait-FederatedWorkers $workers 10 $m } catch { if($_.Exception.Message -notmatch 'exit 7'){throw};$caught=$true }
    Update-FederatedMonitor $m $workers -Force -Final
    if (-not $caught -or $m.Disabled) { throw 'Monitoring hid a real child failure.' }
    $log=[IO.File]::ReadAllText((Join-Path $root 'monitor.log'))
    if ($log -notmatch 'live stdout' -or $log -notmatch 'live stderr' -or $log -notmatch 'alive PID=') { throw 'Missing live logs/heartbeat.' }
} finally { Stop-FederatedWorkers $workers }
@{sites=@('site1','site2')} | ConvertTo-Json | Set-Content (Join-Path $root 'run.json')
$before=@(Get-ChildItem $root -File -Recurse | ForEach-Object { (Get-FileHash $_.FullName).Hash }) -join ','
& (Join-Path $PSScriptRoot '..\Watch-FederatedRun.ps1') -RunDirectory $root -Once -NoProgress
$after=@(Get-ChildItem $root -File -Recurse | ForEach-Object { (Get-FileHash $_.FullName).Hash }) -join ','
if($before -cne $after) {throw 'Read-only watcher modified run files.'}

# Exercise the legacy-wrapper identity guard without needing CIM/Windows.
# Only the OS/process boundaries are stubbed; use the actual watcher function.
$watcherPath=Join-Path $PSScriptRoot '..\Watch-FederatedRun.ps1'
$watcherAst=[Management.Automation.Language.Parser]::ParseFile($watcherPath,[ref]$null,[ref]$null)
$guard=$watcherAst.Find({param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $a.Name -eq 'Get-FederatedWatchedProcess'},$true)
. ([scriptblock]::Create($guard.Extent.Text))
$RunDirectory=$root
$started=[DateTime]::UtcNow.AddMinutes(-1)
$entry=[pscustomobject]@{role='site1';pid=100;startUtc=$started.ToString('o')}
@{role='site1';pid=200;timestamp=$started.AddSeconds(5).ToString('o')} |
    ConvertTo-Json -Compress | Set-Content -LiteralPath $eventPath -Encoding UTF8
$identity=[pscustomobject]@{Name='Rscript.exe';CreationDate=$started.AddSeconds(1);
    CommandLine=('"Rscript.exe" --vanilla "/project/windows/run-role.R" "'+(Join-Path $root 'run.json')+'" "site1"')}
$actualStart=$identity.CreationDate
$previousOs=$env:OS
try {
    $env:OS='Windows_NT'
    function Get-Process([int]$Id) {
        $time=if($Id -eq 100){$started}else{$actualStart}
        $p=[pscustomobject]@{Id=$Id;StartTime=$time;Disposed=$false}
        $p | Add-Member ScriptMethod Dispose {$this.Disposed=$true}
        $p
    }
    function Get-CimInstance { param($ClassName,$Filter); $identity }
    $p=Get-FederatedWatchedProcess $entry
    if($p.Id -ne 200){throw 'Valid legacy interpreter identity was rejected.'}
    $identity.CreationDate=$started.AddSeconds(10)
    if((Get-FederatedWatchedProcess $entry).Id -ne 100){throw 'Reused PID creation time was accepted.'}
    $identity.CreationDate=$started.AddSeconds(1)
    $originalCommand=$identity.CommandLine
    $identity.CommandLine=$originalCommand.Replace('run.json','other-run.json')
    if((Get-FederatedWatchedProcess $entry).Id -ne 100){throw 'Another run was accepted.'}
    $identity.CommandLine=$originalCommand.Replace('"site1"','"site2"')
    if((Get-FederatedWatchedProcess $entry).Id -ne 100){throw 'Another role was accepted.'}
    $identity.CommandLine=$originalCommand
    $actualStart=$started.AddSeconds(20)
    if((Get-FederatedWatchedProcess $entry).Id -ne 100){throw 'PID reuse between CIM and handle lookup was accepted.'}
} finally {
    $env:OS=$previousOs
    Remove-Item Function:\Get-Process
    Remove-Item Function:\Get-CimInstance
}
Write-Host 'PASS: legacy runtime identity accepts the matching process and rejects reused PIDs, other runs and other roles.'
Write-Host 'PASS: live shared-file reading, partial UTF-8/JSON, step clocks, nonnegative ages, actual PID guard, final exit state, percent/ETA scope and real child logs.'
