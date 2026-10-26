#Requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$fresh=Join-Path $project 'windows/fresh'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-fresh-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    # RUN forwards the exact requested options and never starts analysis after a failed local check.
    Copy-Item (Join-Path $fresh 'RUN.ps1') $temp
    Copy-Item (Join-Path $fresh '04_TEST_SYNTHETIC.ps1') $temp
    Copy-Item (Join-Path $fresh '05_RUN_YUHS.ps1') $temp
    New-Item -ItemType Directory -Path (Join-Path $temp 'FederatedPS/windows') -Force | Out-Null
    @'
param($InstallRoot)
if($global:FailFreshCheck){throw 'fixture render hang'}
$global:FreshCalls.Add('render-check')
'@ | Set-Content (Join-Path $temp '03_VERIFY_RUNTIME.ps1')
    @'
param($InstallRoot,[bool]$Test,$Study,$Scenario,$Methods,$PatientLimits,$ExtractionWorkers,$StatusSeconds)
$global:FreshCalls.Add('analysis')
[pscustomobject]@{root=$InstallRoot;test=$Test;study=$Study;scenario=$Scenario;methods=$Methods;limits=$PatientLimits;workers=$ExtractionWorkers;status=$StatusSeconds}
'@ | Set-Content (Join-Path $temp 'FederatedPS/windows/Run-YUHS.ps1')
    @'
param($InstallRoot)
$global:FreshCalls.Add('package-update')
if($global:FailFreshUpdate){throw 'fixture package update failure'}
'@ | Set-Content (Join-Path $temp '10_UPDATE_PACKAGE.ps1')
    $global:FailFreshUpdate=$false
    $global:FreshCalls=New-Object 'System.Collections.Generic.List[string]'
    $global:FailFreshCheck=$false
    $result=& (Join-Path $temp 'RUN.ps1') -InstallRoot 'fixture-root'
    if (($global:FreshCalls -join ',') -ne 'render-check,analysis' -or $result.test -or
        $result.study -ne 'ppi' -or $result.scenario -ne 'default' -or
        ($result.methods -join ',') -ne 'local-only,pooled' -or $result.workers -ne 1 -or $result.status -ne 10 -or
        $result.limits[1] -ne 2 -or $result.limits[2] -ne 2 -or $result.limits[3] -ne 2 -or $result.root -ne 'fixture-root') {
        throw 'RUN options/order changed.'
    }
    $custom=& (Join-Path $temp 'RUN.ps1') -PatientLimits @{1=20;2=10;3=30}
    if($custom.limits[1] -ne 20 -or $custom.limits[2] -ne 10 -or $custom.limits[3] -ne 30){throw 'Per-site override lost'}
    $global:FreshCalls.Clear()
    & (Join-Path $temp 'RUN.ps1') -UpdatePackage | Out-Null
    if(($global:FreshCalls -join ',') -ne 'package-update,render-check,analysis'){throw 'UpdatePackage order changed'}
    $global:FreshCalls.Clear();$global:FailFreshUpdate=$true
    $caught=$false;try{& (Join-Path $temp 'RUN.ps1') -UpdatePackage | Out-Null}catch{$caught=$true}
    if(-not $caught -or ($global:FreshCalls -join ',') -ne 'package-update'){throw 'Failed update did not stop RUN'}
    $global:FailFreshUpdate=$false
    $global:FreshCalls.Clear();$global:FailFreshCheck=$true
    $caught=$false;try { & (Join-Path $temp 'RUN.ps1') | Out-Null } catch { $caught=$true }
    if(-not $caught -or $global:FreshCalls.Count){throw 'Failed rendering did not stop RUN.'}
    $global:FailFreshCheck=$false
    $synthetic=& (Join-Path $temp '04_TEST_SYNTHETIC.ps1')
    if(-not $synthetic.test -or ($synthetic.methods -join ',') -ne 'local-only,pooled'){throw 'Synthetic route touched real DB mode.'}

    # SETUP preserves order and stops immediately on an installation error.
    # Post-install updates bypass bundle integrity and invoke the pure-R updater,
    # preserving the install root without recompiling Cyclops/dependencies.
    $updateRoot=Join-Path $temp 'update-fixture'
    New-Item -ItemType Directory -Path (Join-Path $updateRoot 'support') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $updateRoot 'FederatedPS/windows') -Force | Out-Null
    Copy-Item (Join-Path $fresh '10_UPDATE_PACKAGE.ps1') $updateRoot
    @'
