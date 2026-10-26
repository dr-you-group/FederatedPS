#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Common.ps1')
. (Join-Path $PSScriptRoot '../Monitor.ps1')
. (Join-Path $PSScriptRoot '../SitePreparation.ps1')
. (Join-Path $PSScriptRoot '../ConnectionWatchdog.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('site-workers-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$child=Join-Path $root 'child.ps1'
@'
param($ConfigFile,$Site)
$c=Get-Content $ConfigFile -Raw | ConvertFrom-Json
$start=[DateTime]::UtcNow
if($c.runId -eq 'sqlhang') {
    $d=Join-Path $c.output ('extraction/'+$Site);New-Item -ItemType Directory -Path $d -Force | Out-Null
    @{runId=$c.runId;site=$Site;pid=$PID;id='render1';status='started';
        label='Rendering SitePartition.sql before DB connection';startedUtc=$start.ToString('o')} |
        ConvertTo-Json | Set-Content (Join-Path $d 'sql-prepare-state.json')
    Start-Sleep -Seconds 20
}
if($c.runId -in @('dbhang','dbready')) {
    $d=Join-Path $c.output ('extraction/'+$Site);New-Item -ItemType Directory -Path $d -Force | Out-Null
    $record=@{runId=$c.runId;site=$Site;pid=$PID;startedUtc=$start.ToString('o')}
    $record | ConvertTo-Json | Set-Content (Join-Path $d 'db-startup-start.json.partial')
    Move-Item (Join-Path $d 'db-startup-start.json.partial') (Join-Path $d 'db-startup-start.json')
    $record['phase']='Connection self-check: JDBC executeQuery'
    $record | ConvertTo-Json | Set-Content (Join-Path $d 'db-startup-phase.json')
    if($c.runId -eq 'dbready') {
        $record['state']='checks-passed'
        $record | ConvertTo-Json | Set-Content (Join-Path $d 'db-startup-ready.json.partial')
        Move-Item (Join-Path $d 'db-startup-ready.json.partial') (Join-Path $d 'db-startup-ready.json')
    } else {Start-Sleep -Seconds 20}
}
if($c.runId -eq 'fail' -and $Site -eq '17'){exit 7}
Start-Sleep -Milliseconds 1200
if($c.runId -ne 'missing') {
    $id=if($c.runId -eq 'stale'){'other'}else{$c.runId}
    $entry=if($c.runId -eq 'badname'){'../wrong.ready'}else{'entry-fixture'+$Site+'.ready'}
    @{runId=$id;site=$Site;state='extraction-complete';entryName=$entry;reused=$false;patients=20} |
        ConvertTo-Json | Set-Content (Join-Path $c.output ($Site+'/preparation-complete.json'))
}
@{site=$Site;start=$start.ToString('o');end=[DateTime]::UtcNow.ToString('o')} |
    ConvertTo-Json | Set-Content (Join-Path $c.output ($Site+'/interval.json'))
if($c.runId -eq 'hang'){Start-Sleep -Seconds 20}
if($c.runId -eq 'latefail' -and $Site -eq '17'){exit 9}
'@ | Set-Content $child
$testShell=Join-Path $PSHOME 'pwsh'
if(-not(Test-Path $testShell)){$testShell=Join-Path $PSHOME 'pwsh.exe'}
if(-not(Test-Path $testShell)){$testShell=Join-Path $PSHOME 'powershell.exe'}
function Start-FederatedRWorker {
    param($Runtime,$Script,$Arguments,$WorkingDirectory,$LogPrefix,$Role)
    Start-FederatedWorker -Executable $testShell -Arguments (@('-NoProfile','-File',$child)+$Arguments) `
        -WorkingDirectory $root -LogPrefix $LogPrefix -Role $Role
}
try {
    foreach($case in @('ok1','ok2','ok3','dbready','dbhang','sqlhang','fail','latefail','missing','stale','badname','hang','timeout')) {
        $directory=Join-Path $root $case;New-Item -ItemType Directory -Path $directory | Out-Null
        $config=Join-Path $directory 'run.json'
        @{runId=$case;output=$directory} | ConvertTo-Json | Set-Content $config
        $m=New-FederatedMonitor $directory @('17','42','99') -NoProgress -StatusSeconds 60
        $guard=New-FederatedDbWatchdog $directory $case @('17','42','99') 1 -SqlPreparationTimeoutSeconds 1
        $workers=@();$errorMessage=''
        try {
            $seconds=if($case -eq 'timeout'){1}else{25}
            $limit=if($case -match '^ok([123])$'){[int]$Matches[1]}else{2}
            Invoke-FederatedSitePreparation -Project $root -ConfigFile $config -RunDirectory $directory `
                -Sites @('17','42','99') -MaxWorkers $limit -Deadline ([DateTime]::UtcNow.AddSeconds($seconds)) `
                -ShutdownSeconds 1 -Monitor $m -Workers ([ref]$workers) -DbWatchdog $guard
        } catch {$errorMessage=$_.Exception.Message}
        finally {Stop-FederatedWorkers $workers}
        if($case -match '^ok' -or $case -eq 'dbready') {
            if($errorMessage){throw $errorMessage}
            if($workers.Count -ne 3 -or @($workers | Where-Object {$_.FinalExitCode -ne 0}).Count){throw 'Successful site workers not captured'}
            $intervals=@(Get-ChildItem $directory -Filter interval.json -Recurse | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json})
            $points=@();foreach($i in $intervals){$points+=,[pscustomobject]@{At=(ConvertTo-FederatedUtc $i.start);Delta=1};$points+=,[pscustomobject]@{At=(ConvertTo-FederatedUtc $i.end);Delta=-1}}
            $active=0;$peak=0
            foreach($point in @($points | Sort-Object At,Delta)){$active+=$point.Delta;$peak=[Math]::Max($peak,$active)}
            if($peak -ne $limit){throw "Expected overlap of $limit workers; got $peak"}
        } else {
            $expected=@{dbhang='DB startup exceeded 1s.*JDBC executeQuery';sqlhang='Local SQL preparation exceeded 1s';fail='exit 7';latefail='exit 9';missing='without an extraction receipt';stale='Invalid extraction receipt';badname='Invalid extraction receipt';hang='did not exit normally';timeout='Whole-run timeout'}[$case]
            if($errorMessage -notmatch $expected){throw "Wrong $case failure: $errorMessage"}
            if($workers.Count -gt 2){throw 'Started queued work after failure'}
            foreach($w in $workers){if($null -eq $w.FinalExitCode){throw 'Owned worker not reaped after failure'}}
        }
    }
    Write-Host 'PASS: real process concurrency 1/2/3; numeric IDs; receipt plus normal-exit gate; early/late native failures, missing/stale/unsafe receipts, shutdown/run timeouts, queue cancellation and owned cleanup'
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
