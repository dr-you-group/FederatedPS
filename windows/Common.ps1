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
    $rscript = Join-Path $RHome 'bin\Rscript.exe'
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
    $env:DATABASECONNECTOR_JAR_FOLDER = $jdbc
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

function Start-FederatedWorker {
    param([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory,
          [string]$LogPrefix, [string]$Role)
    $parameters = @{
        FilePath = $Executable
        ArgumentList = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
        WorkingDirectory = $WorkingDirectory
        RedirectStandardOutput = "$LogPrefix.stdout.log"
        RedirectStandardError = "$LogPrefix.stderr.log"
        PassThru = $true
    }
    if ($env:OS -eq 'Windows_NT') { $parameters.WindowStyle = 'Hidden' }
    [pscustomobject]@{ Role = $Role; Process = (Start-Process @parameters); LogPrefix = $LogPrefix }
}

function Wait-FederatedWorkers([object[]]$Workers, [int]$TimeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $active = 0
        foreach ($worker in $Workers) {
            $worker.Process.Refresh()
            if ($worker.Process.HasExited) {
                $worker.Process.WaitForExit()
                if ($worker.Process.ExitCode -ne 0) {
                    throw "Role $($worker.Role) failed (exit $($worker.Process.ExitCode)). See $($worker.LogPrefix).stderr.log"
                }
            } else { $active++ }
        }
        if ($active -eq 0) { break }
        if ([DateTime]::UtcNow -ge $deadline) { throw "Run timed out after $TimeoutSeconds seconds. See per-role logs." }
        Start-Sleep -Milliseconds 200
    }
}

function Stop-FederatedWorkers([object[]]$Workers) {
    foreach ($worker in $Workers) {
        if (-not $worker.Process.HasExited) { $worker.Process.Kill(); $worker.Process.WaitForExit() }
        $worker.Process.Dispose()
    }
}
