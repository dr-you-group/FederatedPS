#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$project = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('fps yuhs routing ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $temp 'config') -Force | Out-Null
try {
    foreach ($file in @('Run-FederatedPS.ps1','Run-YUHS.ps1','Monitor.ps1')) {
        Copy-Item (Join-Path $project "windows\$file") (Join-Path $temp $file)
    }
    Copy-Item (Join-Path $project 'windows\config\yuhs-sites.json') (Join-Path $temp 'config\yuhs-sites.json')
    # Stub OS/runtime/process boundaries, leaving the real launcher routing intact.
    @'
$ErrorActionPreference = 'Stop'
function Get-FederatedProject { $PSScriptRoot }
function Assert-FederatedNames { param($RunId,$Sites) }
function Set-FederatedEnvironment { param($InstallRoot,$RHome,$JavaHome); @{Rscript='unused'} }
function Invoke-FederatedR { param($Rscript,$Arguments) }
function Start-FederatedRWorker { param($Runtime,$Script,$Arguments,$WorkingDirectory,$LogPrefix,$Role)
    if ($Role -eq 'verification') { [IO.File]::WriteAllText((Join-Path (Split-Path (Split-Path $LogPrefix -Parent) -Parent) 'SUCCESS.txt'),'fixture') }
    [pscustomobject]@{ Role=$Role }
}
function Wait-FederatedWorkers { param($Workers,$TimeoutSeconds)
    if ($Workers.Count -notin @(4,5)) { throw 'Expected four model workers, then verification.' }
}
function Stop-FederatedWorkers { param($Workers) }
'@ | Set-Content -LiteralPath (Join-Path $temp 'Common.ps1') -Encoding UTF8
    $run = Join-Path $temp 'Run-YUHS.ps1'
    & $run -WorkDirectory (Join-Path $temp 'default') -ExchangeDirectory (Join-Path $temp 'exchange')
    $json = Get-ChildItem -Path (Join-Path $temp 'default') -Filter run.json -Recurse
    $config = Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json
    if ($config.initialTimeout -ne 21600 -or $config.smallQueryTimeout -ne 60 -or $config.dbQueryTimeout -ne 7200) { throw 'Timeout defaults lost.' }
    if ($config.mode -ne 'SyntheticCDM' -or -not $config.test) { throw 'Default must select synthetic CDM.' }
    & $run -Test $true -BlockSize 4 -Alpha 0.5 -InitialTimeoutSeconds 9000 -SmallQueryTimeoutSeconds 45 -DbQueryTimeoutSeconds 1200 -WorkDirectory (Join-Path $temp 'explicit') -ExchangeDirectory (Join-Path $temp 'exchange')
    $json = Get-ChildItem -Path (Join-Path $temp 'explicit') -Filter run.json -Recurse
    $config = Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json
    if ($config.initialTimeout -ne 9000 -or $config.smallQueryTimeout -ne 45 -or $config.dbQueryTimeout -ne 1200) { throw 'Explicit timeout settings lost.' }
    if ($config.mode -ne 'SyntheticCDM' -or $config.blockSize -ne 4 -or $config.alpha -ne 0.5) { throw 'Parameters lost.' }
    # Even an existing malformed DB configuration must be ignored in test mode.
    'not a connection file' | Set-Content (Join-Path $temp 'config\yuhs.Renviron')
    & $run -Test $true -WorkDirectory (Join-Path $temp 'malformed') -ExchangeDirectory (Join-Path $temp 'exchange')
    Remove-Item (Join-Path $temp 'config\yuhs.Renviron')
    $failed = $false
    try { & $run -Test $false } catch { $failed = $_.Exception.Message -match 'yuhs.Renviron' }
    if (-not $failed) { throw 'Test=false must require the real connection file, without synthetic fallback.' }
    # The R/DB boundary is stubbed above: this checks routing, not connectivity.
    'fixture-only settings' | Set-Content (Join-Path $temp 'config\yuhs.Renviron')
    & $run -Test $false -WorkDirectory (Join-Path $temp 'database') -ExchangeDirectory (Join-Path $temp 'exchange')
    $json = Get-ChildItem -Path (Join-Path $temp 'database') -Filter run.json -Recurse
    $config = Get-Content -LiteralPath $json.FullName -Raw | ConvertFrom-Json
    if ($config.mode -ne 'Database' -or $config.test -or $config.dataset -ne 'YUHS') {
        throw 'Test=false with a settings file must select the real YUHS database path.'
    }
    $failed = $false
    try { & $run -Test $true -Scenario studySpecific } catch { $failed = $_.Exception.Message -match 'Scenario=default' }
    if (-not $failed) { throw 'Unsupported sample scenarios must fail.' }
    Write-Host 'PASS: default/explicit Test=true bypass DB configuration; Test=false selects DB; unsupported sample scenario fails.'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
