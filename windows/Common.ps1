#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FederatedProject {
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-FederatedLock {
    Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime-lock.json') -Raw | ConvertFrom-Json
}

function Assert-FederatedNames([string]$RunId, [string[]]$Sites) {
    if ($RunId -cnotmatch '^[A-Za-z0-9]+$') { throw 'RunId must be alphanumeric.' }
    if ($Sites.Count -lt 2) { throw 'At least two sites are required.' }
    if (@($Sites | Sort-Object -Unique).Count -ne $Sites.Count) { throw 'Site names must be unique (case insensitive on Windows).' }
    foreach ($site in $Sites) {
        if ($site -cnotmatch '^[A-Za-z0-9]+$' -or $site -in @('aggregator', 'total')) {
            throw 'Site names must be alphanumeric; aggregator and total are reserved.'
        }
    }
}

function Set-FederatedEnvironment {
    param([string]$InstallRoot = 'C:\FederatedPS',
          [string]$RHome = 'C:\Program Files\R\R-4.6.1', [string]$JavaHome = '',
          [switch]$ForInstall)
    if ($env:OS -ne 'Windows_NT') { throw 'Use 64-bit Windows PowerShell on the Windows host.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell.' }
    $base = Join-Path $InstallRoot 'RLibrary\4.6'
    $overlay = Join-Path $InstallRoot 'RLibrary\windows-block'
    # bin/Rscript.exe is R's architecture-selection wrapper (Rfe.exe).
    # Its child performs the actual R work. The pinned x64 installation's
    # architecture executable runs R directly, retaining normal Rscript
    # semantics while making Process.Id equal Sys.getpid() in role events.
    $rscript = Join-Path $RHome 'bin\x64\Rscript.exe'
    if (-not (Test-Path -LiteralPath $rscript -PathType Leaf)) {
        throw "Direct x64 Rscript.exe not found: $rscript. Repair the pinned x64 R installation; the bin wrapper is not a safe fallback."
    }
    $jdbc = Join-Path $InstallRoot 'jdbc'
    foreach ($path in @($base, $rscript, $jdbc)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Offline prerequisite missing: $path. Complete bundle steps 10-13 first." }
    }
    if ($ForInstall) { New-Item -ItemType Directory -Path $overlay -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $overlay -PathType Container)) {
        throw 'Run windows\Install-Offline.ps1 first; the old Cyclops 3.7.1 does not support block CCD.'
    }
    if (-not $JavaHome) {
        $candidates = @(Get-ChildItem -LiteralPath 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') })
        if ($candidates.Count -eq 0) { throw 'Temurin 17 not found; supply -JavaHome.' }
        $JavaHome = $candidates[0].FullName
    }
    if (-not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\java.exe'))) { throw 'Invalid JavaHome.' }
    $env:R_LIBS_USER = "$overlay;$base"
    $env:R_LIBS = $env:R_LIBS_USER
    $env:FP_LIB = $env:R_LIBS_USER
    $env:FEDERATEDPS_LIBRARY = $overlay
    $env:JAVA_HOME = $JavaHome
    $env:FEDERATEDPS_PROJECT = Get-FederatedProject
    $env:FEDERATEDPS_DEFAULT_JAR_FOLDER = $jdbc
    if (-not $env:DATABASECONNECTOR_JAR_FOLDER) { $env:DATABASECONNECTOR_JAR_FOLDER = $jdbc }
    $env:PATH = (Join-Path $JavaHome 'bin') + ';' + $env:PATH
    $env:OMP_NUM_THREADS = '1'
    $env:OPENBLAS_NUM_THREADS = '1'
    $env:MAKEFLAGS = '-j2'
    [pscustomobject]@{ Rscript = $rscript; RHome = $RHome; Library = $overlay; BaseLibrary = $base }
}

function Invoke-FederatedR([string]$Rscript, [string[]]$Arguments) {
    & $Rscript --vanilla @Arguments
    if ($LASTEXITCODE -ne 0) { throw "R failed (exit $LASTEXITCODE). See the R output above." }
}

# Start-Process joins ArgumentList with spaces in PowerShell 5.1. Quote using
# Windows CRT rules, including spaces, embedded quotes and trailing backslashes.
function ConvertTo-NativeArgument([AllowEmptyString()][string]$Value) {
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Start-FederatedRWorker {
    param($Runtime, [string]$Script, [string[]]$Arguments = @(),
          [string]$WorkingDirectory, [string]$LogPrefix, [string]$Role)
    if (-not $Runtime.PSObject.Properties['Rscript'] -or -not $Runtime.Rscript) {
        throw 'The runtime has no direct Rscript interpreter. Refresh Set-FederatedEnvironment.'
    }
    if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) { throw "R script not found: $Script" }
    $scriptPath = [IO.Path]::GetFullPath($Script)
    Start-FederatedWorker -Executable $Runtime.Rscript `
        -Arguments (@('--vanilla', $scriptPath) + @($Arguments)) `
        -WorkingDirectory $WorkingDirectory -LogPrefix $LogPrefix -Role $Role
}

function Stop-FederatedProcessTree([System.Diagnostics.Process]$Process) {
    $Process.Refresh()
    if ($Process.HasExited) { return }
    if ($env:OS -eq 'Windows_NT') {
        # PowerShell 5.1/.NET Framework has no Process.Kill(entireProcessTree).
        # Use the Windows utility only for this live, retained process handle;
        # never look up an arbitrary saved PID and terminate it.
        $killer = New-Object System.Diagnostics.Process
        try {
            $killer.StartInfo.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $killer.StartInfo.Arguments = '/PID ' + [string]$Process.Id + ' /T /F'
            $killer.StartInfo.UseShellExecute = $false
            $killer.StartInfo.CreateNoWindow = $true
            $killer.StartInfo.RedirectStandardOutput = $true
            $killer.StartInfo.RedirectStandardError = $true
            if (-not $killer.Start()) { throw 'Could not start taskkill for the owned worker.' }
            $output = $killer.StandardOutput.ReadToEndAsync()
            $errorOutput = $killer.StandardError.ReadToEndAsync()
            if (-not $killer.WaitForExit(10000)) {
                $killer.Kill()
                throw 'Timed out terminating the owned worker process tree.'
            }
            [void]$output.GetAwaiter().GetResult()
            $killError = $errorOutput.GetAwaiter().GetResult()
            $Process.Refresh()
            if ($killer.ExitCode -ne 0) {
                throw ('Could not verify termination of the complete owned worker tree (taskkill exit ' +
                    $killer.ExitCode + '): ' + $killError)
            }
        } finally { $killer.Dispose() }
    } else {
        # Non-Windows is used by the launcher regression tests only.
        $treeKill = $Process.GetType().GetMethod('Kill', [type[]]@([bool]))
        if ($null -ne $treeKill) { $Process.Kill($true) } else { $Process.Kill() }
    }
    if (-not $Process.WaitForExit(10000)) { throw 'Owned worker did not exit after termination.' }
}

function Start-FederatedWorker {
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory,
          [string]$LogPrefix, [string]$Role)
    # Windows PowerShell 5.1 Start-Process + redirected streams can return a
    # Process without its native handle, so ExitCode later reads as $null.
    # Starting through System.Diagnostics.Process retains the original handle,
    # including for children that finish before this function returns.
    $process = New-Object System.Diagnostics.Process
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process.StartInfo = $info
    $stdout = $null; $stderr = $null; $started = $false
    try {
        # Buffer size 1 disables the FileStream write buffer so short log lines
        # become visible to the live reader before the worker exits.
        $stdout = New-Object IO.FileStream("$LogPrefix.stdout.log", [IO.FileMode]::Create,
            [IO.FileAccess]::Write, [IO.FileShare]::Read, 1)
        $stderr = New-Object IO.FileStream("$LogPrefix.stderr.log", [IO.FileMode]::Create,
            [IO.FileAccess]::Write, [IO.FileShare]::Read, 1)
        $started = $process.Start()
        if (-not $started) { throw "Could not start role $Role." }
        # Drain both pipes concurrently using .NET tasks; no PowerShell event
        # handlers/runspaces and no pipe-buffer deadlocks on verbose R builds.
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        [pscustomobject]@{
            Role = $Role; Process = $process; LogPrefix = $LogPrefix
            StdoutStream = $stdout; StderrStream = $stderr
            StdoutTask = $stdoutTask; StderrTask = $stderrTask; Completed = $false; FinalExitCode = $null
        }
    } catch {
        $startFailure = $_
        try {
            if ($started -and -not $process.HasExited) { Stop-FederatedProcessTree $process }
        } catch { Write-Warning "Cleanup after worker startup failure: $($_.Exception.Message)" }
        finally {
            if ($null -ne $stdout) { $stdout.Dispose() }
            if ($null -ne $stderr) { $stderr.Dispose() }
            $process.Dispose()
        }
        throw $startFailure
    }
}

