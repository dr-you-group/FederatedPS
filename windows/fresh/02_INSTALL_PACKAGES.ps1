#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS')
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Assert-FreshWindows
Assert-FreshNoR
Test-FreshManifest $PSScriptRoot
$runtime = Get-FreshRuntime $PSScriptRoot $InstallRoot -PrepareDirectories
. (Join-Path $PSScriptRoot 'FederatedPS\windows\Common.ps1')
$logs = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
Start-Transcript -Path (Join-Path $logs ('packages-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '.log')) | Out-Null
try {
    Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'support\install-binaries.R'),
        (Join-Path $PSScriptRoot 'packages'),$runtime.BaseLibrary)
    & (Join-Path $PSScriptRoot 'FederatedPS\windows\Install-Offline.ps1') -InstallRoot $InstallRoot `
        -RHome 'C:\Program Files\R\R-4.6.1' -JavaHome $env:JAVA_HOME -RtoolsHome 'C:\rtools45'
} finally { Stop-Transcript | Out-Null }
Write-Host 'PASS: dependencies, pinned proximal CCD Cyclops, FederatedPs and JDBC installed.' -ForegroundColor Green
