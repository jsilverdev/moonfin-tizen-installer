# Moonfin Tizen Installer

Instala o actualiza **Moonfin** de forma segura en un Samsung TV con Tizen desde Windows o Linux. Ambos instaladores usan el catalogo firmado de [Apps2Samsung](https://github.com/Apps2Samsung/Apps2Samsung), conservan el mismo certificado entre actualizaciones y verifican el resultado consultando de nuevo la lista de aplicaciones del TV.

- **Windows:** `install.ps1`
- **Linux:** `install.sh`

Los scripts **no desinstalan aplicaciones** y nunca usan `--remove-first` ni `--allow-remove`.

## Requisitos

### Windows

- Windows x64 o ARM64 con PowerShell 7.
- La computadora y el TV en la misma red local.
- Developer Mode activo en el TV.
- `Host PC IP` configurado con la IP LAN de la computadora.
- Una cuenta Samsung para crear el certificado durante la primera instalacion.

### Linux

- Linux x64 o ARM64 con Bash 4+.
- Python 3, `curl`, `tar`, `sha256sum`, `awk` y `find`.
- Los mismos requisitos de red, Developer Mode y cuenta Samsung que en Windows.

Ejecuta el instalador como usuario normal. No requiere instalar Apps2Samsung globalmente: descarga la CLI oficial apropiada para la plataforma y verifica el SHA-256 publicado por GitHub.

## Uso

### Windows

```powershell
.\install.ps1 -TvIp 192.168.1.11 -Launch
```

Con opciones explicitas:

```powershell
.\install.ps1 `
  -TvIp 192.168.1.11 `
  -LocalIp 192.168.1.100 `
  -Variant Regular `
  -Launch
```

### Linux

```bash
chmod +x ./install.sh
./install.sh --tv-ip 192.168.1.11 --launch
```

Con opciones explicitas:

```bash
./install.sh \
  --tv-ip 192.168.1.11 \
  --local-ip 192.168.1.100 \
  --variant Regular \
  --launch
```

`Regular` es la variante predeterminada para televisores Samsung de 2017 en adelante. `Oblong` usa un icono horizontal. El instalador no ofrece `Legacy`, destinada a modelos 2016 con Tizen 2.4.

Para comprobar la conexion, la configuracion del TV y el catalogo sin instalar:

```powershell
.\install.ps1 -TvIp 192.168.1.11 -ValidateOnly
```

```bash
./install.sh --tv-ip 192.168.1.11 --validate-only
```

Para usar una CLI de Apps2Samsung ya instalada, indica `-CliPath` en Windows o `--cli-path` en Linux.

En un sistema sin navegador grafico, la primera creacion del certificado puede imprimir el enlace de inicio de sesion Samsung en vez de intentar abrirlo:

```powershell
.\install.ps1 -TvIp 192.168.1.11 -NoBrowser
```

```bash
./install.sh --tv-ip 192.168.1.11 --no-browser
```

Las consultas y descargas de red se reintentan tres veces con espera progresiva. Puede cambiarse con `-NetworkRetries 5` o `--network-retries 5`. Si GitHub no responde pero ya existe una CLI almacenada y verificada, se utiliza esa copia.

## Actualizar Moonfin

Ejecuta exactamente el mismo comando. El instalador consulta la ultima publicacion estable de Apps2Samsung, valida su SHA-256, busca la ultima version de Moonfin de la variante elegida e instala la actualizacion sobre la aplicacion existente. Si la version instalada ya coincide, no hace cambios.

Las versiones se comparan como SemVer. Si el TV tiene una version posterior a la del catalogo, el instalador bloquea el downgrade. Para autorizarlo deliberadamente use `-AllowDowngrade` en Windows o `--allow-downgrade` en Linux.

El listado del TV tambien se compara con `catalogApp`, lo que permite reconocer IDs alternativos recordados por Apps2Samsung. Como el TV no informa cual variante usa cuando `Regular` y `Oblong` comparten ID y version, el instalador guarda la variante despues de cada instalacion exitosa. Si aun es desconocida, indicar `-Variant` o `--variant` explicitamente realiza el cambio una vez y deja el estado registrado.

Para reinstalar la misma version:

```powershell
.\install.ps1 -TvIp 192.168.1.11 -Force
```

```bash
./install.sh --tv-ip 192.168.1.11 --force
```

No borres `.state`: contiene el certificado de firma y la cache local necesarios para futuras actualizaciones. `.state` y `.tools` estan excluidos de Git; no copies ni publiques su contenido.

Antes de actualizar una copia existente se comprueba que haya un certificado de autor reutilizable. Un certificado vencido, ilegible o ausente detiene la actualizacion con instrucciones; generar uno distinto no puede sobrescribir una aplicacion firmada anteriormente. Los errores de certificado devueltos por el TV distinguen incompatibilidad de autor y vencimiento o reloj incorrecto. El instalador nunca desinstala Moonfin automaticamente.

## CI/CD

Cada push a `main` y cada pull request ejecutan validacion de sintaxis y pruebas de integracion en runners Windows y Ubuntu. Las pruebas simulan el TV y Apps2Samsung; no necesitan credenciales ni un televisor real.

Los pushes a `main`, las ejecuciones manuales, las releases y una tarea semanal tambien descargan la CLI estable real, verifican su SHA-256 y comprueban los contratos JSON actuales del catalogo Moonfin y de certificados. Los pull requests conservan solamente las pruebas simuladas para no depender de red ni tokens externos.

Un tag con formato `v*` ejecuta ambas suites y, solamente si pasan, crea una GitHub Release con paquetes separados para Windows/Linux y un archivo `SHA256SUMS`.

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Seguridad

- La CLI se descarga solamente desde la publicacion estable oficial de Apps2Samsung y se compara con el SHA-256 publicado por GitHub.
- La aplicacion seleccionada debe llamarse exactamente `Moonfin`; no se elige el fork Lica por coincidencia parcial.
- La variante se selecciona por el nombre exacto del archivo.
- Si Developer Mode o `Host PC IP` no coinciden, el instalador se detiene.
- Si una actualizacion exige desinstalar primero, falla sin borrar los datos locales de Moonfin.
- El DUID, los certificados y la cache permanecen solamente en `.state`.

Al terminar, comprueba la reproduccion en el TV y desactiva Developer Mode si no vas a instalar otra actualizacion.
