[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$TvIp,

    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$LocalIp,

    [ValidateSet('Regular', 'Oblong')]
    [string]$Variant = 'Regular',

    [switch]$Launch,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$stateRoot = Join-Path $repoRoot '.state\apps2samsung'
$githubHeaders = @{ 'User-Agent' = 'moonfin-tizen-installer' }

function Get-LanAddress {
    param([Parameter(Mandatory)][string]$RemoteAddress)

    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        # No packet needs to be sent. Connect asks Windows which route it would use.
        $udp.Connect($RemoteAddress, 26101)
        return ([System.Net.IPEndPoint]$udp.Client.LocalEndPoint).Address.ToString()
    }
    finally {
        $udp.Dispose()
    }
}

function Get-Apps2SamsungCli {
    $releaseUri = 'https://api.github.com/repos/Apps2Samsung/Apps2Samsung/releases/latest'
    Write-Host 'Consultando la ultima version estable de Apps2Samsung...'
    $release = Invoke-RestMethod -Uri $releaseUri -Headers $githubHeaders

    if (-not $IsWindows) {
        throw 'Este instalador pequeño actualmente admite Windows PowerShell 7 solamente.'
    }

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($architecture -notin @('x64', 'arm64')) {
        throw "Arquitectura de Windows no compatible: $architecture"
    }

    $platform = "win-$architecture"
    $asset = $release.assets |
        Where-Object { $_.name -match "^Apps2Samsung-cli-v.+-$([regex]::Escape($platform))\.zip$" } |
        Select-Object -First 1

    if (-not $asset) {
        throw "La publicacion $($release.tag_name) no contiene una CLI para $platform."
    }
    if (-not $asset.digest -or $asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw 'GitHub no publico un SHA-256 valido para la descarga; se cancela por seguridad.'
    }

    $expectedHash = $Matches[1].ToUpperInvariant()
    $version = $release.tag_name.TrimStart('v')
    $installDir = Join-Path $toolsRoot "apps2samsung-$version-$platform"
    $cliPath = Join-Path $installDir 'apps2samsung-cli.exe'
    if (Test-Path -LiteralPath $cliPath) {
        return $cliPath
    }

    New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
    $archivePath = Join-Path $toolsRoot $asset.name
    Write-Host "Descargando Apps2Samsung $version para $platform..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archivePath -Headers $githubHeaders

    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        Remove-Item -LiteralPath $archivePath -Force
        throw "El SHA-256 no coincide. Esperado: $expectedHash; recibido: $actualHash"
    }

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $installDir -Force
    if (-not (Test-Path -LiteralPath $cliPath)) {
        throw "La descarga valida no contenia $cliPath"
    }
    return $cliPath
}

function Invoke-CliJson {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string[]]$CliArguments
    )

    $output = & $CliPath @CliArguments --json --quiet
    $exitCode = $LASTEXITCODE
    $text = $output | Out-String
    try {
        $result = $text | ConvertFrom-Json
    }
    catch {
        throw "Apps2Samsung devolvio una respuesta no valida al ejecutar '$($CliArguments -join ' ')': $text"
    }
    if ($exitCode -ne 0) {
        if ($result.PSObject.Properties.Name -contains 'error') {
            throw "Apps2Samsung: $($result.error)"
        }
        throw "Apps2Samsung termino con codigo $exitCode al ejecutar: $($CliArguments -join ' ')"
    }
    return $result
}

function Assert-TvReady {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string]$TvAddress,
        [Parameter(Mandatory)][string]$PcAddress
    )

    Write-Host "Comprobando el TV $TvAddress desde $PcAddress..."
    $tv = Invoke-CliJson -CliPath $CliPath -CliArguments @(
        'tv', $TvAddress,
        '--local-ip', $PcAddress,
        '--data-dir', $stateRoot
    )

    if (-not $tv.ok -or -not $tv.tv.ready) {
        throw 'El TV no esta listo. Activa Developer Mode, configura Host PC IP y reinicialo completamente.'
    }
    if ([string]$tv.tv.developerIp -ne $PcAddress) {
        throw "Host PC IP del TV es $($tv.tv.developerIp), pero esta PC usa $PcAddress. Corrigelo y reinicia el TV."
    }

    Write-Host "TV listo: $($tv.tv.model), Tizen $($tv.tizenVersion)."
}

