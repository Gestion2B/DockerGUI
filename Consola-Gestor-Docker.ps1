#requires -Version 5.1
<#
.SYNOPSIS
  Consola independiente para actualizar aplicaciones y gestionar copias Docker.

.DESCRIPTION
  No usa navegador, API local, cola ni trabajador de la GUI. Ejecuta las
  operaciones directamente mediante Actualizador-Proyectos.ps1 y muestra toda
  la salida en esta misma consola.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Status','BackupDatabase','BackupAllDatabases','VerifyBackup','VerifyAllBackups','Promote','Rollback','RestoreAll','List','Logs','ExternalBackup','ExternalRestore')]
    [string]$Action = 'Menu',
    [string]$Project,
    [string]$Backup,
    # Solo para ExternalBackup / ExternalRestore: carpeta del disco externo (si falta, se pregunta).
    [string]$Destino,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$BaseDirectory = $PSScriptRoot
$Updater = Join-Path $BaseDirectory 'Actualizador-Proyectos.ps1'
$ConfigFile = Join-Path $BaseDirectory 'proyectos-produccion.txt'
$LogFile = Join-Path $BaseDirectory 'actualizaciones.log'

function Write-Title([string]$Text) {
    Clear-Host
    Write-Host '============================================' -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host '  Modo directo: sin navegador ni GUI web' -ForegroundColor DarkGray
    Write-Host '============================================' -ForegroundColor Cyan
}

function Pause-Console { [void](Read-Host "`nPulsa Intro para continuar") }

function Get-Projects {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "No existe $ConfigFile" }
    $items = @(); $id = $null; $values = @{}
    foreach ($raw in Get-Content -LiteralPath $ConfigFile -Encoding UTF8) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') {
            if ($id) { $items += [pscustomobject]@{ Id=$id; Values=$values } }
            $id = $Matches[1]; $values = @{}; continue
        }
        if ($id -and $line -match '^([^=]+)=(.*)$') { $values[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() }
    }
    if ($id) { $items += [pscustomobject]@{ Id=$id; Values=$values } }
    foreach ($item in $items) {
        $v = $item.Values; $active = if ($v.ContainsKey('activo')) { $v['activo'].ToLowerInvariant() } else { 'si' }
        if ($active -in @('no','false','0') -or -not $v.ContainsKey('ruta')) { continue }
        [pscustomobject]@{
            Id = $item.Id
            Name = if ($v.ContainsKey('nombre') -and $v['nombre']) { $v['nombre'] } else { $item.Id }
            Root = $v['ruta'].Trim([char[]]@('"',"'"))
            Engine = if ($v.ContainsKey('bd')) { $v['bd'].ToLowerInvariant() } else { 'no' }
        }
    }
}

function Select-Project {
    $projects = @(Get-Projects)
    if (-not $projects) { throw 'No hay proyectos activos en proyectos-produccion.txt.' }
    Write-Host ''
    for ($i=0; $i -lt $projects.Count; $i++) { Write-Host ('  [{0}] {1} ({2})' -f ($i+1),$projects[$i].Name,$projects[$i].Id) }
    $choice = Read-Host 'Numero del proyecto'
    $number = 0
    if (-not [int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $projects.Count) { throw 'Seleccion incorrecta.' }
    return $projects[$number-1]
}

function Select-DatabaseBackup($SelectedProject) {
    $old = Join-Path $SelectedProject.Root 'old'
    $files = @(Get-ChildItem -LiteralPath $old -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.(postgres\.dump|mysql\.sql)$' } | Sort-Object Name -Descending)
    if (-not $files) { throw "No hay copias de base de datos en $old" }
    Write-Host ''
    for ($i=0; $i -lt $files.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i+1),$files[$i].Name) }
    $choice = Read-Host 'Numero de la copia'
    $number = 0
    if (-not [int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $files.Count) { throw 'Seleccion incorrecta.' }
    return $files[$number-1].Name
}

function Select-AppBackup($SelectedProject) {
    $old = Join-Path $SelectedProject.Root 'old'
    $folders = @(Get-ChildItem -LiteralPath $old -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if (-not $folders) { throw "No hay versiones de aplicacion en $old" }
    Write-Host ''
    for ($i=0; $i -lt $folders.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i+1),$folders[$i].Name) }
    $choice = Read-Host 'Numero de la version a restaurar'
    $number = 0
    if (-not [int]::TryParse($choice,[ref]$number) -or $number -lt 1 -or $number -gt $folders.Count) { throw 'Seleccion incorrecta.' }
    return $folders[$number-1].Name
}