function Assert-FreshWindows { $global:FreshCalls.Add('windows') }
function Assert-FreshNoR { $global:FreshCalls.Add('no-r') }
function Test-FreshManifest { throw 'Package update must not invoke bundle integrity checks' }
function Get-FreshJavaHome { 'fixture-java' }
'@ | Set-Content (Join-Path $updateRoot 'support/Fresh.Common.ps1')
    @'
param($InstallRoot,$JavaHome)
if($InstallRoot -ne 'fixture-install' -or $JavaHome -ne 'fixture-java'){throw 'Update lost runtime paths'}
$global:FreshCalls.Add('pure-r-update')
if($global:FailFreshCheck){throw 'fixture package install failure'}
'@ | Set-Content (Join-Path $updateRoot 'FederatedPS/windows/Update-FederatedPs.ps1')
    $global:FreshCalls.Clear()
    & (Join-Path $updateRoot '10_UPDATE_PACKAGE.ps1') -InstallRoot fixture-install
    if(($global:FreshCalls -join ',') -ne 'windows,no-r,pure-r-update'){throw 'Wrong update sequence'}
    $global:FreshCalls.Clear();$global:FailFreshCheck=$true
    $caught=$false;try { & (Join-Path $updateRoot '10_UPDATE_PACKAGE.ps1') -InstallRoot fixture-install } catch {$caught=$true}
    if(-not $caught -or 'pure-r-update' -notin $global:FreshCalls){throw 'Package installer failure was not propagated'}
    $global:FailFreshCheck=$false

    Copy-Item (Join-Path $fresh 'SETUP.ps1') $temp
    $stages=@('00_VERIFY','01_INSTALL_RUNTIME','02_INSTALL_PACKAGES','03_VERIFY_RUNTIME','04_TEST_SYNTHETIC')
    foreach($stage in $stages) {
        "param(`$InstallRoot,[switch]`$SkipRStudio)`n`$global:FreshCalls.Add('$stage')`nif(`$global:FailFreshStage -eq '$stage'){throw 'fixture install failure'}" |
            Set-Content (Join-Path $temp ($stage+'.ps1'))
    }
    $global:FreshCalls.Clear();$global:FailFreshStage=''
    & (Join-Path $temp 'SETUP.ps1')
    if(($global:FreshCalls -join ',') -ne ($stages -join ',')){throw 'Wrong setup order.'}
    $global:FreshCalls.Clear();$global:FailFreshStage='02_INSTALL_PACKAGES'
    $caught=$false;try { & (Join-Path $temp 'SETUP.ps1') } catch { $caught=$true }
    if(-not $caught -or ($global:FreshCalls -join ',') -ne '00_VERIFY,01_INSTALL_RUNTIME,02_INSTALL_PACKAGES'){throw 'Setup continued after failure.'}

    # Configuration is explicit SSL-off for this deployment and preserves an existing file byte-for-byte.
    Copy-Item (Join-Path $fresh '06_CONFIGURE_DB.ps1') $temp
    New-Item -ItemType Directory -Path (Join-Path $temp 'FederatedPS/windows/config') -Force | Out-Null
    $settings=Join-Path $temp 'FederatedPS/windows/config/yuhs.Renviron'
    'DB_SERVER=' | Set-Content ($settings+'.example')
    & (Join-Path $temp '06_CONFIGURE_DB.ps1') -NoEditor
    if((Get-Content $settings -Raw) -notmatch 'DB_ENCRYPT=false'){throw 'SSL choice lost.'}
    'DB_PASSWORD=fixture-only' | Add-Content $settings
    $before=(Get-FileHash $settings).Hash
    & (Join-Path $temp '06_CONFIGURE_DB.ps1') -NoEditor
    if((Get-FileHash $settings).Hash -ne $before){throw 'Existing configuration overwritten.'}

    # Transfer validation rejects malformed paths before opening them.
    . (Join-Path $fresh 'support/Fresh.Common.ps1')
    foreach($path in @('../escape','nested/../../escape')) {
        $caught=$false;try{Get-FreshPayloadPath $temp $path | Out-Null}catch{$caught=$true}
        if(-not $caught){throw 'Unsafe path accepted.'}
    }

    # Baseline diagnostics include operation logs, not credentials or patient files.
    Copy-Item (Join-Path $fresh '09_COLLECT_DIAGNOSTICS.ps1') $temp
    Copy-Item (Join-Path $fresh 'support') $temp -Recurse
    Copy-Item (Join-Path $project 'windows/RunDiagnostics.Common.ps1') (Join-Path $temp 'FederatedPS/windows')
    $run=Join-Path $temp 'fixture-run'
    $site=Join-Path $run 'baselines/severance/sql-diagnostics'
    New-Item -ItemType Directory -Path $site -Force | Out-Null
    '{"runId":"Fixture123","methods":["local-only","pooled"],"password":"do-not-copy"}' | Set-Content (Join-Path $run 'run.json')
    'fixture rendering started' | Set-Content (Join-Path $site 'operations.tsv')
    'fixture first failure' | Set-Content (Join-Path $site 'probe-events.tsv')
    'SELECT 1' | Set-Content (Join-Path $site '001.sql')
    'SECRET' | Set-Content (Join-Path $run 'yuhs.Renviron')
    'PATIENTS' | Set-Content (Join-Path $site 'patients.rds')
    & (Join-Path $temp '09_COLLECT_DIAGNOSTICS.ps1') -RunDirectory $run -SkipThreads
    $zipFile=Get-ChildItem (Join-Path $temp 'diagnostic-exports') -Filter '*.zip'
    $zip=[IO.Compression.ZipFile]::OpenRead($zipFile.FullName)
    try {
        $entries=@($zip.Entries.FullName)
        if(-not ($entries -match 'probe-events.tsv$') -or -not ($entries -match 'operations.tsv$') -or -not ($entries -match '001.sql$') -or
           ($entries -match '\.Renviron$|\.rds$|/run.json$')) {throw 'Diagnostic allowlist changed.'}
        $entry=@($zip.Entries | Where-Object {$_.Name -eq 'run-summary.json'})[0]
        $reader=New-Object IO.StreamReader($entry.Open())
        try {$summary=$reader.ReadToEnd()} finally {$reader.Dispose()}
        if($summary -match 'password|do-not-copy'){throw 'Unapproved run settings exported.'}
    } finally {$zip.Dispose()}
    # Exercise the real supervisor timeout and cleanup with one owned child.
    # The child is PowerShell rather than R; production R/Windows still needs host validation.
    $commonSource=(Join-Path $project 'windows/Common.ps1').Replace("'","''")
    @"
