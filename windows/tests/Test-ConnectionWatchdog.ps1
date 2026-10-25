#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Monitor.ps1')
. (Join-Path $PSScriptRoot '../ConnectionWatchdog.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('fps-startup-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$now=[DateTime]::UtcNow
function FixtureWorker([string]$Role,$RuntimeId) {
    $p=[pscustomobject]@{Id=$RuntimeId;HasExited=$false};$p | Add-Member ScriptMethod Refresh {}
    [pscustomobject]@{Role=$Role;Process=$p}
}
function Marker($Site,$RuntimeId,$Age) {
    $d=Join-Path $root ('extraction/'+$Site);New-Item -ItemType Directory -Path $d -Force | Out-Null
    $record=@{runId='run1';site=$Site;pid=$RuntimeId;startedUtc=$now.AddSeconds(-$Age).ToString('o')}
    $record | ConvertTo-Json | Set-Content (Join-Path $d 'db-startup-start.json')
    $record
}
try {
    $g=New-FederatedDbWatchdog $root run1 @('17','42','99') 180
    $a=FixtureWorker 17 1001;$b=FixtureWorker 42 1002
    Update-FederatedDbWatchdog $g @($a,$b) $now # Cache/sample mode has no markers.
    $record=Marker 17 1001 179
    Update-FederatedDbWatchdog $g @($a,$b) $now
    '{' | Set-Content (Join-Path $root 'extraction/17/db-startup-phase.json')
    $caught=$false
    try{Update-FederatedDbWatchdog $g @($a,$b) $now.AddSeconds(2)}catch{$caught=$_.Exception.Message -match 'DB startup exceeded 180s.*site_id=17'}
    if(-not $caught -or -not(Test-Path (Join-Path $root 'db-startup-timeout-17.json'))){throw 'Missing independent timeout evidence'}
    # Readiness clears the guard even when the clinical query outlasts 180s.
    $record['state']='checks-passed'
    $record | ConvertTo-Json | Set-Content (Join-Path $root 'extraction/17/db-startup-ready.json')
    Update-FederatedDbWatchdog $g @($a,$b) $now.AddHours(1)
    # Sequential baseline process checks each site's independent startup clock.
    $g=New-FederatedDbWatchdog $root run1 @('42','99') 180
    $baseline=FixtureWorker baselines 1003
    $record=Marker 42 1003 181
    $caught=$false
    try{Update-FederatedDbWatchdog $g @($baseline) $now}catch{$caught=$_.Exception.Message -match 'site_id=42'}
    if(-not $caught){throw 'Sequential startup not guarded'}
    # A completion from a different run/process cannot waive a current deadline.
    $record['state']='checks-passed';$record['pid']=9999
    $record | ConvertTo-Json | Set-Content (Join-Path $root 'extraction/42/db-startup-ready.json')
    $caught=$false
    try{Update-FederatedDbWatchdog $g @($baseline) $now}catch{$caught=$_.Exception.Message -match 'Invalid DB startup completion'}
    if(-not $caught){throw 'Stale completion was accepted'}
    $g=New-FederatedDbWatchdog $root wrongRun @('17') 180
    $caught=$false
    try{Update-FederatedDbWatchdog $g @($a) $now}catch{$caught=$_.Exception.Message -match 'Invalid DB startup marker identity'}
    if(-not $caught){throw 'Foreign start marker accepted'}
    Write-Host 'PASS: startup deadline independent of progress; atomic start/ready identity; malformed optional phase; no DB/sample/cache path; sequential and parallel roles; long clinical work exempt'
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
