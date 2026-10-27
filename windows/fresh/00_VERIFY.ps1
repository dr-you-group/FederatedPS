#Requires -Version 5.1
[CmdletBinding()] param([switch]$StrictSource)
. (Join-Path $PSScriptRoot 'support\Fresh.Common.ps1')
Test-FreshManifest $PSScriptRoot -StrictSource:$StrictSource
