#Requires -Version 5.1
$ErrorActionPreference='Stop'
$project=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $project 'windows/Install-Jdbc.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('fps-jdbc-'+[guid]::NewGuid().ToString('N'))
try {
    $old=Join-Path $root 'jdbc/sqlserver/mssql-jdbc-9.2.0.jre8.jar'
    New-Item -ItemType Directory -Path (Split-Path $old) -Force | Out-Null
    [IO.File]::WriteAllText($old,'unrelated legacy file')
    Install-FederatedJdbc -InstallRoot $root
    $target=Join-Path $root 'jdbc/sqlserver/dbeaver-7.4.1/mssql-jdbc-7.4.1.jre8.jar'
    $reference=Join-Path $root 'jdbc/sqlserver/reference-9.2.0/mssql-jdbc-9.2.0.jre8.jar'
    if (-not(Test-Path $target) -or -not(Test-Path $reference)) { throw 'Missing isolated driver' }
    [IO.File]::WriteAllText($target,'locally changed')
    Install-FederatedJdbc -InstallRoot $root
    if ((Get-Item $target).Length -lt 1000000) { throw 'Existing default was not overwritten' }
    if ([IO.File]::ReadAllText($old) -ne 'unrelated legacy file') { throw 'Old folder changed unexpectedly' }
    Write-Host 'PASS: isolated JDBC install, custom InstallRoot, replacement of local default, legacy reference retained.'
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