function Confirm-Operation([string]$Word, [string]$Description) {
    if ($Force) { return }
    Write-Host "`n$Description" -ForegroundColor Yellow
    $answer = Read-Host "Escribe $Word para continuar"
    if ($answer -cne $Word) { throw 'Operacion cancelada.' }
}

function Invoke-Updater([string]$RequestedAction,[string]$RequestedProject,[string]$RequestedBackup,[switch]$BypassConfirmation) {
    if (-not (Test-Path -LiteralPath $Updater -PathType Leaf)) { throw "No existe $Updater" }
    # En PowerShell una lista de texto no interpreta '-Action' como parametro.
    # El splatting con hashtable si conserva nombre y valor correctamente.
    $updaterArguments = @{ Action = $RequestedAction }
    # El menu ya solicita una confirmacion explicita. En modo por parametros,
    # se conserva la confirmacion normal del actualizador salvo -Force.
    if ($Force -or $BypassConfirmation) { $updaterArguments.Force = $true }
    if ($RequestedProject) { $updaterArguments.Project = $RequestedProject }
    if ($RequestedBackup) { $updaterArguments.Backup = $RequestedBackup }
    Write-Host ''
    & $Updater @updaterArguments
    if ($LASTEXITCODE -ne 0) { throw "La operacion termino con codigo $LASTEXITCODE." }
}

function Show-Logs {
    if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Tail 120 }
    else { Write-Host 'No hay registro general todavia.' }
    $workerLog = Join-Path $BaseDirectory 'Gui-Docker\worker.log'
    if (Test-Path -LiteralPath $workerLog) { Write-Host "`n--- GUI: trabajador (ultimas 40 lineas) ---" -ForegroundColor Cyan; Get-Content -LiteralPath $workerLog -Tail 40 }
}

# Copia COMPLETA a un disco externo (carpetas de los proyectos, bases de todos, gestor) + verificacion.
# El trabajo lo hace Copia-Externa.ps1; no para ninguna aplicacion.
function Invoke-ExternalBackup([string]$Path, [string]$ProjectId) {
    $launcher = Join-Path $BaseDirectory 'Copia-Externa.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw "No existe $launcher" }
    $externalArguments = @{}
    if ($Path) { $externalArguments.Destino = $Path }
    if ($ProjectId) { $externalArguments.Proyecto = $ProjectId }
    Write-Host ''
    & $launcher @externalArguments
    if ($LASTEXITCODE -ne 0) { throw "La copia externa termino con codigo $LASTEXITCODE." }
}

# Restaurar un proyecto desde el disco externo (Restaurar-Copia.ps1): sin -Ejecutar solo ensena el plan.
function Invoke-ExternalRestore([string]$Path, [string]$ProjectId, [bool]$Execute) {
    $restorer = Join-Path $BaseDirectory 'Restaurar-Copia.ps1'
    if (-not (Test-Path -LiteralPath $restorer -PathType Leaf)) { throw "No existe $restorer" }
    $restoreArguments = @{}
    if ($Path) { $restoreArguments.Origen = $Path }
    if ($ProjectId) { $restoreArguments.Proyecto = $ProjectId }
    if ($Execute) { $restoreArguments.Ejecutar = $true }
    Write-Host ''
    & $restorer @restoreArguments
    if ($LASTEXITCODE -ne 0) { throw "La restauracion termino con codigo $LASTEXITCODE." }
}

