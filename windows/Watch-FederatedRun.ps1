#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RunDirectory, [switch]$NoProgress,
      [switch]$Once, [ValidateRange(1,3600)][int]$StatusSeconds=15)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Monitor.ps1')
$RunDirectory=(Resolve-Path -LiteralPath $RunDirectory).Path
$config=Get-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$roles=@('aggregator')+@($config.sites)+@('verification')
foreach($role in $roles) { if($role -notmatch '^[A-Za-z0-9]+$'){throw 'Invalid role in run configuration.'} }
$monitor=New-FederatedMonitor -RunDirectory $RunDirectory -Roles $roles -ReadOnly -NoProgress:$NoProgress -StatusSeconds $StatusSeconds
$monitor.Started=(Get-Item -LiteralPath (Join-Path $RunDirectory 'run.json')).LastWriteTimeUtc
Write-Host 'Read-only monitor. Ctrl+C stops this viewer only. Legacy runs have logs but no stage/ETA events.'

function Get-FederatedWatchedProcess($Entry) {
    $parent=$null
    try {
        $candidate=Get-Process -Id $Entry.pid -ErrorAction SilentlyContinue
        if ($candidate -and $null -ne $candidate.StartTime -and $Entry.startUtc -and
            [Math]::Abs(($candidate.StartTime.ToUniversalTime()-(ConvertTo-FederatedUtc $Entry.startUtc)).TotalSeconds) -lt 1) {
            $parent=$candidate
        } elseif($candidate) { $candidate.Dispose() }
        if ($env:OS -ne 'Windows_NT') { return $parent }
        # Older launches retained an architecture-wrapper PID. The first R
        # event identifies the interpreter, but a saved PID alone is unsafe:
        # require the original creation window and this run's exact arguments.
        $eventPath=Join-Path (Join-Path $RunDirectory $Entry.role) 'progress.jsonl'
        if (-not (Test-Path -LiteralPath $eventPath)) { return $parent }
        $first=Get-Content -LiteralPath $eventPath -TotalCount 1 -Encoding UTF8 | ConvertFrom-Json
        if (-not $first.PSObject.Properties['pid'] -or $first.role -ne $Entry.role -or
            [int]$first.pid -eq [int]$Entry.pid -or -not $Entry.startUtc) { return $parent }
        $runtimeId=[int]$first.pid
        if ($runtimeId -le 0) { return $parent }
        $identity=Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $runtimeId) -ErrorAction Stop
        if (-not $identity -or $identity.Name -notin @('Rscript.exe','Rterm.exe','R.exe') -or
            -not $identity.CommandLine -or -not $identity.CreationDate) { return $parent }
        $created=ConvertTo-FederatedUtc $identity.CreationDate
        $wrapperStarted=ConvertTo-FederatedUtc $Entry.startUtc
        $eventStarted=ConvertTo-FederatedUtc $first.timestamp
        $configPath=Join-Path $RunDirectory 'run.json'
        if ($created -lt $wrapperStarted.AddSeconds(-1) -or $created -gt $eventStarted.AddSeconds(1) -or
            $identity.CommandLine -notmatch [regex]::Escape($configPath) -or
            $identity.CommandLine -notmatch '(?i)(?:\\|/)run-role[.]R' -or
            $identity.CommandLine -notmatch ('(?i)(?:^|\s|")'+[regex]::Escape([string]$Entry.role)+'"?\s*$')) {
            return $parent
        }
        $actual=Get-Process -Id $runtimeId -ErrorAction SilentlyContinue
        if ($actual -and $null -ne $actual.StartTime -and
            [Math]::Abs(($actual.StartTime.ToUniversalTime()-$created).TotalSeconds) -lt 1) {
            if ($parent) { $parent.Dispose() }
            return $actual
        }
        if ($actual) { $actual.Dispose() }
    } catch { }
    $parent
}

try {
    do {
        $workers=@()
        $path=Join-Path $RunDirectory 'processes.json'
        if (Test-Path -LiteralPath $path) {
            try {
                foreach($entry in @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)) {
                    if ($entry.role -notin $roles) { continue }
                    $p=Get-FederatedWatchedProcess $entry
                    if ($p) {
                        $workers += [pscustomobject]@{Role=$entry.role; Process=$p}
                    }
                }
            } catch { }
        }
        try { Update-FederatedMonitor $monitor $workers -Force:$Once }
        finally { foreach($worker in $workers){$worker.Process.Dispose()} }
        if (Test-Path -LiteralPath (Join-Path $RunDirectory 'SUCCESS.txt')) { Write-Host 'SUCCESS.txt exists: final verification passed.'; break }
        $statusPath=Join-Path $RunDirectory 'run-status.json'
        if (Test-Path -LiteralPath $statusPath) {
            try { $status=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } catch { $status=$null }
            if ($status -and $status.state -eq 'failed') { Write-Host 'Run failed. Inspect the role stderr logs.'; break }
        }
        if (-not $Once) { Start-Sleep -Seconds 1 }
    } while (-not $Once)
} finally { Complete-FederatedMonitor $monitor }
