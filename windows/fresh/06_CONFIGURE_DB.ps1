#Requires -Version 5.1
[CmdletBinding()] param([switch]$NoEditor)
$ErrorActionPreference='Stop'
$settings=Join-Path $PSScriptRoot 'FederatedPS\windows\config\yuhs.Renviron'
if (-not (Test-Path -LiteralPath $settings)) {
    Copy-Item -LiteralPath ($settings+'.example') -Destination $settings
    # This deployment follows the user's previously selected DBeaver SSL-off setting.
    Add-Content -LiteralPath $settings -Encoding ASCII -Value @('','# Same setting as DBeaver Use SSL unchecked.','DB_ENCRYPT=false','DB_TRUST_SERVER_CERTIFICATE=false')
}
Write-Host "Edit DB_SERVER, DB_PORT, DB_USER and DB_PASSWORD in: $settings"
Write-Host 'HIWARE must be configured/logged in separately using the organization-provided client.'
if (-not $NoEditor) {
    if ($env:OS -ne 'Windows_NT') { throw 'Use -NoEditor outside Windows.' }
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"'+$settings+'"') -Wait
}
