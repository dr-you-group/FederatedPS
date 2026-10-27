#Requires -Version 5.1
# Process identity tests use local mocks; no real R process or DB is stopped.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\RunDiagnostics.Common.ps1')
function Assert-Diagnostic([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$temp=Join-Path ([IO.Path]::GetTempPath()) ('fps diagnostics '+[guid]::NewGuid().ToString('N'))
$run=Join-Path $temp 'run123'
New-Item -ItemType Directory -Path (Join-Path $run 'gangnam\diagnostics') -Force | Out-Null
$config=[ordered]@{project=$temp; runId='run123';sites=@('gangnam','severance','yongin'); mode='Database';
    output=$run; unexpectedPassword='must-not-be-exported'}
$config | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $run 'run.json') -Encoding UTF8
$context=Get-RunDiagnosticContext $run
$created=[DateTime]::UtcNow.AddSeconds(-1)
$command='"Rterm.exe" "--vanilla" "--file='+$context.RoleScript+'" "--args" "'+$context.ConfigFile+'" "gangnam"'
$candidate=[pscustomobject]@{ProcessId=987654;ParentProcessId=987653;Name='Rterm.exe';SessionId=$context.SessionId;
    CreationDate=$created;CommandLine=$command}
try {
    $expected=Get-RunDiagnosticProcessMatch $context $candidate
    Assert-Diagnostic ($null -ne $expected -and $expected.Role -eq 'gangnam') 'Expected exact run worker was not matched.'
    $candidate.CommandLine=$command.Replace($context.ConfigFile,$context.ConfigFile+'.bak')
    Assert-Diagnostic ($null -eq (Get-RunDiagnosticProcessMatch $context $candidate)) 'A path-prefix collision was matched.'
    $candidate.CommandLine=$command.Replace(('"'+$context.ConfigFile+'"'),$context.ConfigFile)
    Assert-Diagnostic ($null -eq (Get-RunDiagnosticProcessMatch $context $candidate)) 'An unquoted path with spaces was treated as one argument.'
    $candidate.CommandLine=$command.Replace($context.RoleScript,$context.RoleScript+'.evil')
    Assert-Diagnostic ($null -eq (Get-RunDiagnosticProcessMatch $context $candidate)) 'An unrelated script was matched.'
    $candidate.CommandLine=$command; $candidate.Name='rsession.exe'
    Assert-Diagnostic ($null -eq (Get-RunDiagnosticProcessMatch $context $candidate)) 'RStudio must never be matched.'
    $candidate.Name='Rterm.exe';$candidate.SessionId=$context.SessionId+1
    Assert-Diagnostic ($null -eq (Get-RunDiagnosticProcessMatch $context $candidate)) 'A different Windows session was matched.'
    $candidate.SessionId=$context.SessionId;$candidate.CreationDate=$context.StartedAfter.AddSeconds(-1)
    Assert-Diagnostic ($null -eq (Get-RunDiagnosticProcessMatch $context $candidate)) 'A process older than the run was matched.'
    $candidate.CreationDate=$created
    $candidate.CommandLine=$command.Replace('"--file='+$context.RoleScript+'"','--file="'+$context.RoleScript+'"')
    Assert-Diagnostic ($null -ne (Get-RunDiagnosticProcessMatch $context $candidate)) 'Rterm --file="path with spaces" was not matched.'
    $candidate.CommandLine=$command.Replace('"--file='+$context.RoleScript+'"','"'+$context.RoleScript+'"')
    $candidate.Name='Rscript.exe'
    Assert-Diagnostic ($null -ne (Get-RunDiagnosticProcessMatch $context $candidate)) 'Legacy Rscript script argument was not matched.'
    $candidate.CommandLine=$command; $candidate.Name='Rterm.exe'
    $parent=[pscustomobject]@{ProcessId=987653;ParentProcessId=1}
    $order=@(Get-RunDiagnosticStopOrder @($parent,$candidate))
    Assert-Diagnostic ($order[0].ProcessId -eq $candidate.ProcessId) 'Cleanup must order children before matching parents.'

    $script:diagnosticCandidate=$candidate
    $script:diagnosticNative=[pscustomobject]@{Id=987654;Handle=42;StartTime=$created;Disposed=$false}
    $script:diagnosticNative | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
    $script:diagnosticStops=0
    function Get-Process { param($Id,$ErrorAction); $script:diagnosticNative }
    function Get-CimInstance { param($ClassName,$Filter,$ErrorAction); $script:diagnosticCandidate }
    function Stop-Process { param($InputObject,[switch]$Force,$ErrorAction); $script:diagnosticStops++ }
    try {
        $script:diagnosticCandidate.CreationDate=$created.AddSeconds(1)
        Assert-Diagnostic (-not (Stop-RunDiagnosticProcess $context $expected)) 'Reused PID was not refused.'
        Assert-Diagnostic ($script:diagnosticStops -eq 0) 'Reused PID was stopped.'
        $script:diagnosticCandidate.CreationDate=$created
        $script:diagnosticCandidate.CommandLine=$command.Replace('"gangnam"','"severance"')
        Assert-Diagnostic (-not (Stop-RunDiagnosticProcess $context $expected)) 'Changed role was not refused.'
        Assert-Diagnostic ($script:diagnosticStops -eq 0) 'Changed role was stopped.'
        $script:diagnosticCandidate.CommandLine=$command
        Assert-Diagnostic (Stop-RunDiagnosticProcess $context $expected) 'Matching retained process was not stopped by mock.'
        Assert-Diagnostic ($script:diagnosticStops -eq 1) 'Expected exactly one mock stop.'
    } finally {
        Remove-Item Function:Get-Process,Function:Get-CimInstance,Function:Stop-Process
    }

    'stdout fixture' | Set-Content (Join-Path $run 'gangnam\run.stdout.log')
    'stderr fixture' | Set-Content (Join-Path $run 'gangnam\run.stderr.log')
    '{"role":"gangnam","pid":987654}' | Set-Content (Join-Path $run 'gangnam\progress.jsonl')
    'SELECT 1' | Set-Content (Join-Path $run 'gangnam\diagnostics\001-check.sql')
    'operation metadata' | Set-Content (Join-Path $run 'gangnam\diagnostics\operations.tsv')
    'patient-data-do-not-export' | Set-Content (Join-Path $run 'gangnam\result.rds')
    'credential-do-not-export' | Set-Content (Join-Path $run 'gangnam\diagnostics\yuhs.Renviron')
    'patient-table-do-not-export' | Set-Content (Join-Path $run 'gangnam\diagnostics\patients.tsv')
    New-Item -ItemType Directory -Path (Join-Path $run 'gangnam\sql-diagnostics') | Out-Null
    'SELECT @@SPID AS session_id' | Set-Content (Join-Path $run 'gangnam\sql-diagnostics\002-session.sql')
    'connection metadata' | Set-Content (Join-Path $run 'gangnam\sql-diagnostics\connection.tsv')
    New-Item -ItemType Directory -Path (Join-Path $run 'gangnam\andromeda') | Out-Null
    'private' | Set-Content (Join-Path $run 'gangnam\andromeda\data.sqlite')
    $openLog=Join-Path $run 'gangnam\run.stdout.log'
    $writer=[IO.File]::Open($openLog,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes('writer remains open')
        $writer.Write($bytes,0,$bytes.Length);$writer.Flush()
        $copy=Join-Path $temp 'live-copy'
        New-Item -ItemType Directory -Path $copy | Out-Null
        Copy-RunDiagnosticFile $run 'gangnam\run.stdout.log' $copy
        Assert-Diagnostic (([IO.File]::ReadAllText((Join-Path $copy 'gangnam\run.stdout.log'))) -match 'writer remains open') 'Could not snapshot a live shared log.'
    } finally { $writer.Dispose() }

    if ($env:OS -ne 'Windows_NT') {
        # Exercise the actual native diagnostic boundary with a tiny fake JVM tool.
        # It must drain both pipes and stop its own timed-out child, not the target.
        $fakeJcmd=Join-Path $temp 'fake-jcmd'
        [IO.File]::WriteAllText($fakeJcmd,"#!/usr/bin/env python3`nimport sys, time`nprint('thread output', flush=True)`nprint('diagnostic stderr', file=sys.stderr, flush=True)`nif sys.argv[1] == '2': time.sleep(30)`n",(New-Object Text.UTF8Encoding($false)))
        & /bin/chmod '+x' $fakeJcmd
        Invoke-RunDiagnosticThreadDump $fakeJcmd 1 (Join-Path $temp 'normal-threads.txt') -TimeoutSeconds 2
        $threadText=[IO.File]::ReadAllText((Join-Path $temp 'normal-threads.txt'))
        Assert-Diagnostic ($threadText -match 'thread output' -and $threadText -match 'diagnostic stderr') 'Diagnostic stdout/stderr capture failed.'
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Invoke-RunDiagnosticThreadDump $fakeJcmd 2 (Join-Path $temp 'timeout-threads.txt') -TimeoutSeconds 1
        $clock.Stop()
        Assert-Diagnostic ($clock.Elapsed.TotalSeconds -lt 8) 'Diagnostic execution exceeded its bounded timeout.'
        Assert-Diagnostic (([IO.File]::ReadAllText((Join-Path $temp 'timeout-threads.txt'))) -match 'timeout=True') 'Diagnostic timeout was not reported.'
    }
    $before=(Get-FileHash -LiteralPath (Join-Path $run 'run.json')).Hash
    & (Join-Path $PSScriptRoot '..\Collect-RunDiagnostics.ps1') -RunDirectory $run -OutputDirectory (Join-Path $temp 'exports') -SkipThreads
    Assert-Diagnostic ((Get-FileHash -LiteralPath (Join-Path $run 'run.json')).Hash -eq $before) 'Collection changed run.json.'
    $zip=Get-ChildItem (Join-Path $temp 'exports') -Filter '*.zip' -File
    Assert-Diagnostic ($null -ne $zip) 'Diagnostic archive was not created.'
    $archive=[IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        $names=@($archive.Entries | ForEach-Object { $_.FullName })
        Assert-Diagnostic (@($names | Where-Object { $_ -match 'result[.]rds|andromeda|yuhs[.]Renviron|patients[.]tsv' }).Count -eq 0) 'Private data/config files were exported.'
        Assert-Diagnostic (@($names | Where-Object { $_ -match '001-check[.]sql$' }).Count -eq 1) 'Rendered diagnostic SQL missing.'
        Assert-Diagnostic (@($names | Where-Object { $_ -match 'sql-diagnostics/002-session[.]sql$' }).Count -eq 1) 'Runtime SQL diagnostic directory was not included.'
        Assert-Diagnostic (@($names | Where-Object { $_ -match 'sql-diagnostics/connection[.]tsv$' }).Count -eq 1) 'Runtime SPID diagnostic was not included.'
        $entry=@($archive.Entries | Where-Object { $_.FullName -match '/run[.]json$' })[0]
        $reader=New-Object IO.StreamReader($entry.Open())
        try { $safe=$reader.ReadToEnd() } finally { $reader.Dispose() }
        Assert-Diagnostic ($safe -notmatch 'unexpectedPassword|must-not-be-exported') 'Unknown run config credential field was exported.'
    } finally { $archive.Dispose() }
    Write-Host 'PASS: exact run/role/session/time guards, PID reuse refusal, child-first ordering, shared-log snapshot, bounded native diagnostic capture, readonly whitelist and credential-field omission.'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
