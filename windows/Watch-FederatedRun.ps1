#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RunDirectory, [switch]$NoProgress,
      [switch]$Once, [ValidateRange(1,3600)][int]$StatusSeconds=15)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Monitor.ps1')
$RunDirectory=(Resolve-Path -LiteralPath $RunDirectory).Path
$config=Get-Content -LiteralPath (Join-Path $RunDirectory 'run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$roles=@('aggregator')+@($config.sites)
if (Test-Path -LiteralPath (Join-Path $RunDirectory 'verification')) { $roles+=@('verification') }
$monitor=New-FederatedMonitor -RunDirectory $RunDirectory -Roles $roles -ReadOnly -NoProgress:$NoProgress -StatusSeconds $StatusSeconds
$monitor.Started=(Get-Item -LiteralPath (Join-Path $RunDirectory 'run.json')).LastWriteTimeUtc
Write-Host 'Read-only monitor. Ctrl+C stops this viewer only. Legacy runs have logs but no stage/ETA events.'
try {
    do {
        $workers=@()
        $path=Join-Path $RunDirectory 'processes.json'
        if (Test-Path -LiteralPath $path) {
            try {
                foreach($entry in @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)) {
                    $p=Get-Process -Id $entry.pid -ErrorAction SilentlyContinue
                    if ($p -and $null -ne $p.StartTime -and $entry.startUtc -and
                        [Math]::Abs(($p.StartTime.ToUniversalTime()-(ConvertTo-FederatedUtc $entry.startUtc)).TotalSeconds) -lt 1) {
                        $workers += [pscustomobject]@{Role=$entry.role; Process=$p}
                    }
                }
            } catch { }
        }
        Update-FederatedMonitor $monitor $workers -Force:$Once
        if (Test-Path -LiteralPath (Join-Path $RunDirectory 'SUCCESS.txt')) { Write-Host 'SUCCESS.txt exists: final verification passed.'; break }
        $statusPath=Join-Path $RunDirectory 'run-status.json'
        if (Test-Path -LiteralPath $statusPath) {
            try { $status=Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } catch { $status=$null }
            if ($status -and $status.state -eq 'failed') { Write-Host 'Run failed. Inspect the role stderr logs.'; break }
        }
        if (-not $Once) { Start-Sleep -Seconds 1 }
    } while (-not $Once)
} finally { Complete-FederatedMonitor $monitor }
