#Requires -Version 5.1
<# Run on an INTERNET-CONNECTED PC before transferring this checkout. #>
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Common.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$lock = Get-FederatedLock
$payload = Join-Path $PSScriptRoot 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
$archive = Join-Path $payload $lock.cyclopsArchive
$url = "https://codeload.github.com/$($lock.cyclopsRepository)/zip/$($lock.cyclopsCommit)"
if (-not (Test-Path -LiteralPath $archive)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $partial = "$archive.partial"
    Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $lock.cyclopsSha256) {
        throw "Cyclops SHA-256 mismatch: $partial. Do not transfer this download."
    }
    Move-Item -LiteralPath $partial -Destination $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $lock.cyclopsSha256) {
    throw "Cyclops SHA-256 mismatch: $archive"
}
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    $description = "Cyclops-$($lock.cyclopsCommit)/DESCRIPTION"
    if (-not $zip.GetEntry($description)) { throw 'Expected Cyclops source root not found.' }
} finally { $zip.Dispose() }
Write-Host "Ready: $archive" -ForegroundColor Green
$driverArchive = Join-Path $payload $lock.sqlServerArchive
if (-not (Test-Path -LiteralPath $driverArchive)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $partial = "$driverArchive.partial"
    Invoke-WebRequest -Uri $lock.sqlServerUrl -OutFile $partial -UseBasicParsing
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $lock.sqlServerSha256) {
        throw 'SQL Server JDBC archive SHA-256 mismatch. Do not transfer this download.'
    }
    Move-Item -LiteralPath $partial -Destination $driverArchive
}
if ((Get-FileHash -LiteralPath $driverArchive -Algorithm SHA256).Hash -ne $lock.sqlServerSha256) {
    throw 'SQL Server JDBC archive SHA-256 mismatch.'
}
$zip = [IO.Compression.ZipFile]::OpenRead($driverArchive)
try {
    if (-not $zip.GetEntry($lock.sqlServerJar)) { throw 'Expected SQL Server JDBC JAR not found.' }
} finally { $zip.Dispose() }
Write-Host "Ready: $driverArchive" -ForegroundColor Green
Write-Host 'Transfer this clean repository checkout including windows\payload to the offline host.'
Write-Host 'On that host, close all R/RStudio sessions and run windows\Install-Offline.ps1.'
