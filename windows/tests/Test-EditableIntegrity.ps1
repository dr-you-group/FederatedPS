#Requires -Version 5.1
$ErrorActionPreference='Stop'
$fresh=Join-Path (Split-Path $PSScriptRoot -Parent) 'fresh'
. (Join-Path $fresh 'support/Fresh.Common.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-editable-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
function Expect-IntegrityFailure([scriptblock]$Action,[string]$Pattern='Integrity failure') {
    $caught=$false
    try{& $Action}catch{if($_.Exception.Message -notmatch $Pattern){throw};$caught=$true}
    if(-not $caught){throw 'Expected verification failure'}
}
try {
    $paths=@('installers/R-4.6.1-win.exe','installers/rtools45-6768-6492.exe',
        'installers/Temurin17-JDK-windows-x64.msi','installers/RStudio-2026.10.0-233.exe',
        'packages/PACKAGE_LOCK.dcf','packages/PACKAGE_LOCK.json','packages/Fixture.zip',
        'FederatedPS/DESCRIPTION','FederatedPS/windows/runtime-lock.json','RUN.ps1',
        'FederatedPS/R/example.R','FederatedPS/inst/sql/sql_server/Example.sql',
        'support/render-check.R','README_KO.md','SOURCE_INFO.json','git/repository.bundle')
    foreach($path in $paths) {
        $file=Join-Path $temp $path
        New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($file,'fixture-original')
    }
    [IO.File]::WriteAllText((Join-Path $temp 'packages/PACKAGE_LOCK.json'),'{"packages":[{"file":"Fixture.zip"}]}')
    $entries=@(foreach($path in $paths){
        $file=Join-Path $temp $path
        @{path=$path;bytes=(Get-Item $file).Length;sha256=(Get-FileHash $file -Algorithm SHA256).Hash}
    })
    $manifest=Join-Path $temp 'BUNDLE_MANIFEST.json'
    [IO.File]::WriteAllText($manifest,(@{format='FederatedPS-fresh-v1';files=$entries}|ConvertTo-Json -Depth 5))
    $manifestHash=(Get-FileHash $manifest).Hash
    Test-FreshManifest $temp -StrictSource
    foreach($path in @('RUN.ps1','FederatedPS/R/example.R','FederatedPS/inst/sql/sql_server/Example.sql','support/render-check.R')){
        $file=Join-Path $temp $path
        [IO.File]::WriteAllText($file,'user local modification')
        Test-FreshManifest $temp
        Expect-IntegrityFailure {Test-FreshManifest $temp -StrictSource}
        if((Get-FileHash $manifest).Hash -ne $manifestHash){throw 'Verifier rewrote release provenance'}
        [IO.File]::WriteAllText($file,'fixture-original')
    }
    # A deleted optional source file is a source edit, not a broken installer.
    Remove-Item (Join-Path $temp 'FederatedPS/R/example.R')
    Test-FreshManifest $temp
    Expect-IntegrityFailure {Test-FreshManifest $temp -StrictSource} 'Missing bundled file'
    [IO.File]::WriteAllText((Join-Path $temp 'FederatedPS/R/example.R'),'fixture-original')
    foreach($path in @('installers/R-4.6.1-win.exe','packages/Fixture.zip','packages/PACKAGE_LOCK.dcf',
        'FederatedPS/windows/runtime-lock.json','SOURCE_INFO.json','git/repository.bundle')) {
        $file=Join-Path $temp $path
        [IO.File]::WriteAllText($file,'damaged')
        Expect-IntegrityFailure {Test-FreshManifest $temp}
        [IO.File]::WriteAllText($file,'fixture-original')
    }
    Remove-Item (Join-Path $temp 'RUN.ps1')
    Expect-IntegrityFailure {Test-FreshManifest $temp} 'Missing required payload'
    foreach($path in @('../escape.ps1','support/../../escape.R')) {
        Expect-IntegrityFailure {Get-FreshPayloadPath $temp $path} 'Unsafe payload path'
    }
    Write-Host 'PASS: local RUN/R/SQL edits accepted, strict source verification available, manifest unchanged, immutable payload damage/missing requirements/traversal rejected.'
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
