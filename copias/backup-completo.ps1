<#
  BACKUP COMPLETO - Grupo Monzon Media

  Copia TODO a un disco externo, tanto en el PC de desarrollo como en el servidor.
  Es el mismo script para las dos maquinas: detecta que hay en cada una. Muestra barras de
  progreso (general y por fichero) y un resumen final con tiempos y tamanos.

  En el servidor, la app en ejecucion esta en la carpeta "produccion" DENTRO del repo
  (con su .env y su docker-compose.yml reales). Esa carpeta se copia entera; pero los datos
  viven aparte: base de datos y portadas en volumenes de Docker (se copian con docker) y las
  fotos en el hosting FTP (se copian con WinSCP).

  Que copia
    1. La carpeta entera del repo (espejo incremental), INCLUIDOS los ficheros que no estan en
       GitHub: .env, produccion\.env, produccion\docker-compose.yml, upload-keystore.jks,
       key.properties, docs\informes, la carpeta .git... Solo deja fuera lo que se regenera
       (node_modules, build, .dart_tool).
    2. Si hay contenedores de Docker de la app (servidor):
         - volcado de la base de datos (monzon_media.dump)
         - portadas y avatares (uploads; la cache de miniaturas se omite, se regenera sola)
         - lista de volumenes y contenedores y estado del Funnel de Tailscale
       Todo en un ZIP con fecha; se conservan los de los ultimos -Dias dias (y siempre 3).
    3. Opcional: las fotos del hosting FTP, con WinSCP (-WinScpSesion).

  Gestor Docker-Autoarranque (proyectos-produccion.txt)
    Si encuentra la carpeta del gestor (-Gestor, o Escritorio\Docker-Autoarranque), el script lee
    proyectos-produccion.txt y ademas:
      - copia la carpeta del gestor entera (scripts, lista de proyectos, rutas del Funnel, GUI) a "gestor"
      - copia la carpeta de cada proyecto activo que quede fuera del repo (p. ej. PoolDocker) a "proyectos"
      - vuelca la base de datos de CADA proyecto con BD=postgres|mysql (p. ej. MySQL de Pool) sin
        parar la aplicacion, con las mismas comprobaciones que el gestor: contrasena solo dentro del
        contenedor, indice con pg_restore --list o marca final de mysqldump, y SHA256 contenedor-host.
        Quedan en el ZIP de datos, en otras-bases\<proyecto>\.
    Se desactiva con -SinGestor.

  Carpetas de Docker fuera del repo
    Los contenedores de la app pueden haberse lanzado desde otras carpetas (otro docker-compose.yml)
    o guardar datos en carpetas del disco (p. ej. los volcados diarios de pgbackups). El script
    pregunta a Docker que carpetas usan los contenedores del proyecto "app-fotos" y copia tambien las
    que queden fuera del repo (a "docker-extra"). Se desactiva con -SinCarpetasDocker.

  Esta version vive en el repositorio del gestor (DockerGUI, carpeta copias) y la lanza
  Copia-Externa.ps1 (o el boton de la GUI) con -RutaProyecto y -Proyecto. Con -Proyecto app-fotos
  copia SOLO ese proyecto (y el gestor, que lleva los scripts de restauracion): no toca las
  carpetas ni las bases de los demas proyectos (p. ej. Pool).

  Uso (en el servidor)
    powershell -ExecutionPolicy Bypass -File .\backup-completo.ps1 -RutaProyecto C:\Users\ServerIT\Desktop\Docker-Proyectos\app-fotos -Proyecto app-fotos -Destino E:\BackupsMonzon
    ... -WinScpSesion "NombreDeLaSesionGuardadaEnWinSCP"     (incluye las fotos del hosting)
    ... -ProgramarTarea -Hora 03:00                          (lo deja programado cada dia)
    ... -SinProgreso                                         (sin barras, solo el log)

  Importante
    - Cifra el disco con BitLocker To Go: la copia lleva contrasenas y datos personales.
    - La carpeta destino es SOLO para esto: el espejo borra en destino lo que ya no existe.
    - Prueba a restaurar de vez en cuando (importar-backup-monzon.bat acepta el ZIP de datos).
#>
param(
  [Parameter(Mandatory = $true)][string]$Destino,
  # Carpeta raiz del proyecto a copiar (la "Ruta" de proyectos-produccion.txt). Por defecto, la de este script.
  [string]$RutaProyecto = "",
  # Si se indica, solo se copia ese proyecto del gestor (las carpetas y bases de los demas se ignoran).
  [string]$Proyecto = "",
  [int]$Dias = 30,
  [string]$WinScpSesion = "",
  [switch]$ProgramarTarea,
  [string]$Hora = "03:00",
  [switch]$SinProgreso,
  [switch]$SinCarpetasDocker,
  [string]$Gestor = "",
  [switch]$SinGestor
)

$ErrorActionPreference = "Stop"
$Raiz = if ($RutaProyecto) { $RutaProyecto.TrimEnd([char]92) } else { $PSScriptRoot }
$Equipo = $env:COMPUTERNAME
$Base = [System.IO.Path]::Combine($Destino, $Equipo)   # Join-Path falla con un disco que no existe
$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$Problemas = New-Object System.Collections.Generic.List[string]
$Reloj = [System.Diagnostics.Stopwatch]::StartNew()
$Resumen = New-Object System.Collections.Generic.List[string]

