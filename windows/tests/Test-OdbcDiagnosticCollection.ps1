#Requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../RunDiagnostics.Common.ps1')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps-odbc-collect-'+[guid]::NewGuid().ToString('N'))
$run=Join-Path $temp 'run'
New-Item -ItemType Directory -Path $run -Force | Out-Null
function Fixture([string]$Relative,[string]$Text='safe operation metadata') {
    $path=Join-Path $run $Relative
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    Set-Content -LiteralPath $path -Value $Text
}
try {
    $config=@{runId='odbcFixture';project=$temp;sites=@('1','2','3');mode='SelectedMethods';dbBackend='odbc'}
    $config | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'run.json')
    $expected=@('sql-operation-watchdog.log','sql-operation-timeout-2.json',
        'baselines/run.stdout.log','1/sql-operation-state.json','extraction/2/sql-operation-state.json')
    foreach($name in $expected){Fixture $name}
    $excluded=@('private.json','sql-operation-timeout-99.json','baselines/result.rds',
        'extraction/2/yuhs.Renviron','extraction/2/patients.tsv','extraction/2/sql-operation-state.json.partial')
    foreach($name in $excluded){Fixture $name 'private fixture'}
    $context=Get-RunDiagnosticContext $run
    $selected=@(Get-RunDiagnosticFiles $context | ForEach-Object {$_.Replace('\','/')})
    foreach($name in $expected){if($name -notin $selected){throw "Missing watchdog export: $name"}}
    foreach($name in $excluded){if($name -in $selected){throw "Unexpected watchdog export: $name"}}
    # Exercise the shipped closed-network collector, with thread capture off.
    $bundle=Join-Path $temp 'bundle'
    foreach($directory in @('support','FederatedPS/windows')) {
        New-Item -ItemType Directory -Path (Join-Path $bundle $directory) -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../fresh/09_COLLECT_DIAGNOSTICS.ps1') -Destination $bundle
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../fresh/support/Fresh.Common.ps1') -Destination (Join-Path $bundle 'support')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../RunDiagnostics.Common.ps1') -Destination (Join-Path $bundle 'FederatedPS/windows')
    & (Join-Path $bundle '09_COLLECT_DIAGNOSTICS.ps1') -RunDirectory $run -SkipThreads
    $zip=@(Get-ChildItem -LiteralPath (Join-Path $bundle 'diagnostic-exports') -Filter '*.zip')[0]
    $archive=[IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        $entries=@($archive.Entries | ForEach-Object {($_.FullName -split '/',2)[1]})
        foreach($name in $expected){if($name -notin $entries){throw "Fresh collector omitted $name"}}
        foreach($name in $excluded | Where-Object {$_ -ne 'sql-operation-timeout-99.json'}) {
            if($name -in $entries){throw "Fresh collector included private file $name"}
        }
        $entry=@($archive.Entries | Where-Object {$_.FullName -like '*/run-summary.json'})[0]
        $reader=New-Object IO.StreamReader($entry.Open())
        try{$summary=$reader.ReadToEnd() | ConvertFrom-Json}finally{$reader.Dispose()}
        if($summary.dbBackend -cne 'odbc'){throw 'Backend missing from diagnostic summary'}
    } finally {$archive.Dispose()}
    Write-Host 'PASS: ODBC watchdog evidence exported for direct/selected-method layouts; unrelated patient/config/partial files excluded'
} finally {Remove-Item -LiteralPath $temp -Recurse -Force}
