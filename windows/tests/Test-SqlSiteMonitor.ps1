#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Monitor.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('site-progress-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $root 'baselines/sites') -Force | Out-Null
try {
    $now=[DateTime]::UtcNow
    $op=[ordered]@{id='sql-2';status='started';startedUtc=$now.AddSeconds(-40).ToString('o');
        elapsedSeconds=0;sqlFile='local.sql';rowsAffected=$null;rowsFetched=$null;
        statementIndex=2;statementCount=7;statementsCompleted=1;
        historyEstimate=@{seconds=120;samples=3}}
    $e=[ordered]@{kind='stage';stage='extract';detail='Index membership';completed=1;total=10;
        unit='extraction steps (not time)';etaSeconds=$null;timestamp=$now.ToString('o');
        siteId='17';siteState='extracting';operation=[pscustomobject]$op;role='baselines'}
    $v=Get-FederatedProgressDisplay ([pscustomobject]$e) $false $now
    if($v.Percent -ne 14 -or $v.Eta -ne 80 -or $v.Text -notmatch '00:00:40'){throw 'Statement progress / historical ETA wrong'}
    $v=Get-FederatedProgressDisplay ([pscustomobject]$e) $false $now.AddSeconds(100)
    if($v.Eta -ne -1 -or $v.Text -notmatch 'exceeded'){throw 'Overdue SQL must not claim zero remaining'}
    $op.historyEstimate=$null;$e.operation=[pscustomobject]$op
    if((Get-FederatedProgressDisplay ([pscustomobject]$e)).Eta -ne -1){throw 'Cold SQL invented an ETA'}
    $e | ConvertTo-Json -Depth 6 -Compress | Set-Content (Join-Path $root 'baselines/sites/17.json')
    $m=New-FederatedMonitor $root @('baselines') -Sites @('17','42','99') -SiteLabels @{17='A';42='B';99='C'} -NoProgress
    Update-FederatedMonitor $m -Force
    if($m.Disabled -or $m.SiteStates[0].State -ne 'extracting' -or $m.SiteStates[1].State -ne 'queued'){throw 'Site snapshot / queued status failed'}
    $e.siteId='42';$e.siteState='data-ready (cache)';$e.operation=$null;$e.stage='cache-hit'
    $e | ConvertTo-Json -Depth 6 -Compress | Set-Content (Join-Path $root 'baselines/sites/42.json')
    $e.siteId='17';$e.siteState='local-fitting';$e.stage='fitting';$e.unit='coordinates in this sweep';$e.completed=4;$e.total=10;$e.etaSeconds=6
    $e | ConvertTo-Json -Depth 6 -Compress | Set-Content (Join-Path $root 'baselines/sites/17.json')
    Update-FederatedMonitor $m -Force
    if($m.SiteStates[0].State -ne 'local-fitting' -or $m.SiteStates[1].State -ne 'data-ready (cache)' -or $m.SiteStates[2].State -ne 'queued'){throw 'Independent site state was lost'}
    # Partial snapshots leave last valid state intact.
    '{' | Set-Content (Join-Path $root 'baselines/sites/17.json')
    Update-FederatedMonitor $m -Force
    if($m.Disabled -or $m.SiteStates[0].State -ne 'local-fitting'){throw 'Partial snapshot disabled monitor'}
    # Concurrent roles keep independent snapshots and native exit states.
    foreach($id in @('17','42')) {
        $d=Join-Path $root ($id+'/sites');New-Item -ItemType Directory -Path $d -Force | Out-Null
        $e.siteId=$id;$e.role=$id;$e.siteState='extracting';$e.stage='extract';$e.timestamp=[DateTime]::UtcNow.ToString('o')
        $e | ConvertTo-Json -Depth 6 -Compress | Set-Content (Join-Path $d ($id+'.json'))
    }
    $parallel=New-FederatedMonitor $root @('17','42','99','baselines') -Sites @('17','42','99') -NoProgress
    $failed=[pscustomobject]@{Role='17';FinalExitCode=7}
    Update-FederatedMonitor $parallel @($failed) -Force
    if($parallel.Disabled -or $parallel.SiteStates[0].State -ne 'failed/stopped' -or
        $parallel.SiteStates[1].State -ne 'extracting' -or $parallel.SiteStates[2].State -ne 'queued'){throw 'Parallel site failure/status isolation failed'}
    @{mode='SelectedMethods';extractionWorkers=3;sites=@('17','42','99');siteLabels=@{'17'='A';'42'='B';'99'='C'}} |
        ConvertTo-Json | Set-Content (Join-Path $root 'run.json')
    $before=@(Get-ChildItem $root -File -Recurse | Sort-Object FullName | ForEach-Object {(Get-FileHash $_.FullName).Hash}) -join ','
    & (Join-Path $PSScriptRoot '../Watch-FederatedRun.ps1') -RunDirectory $root -Once -NoProgress
    $after=@(Get-ChildItem $root -File -Recurse | Sort-Object FullName | ForEach-Object {(Get-FileHash $_.FullName).Hash}) -join ','
    if($before -cne $after){throw 'Selected-method watcher wrote run files'}
    Write-Host 'PASS: independent numeric site states, partial snapshots, live SQL clock, honest cold/overdue ETA, read-only selected-method watcher'
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