# Avance para la GUI del gestor: si DOCKER_UPDATER_PROGRESS_FILE existe, se escribe ahi la fase actual
# (6 fases: proyecto, carpetas de Docker/gestor, datos, ZIP, fotos FTP y, fuera de este script, la verificacion).
# Un fallo al escribirlo nunca cancela la copia.
$script:FaseNombre = "Preparando"
$script:FasePaso = 0
$script:FaseInicio = (Get-Date).ToString("o")
function Publicar-Avance([string]$detalle = "") {
  if (-not $env:DOCKER_UPDATER_PROGRESS_FILE) { return }
  try {
    $json = [ordered]@{
      phase = $script:FaseNombre; step = $script:FasePaso; steps = 6; detail = $detalle
      project = $(if ($Proyecto) { $Proyecto } else { "" }); phaseStartedAt = $script:FaseInicio
      updatedAt = (Get-Date).ToString("o"); bytesProcessed = 0; bytesTotal = 0; lastMessage = $detalle
    } | ConvertTo-Json -Depth 3
    $tmpProgreso = "$($env:DOCKER_UPDATER_PROGRESS_FILE).tmp"
    Set-Content -LiteralPath $tmpProgreso -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmpProgreso -Destination $env:DOCKER_UPDATER_PROGRESS_FILE -Force
  } catch { }
}
function Fase([int]$paso, [string]$nombre, [string]$detalle = "") {
  $script:FasePaso = $paso; $script:FaseNombre = $nombre; $script:FaseInicio = (Get-Date).ToString("o")
  Publicar-Avance $detalle
}

