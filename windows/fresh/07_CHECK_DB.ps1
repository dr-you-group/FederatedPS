#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS',
    [ValidateSet('jdbc','odbc')][string]$DbBackend='odbc')
$ErrorActionPreference='Stop'
if($DbBackend -eq 'odbc'){
    & (Join-Path $PSScriptRoot 'CHECK_ODBC.ps1') -BundleRoot $PSScriptRoot -InstallRoot $InstallRoot
}else{
    & (Join-Path $PSScriptRoot 'FederatedPS\windows\Test-YUHS-Connection.ps1') -InstallRoot $InstallRoot
}