. '$commonSource'
function Start-FederatedRWorker {
    param(`$Runtime,`$Script,`$Arguments,`$WorkingDirectory,`$LogPrefix,`$Role)
    `$worker=Start-FederatedWorker -Executable `$Runtime.Rscript -Arguments @('-NoProfile','-File',(Join-Path `$WorkingDirectory 'hang.ps1')) -WorkingDirectory `$WorkingDirectory -LogPrefix `$LogPrefix -Role `$Role
    `$global:FreshOwnedPid=`$worker.Process.Id
    `$worker
}
"@ | Set-Content (Join-Path $temp 'FederatedPS/windows/Common.ps1')
    'Start-Sleep -Seconds 30' | Set-Content (Join-Path $temp 'hang.ps1')
    function Get-FreshRuntime {
        $exe=@('powershell.exe','pwsh.exe','pwsh') | ForEach-Object {Join-Path $PSHOME $_} | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
        [pscustomobject]@{Rscript=$exe}
    }
    $savedJava=$env:JAVA_HOME
    try {
        $env:JAVA_HOME=$temp
        $caught=$false
        $failureText='No exception'
        try { Invoke-FreshRenderCheck -Root $temp -TimeoutSeconds 1 } catch {
            $failureText=$_.Exception.Message
            $caught=$_.Exception.Message -match 'Local rendering preflight failed.*timed out'
        }
        if(-not $caught){throw "Rendering timeout did not stop the preflight: $failureText"}
        if(Get-Process -Id $global:FreshOwnedPid -ErrorAction SilentlyContinue){throw 'Timed-out preflight child still running.'}
    } finally { $env:JAVA_HOME=$savedJava }
    Write-Host 'PASS: fresh setup/failure gating, RUN options, synthetic isolation, SSL config, safe paths, diagnostic allowlist, owned preflight timeout cleanup.'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Variable FreshCalls,FailFreshCheck,FailFreshStage,FreshOwnedPid -Scope Global -ErrorAction SilentlyContinue
}
