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

    [switch]$ValidateOnly,

    [switch]$AllowDowngrade,

    [switch]$NoBrowser,

    [ValidateRange(1, 10)]
    [int]$NetworkRetries = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$variantWasSpecified = $PSBoundParameters.ContainsKey('Variant')

$repoRoot = $PSScriptRoot
$toolsRoot = Join-Path $repoRoot '.tools'
$stateRoot = Join-Path $repoRoot '.state\apps2samsung'
$installerStatePath = if ($env:MOONFIN_INSTALLER_STATE_PATH) {
    $env:MOONFIN_INSTALLER_STATE_PATH
}
else {
    Join-Path $stateRoot 'moonfin-installer.json'
}
$githubHeaders = @{ 'User-Agent' = 'moonfin-tizen-installer' }
if ($env:GITHUB_TOKEN) {
    $githubHeaders.Authorization = "Bearer $($env:GITHUB_TOKEN)"
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Operation,
        [int]$Attempts = $NetworkRetries
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            return & $Action
        }
        catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            $delay = [Math]::Min(8, [Math]::Pow(2, $attempt))
            Write-Warning "$Operation fallo (intento $attempt de $Attempts): $($_.Exception.Message). Reintentando en $delay s."
            Start-Sleep -Seconds $delay
        }
    }
}

function Compare-SemanticVersion {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    try {
        $leftVersion = [System.Management.Automation.SemanticVersion]$Left.TrimStart('v')
        $rightVersion = [System.Management.Automation.SemanticVersion]$Right.TrimStart('v')
    }
    catch {
        throw "No se pueden comparar semanticamente las versiones '$Left' y '$Right'."
    }
    return [Math]::Sign($leftVersion.CompareTo($rightVersion))
}

function Get-InstallerState {
    if (-not (Test-Path -LiteralPath $installerStatePath -PathType Leaf)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $installerStatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "No se pudo leer el estado de variante; se ignorara: $($_.Exception.Message)"
        return $null
    }
}

function Save-InstallerState {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$SelectedVariant,
        [Parameter(Mandatory)][string]$File
    )

    $parent = Split-Path -Parent $installerStatePath
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [PSCustomObject]@{
        appId = $AppId
        version = $Version
        variant = $SelectedVariant
        file = $File
    } | ConvertTo-Json | Set-Content -LiteralPath $installerStatePath -Encoding UTF8
}

function Assert-IPv4Address {
    param([Parameter(Mandatory)][string]$Address)

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "'$Address' no es una direccion IPv4 valida."
    }
}

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
    if (-not $IsWindows) {
        throw 'Este instalador pequeño actualmente admite Windows PowerShell 7 solamente.'
    }

    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($architecture -notin @('x64', 'arm64')) {
        throw "Arquitectura de Windows no compatible: $architecture"
    }

    $platform = "win-$architecture"
    Write-Host 'Consultando la ultima version estable de Apps2Samsung...'
    try {
        $release = Invoke-WithRetry -Operation 'La consulta de Apps2Samsung' -Action {
            Invoke-RestMethod -Uri $releaseUri -Headers $githubHeaders
        }
    }
    catch {
        $cachedCli = Get-ChildItem -LiteralPath $toolsRoot -Directory -Filter "apps2samsung-*-$platform" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { Join-Path $_.FullName 'apps2samsung-cli.exe' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
        if ($cachedCli) {
            Write-Warning "No se pudo consultar GitHub; se usara la CLI almacenada: $cachedCli"
            return $cachedCli
        }
        throw
    }

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
    $partialPath = "$archivePath.part"
    Write-Host "Descargando Apps2Samsung $version para $platform..."
    try {
        Invoke-WithRetry -Operation 'La descarga de Apps2Samsung' -Action {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $partialPath -Headers $githubHeaders
        } | Out-Null
        Move-Item -LiteralPath $partialPath -Destination $archivePath -Force
    }
    finally {
        Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
    }

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

function Resolve-Apps2SamsungCli {
    if ([string]::IsNullOrWhiteSpace($CliPath)) {
        return Get-Apps2SamsungCli
    }

    $resolved = Resolve-Path -LiteralPath $CliPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
        throw "La CLI de Apps2Samsung no es un archivo: $CliPath"
    }
    return $resolved.Path
}

