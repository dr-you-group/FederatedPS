#Requires -Version 5.1
<# Copy the supplied release files over local edits, then reinstall FederatedPs.
   No old-file checksum, release-manifest or base-version comparison is made. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BundleRoot,
      [string]$InstallRoot='C:\FederatedPS',
      [switch]$SkipPackageRebuild)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-PatchTarget([string]$Root,[string]$Relative) {
    if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') {throw 'Invalid patch path.'}
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Patch path leaves the selected directory.'}
    return $path
}
$root=(Resolve-Path -LiteralPath $BundleRoot).Path
if(-not (Test-Path -LiteralPath (Join-Path $root 'FederatedPS/DESCRIPTION') -PathType Leaf)) {
    throw 'BundleRoot must be the existing FederatedPS bundle directory (for example C:\FP).'
}
$fix=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PATCH.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not $fix.files.Count){throw 'PATCH.json contains no files.'}
$payload=Join-Path $PSScriptRoot 'payload'
$seen=@{}
$files=@(foreach($entry in $fix.files) {
    $relative=([string]$entry.path).Replace('\','/')
    if($seen.ContainsKey($relative)){throw 'Duplicate patch path.'}
    $seen[$relative]=$true
    if($relative -match '^FederatedPS/(work|output|input|exchange)/' -or
       $relative -match '^FederatedPS/windows/config/[^/]+[.]Renviron$') {
        throw 'Patch payload must not contain local database settings or analysis data.'
    }
    $source=Get-PatchTarget $payload $relative
    $target=Get-PatchTarget $root $relative
    if(-not (Test-Path -LiteralPath $source -PathType Leaf)){throw "Missing patch file: $relative"}
    if((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) {
        throw "A directory occupies a file path: $relative"
    }
    [pscustomobject]@{Relative=$relative;Source=$source;Target=$target;Existed=(Test-Path -LiteralPath $target -PathType Leaf)}
})
$updater=Join-Path $root 'FederatedPS/windows/Update-FederatedPs.ps1'
if(-not $SkipPackageRebuild -and -not (Test-Path -LiteralPath $updater -PathType Leaf) -and
   -not $seen.ContainsKey('FederatedPS/windows/Update-FederatedPs.ps1')) {
    throw 'The offline FederatedPs installer is missing.'
}
$busy=@(Get-Process -Name R,Rgui,Rterm,Rscript,rsession -ErrorAction SilentlyContinue)
if($busy.Count){throw 'Close R/RStudio and analysis processes before reinstalling the package.'}
$backup=Join-Path $root ('patch-backups/overwrite-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach($file in $files) {
    if($file.Existed) {
        $saved=Get-PatchTarget $backup $file.Relative
        New-Item -ItemType Directory -Path (Split-Path $saved -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $file.Target -Destination $saved
    }
}
$changed=New-Object 'System.Collections.Generic.List[object]'
try {
    foreach($file in $files) {
        New-Item -ItemType Directory -Path (Split-Path $file.Target -Parent) -Force | Out-Null
        $changed.Add($file)
        Copy-Item -LiteralPath $file.Source -Destination $file.Target -Force
    }
} catch {
    $failure=$_
    foreach($file in $changed) {
        if($file.Existed){Copy-Item -LiteralPath (Get-PatchTarget $backup $file.Relative) -Destination $file.Target -Force}
        elseif(Test-Path -LiteralPath $file.Target -PathType Leaf){Remove-Item -LiteralPath $file.Target -Force}
    }
    throw "File update failed; source files restored from $backup. $($failure.Exception.Message)"
}
Write-Host "PASS: release files overwritten, including RUN.ps1. Previous files: $backup" -ForegroundColor Green
if(-not $SkipPackageRebuild) {
    Write-Host 'Reinstalling FederatedPs from the updated source...'
    # Invoke the package installer directly. Older 10_UPDATE_PACKAGE wrappers
    # still require a whole-bundle hash check and all original installer EXEs.
    try { & $updater -InstallRoot $InstallRoot }
    catch {throw "Release files are updated, but package installation failed. $($_.Exception.Message)"}
    Write-Host "PASS: FederatedPs reinstalled. Next: Set-Location '$root'; .\RUN.ps1" -ForegroundColor Green
} else {
    Write-Host "Files updated. Package reinstall was explicitly skipped; run '$root\10_UPDATE_PACKAGE.ps1' before analysis."
}
