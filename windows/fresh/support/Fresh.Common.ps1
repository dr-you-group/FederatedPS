#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-FreshWindows([switch]$Administrator) {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit Windows PowerShell 5.1 on Windows Server 2022 x64.'
    }
    if ($Administrator) {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Open Windows PowerShell as Administrator for SETUP/installation.'
        }
    }
}
function Assert-FreshNoR {
    $busy = @(Get-Process -Name R,Rgui,Rterm,Rscript,rsession -ErrorAction SilentlyContinue)
    if ($busy.Count) {
        $busy | Select-Object Id,ProcessName,SessionId | Format-Table -AutoSize | Out-Host
        throw 'Close active R/RStudio processes before changing installed packages. No processes were stopped.'
    }
}
function Get-FreshJavaHome {
    $candidates = @(Get-ChildItem -LiteralPath 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\java.exe') })
    if (-not $candidates.Count) { throw 'Temurin JDK 17 is missing; run 01_INSTALL_RUNTIME.ps1.' }
    $candidates[0].FullName
}
function Get-FreshPayloadPath([string]$Root,[string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw 'Unsafe payload path.' }
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Payload path leaves bundle.' }
    $path
}
# Source/scripts are intentionally editable after transfer. Keep the original
# manifest as provenance; never rewrite it to bless changed installer bytes.
function Test-FreshEditablePath([string]$Relative) {
    $path=$Relative.Replace('\','/')
    if($path -eq 'FederatedPS/windows/runtime-lock.json'){return $false}
    if($path -match '^FederatedPS/(DESCRIPTION|NAMESPACE|LICENSE|[.]Rbuildignore)$'){return $true}
    if($path -match '^FederatedPS/' -and $path -match '[.](R|ps1|sql|md|json|ya?ml|csv|tsv|Rd|txt|example)$'){return $true}
    if($path -match '^[^/]+[.](ps1|md)$'){return $true}
    if($path -match '^support/[^/]+[.](R|ps1)$'){return $true}
    if($path -match '^diagnostics/[^/]+[.]sql$'){return $true}
    return $false
}
function Test-FreshManifest([string]$Root,[switch]$StrictSource) {
    $manifest = Get-Content -LiteralPath (Join-Path $Root 'BUNDLE_MANIFEST.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.format -ne 'FederatedPS-fresh-v1' -or -not $manifest.files.Count) { throw 'Invalid fresh-install manifest.' }
    $seen = @{}
    $edits=New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $manifest.files) {
        if ($seen.ContainsKey([string]$entry.path) -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid manifest entry.' }
        $seen[[string]$entry.path] = $true
        $path = Get-FreshPayloadPath $Root $entry.path
        $exists=Test-Path -LiteralPath $path -PathType Leaf
        $same=$exists -and (Get-Item -LiteralPath $path -Force).Length -eq [long]$entry.bytes -and
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $entry.sha256
        if($same){continue}
        if(-not $StrictSource -and (Test-FreshEditablePath $entry.path)) {
            $edits.Add([string]$entry.path)
            continue
        }
        if(-not $exists){throw "Missing bundled file: $($entry.path)"}
        throw "Integrity failure: $($entry.path)"

    }
    foreach ($relative in @('installers/R-4.6.1-win.exe','installers/rtools45-6768-6492.exe',
        'installers/Temurin17-JDK-windows-x64.msi','installers/RStudio-2026.10.0-233.exe',
        'packages/PACKAGE_LOCK.dcf','packages/PACKAGE_LOCK.json','FederatedPS/DESCRIPTION',
        'FederatedPS/windows/runtime-lock.json','RUN.ps1')) {
        if (-not $seen.ContainsKey($relative)) { throw "Required payload is not in manifest: $relative" }
        if(-not (Test-Path -LiteralPath (Get-FreshPayloadPath $Root $relative) -PathType Leaf)){throw "Missing required payload: $relative"}
    }
    $lock = Get-Content -LiteralPath (Join-Path $Root 'packages/PACKAGE_LOCK.json') -Raw | ConvertFrom-Json
    foreach ($package in $lock.packages) {
        $key = 'packages/' + [string]$package.file
        if (-not $seen.ContainsKey($key)) { throw "Dependency archive absent from manifest: $key" }
    }
    if($edits.Count) {
        Write-Host ("LOCAL EDIT accepted ({0} source/script files): {1}" -f $edits.Count,($edits -join ', ')) -ForegroundColor Yellow
        Write-Host 'R/package changes require 10_UPDATE_PACKAGE.ps1 or RUN.ps1 -UpdatePackage. Use 00_VERIFY.ps1 -StrictSource to compare every source file with the release.'
    }
    Write-Host "PASS: immutable payload and $($lock.packages.Count) Windows package archives verified; $($edits.Count) local source edits allowed." -ForegroundColor Green
}
function Invoke-FreshInstaller([string]$Executable,[string]$InstallerArguments,[string]$Label,[string]$LogFile) {
    Write-Host "Installing $Label from local payload..."
    $process = Start-Process -FilePath $Executable -ArgumentList $InstallerArguments -Wait -PassThru
    $code = $process.ExitCode
    "$([DateTime]::UtcNow.ToString('o')) $Label exit=$code" | Add-Content -LiteralPath $LogFile -Encoding UTF8
    if ($code -eq 3010 -or $code -eq 1641) { throw "$Label requested a Windows restart. Restart, then rerun SETUP.ps1; completed stages are checked again." }
    if ($code -ne 0) { throw "$Label installer failed with exit $code. See $LogFile" }
}
function Get-FreshRuntime([string]$Root,[string]$InstallRoot='C:\FederatedPS',[switch]$PrepareDirectories) {
    Assert-FreshWindows
    if ($PrepareDirectories) {
        foreach ($relative in @('RLibrary\4.6','RLibrary\windows-block','jdbc')) {
            New-Item -ItemType Directory -Path (Join-Path $InstallRoot $relative) -Force | Out-Null
        }
    }
    . (Join-Path $Root 'FederatedPS\windows\Common.ps1')
    Set-FederatedEnvironment -InstallRoot $InstallRoot -RHome 'C:\Program Files\R\R-4.6.1' -JavaHome (Get-FreshJavaHome) -ForInstall:$PrepareDirectories
}
function Invoke-FreshRenderCheck([string]$Root,[string]$InstallRoot='C:\FederatedPS',[int]$TimeoutSeconds=60) {
    $runtime = Get-FreshRuntime $Root $InstallRoot
    . (Join-Path $Root 'FederatedPS\windows\Common.ps1')
    . (Join-Path $Root 'FederatedPS\windows\RunDiagnostics.Common.ps1')
    $logs = Join-Path $Root ('logs\render-check-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $worker = $null
    try {
        $worker = Start-FederatedRWorker -Runtime $runtime -Script (Join-Path $Root 'support\render-check.R') `
            -Arguments @((Join-Path $Root 'FederatedPS')) -WorkingDirectory $Root -LogPrefix (Join-Path $logs 'render') -Role 'render-check'
        Wait-FederatedWorkers -Workers @($worker) -TimeoutSeconds $TimeoutSeconds
        Get-Content -LiteralPath (Join-Path $logs 'render.stdout.log') -Encoding UTF8 | Write-Host
        Write-Host "PASS: isolated local SQL rendering check. Logs: $logs" -ForegroundColor Green
    } catch {
        $failure = $_
        if ($null -ne $worker) {
            $worker.Process.Refresh()
            if (-not $worker.Process.HasExited) {
                $jcmd = Join-Path $env:JAVA_HOME 'bin\jcmd.exe'
                if (Test-Path -LiteralPath $jcmd) {
                    try { Invoke-RunDiagnosticThreadDump -Jcmd $jcmd -RuntimePid $worker.Process.Id -OutputFile (Join-Path $logs 'render-threads.txt') }
                    catch { Write-Warning "Thread snapshot unavailable: $($_.Exception.Message)" }
                }
            }
        }
        throw "Local rendering preflight failed; analysis was not started. $($failure.Exception.Message) Logs: $logs"
    } finally { if ($null -ne $worker) { Stop-FederatedWorkers @($worker) } }
}
