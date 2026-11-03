#requires -Version 5.1
<#
.SYNOPSIS
  Copia COMPLETA de UN proyecto del gestor a un disco externo, y la comprueba.

.DESCRIPTION
  Complementa las copias de base de datos del gestor (Copia-PostgreSQL.ps1, que guarda sus
  volcados en old\ dentro del MISMO disco) con lo que le falta para sobrevivir a un fallo del
  disco del servidor:
    - la carpeta del proyecto elegido (con .env, claves, produccion, old...)
    - la propia carpeta del gestor (scripts, lista de proyectos, rutas del Funnel y Restaurar-Copia.ps1)
    - un volcado de la base de datos del proyecto, sin pararlo, con indice comprobado
    - portadas y avatares de app-fotos, configuracion de Docker y Tailscale
    - opcionalmente las fotos del hosting FTP (WinSCP)
  y despues VERIFICA la copia (volcados legibles, ZIP visible, ficheros imprescindibles...).

  Los scripts que hacen el trabajo estan en la carpeta "copias" de este mismo repositorio.
  Solo se copia el proyecto indicado con -Proyecto: los demas (p. ej. Pool) no se tocan.
  Si no se indica -Proyecto, se usa app-fotos.

  No para ninguna aplicacion. No toca old, pruebas ni VERSION.txt.
  Para restaurar: Restaurar-Copia.ps1.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\Copia-Externa.ps1 -Proyecto app-fotos -Destino D:\BackupsMonzon
#>
[CmdletBinding()]
param(
    # Proyecto del gestor (seccion de proyectos-produccion.txt) que se copia.
    [string]$Proyecto = 'app-fotos',
    # Disco externo (carpeta dedicada: el espejo borra en destino lo que ya no existe en origen).
    [string]$Destino,
    # Nombre de una sesion guardada de WinSCP para incluir las fotos del hosting FTP.
    [string]$WinScpSesion,
    [switch]$SoloVerificar,
    [switch]$SinVerificar,
    [switch]$SinProgreso
)

$ErrorActionPreference = 'Stop'
$BaseDirectory = $PSScriptRoot
$ConfigFile = Join-Path $BaseDirectory 'proyectos-produccion.txt'
$RememberFile = Join-Path $BaseDirectory 'copia-externa.ultimo-destino.txt'
$ResultFile = Join-Path $BaseDirectory 'copia-externa.ultimo-resultado.json'
$DefaultDestination = 'D:\BackupsMonzon'
$Started = Get-Date

function Get-ProjectRoots {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "No existe $ConfigFile" }
    $sections = @(); $id = $null; $values = @{}
    foreach ($raw in Get-Content -LiteralPath $ConfigFile -Encoding UTF8) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') {
            if ($id) { $sections += [pscustomobject]@{ Id = $id; Values = $values } }
            $id = $Matches[1]; $values = @{}; continue
        }
        if ($id -and $line -match '^([^=]+)=(.*)$') { $values[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() }
    }
    if ($id) { $sections += [pscustomobject]@{ Id = $id; Values = $values } }
    foreach ($section in $sections) {
        $v = $section.Values
        if (-not $v.ContainsKey('ruta')) { continue }
        $active = if ($v.ContainsKey('activo')) { $v['activo'].ToLowerInvariant() } else { 'si' }
        if ($active -in @('no', 'false', '0')) { continue }
        [pscustomobject]@{ Id = $section.Id; Root = $v['ruta'].Trim([char[]]@('"', "'")) }
    }
}

function Publish-Step([int]$Step, [string]$Phase, [string]$Detail) {
    if (-not $env:DOCKER_UPDATER_PROGRESS_FILE) { return }
    try {
        $json = [ordered]@{ phase = $Phase; step = $Step; steps = 6; detail = $Detail; project = $Proyecto
            phaseStartedAt = (Get-Date).ToString('o'); updatedAt = (Get-Date).ToString('o'); bytesProcessed = 0; bytesTotal = 0; lastMessage = $Detail } | ConvertTo-Json -Depth 3
        $temporary = "$($env:DOCKER_UPDATER_PROGRESS_FILE).tmp"
        Set-Content -LiteralPath $temporary -Value $json -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $env:DOCKER_UPDATER_PROGRESS_FILE -Force
    } catch { }
}

function Save-Result([bool]$Success, [string]$Message) {
    try {
        [ordered]@{ project = $Proyecto; destination = $Destino; success = $Success; message = $Message
            finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); kind = $(if ($SoloVerificar) { 'verify' } else { 'backup' })
            seconds = [int]((Get-Date) - $Started).TotalSeconds } | ConvertTo-Json | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    } catch { }
}

