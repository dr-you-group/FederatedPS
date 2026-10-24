#Requires -Version 5.1
[CmdletBinding()]
param([string]$InstallRoot = 'C:\FederatedPS',
      [string]$RHome = 'C:\Program Files\R\R-4.6.1',
      [string]$JavaHome = '', [string]$RStudioPath = '')
. (Join-Path $PSScriptRoot 'Common.ps1')
$project = Get-FederatedProject
$runtime = Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
Invoke-FederatedR $runtime.Rscript @((Join-Path $PSScriptRoot 'verify.R'), $project)
if (-not $RStudioPath) {
    $candidates = @((Join-Path $env:ProgramFiles 'RStudio\rstudio.exe'),
        (Join-Path $env:ProgramFiles 'RStudio\bin\rstudio.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\RStudio\rstudio.exe'),
        (Join-Path $env:LOCALAPPDATA 'RStudio\rstudio.exe'))
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if (-not $found.Count) { throw 'RStudio Desktop not found; install the transferred installer or supply -RStudioPath.' }
    $RStudioPath = $found[0]
}
if (-not (Test-Path -LiteralPath $RStudioPath -PathType Leaf)) { throw 'RStudioPath is not a file.' }
$sessionId = (Get-Process -Id $PID).SessionId
if (@(Get-Process -Name rstudio -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }).Count) {
    throw 'Close RStudio before launching so it inherits the new library environment.'
}
$env:FEDERATEDPS_PROJECT = $project
$env:R_PROFILE_USER = Join-Path $PSScriptRoot 'Rprofile.R'
$env:RSTUDIO_DISABLE_CHECK_FOR_UPDATES = '1'
$env:RSTUDIO_DISABLE_POSIT_ASSISTANT = '1'
$env:RSTUDIO_DISABLE_WHATS_NEW = '1'
Start-Process -FilePath $RStudioPath -ArgumentList (ConvertTo-NativeArgument (Join-Path $project 'FederatedPs.Rproj')) -WorkingDirectory $project
Write-Host 'Select R 4.6.1 in RStudio. The startup check must print PASS before using this library.'
