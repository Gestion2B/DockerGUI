<#
  VERIFICAR BACKUP - Grupo Monzon Media

  Comprueba (solo lectura) la copia que dejo backup-completo.ps1 en el disco externo. Revisa cada
  equipo que haya dentro del destino (servidor, PC de desarrollo...).

  Que comprueba
    1. El log: que la ultima copia termino bien y cuando fue.
    2. Los ficheros imprescindibles (.env, produccion\.env, docker-compose, claves de Android).
    3. La ultima copia de datos (ZIP, solo en el servidor):
         - que el ZIP se abre y que el Explorador de Windows lo veria con contenido
         - que monzon_media.dump existe, no esta vacio y es un volcado de PostgreSQL de verdad
           (cabecera "PGDMP"); y, si hay Docker, que pg_restore puede leer su contenido y que
           trae las tablas con datos (users, photos...)
         - que lleva los uploads
    4. Las fotos del hosting, si se incluyeron (WinSCP).

  Uso
    powershell -ExecutionPolicy Bypass -File .\verificar-backup.ps1 -Destino D:\BackupsMonzon

  Termina con codigo 1 si hay algun FALLO (los AVISO no cuentan como fallo).
#>
param(
  [Parameter(Mandatory = $true)][string]$Destino,
  [int]$DiasMaximos = 8,
  # Si se indica, solo se exige la base y la carpeta de ese proyecto del gestor (la copia se hizo con -Proyecto).
  [string]$Proyecto = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Fallos = 0
$script:Avisos = 0
function Ok([string]$m) { Write-Host "  OK     $m" -ForegroundColor Green }
function Aviso([string]$m) { $script:Avisos++; Write-Host "  AVISO  $m" -ForegroundColor Yellow }
function Fallo([string]$m) { $script:Fallos++; Write-Host "  FALLO  $m" -ForegroundColor Red }

# Proyectos del gestor Docker-Autoarranque (proyectos-produccion.txt), tal como los copio backup-completo.ps1.
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
      Id     = $sec.Id
      Activo = ($activo -notin @('no', 'false', '0'))
      Bd     = if ($x.ContainsKey('bd')) { $x['bd'].ToLowerInvariant() } else { 'no' }
    }
  }
}

if (-not (Test-Path $Destino)) {
  throw "No encuentro '$Destino'. Esta conectado el disco externo?"
}
$equipos = @(Get-ChildItem $Destino -Directory)
if ($equipos.Count -eq 0) { throw "No hay ninguna copia dentro de '$Destino'." }

