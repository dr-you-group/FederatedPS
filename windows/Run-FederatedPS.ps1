#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Synthetic','Database','Design')][string]$Mode = 'Synthetic',
    [string[]]$Sites = @('mimic','synpuf'),
    [string]$RunId = ([guid]::NewGuid().ToString('N')),
    [string]$Study = 'ppi',
    [ValidateSet('default','studySpecific')][string]$Scenario = 'default',
    [ValidateRange(1,1000000)][int]$BlockSize = 1,
    [ValidateRange(0.000001,1.0)][double]$Alpha = 1.0,
    [ValidateRange(0.000000000001,0.01)][double]$Tolerance = 0.000001,
    [ValidateRange(1,2147483647)][int]$ExchangeTimeoutSeconds = 3600,
    [ValidateRange(1,2147483647)][int]$RunTimeoutSeconds = 86400,
    [string]$ConfigDirectory = '', [string]$DesignDirectory = '',
    [string]$WorkDirectory = '', [string]$ExchangeDirectory = '',
    [string]$InstallRoot = 'C:\FederatedPS',
    [string]$RHome = 'C:\Program Files\R\R-4.6.1', [string]$JavaHome = ''
)
. (Join-Path $PSScriptRoot 'Common.ps1')
Assert-FederatedNames $RunId $Sites
$project = Get-FederatedProject
$runtime = Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path $PSScriptRoot 'config' }
if (-not $WorkDirectory) { $WorkDirectory = Join-Path $project 'work\windows' }
if (-not $ExchangeDirectory) { $ExchangeDirectory = Join-Path $project 'exchange\windows' }
if ($Mode -eq 'Database') {
    foreach ($site in $Sites) {
        if (-not (Test-Path -LiteralPath (Join-Path $ConfigDirectory "$site.Renviron") -PathType Leaf)) {
            throw "Missing $site.Renviron in $ConfigDirectory. Copy and edit the example for this site."
        }
    }
}
if ($Mode -eq 'Design') {
    if (-not $DesignDirectory) { throw 'Design mode requires -DesignDirectory.' }
    foreach ($site in $Sites) {
        if (-not (Test-Path -LiteralPath (Join-Path $DesignDirectory "$site.rds") -PathType Leaf)) { throw "Missing design for $site." }
    }
}
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'verify.R'), $project)
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
    project = $project; mode = $Mode; runId = $RunId; sites = @($Sites)
    study = $Study; scenario = $Scenario; blockSize = $BlockSize; alpha = $Alpha
    tolerance = $Tolerance; exchangeTimeout = $ExchangeTimeoutSeconds
    output = $output; exchange = $exchange
    configDirectory = [IO.Path]::GetFullPath($ConfigDirectory)
    designDirectory = $(if ($DesignDirectory) { [IO.Path]::GetFullPath($DesignDirectory) } else { '' })
}
$configFile = Join-Path $output 'run.json'
# Windows PowerShell's UTF8 encoder adds a BOM; jsonlite input should be BOM-free.
[IO.File]::WriteAllText($configFile, ($config | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'preflight.R'), $configFile)
$workers = @()
try {
    # Each hospital loads its own file. The aggregator must not inherit a
    # previous hospital's PG* credentials from the invoking PowerShell session.
    $connectionKeys = @('PGHOST','PGPORT','PGDATABASE','PGUSER','PGPASSWORD','CDM_DATABASE_SCHEMA')
    $savedConnection = @{}
    foreach ($key in $connectionKeys) {
        $savedConnection[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
    try {
        foreach ($role in (@('aggregator') + $Sites)) {
            $roleOutput = Join-Path $output $role
            New-Item -ItemType Directory -Path $roleOutput | Out-Null
            $workers += Start-FederatedWorker -Executable $runtime.Rscript -Arguments @('--vanilla', (Join-Path $PSScriptRoot 'run-role.R'), $configFile, $role) `
                -WorkingDirectory $project -LogPrefix (Join-Path $roleOutput 'run') -Role $role
        }
    } finally {
        foreach ($key in $connectionKeys) { [Environment]::SetEnvironmentVariable($key, $savedConnection[$key], 'Process') }
    }
    Write-Host "Run $RunId started. Logs: $output"
    Wait-FederatedWorkers $workers $RunTimeoutSeconds
} finally {
    Stop-FederatedWorkers $workers
}
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'verify-results.R'), $configFile)
Write-Host "PASS: all roles completed. Results: $output" -ForegroundColor Green
