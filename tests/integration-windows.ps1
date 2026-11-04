[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDirectory = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $rootDirectory 'install.ps1'
$mockCli = Join-Path $PSScriptRoot 'mock-apps2samsung.ps1'

function Invoke-Installer {
    param([string[]]$Arguments, [hashtable]$Environment = @{})
    $saved = @{}
    foreach ($name in $Environment.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], 'Process')
    }
    try {
        $lines = @(& pwsh -NoLogo -NoProfile -NonInteractive -File $installer @Arguments 2>&1)
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = ($lines -join [Environment]::NewLine) }
    }
    finally {
        foreach ($name in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

function Assert-Success {
    param([string]$Name, [string[]]$Arguments, [hashtable]$Environment = @{})
    Write-Host "`n--- $Name ---"
    $result = Invoke-Installer -Arguments $Arguments -Environment $Environment
    Write-Host $result.Output
    if ($result.ExitCode -ne 0) { throw "$Name failed with exit code $($result.ExitCode)." }
    $result
}

function Assert-FailureContains {
    param([string]$Name, [string]$Expected, [string[]]$Arguments, [hashtable]$Environment = @{})
    Write-Host "`n--- $Name ---"
    $result = Invoke-Installer -Arguments $Arguments -Environment $Environment
    Write-Host $result.Output
    if ($result.ExitCode -eq 0) { throw "$Name unexpectedly succeeded." }
    if (-not $result.Output.Contains($Expected)) { throw "$Name did not contain expected text: $Expected" }
}

$common = @('-TvIp', '127.0.0.1', '-LocalIp', '127.0.0.1', '-CliPath', $mockCli)

Assert-FailureContains -Name 'invalid IPv4' -Expected 'no es una direccion IPv4 valida' -Arguments @(
    '-TvIp', '999.1.1.1', '-CliPath', $mockCli
)
Assert-FailureContains -Name 'Host PC IP mismatch' -Expected 'Host PC IP del TV es 10.0.0.2' -Arguments ($common + '-ValidateOnly') -Environment @{
    MOCK_DEVELOPER_IP = '10.0.0.2'
}

$validated = Assert-Success -Name 'validate only' -Arguments ($common + '-ValidateOnly')
if (-not $validated.Output.Contains('Validacion completada')) { throw 'Validation confirmation missing.' }

$current = Assert-Success -Name 'already current' -Arguments $common
if (-not $current.Output.Contains('ya esta actualizado')) { throw 'Up-to-date confirmation missing.' }

$installed = Assert-Success -Name 'forced install' -Arguments ($common + @('-Force', '-Launch'))
if (-not $installed.Output.Contains('instalado y verificado correctamente')) { throw 'Installation confirmation missing.' }

Assert-FailureContains -Name 'CLI failure' -Expected 'simulated tv failure' -Arguments ($common + '-ValidateOnly') -Environment @{
    MOCK_FAIL_COMMAND = 'tv'
}
Assert-FailureContains -Name 'application missing after install' -Expected 'no aparece en la lista nueva del TV' -Arguments ($common + '-Force') -Environment @{
    MOCK_APP_MISSING = '1'
}

Write-Host "`nAll Windows integration tests passed."
exit 0