function Invoke-Menu {
    while ($true) {
        Write-Title 'Gestor Docker por terminal'
        Write-Host '  [1] Ver estado de todos los proyectos'
        Write-Host '  [2] Crear copia de la base de UN proyecto'
        Write-Host '  [3] Crear copia de TODAS las bases'
        Write-Host '  [4] Verificar UNA copia de base'
        Write-Host '  [5] Verificar TODAS las copias'
        Write-Host '  [6] Actualizar un proyecto: pruebas -> produccion'
        Write-Host '  [7] Restaurar una version de aplicacion desde old'
        Write-Host '  [8] Restaurar la ultima version de old de todos'
        Write-Host '  [9] Ver registros'
        Write-Host '  [A] Copia COMPLETA de UN proyecto a disco externo (carpetas, base, uploads y verificacion)'
        Write-Host '  [B] Restaurar un proyecto desde el disco externo (primero muestra el plan)'
        Write-Host '  [0] Salir'
        $choice = Read-Host "`nSeleccion"
        try {
            switch ($choice) {
                '1' { Invoke-Updater 'Status' $null $null }
                '2' { $p=Select-Project; Confirm-Operation 'COPIAR' "Se copiara la base de $($p.Name)."; Invoke-Updater 'BackupDatabase' $p.Id $null -BypassConfirmation }
                '3' { Confirm-Operation 'COPIAR TODO' 'Se copiaran las bases de todos los proyectos configurados.'; Invoke-Updater 'BackupAllDatabases' $null $null -BypassConfirmation }
                '4' { $p=Select-Project; $b=Select-DatabaseBackup $p; Confirm-Operation 'VERIFICAR' "Se verificara $b."; Invoke-Updater 'VerifyBackup' $p.Id $b -BypassConfirmation }
                '5' { Confirm-Operation 'VERIFICAR TODO' 'Se verificaran todas las copias de bases.'; Invoke-Updater 'VerifyAllBackups' $null $null -BypassConfirmation }
                '6' { $p=Select-Project; Confirm-Operation 'ACTUALIZAR' "Se actualizara $($p.Name) con la carpeta pruebas."; Invoke-Updater 'Promote' $p.Id $null -BypassConfirmation }
                '7' { $p=Select-Project; $b=Select-AppBackup $p; Confirm-Operation 'RESTAURAR' "Se restaurara $b en $($p.Name)."; Invoke-Updater 'Rollback' $p.Id $b -BypassConfirmation }
                '8' { Confirm-Operation 'RESTAURAR TODO' 'Se restaurara la ultima version disponible de cada proyecto.'; Invoke-Updater 'RestoreAll' $null $null -BypassConfirmation }
                '9' { Show-Logs }
                'A' { $p=Select-Project; Confirm-Operation 'COPIAR' "Se copiaran la carpeta y la base de $($p.Name) (y el gestor) al disco externo, y se verificara."; Invoke-ExternalBackup $null $p.Id }
                'B' { $p=Select-Project; Invoke-ExternalRestore $null $p.Id $false; $go=Read-Host "`nEscribe EJECUTAR para restaurar de verdad (Intro para salir)"; if ($go -ceq 'EJECUTAR') { Invoke-ExternalRestore $null $p.Id $true } }
                '0' { return }
                default { throw 'Seleccion incorrecta.' }
            }
        }
        catch { Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red }
        Pause-Console
    }
}

try {
    if ($Action -eq 'Menu') { Invoke-Menu; exit 0 }
    if ($Action -eq 'Logs') { Show-Logs; exit 0 }
    if ($Action -eq 'ExternalBackup') {
        $externalProject = if ($Project) { $Project } else { 'app-fotos' }
        Confirm-Operation 'COPIAR' "Se copiaran la carpeta y la base de $externalProject (y el gestor) al disco externo, y se verificara."
        Invoke-ExternalBackup $Destino $externalProject
        exit 0
    }
    if ($Action -eq 'ExternalRestore') {
        # Sin -Force solo se muestra el plan; con -Force se restaura (Restaurar-Copia.ps1 pide ademas su propia confirmacion).
        Invoke-ExternalRestore $Destino $(if ($Project) { $Project } else { 'app-fotos' }) ([bool]$Force)
        exit 0
    }
    if ($Action -in @('BackupDatabase','VerifyBackup','Promote','Rollback','List') -and -not $Project) { throw 'Debes indicar -Project.' }
    if ($Action -in @('VerifyBackup','Rollback') -and -not $Backup) { throw 'Debes indicar -Backup.' }
    Invoke-Updater $Action $Project $Backup
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
