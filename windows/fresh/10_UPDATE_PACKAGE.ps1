#Requires -Version 5.1
[CmdletBinding()] param([string]$InstallRoot='C:\FederatedPS',[ValidateSet('jdbc','odbc')][string]$DbBackend)
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Assert-FreshWindows
Assert-FreshNoR
# Package updates operate on the current source without a bundle hash gate.
$options=@{InstallRoot=$InstallRoot;JavaHome=(Get-FreshJavaHome)}
if($DbBackend){$options.DbBackend=$DbBackend}
& (Join-Path $PSScriptRoot 'FederatedPS\windows\Update-FederatedPs.ps1') @options
Write-Host 'PASS: installed FederatedPs includes ODBC support and SQL preparation fixes. Run RUN.ps1.' -ForegroundColor Green
