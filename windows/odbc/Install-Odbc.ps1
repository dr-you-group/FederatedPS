#Requires -Version 5.1
<# Install local ODBC payload. Source/RUN files are intentionally not hash-gated. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PayloadRoot,
      [string]$InstallRoot='C:\FederatedPS',
      [string]$RHome='C:\Program Files\R\R-4.6.1',
      [switch]$InstallVcRuntime)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Run this installer in 64-bit Windows PowerShell 5.1.'
}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open PowerShell as Administrator to install the Microsoft ODBC driver.'
}
$busy=@(Get-Process -Name R,Rgui,Rterm,Rscript,rsession -ErrorAction SilentlyContinue)
if($busy.Count) { throw 'Save and close R/RStudio and running analyses before installing ODBC dependencies. No processes were stopped.' }
$root=(Resolve-Path -LiteralPath $PayloadRoot).Path
. (Join-Path $PSScriptRoot '..\Common.ps1')
$rscript=Join-Path $RHome 'bin\x64\Rscript.exe'
if(-not (Test-Path -LiteralPath $rscript -PathType Leaf)) { throw "R 4.6.1 x64 is missing: $rscript" }
$base=Join-Path $InstallRoot 'RLibrary\4.6'
$overlay=Join-Path $InstallRoot 'RLibrary\windows-block'
foreach($path in @($base,$overlay)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
$logs=Join-Path $InstallRoot ('logs\odbc-install-'+[DateTime]::Now.ToString('yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $logs -Force | Out-Null

function Get-OdbcPayloadFile([string]$Relative,[string]$Sha256,[long]$Bytes) {
    if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Invalid ODBC payload manifest entry.'
    }
    $path=Join-Path $root $Relative
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing ODBC payload: $Relative" }
    if((Get-Item -LiteralPath $path).Length -ne $Bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $Sha256) {
        throw "Downloaded installer/archive is damaged: $Relative. Recopy that payload file; editable scripts are not checked."
    }
    $path
}
function Assert-MicrosoftInstaller([string]$Path) {
    $signature=Get-AuthenticodeSignature -LiteralPath $Path
    if($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
       $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw "Microsoft installer signature validation failed: $Path ($($signature.Status)). Check the machine's trusted certificates; the installer was not executed."
    }
}
function Invoke-OdbcInstaller([string]$Executable,[string[]]$Arguments,[string]$Label,[int[]]$ExtraSuccess=@()) {
    $p=New-Object System.Diagnostics.Process
    try {
        $p.StartInfo.FileName=$Executable
        $p.StartInfo.Arguments=(($Arguments | ForEach-Object {ConvertTo-NativeArgument $_}) -join ' ')
        $p.StartInfo.UseShellExecute=$false
        $p.StartInfo.CreateNoWindow=$true
        if(-not $p.Start()) { throw "$Label could not be started." }
        # Retain the native handle, including for very short-lived installers.
        $p.WaitForExit()
        $code=$p.ExitCode
    } finally { $p.Dispose() }
    if($null -eq $code) { throw "$Label completion could not be verified. Logs: $logs" }
    if($code -in @(3010,1641)) { throw "$Label requested a restart. Restart Windows, then rerun APPLY_ODBC.ps1; completed installation stages are reused." }
    if($code -ne 0 -and $code -notin $ExtraSuccess) { throw "$Label failed with exit $code. Logs: $logs" }
}
$lock=Get-Content -LiteralPath (Join-Path $root 'ODBC_INSTALLER_LOCK.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if($lock.format -ne 'FederatedPS-odbc-installers-v1' -or $lock.driverName -ne 'ODBC Driver 18 for SQL Server') { throw 'Invalid ODBC installer lock.' }
$packages=Get-Content -LiteralPath (Join-Path $root 'packages\ODBC_PACKAGE_LOCK.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if($packages.format -ne 'FederatedPS-odbc-packages-v1' -or $packages.rVersion -ne '4.6.1' -or $packages.architecture -ne 'x64') { throw 'Invalid ODBC package lock.' }
foreach($package in $packages.packages) {
    [void](Get-OdbcPayloadFile ('packages/'+[string]$package.File) ([string]$package.SHA256) ([long]$package.Bytes))
}
$msiEntry=@($lock.installers | Where-Object { $_.file -match '[.]msi$' })
if($msiEntry.Count -ne 1) { throw 'Expected one Microsoft ODBC x64 MSI.' }
$msi=Get-OdbcPayloadFile $msiEntry[0].file $msiEntry[0].sha256 $msiEntry[0].bytes
if($InstallVcRuntime) {
    # Driver 18.7 bundles its runtime; this optional redistributable is retained
    # for other applications on the offline host and is not installed by default.
    $vcEntry=@($lock.installers | Where-Object { $_.file -eq 'installers/vc_redist.x64.exe' })
    if($vcEntry.Count -ne 1) { throw 'The optional VC++ runtime payload is missing.' }
    $vc=Get-OdbcPayloadFile $vcEntry[0].file $vcEntry[0].sha256 $vcEntry[0].bytes
    Assert-MicrosoftInstaller $vc
    Invoke-OdbcInstaller $vc @('/install','/quiet','/norestart','/log',(Join-Path $logs 'vcredist.log')) 'VC++ x64 runtime' @(1638)
}
$registered=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue
$driverReady=$false
if($null -ne $registered -and $registered.PSObject.Properties['Driver'] -and (Test-Path -LiteralPath $registered.Driver)) {
    $version=(Get-Item -LiteralPath $registered.Driver).VersionInfo.FileVersion
    $match=[regex]::Match($version,'\d+[.]\d+[.]\d+[.]\d+')
    $driverReady=$match.Success -and [version]$match.Value -ge [version]$lock.driverVersion
}
if(-not $driverReady) {
    Assert-MicrosoftInstaller $msi
    Write-Host "Installing Microsoft ODBC Driver $($lock.driverVersion) x64 from the local MSI..."
    Invoke-OdbcInstaller (Join-Path $env:SystemRoot 'System32\msiexec.exe') @('/i',$msi,'/qn','/norestart','IACCEPTMSODBCSQLLICENSETERMS=YES','ADDLOCAL=ALL','/L*v',(Join-Path $logs 'msodbcsql.log')) 'Microsoft ODBC Driver 18'
} else { Write-Host 'Microsoft ODBC Driver 18 is already installed at the bundled version or later.' }
$env:R_LIBS_USER="$overlay;$base"
$env:R_LIBS=$env:R_LIBS_USER
$worker=$null
try {
    Write-Host "Installing/loading local R ODBC packages (maximum 300 seconds). Logs: $logs"
    $worker=Start-FederatedRWorker -Runtime ([pscustomobject]@{Rscript=$rscript}) `
        -Script (Join-Path $PSScriptRoot 'install-odbc-packages.R') `
        -Arguments @((Join-Path $root 'packages'),$base,$overlay) `
        -WorkingDirectory $root -LogPrefix (Join-Path $logs 'r-packages') -Role 'odbc-install'
    Wait-FederatedWorkers -Workers @($worker) -TimeoutSeconds 300
    Get-Content -LiteralPath (Join-Path $logs 'r-packages.stdout.log') -Encoding UTF8 | Write-Host
} finally { if($null -ne $worker) { Stop-FederatedWorkers @($worker) } }
Write-Host "PASS: offline ODBC dependencies installed. Installer logs: $logs" -ForegroundColor Green
