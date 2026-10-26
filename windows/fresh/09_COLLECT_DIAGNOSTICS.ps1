#Requires -Version 5.1
[CmdletBinding()] param([Parameter(Mandatory=$true)][string]$RunDirectory,[switch]$SkipThreads)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
. (Join-Path $PSScriptRoot 'FederatedPS\windows\RunDiagnostics.Common.ps1')
$root=(Resolve-Path -LiteralPath $RunDirectory).Path
$configFile=Join-Path $root 'run.json'
$config=Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$config.runId -notmatch '^[A-Za-z0-9]+$') { throw 'Invalid run ID.' }
$exportRoot=Join-Path $PSScriptRoot 'diagnostic-exports'
$out=Join-Path $exportRoot ($config.runId+'-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $out -Force | Out-Null
$safe=[ordered]@{}
foreach($key in @('runId','mode','methods','dataset','test','sites','careSites','study','scenario','patientLimits',
    'extractionWorkers','requestedExtractionWorkers','connectionCheckTimeout','dbQueryTimeout','runTimeout')) {
    if ($config.PSObject.Properties[$key]) { $safe[$key]=$config.$key }
}
$safe | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'run-summary.json') -Encoding UTF8
$names=@('monitor.log','db-startup-watchdog.log','sql-prepare-watchdog.log','sql-prepare-state.json','progress.jsonl','run.stdout.log','run.stderr.log','operations.tsv','connection.tsv',
    'failure.txt','run-status.json','processes.json','db-startup-start.json','db-startup-ready.json','db-startup-phase.json')
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object {
    $_.Name -in $names -or $_.Name -like 'shutdown-thread-*.txt' -or $_.Name -like 'db-startup-timeout-*.json' -or $_.Name -like 'sql-prepare-timeout-*.json' -or
    ($_.Directory.Name -eq 'sql-diagnostics' -and ($_.Extension -eq '.sql' -or $_.Name -like '*-plan.tsv')) })
foreach($file in $files) {
    $relative=$file.FullName.Substring($root.Length).TrimStart('\','/')
    $target=Get-FreshPayloadPath $out $relative
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    # Read only log/SQL allowlist. Keep the last 20,000 lines of large logs.
    Get-Content -LiteralPath $file.FullName -Tail 20000 -Encoding UTF8 | Set-Content -LiteralPath $target -Encoding UTF8
}
if (-not $SkipThreads) {
    Assert-FreshWindows
    $jcmd=Join-Path (Get-FreshJavaHome) 'bin\jcmd.exe'
    $ownSession=(Get-Process -Id $PID).SessionId
    foreach($progressFile in @($files | Where-Object {$_.Name -eq 'progress.jsonl'})) {
        $event=$null
        foreach($line in @(Get-Content -LiteralPath $progressFile.FullName -Tail 10 -Encoding UTF8)) {
            try { $candidate=$line | ConvertFrom-Json; if($candidate.PSObject.Properties['pid']){$event=$candidate} } catch { }
        }
        if ($null -eq $event) { continue }
        $runtimePid=[int]$event.pid
        $process=Get-CimInstance Win32_Process -Filter "ProcessId = $runtimePid" -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.Name -notin @('R.exe','Rterm.exe','Rscript.exe') -or
            $process.SessionId -ne $ownSession -or
            -not (Test-RunDiagnosticArgument $process.CommandLine $configFile)) { continue }
        $role=$progressFile.Directory.Name -replace '[^A-Za-z0-9_-]','_'
        Invoke-RunDiagnosticThreadDump -Jcmd $jcmd -RuntimePid $runtimePid -OutputFile (Join-Path $out ($role+'-threads.txt'))
    }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=$out+'.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($out,$zip,[IO.Compression.CompressionLevel]::Optimal,$true)
Write-Host "Diagnostics saved: $zip" -ForegroundColor Green
Write-Host 'Analysis was not stopped. Database settings and patient-result files were not included.'
