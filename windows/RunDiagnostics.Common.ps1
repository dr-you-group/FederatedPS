#Requires -Version 5.1
# Shared by the explicit diagnostic/stop tools. No process is stopped on import.
Set-StrictMode -Version Latest

function ConvertTo-RunDiagnosticUtc($Value) {
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    if ($null -eq $Value -or -not [string]$Value) { throw 'Missing process creation time.' }
    ([DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
}

function Test-RunDiagnosticArgument([string]$CommandLine, [string]$Value, [switch]$FileArgument) {
    if (-not $CommandLine -or -not $Value) { return $false }
    # Match a complete argument, not a run-ID substring or a path prefix. Windows
    # filenames cannot contain quotes; support Rscript and Rterm --file forms.
    $escaped=[regex]::Escape($Value.Replace('/','\'))
    $prefix=if ($FileArgument) { '(?:--file=)?' } else { '' }
    $forms=@(('"'+$prefix+$escaped+'"'), ($prefix+'"'+$escaped+'"'))
    if ($Value -notmatch '\s') { $forms+=($prefix+$escaped) }
    $pattern='(?:^|\s)(?:'+($forms -join '|')+')(?=\s|$)'
    [regex]::IsMatch($CommandLine.Replace('/','\'),$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-RunDiagnosticContext([string]$RunDirectory) {
    $root=(Resolve-Path -LiteralPath $RunDirectory -ErrorAction Stop).Path
    $file=Join-Path $root 'run.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'The selected directory has no run.json.' }
    $config=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.PSObject.Properties['runId'] -or $config.runId -cnotmatch '^[A-Za-z0-9]+$') {
        throw 'Invalid run.json runId.'
    }
    if (-not $config.PSObject.Properties['project'] -or -not [IO.Path]::IsPathRooted($config.project)) {
        throw 'run.json must contain an absolute project directory.'
    }
    $sites=@($config.sites)
    if (-not $sites.Count -or @($sites | Where-Object { $_ -cnotmatch '^[A-Za-z0-9]+$' -or $_ -in @('aggregator','verification') }).Count) {
        throw 'Invalid institution names in run.json.'
    }
    [pscustomobject]@{
        Root=$root; ConfigFile=$file; Config=$config; RunId=$config.runId
        Roles=@('aggregator')+$sites+@('verification')
        RoleScript=Join-Path $config.project 'windows\run-role.R'
        VerifyScript=Join-Path $config.project 'windows\verify-results.R'
        StartedAfter=(Get-Item -LiteralPath $file).CreationTimeUtc.AddSeconds(-5)
        SessionId=(Get-Process -Id $PID).SessionId
    }
}

function Get-RunDiagnosticProcessMatch($Context, $Process) {
    if ($null -eq $Process -or $Process.Name -notin @('R.exe','Rterm.exe','Rscript.exe') -or
        [int]$Process.SessionId -ne [int]$Context.SessionId -or [int]$Process.ProcessId -eq $PID) { return }
    if (-not (Test-RunDiagnosticArgument $Process.CommandLine $Context.ConfigFile)) { return }
    $role=$null
    if (Test-RunDiagnosticArgument $Process.CommandLine $Context.VerifyScript -FileArgument) { $role='verification' }
    elseif (Test-RunDiagnosticArgument $Process.CommandLine $Context.RoleScript -FileArgument) {
        foreach ($candidate in $Context.Roles) {
            if ($candidate -ne 'verification' -and (Test-RunDiagnosticArgument $Process.CommandLine $candidate)) {
                if ($role) { return }
                $role=$candidate
            }
        }
    }
    if (-not $role) { return }
    try { $created=ConvertTo-RunDiagnosticUtc $Process.CreationDate } catch { return }
    if ($created -lt $Context.StartedAfter -or $created -gt [DateTime]::UtcNow.AddSeconds(5)) { return }
    [pscustomobject]@{
        ProcessId=[int]$Process.ProcessId; ParentProcessId=[int]$Process.ParentProcessId
        Name=[string]$Process.Name; SessionId=[int]$Process.SessionId; Role=$role
        CreationUtc=$created; CommandLine=[string]$Process.CommandLine
    }
}

function Get-RunDiagnosticProcesses($Context) {
    $filter="SessionId = $($Context.SessionId) AND (Name = 'R.exe' OR Name = 'Rterm.exe' OR Name = 'Rscript.exe')"
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Filter $filter -ErrorAction Stop)) {
        Get-RunDiagnosticProcessMatch $Context $p
    }
}

function Open-RunDiagnosticProcess($Context, $Expected) {
    # Pin the native handle before the second identity check. Do not act on a PID
    # that has been reused since the initial process inventory.
    $native=Get-Process -Id $Expected.ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $native) { return }
    $keep=$false
    try {
        [void]$native.Handle
        if ([Math]::Abs(($native.StartTime.ToUniversalTime()-$Expected.CreationUtc).TotalMilliseconds) -gt 10) { return }
        $current=Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($Expected.ProcessId)" -ErrorAction Stop
        $matched=Get-RunDiagnosticProcessMatch $Context $current
        if ($null -eq $matched -or $matched.CreationUtc -ne $Expected.CreationUtc -or
            $matched.CommandLine -cne $Expected.CommandLine -or $matched.Role -cne $Expected.Role) { return }
        $keep=$true
        return $native
    } finally { if (-not $keep) { $native.Dispose() } }
}

function Stop-RunDiagnosticProcess($Context, $Expected) {
    $native=Open-RunDiagnosticProcess $Context $Expected
    if ($null -eq $native) { return $false }
    try { Stop-Process -InputObject $native -Force -ErrorAction Stop; return $true }
    finally { $native.Dispose() }
}

function Get-RunDiagnosticStopOrder([object[]]$Processes) {
    $ranked=foreach ($p in $Processes) {
        $depth=0; $parent=$p.ParentProcessId; $seen=@{}
        while ($parent -and -not $seen.ContainsKey($parent) -and $depth -lt 64) {
            $seen[$parent]=$true
            $match=@($Processes | Where-Object { $_.ProcessId -eq $parent })
            if (-not $match.Count) { break }
            $depth++; $parent=$match[0].ParentProcessId
        }
        [pscustomobject]@{Depth=$depth; Process=$p}
    }
    $ranked | Sort-Object Depth -Descending | ForEach-Object { $_.Process }
}

function Copy-RunDiagnosticFile([string]$Root,[string]$RelativePath,[string]$Destination) {
    $source=[IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $prefix=[IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if (-not $source.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Diagnostic path escaped the run directory.' }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return }
    $item=Get-Item -LiteralPath $source
    for ($check=$item; $null -ne $check -and $check.FullName -ne $Root; $check=$check.Parent) {
        if ($check.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Diagnostic collection refuses linked files/directories.' }
        if ($check -is [IO.FileInfo]) { $check=$check.Directory; if ($check.FullName -eq $Root) { break } }
        if ($check.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Diagnostic collection refuses linked files/directories.' }
    }
    $target=Join-Path $Destination $RelativePath
    New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
    $inputStream=$null; $outputStream=$null
    try {
        $inputStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $remaining=$inputStream.Length
        $outputStream=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $buffer=New-Object byte[] 65536
        while ($remaining -gt 0) {
            $count=$inputStream.Read($buffer,0,[int][Math]::Min($buffer.Length,$remaining))
            if (-not $count) { break }
            $outputStream.Write($buffer,0,$count); $remaining-=$count
        }
    } finally {
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $outputStream) { $outputStream.Dispose() }
    }
}

function Get-RunDiagnosticFiles($Context) {
    foreach ($name in @('run.json','processes.json','run-status.json','monitor.log','SUCCESS.txt',
        'failure.txt','db-startup-watchdog.log','sql-prepare-watchdog.log','sql-operation-watchdog.log')) {
        if (Test-Path -LiteralPath (Join-Path $Context.Root $name) -PathType Leaf) { $name }
    }
    foreach($site in @($Context.Config.sites)) {
        foreach($prefix in @('db-startup-timeout-','sql-prepare-timeout-','sql-operation-timeout-')) {
            $name=$prefix+$site+'.json'
            if(Test-Path -LiteralPath (Join-Path $Context.Root $name) -PathType Leaf){$name}
        }
    }
    $directories=@($Context.Roles)
    if($Context.Config.PSObject.Properties['mode'] -and $Context.Config.mode -eq 'SelectedMethods') {
        $directories+=@('baselines')
        $directories+=@($Context.Config.sites | ForEach-Object {'extraction/'+$_})
    }
    foreach ($role in @($directories | Select-Object -Unique)) {
        foreach ($name in @('run.stdout.log','run.stderr.log','progress.jsonl','db-startup-start.json',
            'db-startup-ready.json','db-startup-phase.json','sql-prepare-state.json','sql-operation-state.json')) {
            $relative=Join-Path $role $name
            if (Test-Path -LiteralPath (Join-Path $Context.Root $relative) -PathType Leaf) { $relative }
        }
        foreach ($folder in @('sql-diagnostics','diagnostics')) {
            $diagnostics=Join-Path $Context.Root (Join-Path $role $folder)
            if (Test-Path -LiteralPath $diagnostics -PathType Container) {
                foreach ($file in @(Get-ChildItem -LiteralPath $diagnostics -File)) {
                    if ($file.Extension -eq '.sql' -or $file.Name -in @('operations.tsv','connection.tsv','probe-events.tsv','errorReportSql.txt')) {
                        Join-Path (Join-Path $role $folder) $file.Name
                    }
                }
            }
        }
    }
}

function Invoke-RunDiagnosticThreadDump([string]$Jcmd, [int]$RuntimePid, [string]$OutputFile,
    [ValidateRange(1,15)][int]$TimeoutSeconds=15) {
    $process=New-Object Diagnostics.Process
    $process.StartInfo=New-Object Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName=$Jcmd
    $process.StartInfo.Arguments="$RuntimePid Thread.print -l"
    $process.StartInfo.UseShellExecute=$false
    $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true
    $process.StartInfo.RedirectStandardError=$true
    try {
        if (-not $process.Start()) { throw 'jcmd could not start.' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $timedOut=-not $process.WaitForExit($TimeoutSeconds*1000)
        if ($timedOut) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $tasks=[Threading.Tasks.Task[]]@($stdout,$stderr)
        $complete=[Threading.Tasks.Task]::WaitAll($tasks,2000)
        $text="Diagnostic PID=$RuntimePid; UTC=$([DateTime]::UtcNow.ToString('o')); timeout=$timedOut`r`n"
        if ($complete) { $text+=$stdout.GetAwaiter().GetResult()+"`r`n"+$stderr.GetAwaiter().GetResult() }
        else { $text+='jcmd output pipes did not finish within the diagnostic time limit.' }
        [IO.File]::WriteAllText($OutputFile,$text,(New-Object Text.UTF8Encoding($false)))
    } finally { $process.Dispose() }
}
