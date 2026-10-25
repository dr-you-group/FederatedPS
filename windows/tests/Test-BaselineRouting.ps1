#Requires -Version 5.1
$ErrorActionPreference='Stop'
$project=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-methods-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $temp 'config') -Force | Out-Null
try {
    Copy-Item (Join-Path $project 'windows\Run-YUHS-Methods.ps1') $temp
    Copy-Item (Join-Path $project 'windows\ConnectionWatchdog.ps1') $temp
    Copy-Item (Join-Path $project 'windows\config\yuhs-sites.json') (Join-Path $temp 'config\yuhs-sites.json')
    @'
$ErrorActionPreference='Stop'
function Get-FederatedProject {$PSScriptRoot}
function Assert-FederatedNames {param($RunId,$Sites)}
function Set-FederatedEnvironment {param($InstallRoot,$RHome,$JavaHome);$env:JAVA_HOME=$PSScriptRoot;@{Rscript='unused'}}
function Invoke-FederatedR {param($Rscript,$Arguments)}
function Start-FederatedRWorker {param($Runtime,$Script,$Arguments,$WorkingDirectory,$LogPrefix,$Role)
    $c=Get-Content $Arguments[0] -Raw | ConvertFrom-Json
    if($Role -eq 'baselines'){
        if($c.extractionWorkers -gt 1 -and -not(Test-Path (Join-Path $c.output 'prepared-sites.fixture'))){throw 'Models started before site preparation'}
        if($c.extractionWorkers -eq 1 -and (Test-Path (Join-Path $c.output 'prepared-sites.fixture'))){throw 'Sequential path launched site workers'}
        if($Script -notmatch 'run-baselines[.]R$'){throw 'Unexpected extraction worker'}
        if($c.PSObject.Properties['exchange']){throw 'Baseline must not configure exchange'}
        $folders=@()
        if('local-only' -in $c.methods){$folders+=@($c.sites | ForEach-Object {'local/'+$_})}
        if('pooled' -in $c.methods){$folders+='pooled'}
        foreach($folder in $folders){
            $d=Join-Path $c.output $folder;New-Item -ItemType Directory -Path $d -Force | Out-Null
            foreach($file in @('result.rds','model.rds','coefficients.csv')){Set-Content (Join-Path $d $file) 'fixture'}
        }
        if('federated' -in $c.methods){
            New-Item -ItemType Directory -Path (Join-Path $c.output 'prepared') | Out-Null
            foreach($site in $c.sites){Set-Content (Join-Path $c.output "prepared/$site.rds") 'same extracted input'}
        }
        Set-Content (Join-Path $c.output 'summary.csv') 'fixture'
        if($c.study -ne 'fixtureMissing'){
            @{runId=$c.runId;state='results-validated';models=$folders.Count;sites=$c.sites;methods=$c.methods} | ConvertTo-Json | Set-Content (Join-Path $c.output 'baselines-complete.json')
        }
    } elseif($Role -eq 'verification'){
        if($Script -notmatch 'finalize-methods[.]R$' -or -not(Test-Path (Join-Path $c.federatedOutput 'SUCCESS.txt'))){throw 'Bad federation ordering'}
        if($c.study -ne 'fixtureMissingMap'){
            $mappedId=if($c.study -eq 'fixtureBadMap'){'anotherRun'}else{$c.runId}
            @{runId=$mappedId;state='federated-mapped';sites=$c.sites} | ConvertTo-Json | Set-Content (Join-Path $c.output 'federated-mapped.json')
        }
    } else {throw 'Unexpected worker'}
    $p=[pscustomobject]@{HasExited=$true};$p | Add-Member ScriptMethod Refresh {}
    [pscustomobject]@{Process=$p;Role=$Role;Fail=($c.study -eq 'fixtureNativeFail')}
}
function Wait-FederatedWorkers {param($Workers,$TimeoutSeconds,$Monitor)
    if(@($Workers | Where-Object Role -eq baselines).Count -ne 1){throw 'Extraction must run exactly once'}
    if(@($Workers | Where-Object Fail).Count){throw 'Native exit 1'}
}
function Stop-FederatedWorkers {param($Workers)}
'@ | Set-Content (Join-Path $temp 'Common.ps1')
    @'
param($Mode,$Dataset,$Sites,$RunId,$Study,$Scenario,$BlockSize,$Alpha,$Tolerance,$ExchangeTimeoutSeconds,$InitialTimeoutSeconds,$RunTimeoutSeconds,$DesignDirectory,$WorkDirectory,$InstallRoot,$RHome,$JavaHome,[switch]$NoProgress,$ExchangeDirectory,[bool]$Test=$false)
if($Mode -ne 'Design' -or $Test){throw 'Federation must use prepared data, never re-extract'}
foreach($site in $Sites){if((Get-Content (Join-Path $DesignDirectory "$site.rds") -Raw).Trim() -ne 'same extracted input'){throw 'Wrong prepared design'}}
if($Study -eq 'fixtureFedFail'){throw 'Federated native failure'}
$out=Join-Path $WorkDirectory $RunId;New-Item -ItemType Directory -Path $out -Force | Out-Null
Set-Content (Join-Path $out 'SUCCESS.txt') 'verified fixture'
$PSBoundParameters | ConvertTo-Json | Set-Content (Join-Path $out 'forwarded.json')
'@ | Set-Content (Join-Path $temp 'Run-FederatedPS.ps1')
    @'
function New-FederatedMonitor {param($RunDirectory,$Roles,[switch]$NoProgress);@{}}
function Update-FederatedMonitor {param($Monitor,$Workers,[switch]$Force,[switch]$Final)}
function Complete-FederatedMonitor {param($Monitor)}
function Write-FederatedProcessMetadata {param($Directory,$Workers)}
'@ | Set-Content (Join-Path $temp 'Monitor.ps1')
    '' | Set-Content (Join-Path $temp 'RunDiagnostics.Common.ps1')
    @'
function Invoke-FederatedSitePreparation {
    param($Runtime,$Project,$ConfigFile,$RunDirectory,$Sites,$MaxWorkers,$Deadline,$ShutdownSeconds,$Monitor,[ref]$Workers)
    $c=Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if($MaxWorkers -ne $c.extractionWorkers -or $MaxWorkers -lt 2 -or $MaxWorkers -gt 3 -or ($Sites -join ',') -ne ($c.sites -join ',')){throw 'Wrong extraction concurrency/sites'}
    if($c.study -eq 'fixturePreparationFail'){throw 'Site preparation failed'}
    Set-Content (Join-Path $RunDirectory 'prepared-sites.fixture') $MaxWorkers
}
'@ | Set-Content (Join-Path $temp 'SitePreparation.ps1')
    $run=Join-Path $temp 'Run-YUHS-Methods.ps1'
    $work=Join-Path $temp 'work'
    & $run -RunId default -WorkDirectory $work
    $c=Get-Content (Join-Path $work 'default/run.json') -Raw | ConvertFrom-Json
    if($c.extractionWorkers -ne 1 -or $c.requestedExtractionWorkers -ne 1 -or $c.connectionCheckTimeout -ne 180){throw 'Wrong sequential/startup defaults'}
    if(-not $c.test -or $c.mode -ne 'SelectedMethods' -or $c.priorVariance -ne 1){throw 'Wrong defaults'}
    foreach($limits in @(@{other=200},@{2=1},@{1=-1},@{3=2.5},@{2=$null},@{3=$true},@{severance=200})){
        $bad=$false;try{& $run -PatientLimits $limits -WorkDirectory $work}catch{$bad=$_.Exception.Message -match 'PatientLimits'}
        if(-not $bad){throw 'Invalid per-site limit accepted'}
    }
    $caught=$false
    try{& $run -Test $false}catch{$caught=$_.Exception.Message -match 'yuhs.Renviron'}
    if(-not $caught){throw 'Real mode ignored missing config'}
    'fixture settings' | Set-Content (Join-Path $temp 'config/yuhs.Renviron')
    $selections=@('local-only','pooled','federated','local-only,pooled','local-only,federated','pooled,federated','local-only,pooled,federated')
    $i=0
    foreach($selection in $selections){
        $i++;$methods=$selection.Split(',');$id='choice'+$i
        & $run -Methods $methods -Test $false -RunId $id -WorkDirectory $work -BlockSize 4 -Alpha 0.5 -PatientLimit 200 -PatientLimits @{2=100;3=300} -CacheDirectory (Join-Path $temp 'cache') -RebuildData
        $out=Join-Path $work $id;$c=Get-Content (Join-Path $out 'run.json') -Raw | ConvertFrom-Json
        if($c.test -or $c.blockSize -ne 4 -or $c.alpha -ne 0.5 -or $c.patientLimits.'1' -ne 200 -or $c.patientLimits.'2' -ne 100 -or $c.patientLimits.'3' -ne 300 -or -not $c.rebuildData){throw 'Real routing/settings lost'}
        if(-not(Test-Path (Join-Path $out 'SUCCESS.txt'))){throw 'Missing success'}
        foreach($pair in @(@('local-only','local'),@('pooled','pooled'),@('federated','federated-runtime'))){
            if((Test-Path (Join-Path $out $pair[1])) -ne ($pair[0] -in $methods)){throw 'Wrong selected output'}
        }
        if('federated' -in $methods){
            $f=Get-Content (Join-Path $out "federated-runtime/$id/forwarded.json") -Raw | ConvertFrom-Json
            if($f.BlockSize -ne 4 -or $f.Alpha -ne 0.5 -or $f.Mode -ne 'Design'){throw 'Federated settings lost'}
        }
    }
    $caught=$false
    try{& $run -RunId default -WorkDirectory $work}catch{$caught=$_.Exception.Message -match 'already exists'}
    if(-not $caught){throw 'Existing run overwrite permitted'}
    foreach($case in @(@('fixturePreparationFail','Site preparation failed'),@('fixtureMissing','without verified'),@('fixtureNativeFail','Native exit'),@('fixtureFedFail','Federated native'),@('fixtureMissingMap','not mapped'),@('fixtureBadMap','Invalid federated mapping'))){
        $caught=$false;$id=$case[0]
        $concurrency=if($id -eq 'fixturePreparationFail'){3}else{1}
        try{& $run -Methods local-only,pooled,federated -Test $false -Study $id -RunId $id -WorkDirectory $work -ExtractionWorkers $concurrency}catch{$caught=$_.Exception.Message -match $case[1]}
        if(-not $caught -or (Test-Path (Join-Path $work "$id/SUCCESS.txt"))){throw "Failed completion accepted: $id"}
    }
    # IDs are read from configuration, never from hard-coded institution names.
    '{"gammaLabel":99,"alphaLabel":17,"betaLabel":42}' | Set-Content (Join-Path $temp 'config/yuhs-sites.json')
    & $run -Test $false -RunId customids -WorkDirectory $work -PatientLimits @{17=12;42=24;99=36}
    $c=Get-Content (Join-Path $work 'customids/run.json') -Raw | ConvertFrom-Json
    if(($c.sites -join ',') -ne '17,42,99' -or $c.patientLimits.'42' -ne 24 -or $c.careSites.'99' -ne 99){throw 'Hard-coded site names or limits'}
    & $run -Test $false -RunId customorder -WorkDirectory $work -Sites @('99','17','42')
    $c=Get-Content (Join-Path $work 'customorder/run.json') -Raw | ConvertFrom-Json
    if(($c.sites -join ',') -ne '99,17,42'){throw 'Explicit site order was not respected'}
    foreach($count in @(2,3)){
        & $run -Test $false -RunId ('workers'+$count) -WorkDirectory $work -ExtractionWorkers $count
        $c=Get-Content (Join-Path $work ('workers'+$count+'/run.json')) -Raw | ConvertFrom-Json
        if($c.extractionWorkers -ne $count){throw 'Concurrency override lost'}
    }
    '{"first":17,"second":42}' | Set-Content (Join-Path $temp 'config/yuhs-sites.json')
    & $run -Test $false -RunId twosites -WorkDirectory $work -ExtractionWorkers 3
    $c=Get-Content (Join-Path $work 'twosites/run.json') -Raw | ConvertFrom-Json
    if($c.extractionWorkers -ne 2 -or $c.requestedExtractionWorkers -ne 3){throw 'Workers not capped to configured site count'}
    Write-Host 'PASS: seven method combinations; default one preprocessing worker and explicit 2/3 overrides; model barrier; prepared federation; settings; native/preparation/missing/stale failure gates.'
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
