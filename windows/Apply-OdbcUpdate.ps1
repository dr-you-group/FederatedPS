#Requires -Version 5.1
<# Offline migration of an already-installed fresh bundle. Source edits may be overwritten. #>
[CmdletBinding()]
param([string]$BundleRoot='C:\FP',
      [string]$InstallRoot='C:\FederatedPS',
      [string]$RHome='C:\Program Files\R\R-4.6.1',
      [string]$JavaHome='',
      [switch]$SkipConnectionCheck)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess){throw 'Use 64-bit Windows PowerShell 5.1 as Administrator.'}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator rights are needed to install the Microsoft ODBC driver.'}
$root=(Resolve-Path -LiteralPath $BundleRoot).Path
if(-not(Test-Path -LiteralPath (Join-Path $root 'FederatedPS/DESCRIPTION') -PathType Leaf)){
    throw 'BundleRoot must be the existing installed bundle, for example C:\FP.'
}
$payload=Join-Path $PSScriptRoot 'odbc-payload'
if(-not(Test-Path -LiteralPath $payload -PathType Container)){throw 'Extract the entire ODBC update ZIP before running APPLY_ODBC.ps1.'}
# The shared patch copier backs up overwritten source files, accepts local edits,
# and excludes actual database settings and analysis output from the payload.
& (Join-Path $PSScriptRoot 'APPLY_FILES.ps1') -BundleRoot $root -InstallRoot $InstallRoot -SkipPackageRebuild
& (Join-Path $root 'FederatedPS/windows/odbc/Install-Odbc.ps1') -PayloadRoot $payload -InstallRoot $InstallRoot -RHome $RHome
$settings=Join-Path $root 'FederatedPS/windows/config/yuhs.Renviron'
if(-not(Test-Path -LiteralPath $settings -PathType Leaf)){
    Copy-Item -LiteralPath ($settings+'.example') -Destination $settings
}
# Append a final assignment without decoding/re-encoding credentials. readRenviron
# uses the last assignment. Preserve the previous private file locally.
$privateBackup=Join-Path $root ('patch-backups/connection-before-odbc-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $privateBackup -Force | Out-Null
$backup=Join-Path $privateBackup 'yuhs.Renviron'
Copy-Item -LiteralPath $settings -Destination $backup
$bytes=[Text.Encoding]::ASCII.GetBytes("`r`n# ODBC migration: keep the existing HIWARE endpoint and credentials.`r`nDB_BACKEND=odbc`r`n")
$stream=[IO.File]::Open($settings,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
& (Join-Path $root 'FederatedPS/windows/Update-FederatedPs.ps1') -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome -DbBackend odbc
Write-Host 'PASS: ODBC dependencies and FederatedPs source installed. Existing HIWARE connection settings retained.' -ForegroundColor Green
if(-not $SkipConnectionCheck){
    & (Join-Path $root 'CHECK_ODBC.ps1') -InstallRoot $InstallRoot -RHome $RHome -JavaHome $JavaHome
    Write-Host ("PASS: ODBC checks and normal process exit. Next: Set-Location '"+$root+"'; .\RUN.ps1") -ForegroundColor Green
}else{
    Write-Host 'Connection check skipped explicitly. Run CHECK_ODBC.ps1 after HIWARE login; RUN.ps1 also checks before analysis.'
}
