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
Write-Host 'PASS: live shared-file reading, partial UTF-8/JSON, percent/ETA scope, real child logs and exit propagation.'
