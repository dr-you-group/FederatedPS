#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('local-only','pooled','federated')][string[]]$Methods=@('local-only','pooled'),
    [ValidateRange(0,2147483647)][int]$PatientLimit=0,
    [hashtable]$PatientLimits=@{},
    [string]$CacheDirectory='', [switch]$RebuildData,
    [string[]]$Sites=@(),
    [bool]$Test=$true, [string]$Study='ppi',
    [ValidateSet('default','studySpecific')][string]$Scenario='default',
    [ValidateRange(1,1000000)][int]$BlockSize=1,
    [ValidateRange(0.000001,1.0)][double]$Alpha=1,
    [ValidateRange(0.000000000001,0.01)][double]$Tolerance=0.000001,
    [ValidateRange(1,86400)][int]$SmallQueryTimeoutSeconds=60,
    [ValidateRange(30,86400)][int]$ConnectionCheckTimeoutSeconds=180,
    [ValidateRange(1,2147483647)][int]$DbQueryTimeoutSeconds=7200,
    [ValidateRange(1,2147483647)][int]$ExchangeTimeoutSeconds=3600,
    [ValidateRange(1,2147483647)][int]$InitialTimeoutSeconds=21600,
    [ValidateRange(1,2147483647)][int]$RunTimeoutSeconds=86400,
    [ValidateRange(1,3600)][int]$ShutdownTimeoutSeconds=60,
    [string]$RunId=([guid]::NewGuid().ToString('N')), [switch]$NoProgress,
    [ValidateRange(1,3600)][int]$StatusSeconds=15,
    [ValidateRange(1,3)][int]$ExtractionWorkers=1,
    [string]$ConfigDirectory='', [string]$WorkDirectory='', [string]$ExchangeDirectory='',
    [string]$InstallRoot='C:\FederatedPS',
    [string]$RHome='C:\Program Files\R\R-4.6.1', [string]$JavaHome=''
)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Monitor.ps1')
. (Join-Path $PSScriptRoot 'RunDiagnostics.Common.ps1')
. (Join-Path $PSScriptRoot 'ConnectionWatchdog.ps1')
$project=Get-FederatedProject
if($PatientLimit -eq 1){throw 'PatientLimit must be 0 (unlimited) or at least 2 per institution.'}
if(-not $Methods.Count -or @($Methods | Sort-Object -Unique).Count -ne $Methods.Count){throw 'Select distinct Methods.'}
$Methods=@($Methods | ForEach-Object { $_.ToLowerInvariant() })
if(-not $ConfigDirectory){$ConfigDirectory=Join-Path $PSScriptRoot 'config'}
$mappingPath=Join-Path $ConfigDirectory 'yuhs-sites.json'
if(-not(Test-Path -LiteralPath $mappingPath)){$mappingPath=Join-Path $PSScriptRoot 'config\yuhs-sites.json'}
$mapping=Get-Content -LiteralPath $mappingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$careSites=[ordered]@{};$siteLabels=[ordered]@{}
foreach($property in $mapping.PSObject.Properties){
    $id=0L
    if(-not [long]::TryParse([string]$property.Value,[ref]$id) -or $id -lt 1 -or $id -gt 2147483647){throw 'yuhs-sites.json must map labels to positive integer CARE_SITE_IDs.'}
    $key=$id.ToString([Globalization.CultureInfo]::InvariantCulture)
    if($careSites.Contains($key)){throw 'Duplicate CARE_SITE_ID in yuhs-sites.json.'}
    $careSites[$key]=[int]$id;$siteLabels[$key]=$property.Name
}
$known=@($careSites.Keys | Sort-Object { [long]$_ })
if(-not $Sites.Count){$Sites=@($known)}
Assert-FederatedNames $RunId $Sites
if($Sites.Count -ne $known.Count -or @($Sites | Where-Object {$_ -cnotin $known}).Count){throw 'Sites must be all configured CARE_SITE_IDs, not institution names.'}
if($Test -and ($Sites.Count -ne 3 -or @($Sites | Where-Object {$_ -notin @('1','2','3')}).Count)){
    throw 'The bundled synthetic sample supports only CARE_SITE_IDs 1, 2, 3.'
}
$resolvedLimits=[ordered]@{}
foreach($site in $Sites){$resolvedLimits[$site]=$PatientLimit}
foreach($key in $PatientLimits.Keys){
    $site=[string]$key
    $value=$PatientLimits[$key];$parsed=0L
    if($site -notin $known){throw "Unknown PatientLimits site_id: $key"}
    if($null -eq $value -or $value -is [bool] -or -not [long]::TryParse([string]$value,[ref]$parsed) -or
        $parsed -lt 0 -or $parsed -eq 1 -or $parsed -gt 2147483647){
        throw "PatientLimits[$key] must be 0 (unlimited) or an integer of at least 2."
    }
    $resolvedLimits[$site]=[int]$parsed
}
$sites=$Sites
$effectiveWorkers=[Math]::Min($ExtractionWorkers,$sites.Count)
if($Test -and ($Study -cne 'ppi' -or $Scenario -ne 'default')) { throw 'Test=true supports only ppi/default.' }
if(-not $ConfigDirectory){$ConfigDirectory=Join-Path $PSScriptRoot 'config'}
if(-not $WorkDirectory){$WorkDirectory=Join-Path $project 'work\methods'}
if(-not $CacheDirectory){$CacheDirectory=Join-Path $project 'work\yuhs-cache'}
if(-not $Test -and -not (Test-Path -LiteralPath (Join-Path $ConfigDirectory 'yuhs.Renviron') -PathType Leaf)) {
    throw 'Test=false requires the existing yuhs.Renviron and authorized HIWARE connection.'
}
$runtime=Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'verify.R'),$project)
$out=[IO.Path]::GetFullPath((Join-Path $WorkDirectory $RunId))
if(Test-Path -LiteralPath $out){throw 'Run directory already exists. Choose a new RunId; results are never overwritten.'}
New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $out | Out-Null
$roleOut=Join-Path $out 'baselines'
New-Item -ItemType Directory -Path $roleOut | Out-Null
$config=[ordered]@{project=$project; runId=$RunId; mode='SelectedMethods'; methods=$Methods; dataset='YUHS'; test=$Test;
    extractionWorkers=$effectiveWorkers; requestedExtractionWorkers=$ExtractionWorkers;
    sites=$sites; careSites=$careSites; siteLabels=$siteLabels;
    study=$Study; scenario=$Scenario; blockSize=$BlockSize; alpha=$Alpha; tolerance=$Tolerance;
    patientLimits=$resolvedLimits; cacheDirectory=[IO.Path]::GetFullPath($CacheDirectory); rebuildData=[bool]$RebuildData;
    maxIterations=5000; priorVariance=1; smallQueryTimeout=$SmallQueryTimeoutSeconds;
    connectionCheckTimeout=$ConnectionCheckTimeoutSeconds;
    dbQueryTimeout=$DbQueryTimeoutSeconds; runTimeout=$RunTimeoutSeconds; shutdownTimeout=$ShutdownTimeoutSeconds;
    output=$out; configDirectory=[IO.Path]::GetFullPath($ConfigDirectory);
    federatedOutput=(Join-Path (Join-Path $out 'federated-runtime') $RunId)}