function Invoke-CliJson {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string[]]$CliArguments,
        [ValidateRange(1, 10)][int]$Attempts = 1
    )

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        try {
            $global:LASTEXITCODE = 0
            $output = & $CliPath @CliArguments --json --quiet
            $exitCode = $global:LASTEXITCODE
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
        catch {
            if ($attempt -eq $Attempts) {
                throw
            }
            $delay = [Math]::Min(8, [Math]::Pow(2, $attempt))
            Write-Warning "Apps2Samsung fallo (intento $attempt de $Attempts). Reintentando en $delay s."
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-CertificateReadiness {
    param(
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string]$TvAddress
    )

    $certificate = Invoke-CliJson -CliPath $CliPath -CliArguments @(
        'cert', '--tv', $TvAddress,
        '--local-ip', $LocalIp,
        '--data-dir', $stateRoot
    ) -Attempts 2
    $usable = @($certificate.profiles | Where-Object { $_.usable })
    if ($usable.Count -gt 0) {
        return [PSCustomObject]@{ Ready = $true; Message = $null }
    }

    $existing = @($certificate.profiles | Where-Object { $_.exists })
    if ($existing.Count -gt 0) {
        $dates = $existing | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'validUntil') { [string]$_.validUntil }
        } | Where-Object { $_ }
        $detail = if ($dates) { " Vencio: $($dates -join ',')." } else { '' }
        return [PSCustomObject]@{
            Ready = $false
            Message = "El certificado guardado esta vencido o no se puede leer.$detail Comprueba tambien la fecha y hora del TV. Importa el certificado original antes de actualizar; generar otro no puede sobrescribir la aplicacion instalada."
        }
    }

    return [PSCustomObject]@{
        Ready = $false
        Message = 'Moonfin ya esta instalado, pero este directorio no contiene un certificado reutilizable. Importa el certificado original antes de actualizar; uno nuevo no puede sobrescribir la aplicacion existente.'
    }
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
    ) -Attempts 2

    if (-not $tv.ok -or -not $tv.tv.ready) {
        throw 'El TV no esta listo. Activa Developer Mode, configura Host PC IP y reinicialo completamente.'
    }
    if ([string]$tv.tv.developerIp -ne $PcAddress) {
        throw "Host PC IP del TV es $($tv.tv.developerIp), pero esta PC usa $PcAddress. Corrigelo y reinicia el TV."
    }

    Write-Host "TV listo: $($tv.tv.model), Tizen $($tv.tizenVersion)."
}

Assert-IPv4Address -Address $TvIp
if ($LocalIp) {
    Assert-IPv4Address -Address $LocalIp
}
else {
    $LocalIp = Get-LanAddress -RemoteAddress $TvIp
}

New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
$rememberedState = Get-InstallerState
if (-not $variantWasSpecified -and $rememberedState -and $rememberedState.variant -in @('Regular', 'Oblong')) {
    $Variant = [string]$rememberedState.variant
}
$cli = Resolve-Apps2SamsungCli
Assert-TvReady -CliPath $cli -TvAddress $TvIp -PcAddress $LocalIp

Write-Host 'Consultando Moonfin en el catalogo firmado...'
$catalog = Invoke-CliJson -CliPath $cli -CliArguments @(
    'catalog', 'Moonfin',
    '--data-dir', $stateRoot
) -Attempts $NetworkRetries
$moonfin = $catalog.apps | Where-Object { $_.name -eq 'Moonfin' } | Select-Object -First 1
if (-not $moonfin) {
    throw 'No se encontro la aplicacion oficial Moonfin en el catalogo.'
}

$variantPattern = "^Moonfin_Tizen_$([regex]::Escape($Variant))_v.+\.wgt$"
$packageFile = $moonfin.files |
    Where-Object { $_.file -match $variantPattern } |
    Sort-Object { [System.Management.Automation.SemanticVersion]([string]$_.version).TrimStart('v') } -Descending |
    Select-Object -First 1
if (-not $packageFile) {
    throw "Moonfin no publico una variante $Variant en la version actual."
}


if ($ValidateOnly) {
    Write-Host "Validacion completada: TV listo y Moonfin $($packageFile.version) ($Variant) disponible."
    exit 0
}

$installedBefore = Invoke-CliJson -CliPath $cli -CliArguments @(
    'installed', '--tv', $TvIp,
    '--local-ip', $LocalIp,
    '--data-dir', $stateRoot
) -Attempts 2
$current = $installedBefore.apps |
    Where-Object {
        $null -ne $_ -and (
            $_.appId -eq 'MoonfinApp.moonfin' -or
            (($_.PSObject.Properties.Name -contains 'catalogApp') -and $_.catalogApp -eq 'Moonfin') -or
            (($_.PSObject.Properties.Name -contains 'title') -and $_.title -eq 'Moonfin')
        )
    } |
    Select-Object -First 1

