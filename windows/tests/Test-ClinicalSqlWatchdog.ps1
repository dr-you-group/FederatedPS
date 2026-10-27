#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../Monitor.ps1')
. (Join-Path $PSScriptRoot '../ConnectionWatchdog.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('fps-clinical-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$now=[DateTime]::UtcNow
function Worker([string]$Role,[int]$RuntimeId) {
    $process=[pscustomobject]@{Id=$RuntimeId;HasExited=$false}
    $process | Add-Member ScriptMethod Refresh {}
    [pscustomobject]@{Role=$Role;Process=$process}
}
function Guard([string[]]$Sites=@('1','2','3'),[string]$Layout='extraction') {
    New-FederatedDbWatchdog -RunDirectory $root -RunId 'runODBC' -Sites $Sites `
        -ClinicalOperationTimeoutSeconds 120 -SiteDirectoryLayout $Layout
}
function Operation([string]$Site,[int]$RuntimeId,[int]$Age,[string]$Id='op1',[string]$Status='started') {
    @{runId='runODBC';site=$Site;pid=$RuntimeId;id=$Id;status=$Status;
        label='SitePartition.sql SQL 1/4';stage='extract';startedUtc=$now.AddSeconds(-$Age).ToString('o')}
}
function Write-Operation($Guard,$Record) {
    $directory=Get-FederatedDbSiteDirectory $Guard $Record.site
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $path=Join-Path $directory 'sql-operation-state.json'
    $Record | ConvertTo-Json | Set-Content -LiteralPath $path
    $path
}
function Assert-Failure([scriptblock]$Action,[string]$Pattern) {
    $message=''
    try { & $Action } catch { $message=$_.Exception.Message }
    if($message -notmatch $Pattern){throw "Expected failure '$Pattern'; got '$message'"}
}
try {
    # No DB work/cache-only paths do not acquire a spurious clinical deadline.
    $guard=Guard;$worker=Worker baselines 1001
    $guard.Ready['baselines:1']=$true
    Update-FederatedDbWatchdog $guard @($worker) $now
    $record=Operation '1' 1001 119
    $path=Write-Operation $guard $record
    Update-FederatedDbWatchdog $guard @($worker) $now
    # An incomplete snapshot preserves the original clock; no progress UI is used.
    '{' | Set-Content -LiteralPath $path
    Assert-Failure {Update-FederatedDbWatchdog $guard @($worker) $now.AddSeconds(2)} 'Database operation exceeded 120s.*site_id=1'
    $evidence=Get-Content -LiteralPath (Join-Path $root 'sql-operation-timeout-1.json') -Raw | ConvertFrom-Json
    if($evidence.pid -ne 1001 -or $evidence.operationId -cne 'op1' -or
       $evidence.elapsedSeconds -ne 121 -or $evidence.limitSeconds -ne 120){throw 'Wrong clinical timeout evidence'}
    if(-not(Test-Path -LiteralPath (Join-Path $root 'sql-operation-watchdog.log'))){throw 'Missing clinical status log'}
    # Successful completion stops the clock while later local model work runs.
    $record.status='completed';[void](Write-Operation $guard $record)
    Update-FederatedDbWatchdog $guard @($worker) $now.AddHours(2)
    # Closing a connection uses the short operation limit, not a two-hour SQL allowance.
    $record=Operation '1' 1001 76 'close'
    $record.stage='disconnecting';$record.label='Closing database connection'
    [void](Write-Operation $guard $record)
    Assert-Failure {Update-FederatedDbWatchdog $guard @($worker) $now} 'Database operation exceeded 75s.*Closing database connection'
    # A new id gets its own start. Repeated same-id snapshots cannot extend it.
    $record=Operation '1' 1001 1 'op2';[void](Write-Operation $guard $record)
    Update-FederatedDbWatchdog $guard @($worker) $now
    $record.startedUtc=$now.ToString('o');[void](Write-Operation $guard $record)
    Assert-Failure {Update-FederatedDbWatchdog $guard @($worker) $now} 'operation start changed'
    foreach($field in @('pid','site','runId')) {
        $guard=Guard;$guard.Ready['baselines:1']=$true
        $record=Operation '1' 1001 1
        $path=Write-Operation $guard $record
        $record[$field]=if($field -eq 'pid'){9999}else{'foreign'}
        $record | ConvertTo-Json | Set-Content -LiteralPath $path
        Assert-Failure {Update-FederatedDbWatchdog $guard @($worker) $now} 'Invalid clinical SQL marker identity'
    }
    # Sequential sites have separate clocks; a completed earlier site is inert.
    $guard=Guard;$guard.Ready['baselines:1']=$true;$guard.Ready['baselines:2']=$true
    [void](Write-Operation $guard (Operation '1' 1001 600 'site1' 'completed'))
    [void](Write-Operation $guard (Operation '2' 1001 121 'site2'))
    Assert-Failure {Update-FederatedDbWatchdog $guard @($worker) $now} 'Database operation exceeded 120s.*site_id=2'
    # Direct federated workers use root/site, rather than extraction/site.
    $guard=Guard @('3') 'roles';$siteWorker=Worker '3' 1003
    $guard.Ready['3:3']=$true
    [void](Write-Operation $guard (Operation '3' 1003 121 'direct'))
    Assert-Failure {Update-FederatedDbWatchdog $guard @($siteWorker) $now} 'Database operation exceeded 120s.*site_id=3'
    $siteWorker.Process.HasExited=$true
    Update-FederatedDbWatchdog $guard @($siteWorker) $now.AddHours(1)
    # First observation of a valid ready marker must also check current SQL.
    $guard=Guard @('3') 'roles';$siteWorker.Process.HasExited=$false
    $directory=Get-FederatedDbSiteDirectory $guard '3'
    $start=@{runId='runODBC';site='3';pid=1003;startedUtc=$now.AddSeconds(-200).ToString('o')}
    $start | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'db-startup-start.json')
    $start.state='checks-passed'
    $start | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $directory 'db-startup-ready.json')
    Assert-Failure {Update-FederatedDbWatchdog $guard @($siteWorker) $now} 'Database operation exceeded 120s.*site_id=3'
    Write-Host 'PASS: clinical SQL deadline after DB ready; unchanged clock; partial writes; completion; identity; sequential sites; roles layout; exited workers'
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
