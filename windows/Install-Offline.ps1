#Requires -Version 5.1
<# Offline only: builds the pinned block CCD fork using the installed Rtools45. #>
[CmdletBinding()]
param([string]$InstallRoot = 'C:\FederatedPS',
      [string]$RHome = 'C:\Program Files\R\R-4.6.1',
      [string]$JavaHome = '', [string]$RtoolsHome = 'C:\rtools45')
. (Join-Path $PSScriptRoot 'Common.ps1')
$project = Get-FederatedProject
$runtime = Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome -ForInstall
$lock = Get-FederatedLock
$archive = Join-Path (Join-Path $PSScriptRoot 'payload') $lock.cyclopsArchive
if (-not (Test-Path -LiteralPath $archive)) { throw 'Missing Cyclops source. Run Prepare-Offline.ps1 on the online PC and transfer windows\payload.' }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $lock.cyclopsSha256) { throw 'Cyclops source SHA-256 mismatch.' }
if (-not (Test-Path -LiteralPath (Join-Path $RtoolsHome 'usr\bin\make.exe'))) {
    throw "Rtools45 missing at $RtoolsHome. Install it using offline bundle step 11 (without -SkipRtools)."
}
# DLLs cannot be replaced while loaded in Windows. Do not terminate the user's sessions.
$sessionId = (Get-Process -Id $PID).SessionId
$busy = @(Get-Process -Name R,Rgui,Rterm,Rscript,rsession -ErrorAction SilentlyContinue |
    Where-Object { $_.SessionId -eq $sessionId })
if ($busy.Count) { throw 'Close R and RStudio sessions before installing. No processes were stopped.' }
$env:RTOOLS45_HOME = $RtoolsHome
$env:PATH = (Join-Path $RtoolsHome 'usr\bin') + ';' + $env:PATH
$build = Join-Path (Join-Path $project 'work') ('install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $build | Out-Null
. (Join-Path $PSScriptRoot 'Install-Jdbc.ps1')
Install-FederatedJdbc -InstallRoot $InstallRoot
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $build)
$source = Join-Path $build "Cyclops-$($lock.cyclopsCommit)"
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'install.R'), $project, $source, $runtime.Library)
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'verify.R'), $project)
Write-Host 'Installation verified. Run windows\Run-FederatedPS.ps1 -Mode Synthetic next.' -ForegroundColor Green
