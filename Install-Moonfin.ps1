[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$TvIp,

    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$LocalIp,

    [ValidateSet('Regular', 'Oblong')]
    [string]$Variant = 'Regular',

    [string]$CliPath,

    [switch]$Launch,

    [switch]$Force,

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Warning 'Install-Moonfin.ps1 se conserva por compatibilidad; para comandos nuevos use install.ps1.'
& (Join-Path $PSScriptRoot 'install.ps1') @PSBoundParameters