function Wait-FederatedWorkers([object[]]$Workers, [int]$TimeoutSeconds, $Monitor = $null) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        if ($null -ne $Monitor) { Update-FederatedMonitor $Monitor $Workers }
        $active = 0
        foreach ($worker in $Workers) {
            if ($worker.Completed) { continue }
            foreach ($task in @($worker.StdoutTask, $worker.StderrTask)) {
                if ($task.IsFaulted -or $task.IsCanceled) { [void]$task.GetAwaiter().GetResult() }
            }
            $worker.Process.Refresh()
            if ($worker.Process.HasExited -and $worker.StdoutTask.IsCompleted -and $worker.StderrTask.IsCompleted) {
                $worker.Process.WaitForExit()
                [void]$worker.StdoutTask.GetAwaiter().GetResult()
                [void]$worker.StderrTask.GetAwaiter().GetResult()
                $worker.StdoutStream.Flush()
                $worker.StderrStream.Flush()
                # ReadAllText opens with FileShare.Read on Windows. Even though
                # our writer allows readers, that new reader does not share an
                # existing write handle. Release writers before reporting done.
                $worker.StdoutStream.Dispose()
                $worker.StderrStream.Dispose()
                $exitCode = $worker.Process.ExitCode
                if ($worker.PSObject.Properties['FinalExitCode']) { $worker.FinalExitCode = $exitCode }
                if ($null -eq $exitCode) {
                    throw "No exit code was available for role $($worker.Role). Completion cannot be verified. See $($worker.LogPrefix).stderr.log"
                }
                if ($exitCode -ne 0) {
                    throw "Role $($worker.Role) failed (exit $exitCode). See $($worker.LogPrefix).stderr.log"
                }
                $worker.Completed = $true
            } else { $active++ }
        }
        if ($active -eq 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Run timed out after $TimeoutSeconds seconds. See per-role logs." }
        Start-Sleep -Milliseconds 200
    }
}