function Find-BackupScripts {
    # 1) los del propio repositorio del gestor (carpeta copias)  2) los antiguos, dentro del proyecto
    $own = Join-Path $BaseDirectory 'copias'
    if ((Test-Path -LiteralPath (Join-Path $own 'backup-completo.ps1') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $own 'verificar-backup.ps1') -PathType Leaf)) {
        return [pscustomobject]@{ Backup = (Join-Path $own 'backup-completo.ps1'); Verify = (Join-Path $own 'verificar-backup.ps1'); Where = 'copias' }
    }
    throw "Faltan copias\backup-completo.ps1 y copias\verificar-backup.ps1 en $BaseDirectory. Actualiza el gestor con git pull (repositorio DockerGUI)."
}

try {
    if ($Proyecto -cnotmatch '^[a-z0-9][a-z0-9_.-]*$') { throw "Nombre de proyecto no valido: '$Proyecto'." }
    $project = @(Get-ProjectRoots | Where-Object { $_.Id -eq $Proyecto }) | Select-Object -First 1
    if (-not $project) { throw "El proyecto '$Proyecto' no esta activo en proyectos-produccion.txt." }
    if (-not (Test-Path -LiteralPath $project.Root -PathType Container)) { throw "No existe la carpeta del proyecto: $($project.Root)" }
    $scripts = Find-BackupScripts
    Write-Host "Proyecto: $Proyecto  ($($project.Root))"
    Write-Host "Scripts de copia: $($scripts.Backup)"

    if (-not $Destino) {
        if ($env:DOCKER_UPDATER_PROGRESS_FILE) { throw 'Falta la carpeta del disco externo (Destino).' }
        $remembered = if (Test-Path -LiteralPath $RememberFile -PathType Leaf) { (Get-Content -LiteralPath $RememberFile -Encoding UTF8 | Select-Object -First 1).Trim() } else { '' }
        $proposal = if ($remembered) { $remembered } else { $DefaultDestination }
        $answer = Read-Host "Carpeta del disco externo [$proposal]"
        $Destino = if ($answer.Trim()) { $answer.Trim().Trim('"') } else { $proposal }
    }
    $Destino = $Destino.Trim().Trim('"').TrimEnd('\')
    $drive = Split-Path $Destino -Qualifier
    if (-not $drive -or -not (Test-Path -LiteralPath $drive)) {
        throw "El disco externo ($drive) no esta conectado. No se ha hecho ninguna copia."
    }

    $exitCode = 0
    if (-not $SoloVerificar) {
        Write-Host "`n=== COPIA a $Destino ===" -ForegroundColor Cyan
        Publish-Step 0 'Preparando' 'Comprobando el disco'
        $backupArguments = @{ Destino = $Destino; Gestor = $BaseDirectory; RutaProyecto = $project.Root; Proyecto = $Proyecto }
        if ($WinScpSesion) { $backupArguments.WinScpSesion = $WinScpSesion }
        if ($SinProgreso -or $env:DOCKER_UPDATER_PROGRESS_FILE) { $backupArguments.SinProgreso = $true }
        & $scripts.Backup @backupArguments
        if ($LASTEXITCODE -ne 0) { $exitCode = 1; Write-Host "`nLa copia termino con problemas." -ForegroundColor Red }
        else { Set-Content -LiteralPath $RememberFile -Value $Destino -Encoding UTF8 }
    }

    if (-not $SinVerificar) {
        Write-Host "`n=== VERIFICACION ===" -ForegroundColor Cyan
        Publish-Step 6 'Verificando la copia' 'Leyendo el volcado, el ZIP y los ficheros imprescindibles'
        & $scripts.Verify -Destino $Destino -Proyecto $Proyecto
        if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
    }

    if ($exitCode -eq 0) {
        Write-Host "`nCopia externa terminada y verificada." -ForegroundColor Green
        Write-Host "Para restaurar: Restaurar-Copia.ps1 (tambien dentro de la copia: <equipo>\gestor\Restaurar-Copia.ps1)."
        Save-Result $true 'Copia verificada'
    }
    else {
        Write-Host "`nHAY PROBLEMAS: la copia no es fiable hasta corregirlos (mira los FALLO de arriba)." -ForegroundColor Red
        Save-Result $false 'Terminada con problemas'
    }
    exit $exitCode
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    Save-Result $false $_.Exception.Message
    exit 1
}
