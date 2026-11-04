[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rootDirectory = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $rootDirectory 'install.ps1'
$mockCli = Join-Path $PSScriptRoot 'mock-apps2samsung.ps1'

function Invoke-Installer {
    param([string[]]$Arguments, [hashtable]$Environment = @{})
    $marker = Join-Path ([IO.Path]::GetTempPath()) "moonfin-test-installed-$PID-$([Guid]::NewGuid().ToString('N'))"
    $installerState = "$marker-state.json"
    $Environment = $Environment.Clone()
    $Environment.MOCK_INSTALLED_MARKER = $marker
    $Environment.MOONFIN_INSTALLER_STATE_PATH = $installerState
    if ($Environment.ContainsKey('MOCK_PRESET_VARIANT')) {
        @{ appId = 'MoonfinApp.moonfin'; version = '1.2.3'; variant = [string]$Environment.MOCK_PRESET_VARIANT; file = 'remembered.wgt' } |
            ConvertTo-Json | Set-Content -LiteralPath $installerState -Encoding UTF8
    }
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
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $installerState -Force -ErrorAction SilentlyContinue
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

$variant = Assert-Success -Name 'variant change at same version' -Arguments ($common + @('-Variant', 'Oblong')) -Environment @{
    MOCK_CATALOG_FILE = 'Moonfin_Tizen_Regular_v1.2.3.wgt'
}
if (-not $variant.Output.Contains('Cambiando Moonfin')) { throw 'Variant change was not detected.' }
$rememberedVariant = Assert-Success -Name 'remembered variant is preserved' -Arguments $common -Environment @{
    MOCK_PRESET_VARIANT = 'Oblong'
}
if (-not $rememberedVariant.Output.Contains('ya esta actualizado (Oblong)')) { throw 'Remembered variant was not preserved.' }

Assert-FailureContains -Name 'downgrade is blocked' -Expected 'Se bloqueo el downgrade' -Arguments $common -Environment @{
    MOCK_CURRENT_VERSION = '10.0.0'
}
$downgrade = Assert-Success -Name 'explicit downgrade' -Arguments ($common + '-AllowDowngrade') -Environment @{
    MOCK_CURRENT_VERSION = '10.0.0'
}
if (-not $downgrade.Output.Contains('por solicitud explicita')) { throw 'Explicit downgrade confirmation missing.' }

Assert-FailureContains -Name 'missing update certificate' -Expected 'no contiene un certificado reutilizable' -Arguments ($common + '-Force') -Environment @{
    MOCK_CERT_STATE = 'missing'
}
Assert-FailureContains -Name 'expired update certificate' -Expected 'certificado guardado esta vencido' -Arguments ($common + '-Force') -Environment @{
    MOCK_CERT_STATE = 'expired'
}
Assert-FailureContains -Name 'certificate mismatch diagnosis' -Expected 'firmado con otro certificado' -Arguments ($common + '-Force') -Environment @{
    MOCK_INSTALL_ERROR = 'Author certificate not match'
}

$alternate = Assert-Success -Name 'alternate remembered app id' -Arguments $common -Environment @{
    MOCK_APP_ID = 'A2S12345.moonfin'
}
if (-not $alternate.Output.Contains('ya esta actualizado')) { throw 'Alternate app ID was not recognized.' }

$headless = Assert-Success -Name 'headless certificate login option' -Arguments ($common + @('-Force', '-NoBrowser')) -Environment @{
    MOCK_EXPECT_ARGUMENT = '--no-browser'
}
if (-not $headless.Output.Contains('instalado y verificado correctamente')) { throw 'Headless install did not complete.' }

Write-Host "`nAll Windows integration tests passed."
exit 0
