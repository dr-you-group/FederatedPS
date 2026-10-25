#Requires -Version 5.1
[CmdletBinding()] param()
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Test-FreshManifest $PSScriptRoot
