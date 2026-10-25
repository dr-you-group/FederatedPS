#Requires -Version 5.1
<# Collect role logs and bounded JVM thread diagnostics; no DB/analysis writes. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RunDirectory,
      [string]$OutputDirectory='', [string]$JavaHome='', [switch]$SkipThreads)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RunDiagnostics.Common.ps1')
$context=Get-RunDiagnosticContext $RunDirectory
if (-not $OutputDirectory) { $OutputDirectory=Join-Path (Split-Path $context.Root -Parent) 'diagnostic-exports' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$rootPrefix=$context.Root.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
if ($OutputDirectory -eq $context.Root -or $OutputDirectory.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be outside the selected run directory.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$name='FederatedPS-diagnostics-'+$context.RunId+'-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$destination=Join-Path $OutputDirectory $name
New-Item -ItemType Directory -Path $destination | Out-Null
$notes=New-Object 'System.Collections.Generic.List[string]'
$notes.Add("Run: $($context.RunId)")
$notes.Add("Captured UTC: $([DateTime]::UtcNow.ToString('o'))")
$notes.Add('Logs are a bounded snapshot; a live last line may be incomplete.')
$notes.Add('No database queries, heap dumps, RDS/Andromeda data or connection-settings files were collected.')
foreach ($relative in @(Get-RunDiagnosticFiles $context)) {
    if ($relative -eq 'run.json') {
        $safe=[ordered]@{}
        foreach ($key in @('project','mode','test','dataset','runId','sites','careSites','study','scenario','blockSize','alpha',
            'tolerance','exchangeTimeout','initialTimeout','startupTimeout','runTimeout','dbQueryTimeout','smallQueryTimeout',
            'output','exchange','configDirectory','designDirectory')) {
            if ($context.Config.PSObject.Properties[$key]) { $safe[$key]=$context.Config.$key }
        }
        [IO.File]::WriteAllText((Join-Path $destination 'run.json'),(ConvertTo-Json $safe -Depth 6),
            (New-Object Text.UTF8Encoding($false)))
        continue
    }
    Copy-RunDiagnosticFile $context.Root $relative $destination
}
$matches=@()
if ($env:OS -eq 'Windows_NT') {
    try { $matches=@(Get-RunDiagnosticProcesses $context) }
    catch { $notes.Add('Process inventory unavailable: '+$_.Exception.Message) }
} else { $notes.Add('Process/JVM inspection skipped: this is not Windows.') }
$inventory=@($matches | Select-Object Role,ProcessId,ParentProcessId,Name,SessionId,CreationUtc)
[IO.File]::WriteAllText((Join-Path $destination 'live-processes.json'),(ConvertTo-Json -InputObject $inventory -Depth 4),
    (New-Object Text.UTF8Encoding($false)))
$jcmd=$null
if (-not $SkipThreads -and $env:OS -eq 'Windows_NT') {
    if ($JavaHome) { $candidate=Join-Path $JavaHome 'bin\jcmd.exe'; if (Test-Path -LiteralPath $candidate -PathType Leaf) { $jcmd=$candidate } }
    else {
        $candidate=@(Get-ChildItem -Path 'C:\Program Files\Eclipse Adoptium\jdk-17*\bin\jcmd.exe' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        if ($candidate.Count) { $jcmd=$candidate[0].FullName }
    }
    if (-not $jcmd) { $notes.Add('jcmd.exe unavailable. Supply -JavaHome for installed Temurin 17; log collection still succeeded.') }
}
if ($jcmd) {
    foreach ($role in $context.Roles) {
        $path=Join-Path $destination (Join-Path $role 'progress.jsonl')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $event=$null
        foreach ($line in @(Get-Content -LiteralPath $path -Tail 20 -Encoding UTF8)) {
            try { $candidate=$line | ConvertFrom-Json; if ($candidate.PSObject.Properties['pid'] -and $candidate.role -ceq $role) { $event=$candidate } } catch { }
        }
        if ($null -eq $event) { continue }
        $matching=@($matches | Where-Object { $_.ProcessId -eq [int]$event.pid -and $_.Role -ceq $role })
        if ($matching.Count -ne 1) { $notes.Add("$role JVM snapshot skipped: no matching live R process for the recorded runtime PID."); continue }
        $native=$null
        try {
            $native=Open-RunDiagnosticProcess $context $matching[0]
            if ($null -eq $native) { $notes.Add("$role JVM snapshot skipped: process exited or identity changed."); continue }
            Invoke-RunDiagnosticThreadDump $jcmd ([int]$event.pid) (Join-Path $destination ($role+'-threads.txt'))
        } catch { $notes.Add("$role JVM snapshot unavailable: "+$_.Exception.Message) }
        finally { if ($null -ne $native) { $native.Dispose() } }
    }
}
[IO.File]::WriteAllLines((Join-Path $destination 'COLLECTION_NOTES.txt'),$notes,(New-Object Text.UTF8Encoding($false)))
$zip=$destination+'.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($destination,$zip,[IO.Compression.CompressionLevel]::Optimal,$true)
Write-Host "PASS: diagnostics saved: $zip" -ForegroundColor Green
Write-Host 'The analysis was not stopped. Share this diagnostic ZIP, not patient-result files.'
