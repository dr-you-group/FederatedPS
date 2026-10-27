#Requires -Version 5.1
# Install isolated drivers. Existing JARs are not scanned or selected by order.
function Install-FederatedJdbc {
    param([string]$InstallRoot='C:\FederatedPS')
    $lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime-lock.json') -Raw | ConvertFrom-Json
    $source=Join-Path (Join-Path $PSScriptRoot 'payload') $lock.sqlServerActiveJar
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing offline JDBC payload: $source. Transfer the complete JDBC driver fix ZIP." }
    $destination=Join-Path (Join-Path $InstallRoot 'jdbc\sqlserver') $lock.sqlServerActiveDirectory
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination (Join-Path $destination $lock.sqlServerActiveJar) -Force
    # Retain 9.2 ONLY as a comparison reference, never on the normal classpath.
    $legacy=Join-Path (Join-Path $PSScriptRoot 'payload') $lock.sqlServerArchive
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        $reference=Join-Path (Join-Path $InstallRoot 'jdbc\sqlserver') 'reference-9.2.0'
        New-Item -ItemType Directory -Path $reference -Force | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip=[IO.Compression.ZipFile]::OpenRead($legacy)
        try {
            $entry=$zip.GetEntry($lock.sqlServerJar)
            if ($null -eq $entry) { throw 'Reference JDBC archive does not contain its JAR.' }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $reference $lock.sqlServerJar),$true)
        } finally { $zip.Dispose() }
    }
    Write-Host "JDBC default installed: $($lock.sqlServerActiveJar). Explicit yuhs.Renviron paths take precedence."
}
