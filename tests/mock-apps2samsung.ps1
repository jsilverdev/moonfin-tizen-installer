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
        $apps = if ($env:MOCK_APP_MISSING -eq '1') { @() } else { @(@{ appId = 'MoonfinApp.moonfin'; version = '1.2.3' }) }
        @{ apps = $apps } | ConvertTo-Json -Compress -Depth 3
    }
    'install' { @{ ok = $true } | ConvertTo-Json -Compress }
    'launch' { @{ ok = $true } | ConvertTo-Json -Compress }
    default {
        @{ error = "unexpected command: $CommandName" } | ConvertTo-Json -Compress
        exit 2
    }
}