# ---------------------------------------------------------------- programar tarea diaria
if ($ProgramarTarea) {
  $argumentos = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Destino `"$Destino`" -Dias $Dias -SinProgreso"
  if ($WinScpSesion) { $argumentos += " -WinScpSesion `"$WinScpSesion`"" }
  $accion = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argumentos -WorkingDirectory $Raiz
  $disparador = New-ScheduledTaskTrigger -Daily -At $Hora
  $ajustes = New-ScheduledTaskSettingsSet -StartWhenAvailable
  Register-ScheduledTask -TaskName "Backup Monzon" -Action $accion -Trigger $disparador -Settings $ajustes -Force | Out-Null
  Write-Host "Tarea 'Backup Monzon' programada cada dia a las $Hora (el disco debe estar conectado)."
  return
}

# ---------------------------------------------------------------- comprobaciones previas
if ($Proyecto -and $Proyecto -ne "app-fotos") {
  throw "De momento la copia externa solo esta preparada para app-fotos (se pidio '$Proyecto')."
}
$unidad = Split-Path $Destino -Qualifier
if (-not (Test-Path $unidad)) {
  throw "El disco externo ($unidad) no esta conectado. No se ha hecho ninguna copia."
}
$rutaRaiz = (Resolve-Path $Raiz).Path.TrimEnd('\')
$rutaDestino = [System.IO.Path]::GetFullPath($Destino).TrimEnd('\')
if ($rutaDestino -eq $rutaRaiz -or $rutaDestino.StartsWith($rutaRaiz + "\")) {
  throw "El destino no puede estar dentro de la carpeta del proyecto."
}

New-Item -ItemType Directory -Force $Base | Out-Null
$LogFile = Join-Path $Base "backup.log"

function Log([string]$mensaje) {
  $linea = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $mensaje
  Write-Host $linea
  Add-Content -Path $LogFile -Value $linea
}

# Barra general (1 sola para todo el backup).
function Progreso([double]$porcentaje, [string]$estado, [string]$detalle = "") {
  Publicar-Avance $estado
  if ($SinProgreso) { return }
  $p = [Math]::Max(0, [Math]::Min(100, [int]$porcentaje))
  Write-Progress -Id 0 -Activity "Backup completo - $Equipo" -Status $estado -PercentComplete $p -CurrentOperation $detalle
}

function Tamano([string]$ruta) {
  if (-not (Test-Path $ruta)) { return "-" }
  $bytes = (Get-ChildItem $ruta -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  if (-not $bytes) { $bytes = 0 }
  return "{0:N1} MB" -f ($bytes / 1MB)
}

# Cuenta las lineas del log de robocopy mientras se escribe (cada linea = un fichero tratado).
function Leer-Avance([string]$ruta) {
  $n = 0
  $ultima = ""
  try {
    $fs = [System.IO.File]::Open($ruta, 'Open', 'Read', 'ReadWrite')
    $sr = New-Object System.IO.StreamReader($fs)
    while (($l = $sr.ReadLine()) -ne $null) {
      if ($l.Trim().Length -gt 0) { $n++; $ultima = $l.Trim() }
    }
    $sr.Close()
  } catch { }
  return [pscustomobject]@{ N = $n; Ultima = $ultima }
}

# Espejo con robocopy y barra de progreso: primero cuenta lo que hay que tratar y despues
# copia mostrando "X de Y ficheros" y el fichero actual.
function Copiar-ConProgreso {
  param(
    [string]$Origen, [string]$Destino, [string[]]$Opciones,
    [string]$Titulo, [double]$Desde, [double]$Hasta
  )
  $o = $Origen.TrimEnd('\')
  $d = $Destino.TrimEnd('\')

  Progreso $Desde "$Titulo - calculando lo que hay que copiar..."
  $plan = & robocopy.exe $o $d @Opciones /L /NJH /NJS /NDL /NP /NS /NC /FP
  $total = @($plan | Where-Object { $_.Trim().Length -gt 0 }).Count

  $log = Join-Path $env:TEMP "monzon-robocopy-$Stamp.log"
  Remove-Item $log -Force -ErrorAction SilentlyContinue
  $parametros = "`"$o`" `"$d`" " + ($Opciones -join " ") + " /R:1 /W:1 /NJH /NJS /NDL /NP /NS /NC /FP /LOG:`"$log`""
  $proceso = Start-Process -FilePath "robocopy.exe" -ArgumentList $parametros -PassThru -WindowStyle Hidden

  while (-not $proceso.HasExited) {
    Start-Sleep -Milliseconds 400
    if (-not $SinProgreso -and $total -gt 0) {
      $a = Leer-Avance $log
      $pct = [Math]::Min(100, [int](100 * $a.N / $total))
      Write-Progress -Id 1 -ParentId 0 -Activity $Titulo -Status ("{0} de {1} ficheros ({2} %)" -f $a.N, $total, $pct) -PercentComplete $pct -CurrentOperation $a.Ultima
      Progreso ($Desde + ($Hasta - $Desde) * $pct / 100) ("$Titulo - {0} de {1} ficheros" -f $a.N, $total)
    }
  }
  $proceso.WaitForExit()
  $codigo = $proceso.ExitCode
  Write-Progress -Id 1 -Completed -Activity $Titulo

  # Si hubo fallos (codigo 8 o mas) se guarda el detalle y se devuelven las primeras lineas con
  # error junto con la linea siguiente (que explica la causa).
  $errores = @()
  if ($codigo -ge 8 -and (Test-Path $log)) {
    $lineas = @(Get-Content $log -ErrorAction SilentlyContinue)
    for ($i = 0; $i -lt $lineas.Count -and $errores.Count -lt 20; $i++) {
      if ($lineas[$i] -match "ERROR") {
        $errores += $lineas[$i].Trim()
        if (($i + 1) -lt $lineas.Count -and $lineas[$i + 1] -notmatch "^\s*$") { $errores += ("    " + $lineas[$i + 1].Trim()) }
      }
    }
    $nombreLog = "robocopy-errores-" + (($Titulo -replace "[^A-Za-z0-9]+", "_").Trim("_")) + ".log"
    Copy-Item $log (Join-Path $Base $nombreLog) -Force -ErrorAction SilentlyContinue
  }
  Remove-Item $log -Force -ErrorAction SilentlyContinue

  return [pscustomobject]@{ Codigo = $codigo; Ficheros = $total; Errores = $errores }
}

# Ruta de Docker Desktop (Linux) -> ruta de Windows. Devuelve $null si no se reconoce.
function Convertir-RutaDocker([string]$ruta) {
  if ($ruta -match '^/(?:run/desktop/mnt/host|host_mnt|mnt)/([a-zA-Z])/(.*)$') {
    return ($Matches[1].ToUpper() + ":\" + ($Matches[2] -replace '/', '\'))
  }
  if ($ruta -match '^[a-zA-Z]:\\') { return $ruta }
  return $null
}

# De una lista de carpetas, deja solo las que NO estan dentro de $raiz ni de otra de la lista.
function Filtrar-Rutas([string[]]$rutas, [string]$raiz) {
  # Nunca una unidad entera ("C:\"): ni como carpeta a copiar ni como "carpeta madre" de las demas.
  $limpias = @($rutas | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') } | Where-Object { $_.Length -gt 3 } | Sort-Object -Unique)
  $resultado = @()
  foreach ($r in $limpias) {
    if ($r -ieq $raiz -or $r.StartsWith($raiz + "\", [StringComparison]::OrdinalIgnoreCase)) { continue }
    $dentro = $false
    foreach ($otra in $limpias) {
      if ($otra -ne $r -and $r.StartsWith($otra + "\", [StringComparison]::OrdinalIgnoreCase)) { $dentro = $true }
    }
    if (-not $dentro) { $resultado += $r }
  }
  return $resultado
}

# Carpetas que usan los contenedores del proyecto de Docker: desde donde se lanzaron
# (docker compose) y las carpetas del disco montadas dentro (bind mounts, p. ej. backups).
function Carpetas-De-Docker {
  $rutas = @()
  $nombres = @(docker ps -a --filter "label=com.docker.compose.project=app-fotos" --format "{{.Names}}" 2>$null)
  foreach ($n in $nombres) {
    $c = (docker inspect $n 2>$null | ConvertFrom-Json)[0]
    if (-not $c) { continue }
    $wd = $c.Config.Labels.'com.docker.compose.project.working_dir'
    if ($wd) { $rutas += $wd }
    foreach ($m in $c.Mounts) {
      if ($m.Type -eq 'bind') {
        $r = Convertir-RutaDocker $m.Source
        if ($r) { $rutas += $r }
      }
    }
  }
  return @($rutas | Where-Object { $_ })
}

# Busca el contenedor de un servicio de la app (por la etiqueta de docker compose) y, si no,
# por el nombre habitual.
function Buscar-Contenedor([string]$servicio, [string]$porDefecto) {
  $n = docker ps --filter "label=com.docker.compose.project=app-fotos" --filter "label=com.docker.compose.service=$servicio" --format "{{.Names}}" 2>$null | Select-Object -First 1
  if ($n) { return $n }
  $st = docker inspect -f "{{.State.Running}}" $porDefecto 2>$null
  if ($st -eq "true") { return $porDefecto }
  return $null
}

# Lee proyectos-produccion.txt del gestor Docker-Autoarranque (mismo formato que usa el gestor).
function Leer-ProyectosGestor([string]$fichero) {
  $secciones = @()
  $id = $null
  $v = @{}
  foreach ($crudo in Get-Content -LiteralPath $fichero -Encoding UTF8) {
    $l = $crudo.Trim()
    if (-not $l -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
    if ($l -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') {
      if ($id) { $secciones += [pscustomobject]@{ Id = $id; V = $v } }
      $id = $Matches[1]; $v = @{}; continue
    }
    if ($id -and $l -match '^([^=]+)=(.*)$') { $v[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() }
  }
  if ($id) { $secciones += [pscustomobject]@{ Id = $id; V = $v } }
  foreach ($sec in $secciones) {
    $x = $sec.V
    if (-not $x.ContainsKey('ruta')) { continue }
    $activo = if ($x.ContainsKey('activo')) { $x['activo'].ToLowerInvariant() } else { 'si' }
    [pscustomobject]@{
      Id         = $sec.Id
      Nombre     = if ($x.ContainsKey('nombre') -and $x['nombre']) { $x['nombre'] } else { $sec.Id }
      Ruta       = $x['ruta'].Trim([char[]]@('"', "'")).TrimEnd('\')
      Activo     = ($activo -notin @('no', 'false', '0'))
      Bd         = if ($x.ContainsKey('bd')) { $x['bd'].ToLowerInvariant() } else { 'no' }
      BdServicio = if ($x.ContainsKey('bdservicio')) { $x['bdservicio'] } else { '' }
      BdNombre   = if ($x.ContainsKey('bdnombre')) { $x['bdnombre'] } else { '' }
      BdUsuario  = if ($x.ContainsKey('bdusuario')) { $x['bdusuario'] } else { '' }
    }
  }
}

# Volcado de la base de datos de un proyecto del gestor (Postgres o MySQL), sin parar la aplicacion.
# Reproduce las comprobaciones de Copia-PostgreSQL.ps1 del gestor. Los errores se anotan en
# $Problemas y NO detienen la copia de lo demas.
function Volcar-OtraBase($proyecto, [string]$carpetaTemporal) {
  $id = $proyecto.Id
  $tipo = $proyecto.Bd
  $patron = '^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$'
  foreach ($campo in @($proyecto.BdServicio, $proyecto.BdNombre, $proyecto.BdUsuario)) {
    if ($campo -cnotmatch $patron) {
      Log "    ERROR ($id): BDServicio, BDNombre o BDUsuario faltan o tienen caracteres no admitidos en proyectos-produccion.txt."
      $Problemas.Add("No se copio la base de datos de ${id}: configuracion BD* incorrecta.")
      return
    }
  }
  $contenedor = docker ps --filter "label=com.docker.compose.project=$id" --filter "label=com.docker.compose.service=$($proyecto.BdServicio)" --format "{{.Names}}" 2>$null | Select-Object -First 1
  if (-not $contenedor) {
    Log "    ERROR ($id): no encuentro el contenedor del servicio '$($proyecto.BdServicio)' en marcha."
    $Problemas.Add("No se copio la base de datos de ${id}: contenedor no encontrado o parado.")
    return
  }
  $bd = $proyecto.BdNombre
  $remoto = $null
  try {
    if ($tipo -eq "mysql") {
      if ($proyecto.BdUsuario -ne "root") { throw "MySQL requiere BDUsuario=root (y MYSQL_ROOT_PASSWORD dentro del contenedor)." }
      if ($bd -eq "auto") {
        $bd = (docker exec $contenedor printenv MYSQL_DATABASE 2>$null | Select-Object -First 1)
        if (-not $bd -or $bd -cnotmatch $patron) { throw "No se pudo leer MYSQL_DATABASE del contenedor. Indica BDNombre." }
      }
    }
    $ext = if ($tipo -eq "mysql") { ".mysql.sql" } else { ".postgres.dump" }
    $remoto = "/tmp/copia-" + [guid]::NewGuid().ToString("N") + $ext
    $carpeta = Join-Path $carpetaTemporal ("otras-bases\" + $id)
    New-Item -ItemType Directory -Force $carpeta | Out-Null
    $destino = Join-Path $carpeta ($bd + $ext)

    # La contrasena se queda dentro del contenedor: no se imprime ni se copia a ningun fichero.
    if ($tipo -eq "mysql") {
      $orden = "umask 077; MYSQL_PWD=`${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD_no_configurada}; export MYSQL_PWD; exec mysqldump --no-defaults --protocol=socket --user=root --single-transaction --quick --routines --events --triggers --hex-blob --no-tablespaces --set-gtid-purged=OFF --default-character-set=utf8mb4 --comments --dump-date --databases $bd --result-file=$remoto"
    } else {
      $orden = "umask 077; export PGPASSWORD=`$POSTGRES_PASSWORD; exec pg_dump -w -Fc -U $($proyecto.BdUsuario) -d $bd -f $remoto"
    }
    docker exec $contenedor sh -c $orden
    if ($LASTEXITCODE -ne 0) { throw "el volcado $tipo de $bd fallo." }

    if ($tipo -eq "postgres") {
      docker exec $contenedor pg_restore --list $remoto | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "pg_restore no pudo leer el indice del volcado." }
    }
    $lineaHash = @(docker exec $contenedor sha256sum $remoto)
    if ($LASTEXITCODE -ne 0 -or $lineaHash.Count -ne 1 -or $lineaHash[0] -notmatch '^([a-fA-F0-9]{64})\s') {
      throw "no se pudo calcular el SHA256 del volcado dentro del contenedor."
    }
    $hashOrigen = $Matches[1].ToLowerInvariant()

    docker cp "${contenedor}:$remoto" $destino
    if ($LASTEXITCODE -ne 0) { throw "no se pudo copiar el volcado a Windows." }
    if (-not (Test-Path -LiteralPath $destino) -or (Get-Item -LiteralPath $destino).Length -lt 5) { throw "el volcado copiado esta vacio." }
    $hashLocal = (Get-FileHash -LiteralPath $destino -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hashLocal -ne $hashOrigen) { throw "el volcado copiado no coincide con el original (SHA256)." }

    if ($tipo -eq "mysql") {
      $cola = @(Get-Content -LiteralPath $destino -Encoding UTF8 -Tail 8)
      if (-not ($cola -match '^-- Dump completed on ')) { throw "falta la marca final de mysqldump: volcado incompleto." }
    } else {
      $flujo = [System.IO.File]::OpenRead($destino)
      try {
        $cab = New-Object byte[] 5
        [void]$flujo.Read($cab, 0, 5)
        if ([System.Text.Encoding]::ASCII.GetString($cab) -cne "PGDMP") { throw "el volcado no tiene la cabecera PGDMP." }
      } finally { $flujo.Dispose() }
    }
    Log ("    OK    {0}: {1} volcado de '{2}' ({3:N1} MB, SHA256 coincide)" -f $id, $tipo, $bd, ((Get-Item -LiteralPath $destino).Length / 1MB))
  } catch {
    Log ("    ERROR ({0}): {1}" -f $id, $_.Exception.Message)
    $Problemas.Add(("No se copio bien la base de datos de {0}: {1}" -f $id, $_.Exception.Message))
    # Un volcado dudoso no debe quedar dentro del ZIP: alguien podria restaurarlo por error.
    if ($destino -and (Test-Path -LiteralPath $destino)) { Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue }
    if ($carpeta -and (Test-Path -LiteralPath $carpeta) -and -not @(Get-ChildItem -LiteralPath $carpeta -Force)) { Remove-Item -LiteralPath $carpeta -Force -ErrorAction SilentlyContinue }
  } finally {
    if ($remoto) { docker exec $contenedor rm -f $remoto 2>$null | Out-Null }
  }
}

