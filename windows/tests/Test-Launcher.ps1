#Requires -Version 5.1
<# No R, database, Pester, or Internet needed. Run with Windows PowerShell 5.1. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\Common.ps1')
function Assert-Throws([scriptblock]$Action, [string]$Pattern) {
    $caught = $false
    try { & $Action } catch {
        $caught = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw }
    }
    if (-not $caught) { throw "Expected failure matching $Pattern" }
}
Assert-FederatedNames 'run01' @('site1','site2')
Assert-Throws { Assert-FederatedNames '../run' @('site1','site2') } 'alphanumeric'
Assert-Throws { Assert-FederatedNames 'run' @('site1','SITE1') } 'unique'
Assert-Throws { Assert-FederatedNames 'run' @('total','site2') } 'reserved'
Assert-Throws { Assert-FederatedNames 'run' @('aggregator','site2') } 'reserved'

$root = Join-Path ([IO.Path]::GetTempPath()) ('fedps launcher ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$child = Join-Path $root 'child with spaces.ps1'
@'
param([string]$Output, [string]$Value, [int]$Code = 0, [int]$Delay = 0)
[IO.File]::WriteAllText($Output, $Value)
if ($Delay) { Start-Sleep -Seconds $Delay }
exit $Code
'@ | Set-Content -LiteralPath $child -Encoding UTF8
$binaryName = if ($env:OS -ne 'Windows_NT') { 'pwsh' } elseif ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
$executable = Join-Path $PSHOME $binaryName
$output = Join-Path $root 'received.txt'
$value = 'path with spaces and "quotes" and trailing\'
$workers = @()
try {
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,$output,$value) $root (Join-Path $root 'roundtrip') 'roundtrip'
    Wait-FederatedWorkers $workers 30
    if ([IO.File]::ReadAllText($output) -cne $value) { throw 'Native argument roundtrip failed.' }
} finally { Stop-FederatedWorkers $workers }

$workers = @()
try {
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,$output,'slow','0','30') $root (Join-Path $root 'slow') 'slow'
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,(Join-Path $root 'failed.txt'),'fail','7') $root (Join-Path $root 'failed') 'failed'
    $ownedIds = @($workers | ForEach-Object { $_.Process.Id })
    Assert-Throws { Wait-FederatedWorkers $workers 30 } 'failed.*exit 7'
} finally { Stop-FederatedWorkers $workers }
foreach ($idValue in $ownedIds) {
    if (Get-Process -Id $idValue -ErrorAction SilentlyContinue) { throw 'An owned worker was not stopped after failure.' }
}
$workers = @()
try {
    $workers += Start-FederatedWorker $executable @('-NoProfile','-File',$child,$output,'slow','0','30') $root (Join-Path $root 'timeout') 'timeout'
    Assert-Throws { Wait-FederatedWorkers $workers 1 } 'timed out'
} finally { Stop-FederatedWorkers $workers }
Write-Host "PASS: identifiers, argument roundtrip, nonzero exits, owned-worker cleanup and timeout. Logs: $root"
