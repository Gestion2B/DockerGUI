#requires -Version 5.1
<#
.SYNOPSIS
  Restaura un proyecto (carpeta, claves, base de datos y uploads) desde la copia del disco externo.

.DESCRIPTION
  Sirve para levantar app-fotos en un equipo NUEVO (o limpio) usando solo el disco externo.
  Tambien se copia dentro de la propia copia (carpeta "gestor"), asi que puede ejecutarse desde el disco:
      D:\BackupsMonzon\SERVERIT\gestor\Restaurar-Copia.ps1

  Seguridad (importante):
    - Sin -Ejecutar solo ensena el plan y no cambia nada.
    - Se niega a actuar si ya existen contenedores del proyecto (produccion en marcha), salvo -Sustituir
      y escribir SUSTITUIR. Restaurar una copia antigua sobre una base viva PIERDE lo creado despues.
    - Nunca borra: si la carpeta de destino ya tiene contenido, la renombra a "<carpeta>.antes-de-restaurar-<fecha>".
    - Las fotos y videos originales estan en el hosting FTP; esto no los toca. Si el hosting tambien se
      perdio, hay que restaurarlo aparte (copia de WinSCP, carpeta "fotos" del disco).

  Que hace con -Ejecutar
    1. Copia la carpeta del proyecto (con .env, claves y produccion) a la ruta de destino.
    2. Arranca solo el servicio de la base de datos y espera a que responda.
    3. Restaura monzon_media.dump con pg_restore --clean --if-exists.
    4. Arranca el resto (docker compose up -d --build) y copia los uploads (portadas y avatares).
    5. Comprueba http://localhost:3000/api/health.
  Despues: ejecuta Iniciar-Docker-Produccion-Completo.ps1 del gestor para recrear el Funnel de Tailscale,
  y prueba con probar-restauracion.ps1 (repositorio app-fotos).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Restaurar-Copia.ps1 -Origen D:\BackupsMonzon\SERVERIT
  powershell -ExecutionPolicy Bypass -File .\Restaurar-Copia.ps1 -Origen D:\BackupsMonzon\SERVERIT -DestinoProyecto C:\Proyectos\app-fotos -Ejecutar