if (-not $LocalIp) {
    $LocalIp = Get-LanAddress -RemoteAddress $TvIp
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$cli = Get-Apps2SamsungCli
Assert-TvReady -CliPath $cli -TvAddress $TvIp -PcAddress $LocalIp

Write-Host 'Consultando Moonfin en el catalogo firmado...'
$catalog = Invoke-CliJson -CliPath $cli -CliArguments @(
    'catalog', 'Moonfin',
    '--data-dir', $stateRoot
)
$moonfin = $catalog.apps | Where-Object { $_.name -eq 'Moonfin' } | Select-Object -First 1
if (-not $moonfin) {
    throw 'No se encontro la aplicacion oficial Moonfin en el catalogo.'
}

$variantPattern = "^Moonfin_Tizen_$([regex]::Escape($Variant))_v.+\.wgt$"
$packageFile = $moonfin.files |
    Where-Object { $_.file -match $variantPattern } |
    Sort-Object version -Descending |
    Select-Object -First 1
if (-not $packageFile) {
    throw "Moonfin no publico una variante $Variant en la version actual."
}

$installedBefore = Invoke-CliJson -CliPath $cli -CliArguments @(
    'installed', '--tv', $TvIp,
    '--local-ip', $LocalIp,
    '--data-dir', $stateRoot
)
$current = $installedBefore.apps |
    Where-Object { $_.appId -eq 'MoonfinApp.moonfin' } |
    Select-Object -First 1

if ($current -and ([string]$current.version -eq [string]$packageFile.version) -and -not $Force) {
    Write-Host "Moonfin $($current.version) ya esta actualizado ($Variant). Use -Force para reinstalar."
    if ($Launch) {
        Invoke-CliJson -CliPath $cli -CliArguments @(
            'launch', 'MoonfinApp.moonfin', '--tv', $TvIp,
            '--local-ip', $LocalIp,
            '--data-dir', $stateRoot
        ) | Out-Null
        Write-Host 'Moonfin abierto en el TV.'
    }
    exit 0
}

if ($current) {
    Write-Host "Actualizando Moonfin $($current.version) a $($packageFile.version) ($Variant)..."
}
else {
    Write-Host "Instalando Moonfin $($packageFile.version) ($Variant)..."
}

$installArguments = @(
    'install', 'Moonfin',
    '--file', [string]$packageFile.file,
    '--tv', $TvIp,
    '--local-ip', $LocalIp,
    '--data-dir', $stateRoot,
    '--keep',
    '--json'
)
if ($Launch) {
    $installArguments += '--launch'
}

# Deliberately omit --remove-first and --allow-remove: updates must not erase app data silently.
& $cli @installArguments
if ($LASTEXITCODE -ne 0) {
    throw "La instalacion termino con codigo $LASTEXITCODE. No se elimino ninguna aplicacion."
}

$installedAfter = Invoke-CliJson -CliPath $cli -CliArguments @(
    'installed', '--tv', $TvIp,
    '--local-ip', $LocalIp,
    '--data-dir', $stateRoot
)
$verified = $installedAfter.apps |
    Where-Object { $_.appId -eq 'MoonfinApp.moonfin' } |
    Select-Object -First 1

if (-not $verified) {
    throw 'Apps2Samsung termino, pero Moonfin no aparece en la lista nueva del TV.'
}
if ([string]$verified.version -ne [string]$packageFile.version) {
    throw "Moonfin aparece con version $($verified.version), no con la esperada $($packageFile.version)."
}

Write-Host "Moonfin $($verified.version) ($Variant) instalado y verificado correctamente."
