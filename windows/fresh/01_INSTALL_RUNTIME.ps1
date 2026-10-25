#Requires -Version 5.1
[CmdletBinding()] param([switch]$SkipRStudio)
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Assert-FreshWindows -Administrator
Assert-FreshNoR
Test-FreshManifest $PSScriptRoot
$logs = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$log = Join-Path $logs 'runtime-install.log'
$rscript = 'C:\Program Files\R\R-4.6.1\bin\x64\Rscript.exe'
if (-not (Test-Path -LiteralPath $rscript)) {
    Invoke-FreshInstaller (Join-Path $PSScriptRoot 'installers\R-4.6.1-win.exe') `
        '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR="C:\Program Files\R\R-4.6.1"' 'R 4.6.1' $log
}
if (-not (Test-Path -LiteralPath $rscript)) { throw 'Direct x64 Rscript.exe missing after R installation.' }
if (-not (Test-Path -LiteralPath 'C:\rtools45\usr\bin\make.exe')) {
    Invoke-FreshInstaller (Join-Path $PSScriptRoot 'installers\rtools45-6768-6492.exe') `
        '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR="C:\rtools45"' 'Rtools45' $log
}
if (-not (Test-Path -LiteralPath 'C:\rtools45\usr\bin\make.exe')) { throw 'Rtools45 installation incomplete.' }
$javaHome = $null
try { $javaHome = Get-FreshJavaHome } catch { }
if (-not $javaHome) {
    $msi = Join-Path $PSScriptRoot 'installers\Temurin17-JDK-windows-x64.msi'
    Invoke-FreshInstaller (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
        ('/i "{0}" /qn /norestart /L*v "{1}"' -f $msi,(Join-Path $logs 'temurin-install.log')) 'Temurin JDK 17' $log
    $javaHome = Get-FreshJavaHome
}
$env:JAVA_HOME = $javaHome
[Environment]::SetEnvironmentVariable('JAVA_HOME',$javaHome,'Machine')
& (Join-Path $javaHome 'bin\java.exe') -version
if ($LASTEXITCODE -ne 0) { throw 'Java version check failed.' }
& $rscript --vanilla (Join-Path $PSScriptRoot 'support\runtime-version.R')
if ($LASTEXITCODE -ne 0) { throw 'R version check failed.' }
if (-not $SkipRStudio -and -not (Test-Path -LiteralPath 'C:\Program Files\RStudio\rstudio.exe')) {
    Write-Host 'Complete the RStudio installer wizard, then close RStudio to continue.'
    $installer = Join-Path $PSScriptRoot 'installers\RStudio-2026.10.0-233.exe'
    $process = Start-Process -FilePath $installer -Wait -PassThru
    if ($process.ExitCode -notin @(0)) { throw "RStudio installer returned $($process.ExitCode). Restart if requested, then rerun SETUP.ps1." }
    if (-not (Test-Path -LiteralPath 'C:\Program Files\RStudio\rstudio.exe')) { throw 'RStudio was not found in its default installation location.' }
}
Write-Host 'PASS: offline runtimes installed. Next: 02_INSTALL_PACKAGES.ps1.' -ForegroundColor Green
