#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('jdbc','odbc')][string]$DbBackend,
    [ValidateSet('Synthetic','SyntheticCDM','Database','Design')][string]$Mode = 'Synthetic',
    [switch]$NoProgress,
    [ValidateRange(1,3600)][int]$StatusSeconds = 15,
    [bool]$Test = $false,
    [ValidateSet('YUHS','Example')][string]$Dataset = 'YUHS',
    [string[]]$Sites = @(),
    [string]$RunId = ([guid]::NewGuid().ToString('N')),
    [string]$Study = 'ppi',
    [ValidateSet('default','studySpecific')][string]$Scenario = 'default',
    [ValidateRange(1,1000000)][int]$BlockSize = 1,
    [ValidateRange(0.000001,1.0)][double]$Alpha = 1.0,
    [ValidateRange(0.000000000001,0.01)][double]$Tolerance = 0.000001,
    [ValidateRange(1,2147483647)][int]$ExchangeTimeoutSeconds = 3600,
    [ValidateRange(1,2147483647)][int]$InitialTimeoutSeconds = 21600,
    [ValidateRange(1,86400)][int]$SmallQueryTimeoutSeconds = 60,
    [ValidateRange(1,2147483647)][int]$DbQueryTimeoutSeconds = 7200,
    [ValidateRange(1,2147483647)][int]$RunTimeoutSeconds = 86400,
    [string]$ConfigDirectory = '', [string]$DesignDirectory = '',
    [string]$WorkDirectory = '', [string]$ExchangeDirectory = '',
    [string]$InstallRoot = 'C:\FederatedPS',
    [string]$RHome = 'C:\Program Files\R\R-4.6.1', [string]$JavaHome = ''
)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Monitor.ps1')
. (Join-Path $PSScriptRoot 'ConnectionWatchdog.ps1')
if ($Test) { $Mode = 'SyntheticCDM' }
if ($Mode -eq 'SyntheticCDM' -and ($Dataset -ne 'YUHS' -or $Study -cne 'ppi' -or $Scenario -ne 'default')) {
    throw 'The synthetic YUHS CDM smoke test requires Dataset=YUHS, Study=ppi, Scenario=default.'
}
$careSites = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config\yuhs-sites.json') -Encoding UTF8 -Raw | ConvertFrom-Json
if ($Sites.Count -eq 0) {
    $Sites = if ($Dataset -eq 'YUHS') { @($careSites.PSObject.Properties.Name) } else { @('mimic','synpuf','ehrshot') }
}
Assert-FederatedNames $RunId $Sites
if ($Mode -eq 'SyntheticCDM') {
    $expectedSites = @('severance','gangnam','yongin')
    if ($Sites.Count -ne 3 -or @($expectedSites | Where-Object { $_ -cnotin $Sites }).Count -ne 0) {
        throw 'The synthetic YUHS CDM smoke test runs severance, gangnam and yongin together.'
    }
    foreach ($site in $expectedSites) {
        if ($careSites.$site -ne (1 + [array]::IndexOf($expectedSites, $site))) {
            throw 'The bundled sample requires severance=1, gangnam=2, yongin=3.'
        }
    }
    Write-Host 'TEST=true: invented YUHS CDM sample only; no DB settings, DB connection or HIWARE login used.' -ForegroundColor Cyan
} elseif ($Mode -eq 'Database') {
    Write-Host 'TEST=false: real database run. YUHS requires the authorized HIWARE session and DB settings.' -ForegroundColor Yellow
}
$project = Get-FederatedProject
$runtime = Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path $PSScriptRoot 'config' }
if (-not $WorkDirectory) { $WorkDirectory = Join-Path $project 'work\windows' }
if (-not $ExchangeDirectory) { $ExchangeDirectory = Join-Path $project 'exchange\windows' }
if ($Mode -eq 'Database') {
    if ($Dataset -eq 'YUHS') {
        foreach ($site in $Sites) {
            if ($site -cnotin @($careSites.PSObject.Properties.Name)) { throw "Unknown YUHS site: $site" }
        }
        if (-not (Test-Path -LiteralPath (Join-Path $ConfigDirectory 'yuhs.Renviron') -PathType Leaf)) {
            throw 'Copy yuhs.Renviron.example to yuhs.Renviron and set the SQL Server connection.'
        }
    } else {
        foreach ($site in $Sites) {
            if (-not (Test-Path -LiteralPath (Join-Path $ConfigDirectory "$site.Renviron") -PathType Leaf)) {
                throw "Missing $site.Renviron in $ConfigDirectory. Copy and edit the example for this site."
            }
        }
    }
}
if ($Mode -eq 'Design') {
    if (-not $DesignDirectory) { throw 'Design mode requires -DesignDirectory.' }
    foreach ($site in $Sites) {
        if (-not (Test-Path -LiteralPath (Join-Path $DesignDirectory "$site.rds") -PathType Leaf)) { throw "Missing design for $site." }
    }
}
Invoke-FederatedRuntimeCheck -Runtime $runtime -Project $project -DbBackend $DbBackend -ConfigDirectory $ConfigDirectory
$output = [IO.Path]::GetFullPath((Join-Path $WorkDirectory $RunId))
$exchange = [IO.Path]::GetFullPath((Join-Path $ExchangeDirectory $RunId))
if ((Test-Path -LiteralPath $output) -or (Test-Path -LiteralPath $exchange)) {
    throw 'This RunId already has an output or exchange directory. Choose a new RunId; existing results are never overwritten.'
}
New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $ExchangeDirectory -Force | Out-Null
# New-Item without -Force also guards against another launcher claiming this ID.
New-Item -ItemType Directory -Path $output -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $exchange -ErrorAction Stop | Out-Null
$config = [ordered]@{
    project = $project; mode = $Mode; test = ($Mode -eq 'SyntheticCDM'); dataset = $Dataset; runId = $RunId; sites = @($Sites)
    careSites = $(if ($Dataset -eq 'YUHS') { $careSites } else { $null })
    study = $Study; scenario = $Scenario; blockSize = $BlockSize; alpha = $Alpha
    tolerance = $Tolerance; exchangeTimeout = $ExchangeTimeoutSeconds
    initialTimeout = $InitialTimeoutSeconds; smallQueryTimeout = $SmallQueryTimeoutSeconds
    dbQueryTimeout = $DbQueryTimeoutSeconds; runTimeout = $RunTimeoutSeconds
    output = $output; exchange = $exchange
    configDirectory = [IO.Path]::GetFullPath($ConfigDirectory)
    designDirectory = $(if ($DesignDirectory) { [IO.Path]::GetFullPath($DesignDirectory) } else { '' })
}
if($DbBackend){$config['dbBackend']=$DbBackend.ToLowerInvariant()}
$configFile = Join-Path $output 'run.json'
# Windows PowerShell's UTF8 encoder adds a BOM; jsonlite input should be BOM-free.
[IO.File]::WriteAllText($configFile, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'preflight.R'), $configFile)
$workers = @()
$monitor = New-FederatedMonitor -RunDirectory $output -Roles (@('aggregator') + $Sites + @('verification')) -NoProgress:$NoProgress -StatusSeconds $StatusSeconds
$dbWatchdog=$null
if($Mode -eq 'Database' -and $Dataset -eq 'YUHS'){
    $dbWatchdog=New-FederatedDbWatchdog -RunDirectory $output -RunId $RunId -Sites $Sites `
        -TimeoutSeconds 180 -OperationTimeoutSeconds ($SmallQueryTimeoutSeconds+15) `
        -ClinicalOperationTimeoutSeconds $DbQueryTimeoutSeconds -SiteDirectoryLayout roles
}
$runStarted = [DateTime]::UtcNow
try {
    # Site workers load connection settings themselves. The aggregator must not
    # inherit database credentials from the invoking PowerShell session.
    $connectionKeys = @('PGHOST','PGPORT','PGDATABASE','PGUSER','PGPASSWORD','CDM_DATABASE_SCHEMA',
        'DBMS','DB_SERVER','DB_PORT','DB_DATABASE','DB_USER','DB_PASSWORD')
    $savedConnection = @{}
    foreach ($key in $connectionKeys) {
        $savedConnection[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
    try {
        foreach ($role in (@('aggregator') + $Sites)) {
            $roleOutput = Join-Path $output $role
            New-Item -ItemType Directory -Path $roleOutput | Out-Null
            $workers += Start-FederatedRWorker -Runtime $runtime -Script (Join-Path $PSScriptRoot 'run-role.R') -Arguments @($configFile, $role) `
                -WorkingDirectory $project -LogPrefix (Join-Path $roleOutput 'run') -Role $role
        }
    } finally {
        foreach ($key in $connectionKeys) { [Environment]::SetEnvironmentVariable($key, $savedConnection[$key], 'Process') }
    }
    Write-FederatedProcessMetadata $output $workers
    Write-Host "Run $RunId started. Live logs and status below. Files: $output"
    Write-Host "Timeouts (seconds): initial/feature negotiation=$InitialTimeoutSeconds; exchange=$ExchangeTimeoutSeconds; small DB query=$SmallQueryTimeoutSeconds; bulk DB statement=$DbQueryTimeoutSeconds; whole run=$RunTimeoutSeconds"
    Wait-FederatedWorkers $workers $RunTimeoutSeconds $monitor $dbWatchdog
    Write-FederatedMonitorLine $monitor 'All model roles exited successfully. Starting final result verification.'
    $verification = Join-Path $output 'verification'
    New-Item -ItemType Directory -Path $verification | Out-Null
    $workers += Start-FederatedRWorker -Runtime $runtime -Script (Join-Path $PSScriptRoot 'verify-results.R') -Arguments @($configFile) `
        -WorkingDirectory $project -LogPrefix (Join-Path $verification 'run') -Role 'verification'
    Write-FederatedProcessMetadata $output $workers
    $remaining = [Math]::Max(1, $RunTimeoutSeconds - [int]([DateTime]::UtcNow-$runStarted).TotalSeconds)
    Wait-FederatedWorkers $workers $remaining $monitor
    if (-not (Test-Path -LiteralPath (Join-Path $output 'SUCCESS.txt'))) { throw 'Verification exited without SUCCESS.txt.' }
    Write-FederatedMonitorLine $monitor "PASS: all roles and final verification completed. Results: $output"
    [IO.File]::WriteAllText((Join-Path $output 'run-status.json'), '{"state":"success"}')
} catch {
    $runFailure=$_
    [IO.File]::WriteAllText((Join-Path $output 'run-status.json'), '{"state":"failed"}')
    # Capture the original live workers before cleanup; no SQL admin permission
    # or heap/patient-data dump is involved. Each JVM attach is time-bounded.
    $collector=Join-Path $PSScriptRoot 'Collect-RunDiagnostics.ps1'
    if ($Mode -eq 'Database' -and (Test-Path -LiteralPath $collector)) {
        try { & $collector -RunDirectory $output -JavaHome $env:JAVA_HOME }
        catch { Write-Warning "Diagnostic collection failed: $($_.Exception.Message). Original analysis error follows." }
    }
    throw $runFailure
} finally {
    Stop-FederatedWorkers $workers
    Update-FederatedMonitor $monitor $workers -Force -Final
    Complete-FederatedMonitor $monitor
}