Log "===== Backup completo en $Equipo -> $Base ====="
if ($Proyecto) { Log "Proyecto elegido: $Proyecto (los demas proyectos del gestor NO se copian)." }
Fase 0 "Preparando" "Comprobando el disco y el proyecto"
Progreso 0 "Preparando..."

# Espacio libre y cifrado del disco (solo avisos)
try {
  $libre = (Get-PSDrive ($unidad.TrimEnd(':'))).Free
  if ($libre -lt 2GB) { Log ("AVISO: quedan solo {0:N1} GB libres en el disco." -f ($libre / 1GB)) }
} catch { }
try {
  $bl = Get-BitLockerVolume -MountPoint $unidad -ErrorAction Stop
  if ($bl.ProtectionStatus -ne "On") {
    Log "AVISO: el disco $unidad NO esta cifrado con BitLocker. La copia lleva contrasenas y datos personales."
  }
} catch {
  Log "AVISO: no se pudo comprobar si el disco esta cifrado (ejecuta como administrador). Cifralo con BitLocker To Go."
}

$esServidor = Test-Path (Join-Path $Raiz "produccion\docker-compose.yml")
if ($esServidor) { Log "Detectado: servidor (existe la carpeta 'produccion' con su docker-compose.yml)." }
else { Log "Detectado: PC de desarrollo (no hay carpeta 'produccion')." }

