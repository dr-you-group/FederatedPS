#Requires -Version 5.1
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-run-odbc-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null
try{
 Copy-Item (Join-Path $root 'fresh/RUN.ps1') $temp
 @'
param($BundleRoot,$InstallRoot)
if(Test-Path (Join-Path $PSScriptRoot 'fail-probe')){throw 'fixture ODBC check failed'}
Set-Content (Join-Path $PSScriptRoot 'probe-complete') 'both native and production completed'
'@|Set-Content (Join-Path $temp 'CHECK_ODBC.ps1')
 @'
param($InstallRoot,$Test,$DbBackend,$Study,$Scenario,$Methods,$PatientLimits,$ExtractionWorkers,$StatusSeconds)
if($DbBackend -eq 'odbc' -and -not(Test-Path (Join-Path $PSScriptRoot 'probe-complete'))){throw 'Analysis started without successful ODBC check'}
$record=@{}+$PSBoundParameters;$record.PatientLimits=@{}
foreach($key in $PatientLimits.Keys){$record.PatientLimits[[string]$key]=$PatientLimits[$key]}
$record|ConvertTo-Json -Depth 8|Set-Content (Join-Path $PSScriptRoot 'forwarded.json')
'@|Set-Content (Join-Path $temp '05_RUN_YUHS.ps1')
 @'
param($InstallRoot,$DbBackend)
$DbBackend|Set-Content (Join-Path $PSScriptRoot 'updated-backend')
'@|Set-Content (Join-Path $temp '10_UPDATE_PACKAGE.ps1')
 & (Join-Path $temp 'RUN.ps1')
 $c=Get-Content (Join-Path $temp 'forwarded.json') -Raw|ConvertFrom-Json
 if($c.DbBackend -cne 'odbc' -or $c.Test -or $c.Study -cne 'ppi' -or $c.Scenario -cne 'default' -or
    ($c.Methods -join ',') -cne 'local-only,pooled' -or $c.ExtractionWorkers -ne 1 -or
    $c.PatientLimits.'1' -ne 2 -or $c.PatientLimits.'2' -ne 2 -or $c.PatientLimits.'3' -ne 2){throw 'RUN defaults changed'}
 Remove-Item (Join-Path $temp 'forwarded.json'),(Join-Path $temp 'probe-complete')
 Set-Content (Join-Path $temp 'fail-probe') 'fixture'
 $failed=$false;try{& (Join-Path $temp 'RUN.ps1')}catch{$failed=$_.Exception.Message -match 'fixture ODBC check failed'}
 if(-not $failed -or (Test-Path (Join-Path $temp 'forwarded.json'))){throw 'Analysis was not blocked by failed ODBC probe'}
 & (Join-Path $temp 'RUN.ps1') -DbBackend jdbc -PatientLimits @{1=4;2=6;3=8} -UpdatePackage
 $c=Get-Content (Join-Path $temp 'forwarded.json') -Raw|ConvertFrom-Json
 if($c.DbBackend -cne 'jdbc' -or $c.PatientLimits.'2' -ne 6 -or (Get-Content (Join-Path $temp 'updated-backend')).Trim() -cne 'jdbc'){throw 'Explicit backend/update/caps lost'}
 Write-Host 'PASS: RUN ODBC preflight gate, explicit JDBC selection, update forwarding and per-site cap defaults.'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
