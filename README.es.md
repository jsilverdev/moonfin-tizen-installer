# Instalador de Moonfin para Tizen

[English](README.md)

Instalador y actualizador multiplataforma de **Moonfin** para televisores Samsung con Tizen. Usa el catálogo firmado de [Apps2Samsung](https://github.com/Apps2Samsung/Apps2Samsung), conserva el certificado entre actualizaciones y verifica la aplicación instalada.

- Windows: `install.ps1`
- Linux: `install.sh`
- Variantes compatibles: `Regular` y `Oblong` para televisores Samsung de 2017 en adelante

El instalador nunca elimina automáticamente una aplicación existente.

## Requisitos

- TV y computadora en la misma red local.
- Developer Mode activo en el TV.
- `Host PC IP` del TV configurado con la dirección LAN de la computadora.
- Cuenta Samsung para crear el primer certificado de firma.
- Windows: PowerShell 7 en x64 o ARM64.
- Linux: Bash 4+, Python 3, `curl`, `tar`, `sha256sum`, `awk` y `find` en x64 o ARM64.

## Uso

Windows:

```powershell
.\install.ps1 -TvIp 192.168.1.11 -Launch
```

Linux:

```bash
chmod +x ./install.sh
./install.sh --tv-ip 192.168.1.11 --launch
```

Opciones útiles:

| Objetivo | Windows | Linux |
|---|---|---|
| Elegir Oblong | `-Variant Oblong` | `--variant Oblong` |
| Validar sin instalar | `-ValidateOnly` | `--validate-only` |
| Reinstalar la misma versión | `-Force` | `--force` |
| Mostrar el enlace de acceso Samsung | `-NoBrowser` | `--no-browser` |
| Permitir un downgrade intencional | `-AllowDowngrade` | `--allow-downgrade` |
| Cambiar la cantidad de reintentos | `-NetworkRetries 5` | `--network-retries 5` |
| Indicar la dirección LAN local | `-LocalIp 192.168.1.100` | `--local-ip 192.168.1.100` |
| Usar una CLI existente | `-CliPath <ruta>` | `--cli-path <ruta>` |

## Actualizaciones y certificados

Ejecuta nuevamente el mismo comando para actualizar Moonfin. Las versiones se comparan como SemVer, los downgrades se bloquean por defecto, se conserva la variante elegida y se reconocen los IDs alternativos de Apps2Samsung.

Conserva el directorio `.state`. Contiene el certificado necesario para actualizar la copia instalada sin borrar sus datos locales. Si el certificado original falta, venció o es incompatible, el instalador se detiene con instrucciones y no desinstala Moonfin. `.state` y `.tools` nunca deben publicarse ni compartirse.

Las operaciones de red se reintentan tres veces. Si GitHub no está disponible temporalmente, se puede reutilizar una CLI de Apps2Samsung ya descargada.

## CI/CD

GitHub Actions valida PowerShell y Bash en Windows y Ubuntu. Una prueba contractual comprueba también la release actual de Apps2Samsung, su SHA-256, el catálogo Moonfin y el esquema JSON de certificados en los pushes a `main`, releases, ejecuciones manuales y semanalmente.

Un tag `v*` crea paquetes para Windows y Linux junto con `SHA256SUMS` después de superar todas las validaciones.

```bash
git tag v1.0.0
git push origin v1.0.0
```