# Gestor Docker-Autoarranque: su proyectos-produccion.txt dice que proyectos hay y como son sus bases.
$gestorRuta = ""
$proyectosGestor = @()
if (-not $SinGestor) {
  $candidatos = @()
  if ($Gestor) { $candidatos += $Gestor }
  $candidatos += @(
    (Join-Path $Raiz "..\..\Docker-Autoarranque"),
    (Join-Path $Raiz "..\Docker-Autoarranque"),
    (Join-Path ([Environment]::GetFolderPath("Desktop")) "Docker-Autoarranque")
  )
  foreach ($c in $candidatos) {
    $resuelta = $null
    try { $resuelta = (Resolve-Path -LiteralPath $c -ErrorAction Stop).Path } catch { continue }
    if (Test-Path -LiteralPath (Join-Path $resuelta "proyectos-produccion.txt") -PathType Leaf) { $gestorRuta = $resuelta.TrimEnd('\'); break }
  }
}
if ($gestorRuta) {
  try { $proyectosGestor = @(Leer-ProyectosGestor (Join-Path $gestorRuta "proyectos-produccion.txt")) }
  catch { Log "AVISO: no se pudo leer proyectos-produccion.txt del gestor: $($_.Exception.Message)"; $Problemas.Add("No se pudo leer proyectos-produccion.txt del gestor.") }
  if ($Proyecto) {
    if (-not @($proyectosGestor | Where-Object { $_.Id -eq $Proyecto -and $_.Activo })) {
      throw "El proyecto '$Proyecto' no esta activo en proyectos-produccion.txt."
    }
    # Solo el elegido: las carpetas y las bases de los demas no se tocan.
    $proyectosGestor = @($proyectosGestor | Where-Object { $_.Id -eq $Proyecto })
  }
  $activos = @($proyectosGestor | Where-Object { $_.Activo })
  Log "Gestor Docker-Autoarranque: $gestorRuta ($($activos.Count) proyecto(s) activo(s): $(($activos | ForEach-Object { $_.Id }) -join ', '))"
} else {
  Log "Gestor Docker-Autoarranque: no detectado (la copia no incluye sus proyectos ni sus bases; usa -Gestor <ruta>)."
}

# ---------------------------------------------------------------- 1) carpeta del repo
Log "1/3 Copiando la carpeta del proyecto (incluye .env, claves, produccion y .git)..."
Fase 1 "Copiando la carpeta del proyecto" "Espejo de la carpeta con .env, claves y produccion"
$opciones = @("/MIR", "/XJ", "/XD", "node_modules", "build", ".dart_tool", ".gradle", ".idea", "restore-temp-*", "/XF", "hs_err_pid*.log")

function Copiar-Y-Registrar([string]$origen, [string]$destino, [string]$titulo, [double]$desde, [double]$hasta) {
  $r = Copiar-ConProgreso -Origen $origen -Destino $destino -Opciones $opciones -Titulo $titulo -Desde $desde -Hasta $hasta
  if ($r.Codigo -ge 8) {
    $Problemas.Add("Fallo copiando '$titulo' (robocopy codigo $($r.Codigo)).")
    Log "    ERROR: robocopy devolvio $($r.Codigo) copiando '$titulo'. Primeros errores:"
    foreach ($e in $r.Errores) { Log "        $e" }
    Log "    (detalle completo en la carpeta de la copia: robocopy-errores-*.log)"
  } else {
    $tam = Tamano $destino
    Log "    '$titulo' copiado: $tam ($($r.Ficheros) ficheros nuevos o cambiados)"
    $Resumen.Add(("{0,-15} {1}" -f ($titulo + ":"), $tam))
  }
}

$destProyecto = Join-Path $Base "proyecto"
Copiar-Y-Registrar $Raiz $destProyecto "Proyecto" 2 45

# Carpetas que usan los contenedores y quedan fuera del repo (otro docker-compose, backups...).
if (-not $SinCarpetasDocker -and (Get-Command docker -ErrorAction SilentlyContinue)) {
  Fase 2 "Carpetas de Docker y gestor" "Preguntando a Docker que carpetas usan los contenedores"
  Progreso 45 "Preguntando a Docker que carpetas usan los contenedores..."
  $extras = @(Filtrar-Rutas (Carpetas-De-Docker) $rutaRaiz | Where-Object { Test-Path $_ -PathType Container })
  if ($extras.Count -eq 0) {
    Log "    Docker: los contenedores solo usan carpetas que ya estan dentro del repo."
  } else {
    Log "    Docker: los contenedores usan $($extras.Count) carpeta(s) fuera del repo, se copian tambien:"
    $i = 0
    foreach ($extra in $extras) {
      $i++
      Log "        $extra"
      $nombre = ($extra -replace "[:\\/]+", "_").Trim("_")
      Copiar-Y-Registrar $extra (Join-Path $Base "docker-extra\$nombre") ("Docker " + $i) (45 + 10 * ($i - 1) / $extras.Count) (45 + 10 * $i / $extras.Count)
    }
  }
}

# Carpeta del gestor y carpetas de los demas proyectos que declara (p. ej. PoolDocker).
if ($gestorRuta) {
  Progreso 52 "Copiando el gestor Docker-Autoarranque y los demas proyectos..."
  $dentroDelRepo = { param($ruta) ($ruta -ieq $rutaRaiz) -or $ruta.StartsWith($rutaRaiz + "\", [StringComparison]::OrdinalIgnoreCase) }
  if (-not (& $dentroDelRepo $gestorRuta)) {
    Copiar-Y-Registrar $gestorRuta (Join-Path $Base "gestor") "Gestor" 52 53
    $txt = Join-Path $Base "gestor\proyectos-produccion.txt"
    if (Test-Path -LiteralPath $txt) { Log "    OK    gestor\proyectos-produccion.txt" }
    else { Log "    FALTA gestor\proyectos-produccion.txt"; $Problemas.Add("No se copio proyectos-produccion.txt del gestor.") }
  }
  foreach ($proy in @($proyectosGestor | Where-Object { $_.Activo })) {
    if (-not (Test-Path -LiteralPath $proy.Ruta -PathType Container)) {
      Log "    AVISO: la carpeta del proyecto '$($proy.Id)' no existe en este equipo ($($proy.Ruta)): se omite."
      continue
    }
    if (& $dentroDelRepo $proy.Ruta) { continue }                                  # ya va dentro de "proyecto"
    if ($proy.Ruta -ieq $gestorRuta) { continue }
    Copiar-Y-Registrar $proy.Ruta (Join-Path $Base ("proyectos\" + $proy.Id)) ("Proyecto " + $proy.Id) 53 55
  }
}

# Ficheros imprescindibles: si existen en el origen, tienen que existir en la copia.
$criticos = @(
  ".env",
  "produccion\.env",
  "produccion\docker-compose.yml",
  "docker-compose.yml",
  "app\monzonmedia\android\app\upload-keystore.jks",
  "app\monzonmedia\android\key.properties"
)
Progreso 56 "Comprobando los ficheros imprescindibles..."
foreach ($rel in $criticos) {
  $origen = Join-Path $Raiz $rel
  $copia = Join-Path $destProyecto $rel
  if (Test-Path $origen) {
    if ((Test-Path $copia) -and ((Get-Item $copia).Length -eq (Get-Item $origen).Length)) {
      Log "    OK    $rel"
    } else {
      Log "    FALTA $rel"
      $Problemas.Add("No se copio correctamente: $rel")
    }
  }
}

# ---------------------------------------------------------------- 2) datos de Docker
Log "2/3 Datos de Docker (base de datos y uploads)..."
Fase 3 "Base de datos y uploads" "Volcado en caliente, sin parar la aplicacion"
Progreso 58 "Buscando los contenedores de la app..."
$pg = $null
$be = $null
if (Get-Command docker -ErrorAction SilentlyContinue) {
  $pg = Buscar-Contenedor "postgres" "monzon_postgres"
  $be = Buscar-Contenedor "backend" "monzon_backend"
}
# Bases de datos de OTROS proyectos del gestor (p. ej. Pool con MySQL). La de app-fotos va aparte.
$otrosBd = @()
if ((Get-Command docker -ErrorAction SilentlyContinue) -and $proyectosGestor.Count -gt 0) {
  $otrosBd = @($proyectosGestor | Where-Object { $_.Activo -and ($_.Bd -in @("postgres", "mysql")) -and $_.Id -ne "app-fotos" })
}

if (-not $pg -and $otrosBd.Count -eq 0) {
  if ($esServidor) {
    Log "    ERROR: es el servidor pero no encuentro el contenedor de la base de datos en marcha."
    $Problemas.Add("No se copio la base de datos: contenedor de Postgres no encontrado o parado.")
  } else {
    Log "    No hay contenedor de la base de datos en este equipo: se omite (normal en el PC de desarrollo)."
  }
} else {
  if ($pg) {
    Log "    Contenedores: base de datos = $pg, backend = $(if ($be) { $be } else { '(no encontrado)' })"
  } elseif ($esServidor) {
    Log "    ERROR: es el servidor pero no encuentro el contenedor de la base de datos de app-fotos en marcha."
    $Problemas.Add("No se copio la base de datos de app-fotos: contenedor de Postgres no encontrado o parado.")
  }
  $tmp = Join-Path $env:TEMP "monzon-backup-$Stamp"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    if ($pg) {
      $usuario = (docker exec $pg printenv POSTGRES_USER 2>$null | Select-Object -First 1)
      $bd = (docker exec $pg printenv POSTGRES_DB 2>$null | Select-Object -First 1)
      if (-not $usuario) { $usuario = "monzon_user" }
      if (-not $bd) { $bd = "monzon_media" }

      Progreso 62 "Volcando la base de datos..." "pg_dump de $bd"
      docker exec $pg pg_dump -U $usuario -d $bd -Fc -f /tmp/monzon_media.dump
      if ($LASTEXITCODE -ne 0) { throw "Fallo el volcado de la base de datos." }
      docker cp "${pg}:/tmp/monzon_media.dump" (Join-Path $tmp "monzon_media.dump")
      if ($LASTEXITCODE -ne 0) { throw "Fallo la copia del volcado." }
      docker exec $pg rm -f /tmp/monzon_media.dump | Out-Null
      Log ("    Base de datos volcada ({0:N1} MB)" -f ((Get-Item (Join-Path $tmp "monzon_media.dump")).Length / 1MB))

      if ($be) {
        Progreso 70 "Copiando portadas y avatares (uploads)..."
        docker cp "${be}:/app/uploads" (Join-Path $tmp "uploads")
        if ($LASTEXITCODE -ne 0) { throw "Fallo la copia de uploads." }
        # La cache de miniaturas se regenera sola y puede ser muy grande.
        Remove-Item (Join-Path $tmp "uploads\thumbnails") -Recurse -Force -ErrorAction SilentlyContinue
        Log ("    Uploads copiados ({0})" -f (Tamano (Join-Path $tmp "uploads")))
      } else {
        Log "    AVISO: no hay contenedor del backend en marcha, no se copian las portadas ni los avatares."
        $Problemas.Add("No se copio uploads: contenedor del backend parado.")
      }
    }

    # Bases de datos de los demas proyectos del gestor (un fallo en una no impide copiar las otras).
    foreach ($otro in $otrosBd) {
      Progreso 73 ("Volcando la base de datos de " + $otro.Id + "...")
      Volcar-OtraBase $otro $tmp
    }

    Progreso 76 "Guardando la configuracion de Docker y Tailscale..."
    docker volume ls > (Join-Path $tmp "docker-volumes.txt")
    docker ps -a --format "{{.Names}}  {{.Image}}  {{.Status}}" > (Join-Path $tmp "docker-contenedores.txt")
    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
      tailscale funnel status > (Join-Path $tmp "tailscale-funnel.txt")
      tailscale status > (Join-Path $tmp "tailscale-status.txt")
    }

    $carpetaDatos = Join-Path $Base "bases"
    New-Item -ItemType Directory -Force $carpetaDatos | Out-Null
    $zip = Join-Path $carpetaDatos "backup-datos-$Stamp.zip"
    Fase 4 "Comprimiendo y comprobando los datos" "Puede tardar si uploads es grande"
    Progreso 80 "Comprimiendo los datos..." "puede tardar si uploads es grande"
    # Nombres de primer nivel explicitos. Con "tar ... ." las entradas llevan el prefijo "./" y el
    # Explorador de Windows muestra el ZIP como VACIO aunque tenga todo dentro.
    $nombres = @(Get-ChildItem $tmp -Force | ForEach-Object { $_.Name })
    tar -a -c -f $zip -C $tmp @nombres
    if ($LASTEXITCODE -ne 0) { throw "Fallo al crear el ZIP." }

    Progreso 90 "Comprobando el ZIP..."
    # Se comprueba tambien como lo veria el Explorador de Windows (-1 = no se pudo comprobar).
    $visibles = -1
    try { $visibles = @((New-Object -ComObject Shell.Application).NameSpace($zip).Items()).Count } catch { }
    $contenido = @(tar -tf $zip)
    $conPrefijo = @($contenido | Where-Object { $_ -like "./*" }).Count
    $hayDump = [bool]($contenido -match "monzon_media\.dump")
    $bases = @($contenido | Where-Object { $_ -match "(\.postgres\.dump|\.mysql\.sql)$" }).Count
    $correcto = ((Get-Item $zip).Length -gt 0) -and ($visibles -ne 0) -and ($conPrefijo -eq 0) -and ((-not $pg) -or $hayDump)
    if ($correcto) {
      $mb = "{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)
      Log ("    OK    {0} ({1}, {2} entradas, {3} volcado(s) de otras bases{4})" -f (Split-Path $zip -Leaf), $mb, $contenido.Count, $bases, $(if ($hayDump) { ", con monzon_media.dump" } else { "" }))
      $Resumen.Add("Datos (ZIP):    $mb")
    } elseif ($visibles -eq 0 -or $conPrefijo -gt 0) {
      throw "El ZIP se ve vacio en el Explorador de Windows (entradas con prefijo './')."
    } else {
      throw "El ZIP no contiene monzon_media.dump."
    }

    # Retencion: borra los de mas de -Dias dias, pero conserva siempre los 3 mas recientes.
    $todos = Get-ChildItem $carpetaDatos -Filter "backup-datos-*.zip" | Sort-Object LastWriteTime -Descending
    $viejos = @($todos | Select-Object -Skip 3 | Where-Object LastWriteTime -lt (Get-Date).AddDays(-$Dias))
    $viejos | Remove-Item -Force
    if ($viejos.Count -gt 0) { Log "    Borradas $($viejos.Count) copias de datos de mas de $Dias dias." }
    Log "    Copias de datos guardadas: $(@(Get-ChildItem $carpetaDatos -Filter 'backup-datos-*.zip').Count)"
  } catch {
    Log ("    ERROR: " + $_.Exception.Message)
    $Problemas.Add($_.Exception.Message)
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- 3) fotos del hosting FTP
if ($WinScpSesion) {
  Log "3/3 Fotos del hosting FTP (WinSCP, sesion '$WinScpSesion')..."
  Fase 5 "Fotos del hosting FTP" "Sincronizando con WinSCP"
  Progreso 92 "Sincronizando las fotos del hosting (WinSCP)..." "WinSCP muestra su propio avance"
  $winscp = $null
  $cmd = Get-Command winscp.com -ErrorAction SilentlyContinue
  if ($cmd) { $winscp = $cmd.Source }
  foreach ($c in @("C:\Program Files (x86)\WinSCP\WinSCP.com", "C:\Program Files\WinSCP\WinSCP.com")) {
    if (-not $winscp -and (Test-Path $c)) { $winscp = $c }
  }
  if (-not $winscp) {
    Log "    ERROR: no se encuentra WinSCP.com. Instala WinSCP."
    $Problemas.Add("No se encontro WinSCP.com para copiar las fotos del hosting.")
  } else {
    $fotos = Join-Path $Base "fotos"
    New-Item -ItemType Directory -Force $fotos | Out-Null
    $guion = Join-Path $env:TEMP "monzon-winscp-$Stamp.txt"
    @(
      "option batch abort",
      "option confirm off",
      "open `"$WinScpSesion`"",
      "synchronize local `"$fotos`" /",
      "exit"
    ) | Set-Content -Path $guion -Encoding ASCII
    & $winscp "/script=$guion" "/log=$(Join-Path $Base 'winscp.log')"
    $codigo = $LASTEXITCODE
    Remove-Item $guion -Force -ErrorAction SilentlyContinue
    if ($codigo -ne 0) {
      Log "    ERROR: WinSCP termino con codigo $codigo (mira winscp.log)."
      $Problemas.Add("Fallo la sincronizacion de fotos con WinSCP (codigo $codigo).")
    } else {
      $tam = Tamano $fotos
      Log "    Fotos sincronizadas: $tam"
      $Resumen.Add("Fotos (FTP):    $tam")
    }
  }
} else {
  Log "3/3 Fotos del hosting FTP: omitido (usa -WinScpSesion para incluirlas)."
}

# ---------------------------------------------------------------- resumen
Progreso 100 "Terminado"
if (-not $SinProgreso) {
  Write-Progress -Id 0 -Completed -Activity "Backup completo - $Equipo"
}
Log "----- Resumen -----"
foreach ($linea in $Resumen) { Log "    $linea" }
Log ("Total en el disco para este equipo: " + (Tamano $Base))
Log ("Duracion: {0:mm\:ss} (min:seg)" -f $Reloj.Elapsed)
if ($Problemas.Count -eq 0) {
  Log "COPIA COMPLETA Y COMPROBADA."
  exit 0
} else {
  foreach ($p in $Problemas) { Log "PROBLEMA: $p" }
  Log "LA COPIA TERMINO CON PROBLEMAS. Revisa el log: $LogFile"
  exit 1
}