$configFile=Join-Path $out 'run.json'
[IO.File]::WriteAllText($configFile,($config | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
$roles=if($effectiveWorkers -gt 1){@($sites)+@('baselines')}else{@('baselines')}
$workers=@();$monitor=New-FederatedMonitor -RunDirectory $out -Roles $roles -NoProgress:$NoProgress -Sites $sites -SiteLabels $siteLabels -StatusSeconds $StatusSeconds
$dbWatchdog=New-FederatedDbWatchdog -RunDirectory $out -RunId $RunId -Sites $sites -TimeoutSeconds $ConnectionCheckTimeoutSeconds `
    -OperationTimeoutSeconds ($SmallQueryTimeoutSeconds+15) -StatusSeconds $StatusSeconds
try {
    $limitText=($sites | ForEach-Object {$_+'='+$resolvedLimits[$_]}) -join ', '
    Write-Host "Methods=$($Methods -join ','); Test=$Test; PatientLimits: $limitText (0=all); ExtractionWorkers=$effectiveWorkers; site queue: $($sites -join ' -> '); RebuildData=$RebuildData. Output: $out"
    if($effectiveWorkers -eq 1){Write-Host 'Preprocessing first: one R process prepares each site in order; all site inputs are validated before model fitting.'}
    $started=[DateTime]::UtcNow
    $deadline=$started.AddSeconds($RunTimeoutSeconds)
    if($effectiveWorkers -gt 1) {
        . (Join-Path $PSScriptRoot 'SitePreparation.ps1')
        Invoke-FederatedSitePreparation -Runtime $runtime -Project $project -ConfigFile $configFile -RunDirectory $out `
            -Sites $sites -MaxWorkers $effectiveWorkers -Deadline $deadline -ShutdownSeconds $ShutdownTimeoutSeconds `
            -Monitor $monitor -Workers ([ref]$workers) -DbWatchdog $dbWatchdog
    }
    if([DateTime]::UtcNow -ge $deadline){throw 'No whole-run time remains for baseline fitting.'}
    $baselineWorker=Start-FederatedRWorker -Runtime $runtime -Script (Join-Path $PSScriptRoot 'run-baselines.R') `
        -Arguments @($configFile) -WorkingDirectory $project -LogPrefix (Join-Path $roleOut 'run') -Role baselines
    $workers+=,$baselineWorker
    Write-FederatedProcessMetadata $out $workers
    $finishedAt=$null
    $marker=Join-Path $out 'baselines-complete.json'
    while($true){
        Update-FederatedDbWatchdog $dbWatchdog $workers
        Update-FederatedMonitor $monitor $workers
        $worker=$baselineWorker;$worker.Process.Refresh()
        if($worker.Process.HasExited){Wait-FederatedWorkers $workers 10 $monitor;break}
        if(-not $finishedAt -and (Test-Path -LiteralPath $marker)){$finishedAt=[DateTime]::UtcNow}
        if($finishedAt -and [DateTime]::UtcNow -ge $finishedAt.AddSeconds($ShutdownTimeoutSeconds)) {
            throw 'Model results were written, but the R process did not exit. SUCCESS was not written; inspect shutdown-thread.txt.'
        }
        if([DateTime]::UtcNow -ge $deadline){throw "Baseline run timed out after $RunTimeoutSeconds seconds."}
        Start-Sleep -Milliseconds 200
    }
    if(-not(Test-Path -LiteralPath $marker)){throw 'R exited without verified baseline results.'}
    $complete=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    $expectedModels=$(if('local-only' -in $Methods){$sites.Count}else{0})+$(if('pooled' -in $Methods){1}else{0})
    if($complete.runId -cne $RunId -or $complete.state -cne 'results-validated' -or $complete.models -ne $expectedModels -or
        (@($complete.methods) -join ',') -cne ($Methods -join ',') -or
        (@($complete.sites) -join ',') -cne ($sites -join ',')){throw 'Invalid baseline completion record.'}
    $folders=@()
    if('local-only' -in $Methods){$folders+=@($sites | ForEach-Object { 'local\'+$_ })}
    if('pooled' -in $Methods){$folders+='pooled'}
    foreach($folder in $folders){
        foreach($file in @('result.rds','model.rds','coefficients.csv')){
            if(-not(Test-Path -LiteralPath (Join-Path (Join-Path $out $folder) $file) -PathType Leaf)){
                throw "Missing baseline artifact: $folder\$file"
            }
        }
    }
    if(-not(Test-Path -LiteralPath (Join-Path $out 'summary.csv'))){throw 'Missing baseline summary.'}
    if('federated' -in $Methods){
        $remaining=$RunTimeoutSeconds-[int]([DateTime]::UtcNow-$started).TotalSeconds
        if($remaining -lt 1){throw 'No whole-run time remains for the selected federated fit.'}
        $fed=@{Mode='Design';Dataset='YUHS';Sites=$sites;RunId=$RunId;Study=$Study;Scenario=$Scenario;
            BlockSize=$BlockSize;Alpha=$Alpha;Tolerance=$Tolerance;ExchangeTimeoutSeconds=$ExchangeTimeoutSeconds;
            InitialTimeoutSeconds=$InitialTimeoutSeconds;RunTimeoutSeconds=$remaining;
            DesignDirectory=(Join-Path $out 'prepared');WorkDirectory=(Join-Path $out 'federated-runtime');
            InstallRoot=$InstallRoot;RHome=$RHome;JavaHome=$JavaHome;NoProgress=$NoProgress;StatusSeconds=$StatusSeconds}
        if($ExchangeDirectory){$fed['ExchangeDirectory']=$ExchangeDirectory}
        & (Join-Path $PSScriptRoot 'Run-FederatedPS.ps1') @fed
        $remaining=$RunTimeoutSeconds-[int]([DateTime]::UtcNow-$started).TotalSeconds
        if($remaining -lt 1){throw 'No whole-run time remains for federated result mapping.'}
        $verification=Join-Path $out 'verification'
        New-Item -ItemType Directory -Path $verification | Out-Null
        $workers+=Start-FederatedRWorker -Runtime $runtime -Script (Join-Path $PSScriptRoot 'finalize-methods.R') `
            -Arguments @($configFile) -WorkingDirectory $project -LogPrefix (Join-Path $verification 'run') -Role verification
        Write-FederatedProcessMetadata $out $workers
        Wait-FederatedWorkers $workers $remaining
        if(-not(Test-Path (Join-Path $out 'federated-mapped.json'))){throw 'Federated results were not mapped and verified.'}
        $mapped=Get-Content (Join-Path $out 'federated-mapped.json') -Raw | ConvertFrom-Json
        if($mapped.runId -cne $RunId -or $mapped.state -cne 'federated-mapped' -or
            (@($mapped.sites) -join ',') -cne ($sites -join ',')){throw 'Invalid federated mapping record.'}
    }
    [IO.File]::WriteAllText((Join-Path $out 'run-status.json'),'{"state":"success"}')
    [IO.File]::WriteAllText((Join-Path $out 'SUCCESS.txt'),"PASS: $($Methods -join ','); results verified and R workers exited normally.")
    Write-Host "PASS: selected methods complete. Results: $out" -ForegroundColor Green
} catch {
    $failure=$_
    [IO.File]::WriteAllText((Join-Path $out 'failure.txt'),$failure.Exception.Message,(New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $out 'run-status.json'),'{"state":"failed"}')
    if($workers.Count){
        try {
            $live=@($workers | Where-Object { $_.Process.Refresh(); -not $_.Process.HasExited })
            $jcmd=Join-Path $env:JAVA_HOME 'bin\jcmd.exe'
            foreach($w in $live) {
              if(Test-Path -LiteralPath $jcmd) {
                Invoke-RunDiagnosticThreadDump -Jcmd $jcmd -RuntimePid $w.Process.Id `
                    -OutputFile (Join-Path $out ("shutdown-thread-"+$w.Role+".txt")) -TimeoutSeconds 15
              }
            }
        } catch {Write-Warning "Could not collect JVM thread diagnostics: $($_.Exception.Message)"}
    }
    throw $failure
} finally {
    Stop-FederatedWorkers $workers
    Update-FederatedMonitor $monitor $workers -Force -Final
    Complete-FederatedMonitor $monitor
}