$versionComparison = $null
$variantChanged = $false
$certificateReadiness = $null
if ($current) {
    $versionComparison = Compare-SemanticVersion -Left ([string]$current.version) -Right ([string]$packageFile.version)
    $installerState = Get-InstallerState
    if ($installerState -and [string]$installerState.version -eq [string]$current.version -and $installerState.variant) {
        $variantChanged = [string]$installerState.variant -ne $Variant
    }
    elseif ($variantWasSpecified) {
        $variantChanged = $true
    }
    $certificateReadiness = Get-CertificateReadiness -CliPath $cli -TvAddress $TvIp
}

if ($current -and $versionComparison -gt 0 -and -not $AllowDowngrade) {
    throw "El TV tiene Moonfin $($current.version), mas nuevo que el catalogo ($($packageFile.version)). Se bloqueo el downgrade. Use -AllowDowngrade solamente si desea volver atras."
}

if ($current -and $versionComparison -eq 0 -and -not $variantChanged -and -not $Force) {
    if (-not $certificateReadiness.Ready) {
        Write-Warning $certificateReadiness.Message
    }
    Write-Host "Moonfin $($current.version) ya esta actualizado ($Variant). Use -Force para reinstalar."
    if ($Launch) {
        $launchId = if ($current.appId) { [string]$current.appId } else { 'MoonfinApp.moonfin' }
        Invoke-CliJson -CliPath $cli -CliArguments @(
            'launch', $launchId, '--tv', $TvIp,
            '--local-ip', $LocalIp,
            '--data-dir', $stateRoot
        ) | Out-Null
        Write-Host 'Moonfin abierto en el TV.'
    }
    exit 0
}

if ($current -and -not $certificateReadiness.Ready) {
    throw $certificateReadiness.Message
}

if ($current -and $variantChanged -and $versionComparison -eq 0) {
    Write-Host "Cambiando Moonfin $($current.version) a la variante $Variant ($($packageFile.file))..."
}
elseif ($current -and $versionComparison -gt 0) {
    Write-Host "Bajando Moonfin $($current.version) a $($packageFile.version) ($Variant) por solicitud explicita..."
}
elseif ($current) {
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
if ($NoBrowser) {
    $installArguments += '--no-browser'
}

# Deliberately omit --remove-first and --allow-remove: updates must not erase app data silently.
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $global:LASTEXITCODE = 0
    $installOutput = @(& $cli @installArguments 2>&1 | ForEach-Object { Write-Host $_; $_.ToString() })
    $installExitCode = $global:LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorAction
}
if ($installExitCode -ne 0) {
    $installText = $installOutput -join [Environment]::NewLine
    if ($installText -match '(?i)author certificate not match|different certificate|certificate mismatch') {
        throw 'El TV rechazo la actualizacion porque Moonfin fue firmado con otro certificado. Importa el certificado original o desinstala manualmente la copia existente; no se elimino ninguna aplicacion.'
    }
    if ($installText -match '(?i)certificate.*expired|expired.*certificate') {
        throw 'El TV rechazo el certificado por vencimiento. Comprueba su fecha y hora e importa o renueva el certificado original; no se elimino ninguna aplicacion.'
    }
    throw "La instalacion termino con codigo $installExitCode. No se elimino ninguna aplicacion."
}

$installedAfter = Invoke-CliJson -CliPath $cli -CliArguments @(
    'installed', '--tv', $TvIp,
    '--local-ip', $LocalIp,
    '--data-dir', $stateRoot
) -Attempts 2
$verified = $installedAfter.apps |
    Where-Object {
        $null -ne $_ -and (
            $_.appId -eq 'MoonfinApp.moonfin' -or
            (($_.PSObject.Properties.Name -contains 'catalogApp') -and $_.catalogApp -eq 'Moonfin') -or
            (($_.PSObject.Properties.Name -contains 'title') -and $_.title -eq 'Moonfin')
        )
    } |
    Select-Object -First 1

if (-not $verified) {
    throw 'Apps2Samsung termino, pero Moonfin no aparece en la lista nueva del TV.'
}
if ([string]$verified.version -ne [string]$packageFile.version) {
    throw "Moonfin aparece con version $($verified.version), no con la esperada $($packageFile.version)."
}

$verifiedAppId = if ($verified.appId) { [string]$verified.appId } else { 'MoonfinApp.moonfin' }
Save-InstallerState -AppId $verifiedAppId -Version ([string]$verified.version) -SelectedVariant $Variant -File ([string]$packageFile.file)

Write-Host "Moonfin $($verified.version) ($Variant) instalado y verificado correctamente."
