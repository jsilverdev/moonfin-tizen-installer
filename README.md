# Moonfin Tizen Installer

Instala o actualiza **Moonfin** de forma segura en un Samsung TV con Tizen desde
Windows. Usa el catalogo firmado de
[Apps2Samsung](https://github.com/Apps2Samsung/Apps2Samsung), conserva el mismo
certificado entre actualizaciones y verifica el resultado leyendo de nuevo la
lista de aplicaciones del TV.

El script **no desinstala aplicaciones** y nunca usa `--remove-first` ni
`--allow-remove`.

## Requisitos

- Windows x64 o ARM64 con PowerShell 7.
- La computadora y el TV en la misma red local.
- Developer Mode activo en el TV.
- `Host PC IP` configurado con la IP LAN de la computadora.
- Una cuenta Samsung para crear el certificado durante la primera instalacion.

## Uso

Abre PowerShell en este directorio:

```powershell
.\Install-Moonfin.ps1 -TvIp 192.168.1.11 -Launch
```

El script detecta la IP LAN que Windows usaria para llegar al TV, evitando tomar
por accidente una VPN como Cloudflare WARP. Si prefieres fijarla:

```powershell
.\Install-Moonfin.ps1 `
  -TvIp 192.168.1.11 `
  -LocalIp 192.168.1.100 `
  -Variant Regular `
  -Launch
```

`Regular` es la variante predeterminada para televisores Samsung de 2017 en
adelante. `Oblong` usa un icono horizontal. El script no ofrece `Legacy`, que
esta destinada a modelos 2016 con Tizen 2.4.

## Actualizar Moonfin

Ejecuta exactamente el mismo comando. El script consulta la ultima publicacion
estable de Apps2Samsung, valida su SHA-256, busca la ultima version de Moonfin
Regular en el catalogo e instala la actualizacion sobre la aplicacion existente.
Si la version instalada ya coincide, no hace cambios.

Para reinstalar la misma version:

```powershell
.\Install-Moonfin.ps1 -TvIp 192.168.1.11 -Launch -Force
```

No borres `.state`: contiene el certificado de firma y la cache local necesarios
para futuras actualizaciones. Tanto `.state` como `.tools` estan excluidos de Git.
No copies ni publiques su contenido.

## Seguridad

- La CLI se descarga solamente desde la publicacion estable oficial de
  Apps2Samsung y se compara con el SHA-256 publicado por GitHub.
- La aplicacion seleccionada debe llamarse exactamente `Moonfin`; no se elige el
  fork Lica por coincidencia parcial.
- La variante se selecciona por el nombre exacto del archivo.
- Si Developer Mode o `Host PC IP` no coinciden, el script se detiene.
- Si una actualizacion exige desinstalar primero, el script falla sin borrar los
  datos locales de Moonfin.
- El DUID, los certificados y la cache permanecen solamente en `.state`.

Al terminar, comprueba la reproduccion en el TV y desactiva Developer Mode si no
vas a instalar otra actualizacion.
