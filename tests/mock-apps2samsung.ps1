[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)][string]$CommandName,
    [Parameter(ValueFromRemainingArguments)][object[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'
if ($env:MOCK_FAIL_COMMAND -eq $CommandName) {
    @{ error = "simulated $CommandName failure" } | ConvertTo-Json -Compress
    exit 1
}

switch ($CommandName) {
    'tv' {
        $developerIp = if ($env:MOCK_DEVELOPER_IP) { $env:MOCK_DEVELOPER_IP } else { '127.0.0.1' }
        @{
            ok = $true
            tv = @{ ready = $true; developerIp = $developerIp; model = 'MOCK-TV' }
            tizenVersion = '8.0'
        } | ConvertTo-Json -Compress -Depth 4
    }
    'catalog' {
        @{
            apps = @(@{
                name = 'Moonfin'
                files = @(
                    @{ file = 'Moonfin_Tizen_Regular_v1.2.3.wgt'; version = '1.2.3' }
                    @{ file = 'Moonfin_Tizen_Oblong_v1.2.3.wgt'; version = '1.2.3' }
                )
            })
        } | ConvertTo-Json -Compress -Depth 5
    }
    'installed' {
        $installedDuringRun = $env:MOCK_INSTALLED_MARKER -and (Test-Path -LiteralPath $env:MOCK_INSTALLED_MARKER)
        $version = if ($installedDuringRun) { '1.2.3' } elseif ($env:MOCK_CURRENT_VERSION) { $env:MOCK_CURRENT_VERSION } else { '1.2.3' }
        $appId = if ($env:MOCK_APP_ID) { $env:MOCK_APP_ID } else { 'MoonfinApp.moonfin' }
        $catalogFile = if ($env:MOCK_CATALOG_FILE) { $env:MOCK_CATALOG_FILE } else { 'Moonfin_Tizen_Regular_v1.2.3.wgt' }
        $apps = if ($env:MOCK_APP_MISSING -eq '1') { @() } else {
            @(@{ appId = $appId; title = 'Moonfin'; version = $version; catalogApp = 'Moonfin'; catalogFile = $catalogFile })
        }
        @{ apps = $apps } | ConvertTo-Json -Compress -Depth 3
    }
    'cert' {
        $profiles = switch ($env:MOCK_CERT_STATE) {
            'missing' { @(@{ level = 'Public'; exists = $false; usable = $false; duids = @() }) }
            'expired' { @(@{ level = 'Public'; exists = $true; usable = $false; validUntil = '2025-01-01'; duids = @('mock-duid') }) }
            default { @(@{ level = 'Public'; exists = $true; usable = $true; validUntil = '2030-01-01'; duids = @('mock-duid') }) }
        }
        @{ ok = $true; tvDuid = 'mock-duid'; profiles = $profiles } | ConvertTo-Json -Compress -Depth 4
    }
    'install' {
        if ($env:MOCK_EXPECT_ARGUMENT -and $RemainingArguments -notcontains $env:MOCK_EXPECT_ARGUMENT) {
            @{ error = "missing expected argument: $($env:MOCK_EXPECT_ARGUMENT)" } | ConvertTo-Json -Compress
            exit 1
        }
        if ($env:MOCK_INSTALL_ERROR) {
            @{ error = $env:MOCK_INSTALL_ERROR } | ConvertTo-Json -Compress
            exit 1
        }
        if ($env:MOCK_INSTALLED_MARKER) {
            New-Item -ItemType File -Path $env:MOCK_INSTALLED_MARKER -Force | Out-Null
        }
        @{ ok = $true } | ConvertTo-Json -Compress
    }
    'launch' { @{ ok = $true } | ConvertTo-Json -Compress }
    default {
        @{ error = "unexpected command: $CommandName" } | ConvertTo-Json -Compress
        exit 2
    }
}