#>
[CmdletBinding()]
param(
    # Carpeta del equipo dentro del disco (la que contiene proyecto\, bases\, gestor\) o el destino raiz de la copia.
    [string]$Origen,
    [string]$Proyecto = 'app-fotos',
    # Donde dejar el proyecto. Por defecto, la Ruta que tenia en proyectos-produccion.txt.
    [string]$DestinoProyecto,
    # ZIP de datos concreto (por defecto, el mas reciente de bases\).
    [string]$ZipDatos,
    [switch]$Ejecutar,
    [switch]$Sustituir,
    [switch]$SinArrancar
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$Stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$script:Avisos = 0

function Say([string]$m, [string]$color = 'Gray') { Write-Host $m -ForegroundColor $color }
function Stop-Restore([string]$m) { throw $m }

function Read-Gestor([string]$file) {
    $id = $null; $v = @{}; $out = @()
    foreach ($raw in Get-Content -LiteralPath $file -Encoding UTF8) {
        $l = $raw.Trim()
        if (-not $l -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
        if ($l -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') { if ($id) { $out += [pscustomobject]@{ Id = $id; V = $v } }; $id = $Matches[1]; $v = @{}; continue }
        if ($id -and $l -match '^([^=]+)=(.*)$') { $v[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() }
    }
    if ($id) { $out += [pscustomobject]@{ Id = $id; V = $v } }
    return $out
}

function Resolve-Backup([string]$path) {
    if (-not $path) {
        # Ejecutado desde <equipo>\gestor\Restaurar-Copia.ps1 dentro del disco.
        $up = Split-Path $PSScriptRoot -Parent
        if ((Split-Path $PSScriptRoot -Leaf) -eq 'gestor' -and (Test-Path -LiteralPath (Join-Path $up 'proyecto'))) { return $up }
        $path = Read-Host 'Carpeta de la copia en el disco (p. ej. D:\BackupsMonzon\SERVERIT)'
    }
    $path = $path.Trim().Trim('"').TrimEnd('\')
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { Stop-Restore "No existe '$path'. Esta conectado el disco?" }
    if (Test-Path -LiteralPath (Join-Path $path 'proyecto')) { return $path }
    $cands = @(Get-ChildItem -LiteralPath $path -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'proyecto') } |
        Sort-Object { (Get-Item -LiteralPath (Join-Path $_.FullName 'backup.log') -ErrorAction SilentlyContinue).LastWriteTime } -Descending)
    if ($cands.Count -eq 0) { Stop-Restore "Dentro de '$path' no hay ninguna copia (falta la carpeta 'proyecto')." }
    if ($cands.Count -gt 1) { Say "Hay varias copias; se usa la mas reciente: $($cands[0].Name)  (otras: $((@($cands | Select-Object -Skip 1) | ForEach-Object { $_.Name }) -join ', '))" 'Yellow' }
    return $cands[0].FullName
}

function Find-Container([string]$project, [string]$service) {
    $n = docker ps -a --filter "label=com.docker.compose.project=$project" --filter "label=com.docker.compose.service=$service" --format '{{.Names}}' 2>$null | Select-Object -First 1
    return $n
}

try {
    $backup = Resolve-Backup $Origen
    Say "`n=== RESTAURAR '$Proyecto' desde $backup ===" 'Cyan'

    # ---- 1) que hay en la copia
    $carpetaProy = Join-Path $backup 'proyecto'
    $txt = Join-Path $backup 'gestor\proyectos-produccion.txt'
    $cfg = $null
    if (Test-Path -LiteralPath $txt) { $cfg = (Read-Gestor $txt | Where-Object { $_.Id -eq $Proyecto } | Select-Object -First 1) }
    if (-not $cfg) { Stop-Restore "La copia no lleva el proyecto '$Proyecto' en gestor\proyectos-produccion.txt." }
    $v = $cfg.V
    $rutaOriginal = if ($v.ContainsKey('ruta')) { $v['ruta'].Trim([char[]]@('"', "'")).TrimEnd('\') } else { '' }
    $servicioBd = if ($v['bdservicio']) { $v['bdservicio'] } else { 'postgres' }
    $nombreBd = if ($v['bdnombre']) { $v['bdnombre'] } else { 'monzon_media' }
    $usuarioBd = if ($v['bdusuario']) { $v['bdusuario'] } else { 'monzon_user' }
    if ($Proyecto -ne 'app-fotos') { Stop-Restore "De momento la restauracion automatica solo esta preparada para app-fotos. Los volcados de '$Proyecto' estan en $backup (otras-bases dentro del ZIP de bases\)." }
    if (-not $DestinoProyecto) { $DestinoProyecto = $rutaOriginal }
    if (-not $DestinoProyecto) { Stop-Restore 'No se sabe donde dejar el proyecto: usa -DestinoProyecto.' }
    $DestinoProyecto = $DestinoProyecto.Trim().Trim('"').TrimEnd('\')

    $zip = $null
    if ($ZipDatos) { $zip = Get-Item -LiteralPath $ZipDatos }
    else { $zip = Get-ChildItem -LiteralPath (Join-Path $backup 'bases') -Filter 'backup-datos-*.zip' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    if (-not $zip) { Stop-Restore "No hay ZIP de datos en $backup\bases." }
    $abierto = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
    try {
        $dumpEntrada = $abierto.Entries | Where-Object { $_.FullName -match '(^|/)monzon_media\.dump$' } | Select-Object -First 1
        $nUploads = @($abierto.Entries | Where-Object { $_.FullName -like 'uploads/*' -and -not $_.FullName.EndsWith('/') }).Count
    } finally { $abierto.Dispose() }
    if (-not $dumpEntrada -or $dumpEntrada.Length -lt 5KB) { Stop-Restore "El ZIP $($zip.Name) no tiene un monzon_media.dump valido." }

    $compose = if (Test-Path -LiteralPath (Join-Path $carpetaProy 'produccion\docker-compose.yml')) { 'produccion' } else { '' }
    Say "  Carpeta del proyecto en la copia : $carpetaProy"
    Say "  Datos                            : $($zip.Name) ($([math]::Round($zip.Length/1MB,1)) MB; base $([math]::Round($dumpEntrada.Length/1KB)) KB; $nUploads ficheros de uploads)"
    Say "  Se dejara en                     : $DestinoProyecto"
    Say "  Base de datos                    : servicio '$servicioBd', base '$nombreBd', usuario '$usuarioBd'"
    Say "  Compose                          : $(if ($compose) { "$DestinoProyecto\$compose\docker-compose.yml" } else { "$DestinoProyecto\docker-compose.yml" })"

    # ---- 2) seguridad: que no haya una produccion viva
    $hayDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
    if (-not $hayDocker) { Stop-Restore 'Docker no esta instalado o no esta en el PATH.' }
    $existentes = @(docker ps -a --filter "label=com.docker.compose.project=$Proyecto" --format '{{.Names}}' 2>$null | Where-Object { $_ })
    $conocidos = @(docker ps -a --filter 'name=monzon_' --format '{{.Names}}' 2>$null | Where-Object { $_ })
    $vivos = @($existentes + $conocidos | Sort-Object -Unique)
    if ($vivos.Count -gt 0) {
        Say "`n  AVISO: ya existen contenedores de este proyecto: $($vivos -join ', ')" 'Yellow'
        Say '  Esto parece una produccion en marcha. Restaurar SUSTITUYE su base de datos y pierde lo creado despues de la copia.' 'Yellow'
        if (-not $Sustituir) { Stop-Restore 'Nada que hacer: usa otro equipo, o -Sustituir si de verdad quieres reemplazar la base actual.' }
    }

    if (-not $Ejecutar) {
        Say "`nPLAN (no se ha cambiado nada). Para hacerlo de verdad, anade -Ejecutar." 'Green'
        Say '  1. Copiar la carpeta del proyecto (con .env y claves) al destino.'
        Say "  2. Arrancar solo '$servicioBd' y restaurar el volcado con pg_restore --clean --if-exists."
        Say '  3. Arrancar el resto, copiar los uploads y comprobar /api/health.'
        exit 0
    }

    if ($vivos.Count -gt 0) {
        $c = Read-Host 'Escribe SUSTITUIR para continuar'
        if ($c -cne 'SUSTITUIR') { Stop-Restore 'Cancelado: no se cambio nada.' }
    } else {
        $c = Read-Host "Se creara/restaurara '$Proyecto' en $DestinoProyecto. Escribe RESTAURAR para continuar"
        if ($c -cne 'RESTAURAR') { Stop-Restore 'Cancelado: no se cambio nada.' }
    }

    # ---- 3) carpeta del proyecto
    Say "`n1/5 Copiando la carpeta del proyecto..." 'Cyan'
    if ((Test-Path -LiteralPath $DestinoProyecto) -and @(Get-ChildItem -LiteralPath $DestinoProyecto -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        $viejo = "$DestinoProyecto.antes-de-restaurar-$Stamp"
        Move-Item -LiteralPath $DestinoProyecto -Destination $viejo
        Say "    La carpeta existente se ha conservado en: $viejo" 'Yellow'
    }
    New-Item -ItemType Directory -Force $DestinoProyecto | Out-Null
    & robocopy.exe $carpetaProy $DestinoProyecto /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Stop-Restore "robocopy fallo al copiar el proyecto (codigo $LASTEXITCODE)." }
    $dirCompose = if ($compose) { Join-Path $DestinoProyecto $compose } else { $DestinoProyecto }
    $ficheroCompose = Join-Path $dirCompose 'docker-compose.yml'
    if (-not (Test-Path -LiteralPath $ficheroCompose)) { Stop-Restore "Falta $ficheroCompose tras copiar." }
    foreach ($rel in @('.env', 'produccion\.env')) { if (Test-Path -LiteralPath (Join-Path $DestinoProyecto $rel)) { Say "    OK  $rel" 'Green' } }

    # ---- 4) datos
    $tmp = Join-Path $env:TEMP "restaurar-$Stamp"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        Say '2/5 Extrayendo los datos...' 'Cyan'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $tmp)
        $dump = Get-ChildItem -LiteralPath $tmp -Recurse -Filter 'monzon_media.dump' -File | Select-Object -First 1
        if (-not $dump) { Stop-Restore 'No aparece monzon_media.dump tras extraer.' }

        Say "3/5 Arrancando la base de datos ('$servicioBd') y restaurando..." 'Cyan'
        Push-Location $dirCompose
        try {
            docker compose --project-name $Proyecto up -d $servicioBd
            if ($LASTEXITCODE -ne 0) { Stop-Restore "docker compose no pudo arrancar '$servicioBd'." }
        } finally { Pop-Location }
        $pg = $null; $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt 120) {
            $pg = Find-Container $Proyecto $servicioBd
            if ($pg) {
                docker exec $pg pg_isready -U $usuarioBd -d $nombreBd 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { break }
            }
            $pg = $null; Start-Sleep -Seconds 2
        }
        if (-not $pg) { Stop-Restore 'PostgreSQL no respondio en 2 minutos.' }
        Say "    Contenedor: $pg" 'Green'

        docker cp $dump.FullName "${pg}:/tmp/monzon_media.dump"
        if ($LASTEXITCODE -ne 0) { Stop-Restore 'No se pudo copiar el volcado al contenedor.' }
        $ErrorActionPreference = 'Continue'   # pg_restore escribe avisos por stderr; no deben cortar el script
        $salida = docker exec $pg pg_restore -U $usuarioBd -d $nombreBd --clean --if-exists --no-owner /tmp/monzon_media.dump 2>&1
        $codigoRestore = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        docker exec $pg rm -f /tmp/monzon_media.dump 2>$null | Out-Null
        $errores = @($salida | Where-Object { "$_" -match 'error' })
        if ($codigoRestore -ne 0) {
            $script:Avisos++
            Say "    pg_restore devolvio $codigoRestore ($($errores.Count) mensajes de error). Con --clean suelen ser avisos de objetos que no existian; revisa:" 'Yellow'
            $errores | Select-Object -First 8 | ForEach-Object { Say "      $_" 'Yellow' }
        } else { Say '    Base de datos restaurada sin errores.' 'Green' }
        $filas = docker exec $pg psql -U $usuarioBd -d $nombreBd -t -A -c 'SELECT (SELECT count(*) FROM events) || '' eventos, '' || (SELECT count(*) FROM photos) || '' fotos, '' || (SELECT count(*) FROM users) || '' usuarios''' 2>$null
        if ($filas) { Say "    Contenido: $($filas | Select-Object -First 1)" 'Green' }

        if ($SinArrancar) { Say "`nTerminado sin arrancar el resto (-SinArrancar)." 'Green'; exit 0 }

        # ---- 5) resto de la app + uploads
        Say '4/5 Arrancando la aplicacion...' 'Cyan'
        Push-Location $dirCompose
        try {
            docker compose --project-name $Proyecto up -d --build
            if ($LASTEXITCODE -ne 0) { Stop-Restore 'docker compose up --build fallo.' }
        } finally { Pop-Location }
        $be = $null; $t0 = Get-Date
        while (-not $be -and ((Get-Date) - $t0).TotalSeconds -lt 60) { $be = Find-Container $Proyecto 'backend'; if (-not $be) { Start-Sleep -Seconds 2 } }
        $subidas = Join-Path $tmp 'uploads'
        if ($be -and (Test-Path -LiteralPath $subidas)) {
            docker cp "$subidas\." "${be}:/app/uploads"
            if ($LASTEXITCODE -ne 0) { Stop-Restore 'No se pudieron copiar los uploads al backend.' }
            docker restart $be | Out-Null
            Say "    Uploads copiados ($nUploads ficheros: portadas y avatares)." 'Green'
        } else { $script:Avisos++; Say '    AVISO: no se copiaron uploads (sin backend o sin carpeta uploads en la copia).' 'Yellow' }

        Say '5/5 Comprobando que responde...' 'Cyan'
        $ok = $false; $t0 = Get-Date
        while (((Get-Date) - $t0).TotalSeconds -lt 60) {
            try { $r = Invoke-WebRequest -Uri 'http://localhost:3000/api/health' -UseBasicParsing -TimeoutSec 5; if ($r.StatusCode -eq 200) { $ok = $true; break } } catch { }
            Start-Sleep -Seconds 3
        }
        if ($ok) { Say '    /api/health responde 200.' 'Green' } else { $script:Avisos++; Say '    AVISO: /api/health no respondio; mira "docker compose --project-name app-fotos logs backend" (en la carpeta produccion).' 'Yellow' }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($script:Avisos -eq 0) { Say "`nRESTAURACION TERMINADA." 'Green' } else { Say "`nRESTAURACION TERMINADA CON $($script:Avisos) AVISO(S): revisa los mensajes amarillos de arriba antes de fiarte." 'Yellow' }
    Say '  Pendiente: 1) Iniciar-Docker-Produccion-Completo.ps1 del gestor (recrea el Funnel de Tailscale).'
    Say '             2) Probar con probar-restauracion.ps1 (repositorio app-fotos).'
    Say '             3) Las fotos y videos salen del hosting FTP; si el hosting se perdio, restaura la carpeta "fotos" del disco.'
    exit 0
}
catch {
    Say "`nERROR: $($_.Exception.Message)" 'Red'
    exit 1
}