foreach ($eq in $equipos) {
  Write-Host ""
  Write-Host "=== $($eq.Name) ===" -ForegroundColor Cyan
  $esServidor = Test-Path (Join-Path $eq.FullName "proyecto\produccion\docker-compose.yml")

  # ------------------------------------------------------------ 1) log
  Write-Host "1. Ultima copia"
  $log = Join-Path $eq.FullName "backup.log"
  if (-not (Test-Path $log)) {
    Fallo "no hay backup.log"
  } else {
    $lineas = @(Get-Content $log)
    $veredicto = $null
    for ($i = $lineas.Count - 1; $i -ge 0; $i--) {
      if ($lineas[$i] -match "COPIA COMPLETA Y COMPROBADA" -or $lineas[$i] -match "LA COPIA TERMINO CON PROBLEMAS") { $veredicto = $lineas[$i]; break }
    }
    if (-not $veredicto) {
      Fallo "el log no tiene un resultado final (la copia se interrumpio?)"
    } else {
      $fecha = $null
      try { $fecha = [datetime]::ParseExact($veredicto.Substring(0, 19), "yyyy-MM-dd HH:mm:ss", $null) } catch { }
      $edad = if ($fecha) { (Get-Date) - $fecha } else { $null }
      $cuando = if ($fecha) { "{0:yyyy-MM-dd HH:mm} (hace {1:N1} dias)" -f $fecha, $edad.TotalDays } else { "fecha desconocida" }
      if ($veredicto -match "CON PROBLEMAS") {
        Fallo "la ultima copia termino CON PROBLEMAS: $cuando. Mira $log"
      } elseif ($edad -and $edad.TotalDays -gt $DiasMaximos) {
        Aviso "la ultima copia buena es antigua: $cuando"
      } else {
        Ok "ultima copia completa: $cuando"
      }
    }
  }

  # ------------------------------------------------------------ 2) ficheros imprescindibles
  Write-Host "2. Ficheros imprescindibles"
  $proy = Join-Path $eq.FullName "proyecto"
  if (-not (Test-Path $proy)) {
    Fallo "no hay carpeta 'proyecto' en la copia"
  } else {
    $envs = @(".env", "produccion\.env") | Where-Object { Test-Path (Join-Path $proy $_) }
    if ($envs.Count -eq 0) { Fallo "no hay ningun .env en la copia" } else { Ok ".env presente ($($envs -join ', '))" }
    foreach ($rel in @("produccion\docker-compose.yml", "docker-compose.yml")) {
      if (Test-Path (Join-Path $proy $rel)) { Ok $rel }
    }
    foreach ($rel in @("app\monzonmedia\android\app\upload-keystore.jks", "app\monzonmedia\android\key.properties",
                       "produccion\app\monzonmedia\android\app\upload-keystore.jks", "produccion\app\monzonmedia\android\key.properties")) {
      if (Test-Path (Join-Path $proy $rel)) { Ok "clave de Android: $rel" }
    }
    $hayClaves = @(Get-ChildItem $proy -Recurse -Filter "upload-keystore.jks" -File -ErrorAction SilentlyContinue).Count
    if ($hayClaves -eq 0 -and -not $esServidor) { Aviso "no hay upload-keystore.jks en la copia de este equipo" }
    if ($esServidor) {
      $bk = Join-Path $proy "produccion\backups"
      if (Test-Path $bk) {
        $ult = Get-ChildItem $bk -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($ult) { Ok ("volcados de pgbackups copiados (el mas reciente: {0:yyyy-MM-dd})" -f $ult.LastWriteTime) }
      }
    }
  }

  # ------------------------------------------------------------ 3) copia de datos (ZIP)
  Write-Host "3. Copia de datos (base de datos y uploads)"
  $carpetaBases = Join-Path $eq.FullName "bases"
  $zips = @(Get-ChildItem $carpetaBases -Filter "backup-datos-*.zip" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  if ($zips.Count -eq 0) {
    if ($esServidor) { Fallo "es el servidor y no hay ninguna copia de datos en 'bases'" }
    else { Ok "no aplica: este equipo no tiene base de datos en Docker" }
  } else {
    $zip = $zips[0]
    $horas = ((Get-Date) - $zip.LastWriteTime).TotalHours
    Ok ("{0} copias de datos guardadas; la ultima: {1} ({2:N1} MB, hace {3:N1} h)" -f $zips.Count, $zip.Name, ($zip.Length / 1MB), $horas)
    if ($horas -gt 24 * $DiasMaximos) { Aviso "la ultima copia de datos tiene mas de $DiasMaximos dias" }

    $abierto = $null
    try {
      $abierto = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
      $entradas = @($abierto.Entries)

      # Lo que veria el Explorador de Windows
      $visibles = -1
      try { $visibles = @((New-Object -ComObject Shell.Application).NameSpace($zip.FullName).Items()).Count } catch { }
      $conPrefijo = @($entradas | Where-Object { $_.FullName -like "./*" }).Count
      if ($visibles -eq 0 -or $conPrefijo -gt 0) { Fallo "el ZIP se veria VACIO en el Explorador de Windows (formato antiguo con './')" }
      else { Ok "el ZIP se abre y el Explorador de Windows ve su contenido ($($entradas.Count) entradas)" }

      # El volcado
      $dump = $entradas | Where-Object { $_.FullName -match "(^|/)monzon_media\.dump$" } | Select-Object -First 1
      if (-not $dump) {
        Fallo "el ZIP no contiene monzon_media.dump"
      } elseif ($dump.Length -lt 5KB) {
        Fallo ("monzon_media.dump pesa solo {0} bytes: parece vacio" -f $dump.Length)
      } else {
        $flujo = $dump.Open()
        $cab = New-Object byte[] 5
        [void]$flujo.Read($cab, 0, 5)
        $flujo.Dispose()
        if ([System.Text.Encoding]::ASCII.GetString($cab) -ne "PGDMP") {
          Fallo "monzon_media.dump NO es un volcado de PostgreSQL (cabecera incorrecta)"
        } else {
          Ok ("monzon_media.dump es un volcado de PostgreSQL valido ({0:N0} KB)" -f ($dump.Length / 1KB))

          # Lectura real con pg_restore, si hay Docker
          $tmp = Join-Path $env:TEMP ("verificar-dump-" + [guid]::NewGuid().ToString("N") + ".dump")
          try {
            if (Get-Command docker -ErrorAction SilentlyContinue) {
              [System.IO.Compression.ZipFileExtensions]::ExtractToFile($dump, $tmp, $true)
              $imagen = docker inspect monzon_postgres --format "{{.Config.Image}}" 2>$null | Select-Object -First 1
              if (-not $imagen) { $imagen = "postgres:16-alpine" }
              $carpeta = Split-Path $tmp -Parent
              $sal = @(docker run --rm --pull never -v "${carpeta}:/b:ro" $imagen pg_restore -l ("/b/" + (Split-Path $tmp -Leaf)) 2>$null)
              if ($LASTEXITCODE -ne 0 -or $sal.Count -eq 0) {
                Aviso "no se pudo leer el volcado con pg_restore (imagen '$imagen' no disponible?); la cabecera es correcta"
              } else {
                $tablas = @($sal | Where-Object { $_ -match "TABLE DATA" } | ForEach-Object { ($_ -split "\s+")[-2] } | Sort-Object -Unique)
                if ($tablas.Count -eq 0) { Fallo "pg_restore lee el volcado pero no trae datos de ninguna tabla" }
                else {
                  Ok ("pg_restore lo lee bien; tablas con datos: {0}" -f ($tablas -join ", "))
                  foreach ($t in @("users", "photos", "events")) {
                    if ($tablas -notcontains $t) { Aviso "no aparece la tabla '$t' entre las que tienen datos" }
                  }
                }
              }
            } else {
              Aviso "sin Docker en este equipo: no se pudo leer el volcado con pg_restore (solo se comprobo la cabecera)"
            }
          } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
      }

      # uploads
      $subidas = @($entradas | Where-Object { $_.FullName -like "uploads/*" -and -not $_.FullName.EndsWith("/") }).Count
      if ($subidas -gt 0) { Ok "uploads incluidos ($subidas ficheros: portadas, avatares...)" }
      else { Aviso "el ZIP no lleva ficheros de uploads" }

      # Bases de los demas proyectos del gestor (otras-bases\<proyecto>\<base>.postgres.dump | .mysql.sql)
      foreach ($ob in @($entradas | Where-Object { $_.FullName -match '^otras-bases/[^/]+/.+\.(postgres\.dump|mysql\.sql)$' })) {
        $idp = ($ob.FullName -split '/')[1]
        $nombreBd = ($ob.FullName -split '/')[-1]
        if ($ob.Length -lt 5) { Fallo "${idp}: $nombreBd esta vacio"; continue }
        $flujo = $ob.Open()
        try {
          if ($nombreBd.EndsWith(".postgres.dump")) {
            $cab = New-Object byte[] 5
            [void]$flujo.Read($cab, 0, 5)
            if ([System.Text.Encoding]::ASCII.GetString($cab) -ne "PGDMP") { Fallo "${idp}: $nombreBd NO es un volcado de PostgreSQL (cabecera incorrecta)" }
            else { Ok ("{0}: {1} es un volcado de PostgreSQL valido ({2:N0} KB)" -f $idp, $nombreBd, ($ob.Length / 1KB)) }
          } elseif ($ob.Length -gt 400MB) {
            Aviso "${idp}: $nombreBd es muy grande ($([int]($ob.Length / 1MB)) MB); no se comprobo su marca final"
          } else {
            $lector = New-Object System.IO.StreamReader($flujo, [System.Text.Encoding]::UTF8)
            $texto = $lector.ReadToEnd()
            $cola = $texto.Substring([Math]::Max(0, $texto.Length - 600))
            if ($cola -match '-- Dump completed on ') { Ok ("{0}: {1} es un volcado MySQL completo ({2:N0} KB)" -f $idp, $nombreBd, ($ob.Length / 1KB)) }
            else { Fallo "${idp}: $nombreBd no termina con la marca de mysqldump: volcado incompleto" }
          }
        } finally { $flujo.Dispose() }
      }

      # ¿Falta la base de algun proyecto que el gestor declara con BD?
      $txtGestor = Join-Path $eq.FullName "gestor\proyectos-produccion.txt"
      if (Test-Path -LiteralPath $txtGestor) {
        foreach ($pr in @(Leer-ProyectosGestor $txtGestor | Where-Object { $_.Activo -and $_.Bd -in @("postgres", "mysql") -and (-not $Proyecto -or $_.Id -eq $Proyecto) })) {
          $tiene = if ($pr.Id -eq "app-fotos") { [bool]($entradas | Where-Object { $_.FullName -match '(^|/)monzon_media\.dump$' }) }
                   else { [bool]($entradas | Where-Object { $_.FullName -match ('^otras-bases/' + [regex]::Escape($pr.Id) + '/.+\.(postgres\.dump|mysql\.sql)$') }) }
          if (-not $tiene) { Fallo "el gestor declara una base de datos para '$($pr.Id)' y NO esta en la copia" }
        }
      }
    } catch {
      Fallo ("no se pudo abrir el ZIP: " + $_.Exception.Message)
    } finally {
      if ($abierto) { $abierto.Dispose() }
    }
  }

  # ------------------------------------------------------------ 3b) gestor Docker-Autoarranque
  $carpetaGestor = Join-Path $eq.FullName "gestor"
  if (Test-Path $carpetaGestor) {
    Write-Host "3b. Gestor Docker-Autoarranque y sus proyectos"
    $txtGestor = Join-Path $carpetaGestor "proyectos-produccion.txt"
    if (-not (Test-Path -LiteralPath $txtGestor)) {
      Fallo "la copia del gestor no lleva proyectos-produccion.txt"
    } else {
      Ok "gestor copiado (con proyectos-produccion.txt y sus scripts)"
      if (Test-Path -LiteralPath (Join-Path $carpetaGestor "Restaurar-Copia.ps1")) { Ok "gestor\Restaurar-Copia.ps1 (para restaurar con solo este disco)" }
      else { Aviso "el gestor copiado no lleva Restaurar-Copia.ps1: actualiza el gestor desde el repositorio DockerGUI" }
      foreach ($pr in @(Leer-ProyectosGestor $txtGestor | Where-Object { $_.Activo -and (-not $Proyecto -or $_.Id -eq $Proyecto) })) {
        $esDeEsteRepo = ($pr.Id -eq "app-fotos")
        $dentro = if ($esDeEsteRepo) { Join-Path $eq.FullName "proyecto" } else { Join-Path $eq.FullName ("proyectos\" + $pr.Id) }
        if (Test-Path $dentro) { Ok "carpeta del proyecto '$($pr.Id)' copiada" }
        else { Aviso "no hay copia de la carpeta del proyecto '$($pr.Id)' (no existia en el equipo al copiar?)" }
      }
    }
  }

  # ------------------------------------------------------------ 4) fotos del hosting
  Write-Host "4. Fotos del hosting FTP"
  $fotos = Join-Path $eq.FullName "fotos"
  if (Test-Path $fotos) {
    $n = @(Get-ChildItem $fotos -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($n -gt 0) { Ok "$n ficheros de fotos copiados" } else { Aviso "la carpeta 'fotos' esta vacia" }
  } elseif ($esServidor) {
    Aviso "NO se han copiado las fotos del hosting (hace falta -WinScpSesion en backup-completo.ps1)"
  } else {
    Ok "no aplica en este equipo"
  }
}

Write-Host ""
Write-Host "------------------------------------------------------------"
if ($script:Fallos -eq 0) {
  Write-Host ("RESULTADO: copia en buen estado ({0} aviso(s))." -f $script:Avisos) -ForegroundColor Green
  exit 0
} else {
  Write-Host ("RESULTADO: {0} FALLO(S) y {1} aviso(s). La copia NO es fiable hasta corregirlos." -f $script:Fallos, $script:Avisos) -ForegroundColor Red
  exit 1
}
