#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot='C:\FederatedPS', [string]$RHome='C:\Program Files\R\R-4.6.1',
      [string]$JavaHome='', [string]$ConfigDirectory='',
      [ValidateRange(1,300)][int]$SmallQueryTimeoutSeconds=30)
. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot 'Monitor.ps1')
$runtime=Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
$project=Get-FederatedProject
if (-not $ConfigDirectory) { $ConfigDirectory=Join-Path $PSScriptRoot 'config' }
$out=Join-Path $project ('work\diagnostics\connection-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $out -Force | Out-Null
$roleOut=Join-Path $out 'diagnostic'
New-Item -ItemType Directory -Path $roleOut | Out-Null
$config=[ordered]@{project=$project;configDirectory=[IO.Path]::GetFullPath($ConfigDirectory);
    output=$roleOut;smallQueryTimeout=$SmallQueryTimeoutSeconds;dbQueryTimeout=$SmallQueryTimeoutSeconds;
    careSites=(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config\yuhs-sites.json') -Raw | ConvertFrom-Json)}
$configFile=Join-Path $out 'diagnostic.json'
[IO.File]::WriteAllText($configFile,($config | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
$workers=@();$monitor=New-FederatedMonitor -RunDirectory $out -Roles @('diagnostic') -NoProgress
try {
    $workers+=Start-FederatedRWorker -Runtime $runtime -Script (Join-Path $PSScriptRoot 'diagnose-db.R') `
        -Arguments @($configFile) -WorkingDirectory $project -LogPrefix (Join-Path $roleOut 'run') -Role diagnostic
    Wait-FederatedWorkers $workers (60+4*($SmallQueryTimeoutSeconds+15)) $monitor
    Write-Host "PASS: diagnostic completed. Logs: $out" -ForegroundColor Green
} finally {
    Stop-FederatedWorkers $workers
    Update-FederatedMonitor $monitor $workers -Force -Final
    Complete-FederatedMonitor $monitor
}