function Stop-FederatedWorkers([object[]]$Workers) {
    foreach ($worker in $Workers) {
        try {
            Stop-FederatedProcessTree $worker.Process
            if ($worker.Process.HasExited -and $worker.PSObject.Properties['FinalExitCode']) {
                $worker.FinalExitCode = $worker.Process.ExitCode
            }
            # Bound pipe cleanup as a descendant could still hold an inherited
            # pipe open. Do not let cleanup hide the original role/timeout error.
            $tasks = [System.Threading.Tasks.Task[]]@($worker.StdoutTask, $worker.StderrTask)
            if (-not [System.Threading.Tasks.Task]::WaitAll($tasks, 5000)) {
                Write-Warning "Log drain did not finish for role $($worker.Role)."
            }
        } catch {
            Write-Warning "Cleanup for role $($worker.Role): $($_.Exception.Message)"
        } finally {
            try {
                if ($worker.Process.HasExited -and $worker.PSObject.Properties['FinalExitCode']) {
                    $worker.FinalExitCode = $worker.Process.ExitCode
                }
            } catch { }
            $worker.Process.StandardOutput.Dispose()
            $worker.Process.StandardError.Dispose()
            $worker.StdoutStream.Dispose()
            $worker.StderrStream.Dispose()
            $worker.Process.Dispose()
        }
    }
}
