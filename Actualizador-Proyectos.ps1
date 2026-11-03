#requires -Version 5.1

<#
.SYNOPSIS
    Promueve pruebas a produccion y permite restaurar versiones desde old.

.DESCRIPTION
    Estructura esperada por proyecto:
      proyecto\produccion
      proyecto\pruebas
      proyecto\old\<fecha>__<version>

    VERSION.txt contiene la version de la aplicacion, por ejemplo 1.4.0.
    El script archiva produccion y mueve el contenido de pruebas a produccion,
    conservando la propia carpeta pruebas. Con BD=postgres o mysql crea un dump previo.
    No restaura automaticamente bases de datos ni copia otros volumenes.

.EXAMPLE
    .\Actualizador-Proyectos.ps1
    .\Actualizador-Proyectos.ps1 -Action Promote -Project fotos-produccion
    .\Actualizador-Proyectos.ps1 -Action Rollback -Project fotos-produccion
    .\Actualizador-Proyectos.ps1 -Action List -Project fotos-produccion
    .\Actualizador-Proyectos.ps1 -Action Promote -Project fotos-produccion -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Menu', 'Promote', 'Rollback', 'RestoreAll', 'List', 'Status', 'BackupDatabase', 'BackupAllDatabases', 'VerifyBackup', 'VerifyAllBackups')]
    [string]$Action = 'Menu',

    [string]$Project,

    [string]$Backup,

    [ValidateRange(10, 900)]
    [int]$StartupTimeoutSeconds = 120,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $PSScriptRoot 'proyectos-produccion.txt'
$LogFile = Join-Path $PSScriptRoot 'actualizaciones.log'
$script:LockTaken = $false
$script:UpdaterMutex = $null
. (Join-Path $PSScriptRoot 'Progreso-Operacion.ps1')
. (Join-Path $PSScriptRoot 'Copia-PostgreSQL.ps1')
. (Join-Path $PSScriptRoot 'Verificar-Copias.ps1')

function Write-DeployLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
    if ($script:OperationProgress) {
        $script:OperationProgress.lastMessage = $line
        Publish-OperationProgress
    }
}

function Enter-UpdaterLock {
    $script:UpdaterMutex = New-Object System.Threading.Mutex($false, 'Local\DockerProjectUpdater')
    $script:LockTaken = $script:UpdaterMutex.WaitOne(0)
    if (-not $script:LockTaken) {
        throw 'Ya hay otra actualizacion o restauracion en curso.'
    }
}

function Exit-UpdaterLock {
    if ($script:UpdaterMutex) {
        if ($script:LockTaken) { $script:UpdaterMutex.ReleaseMutex() }
        $script:UpdaterMutex.Dispose()
    }
}

function Convert-SectionToProject {
    param(
        [string]$Section,
        [hashtable]$Values,
        [int]$Line
    )

    if (-not $Section) { return $null }

    $active = 'si'
    if ($Values.ContainsKey('activo')) {
        $active = $Values['activo'].Trim().ToLowerInvariant()
    }
    if ($active -in @('no', 'false', '0')) { return $null }
    if ($active -notin @('si', 'yes', 'true', '1')) {
        throw "Activo debe ser si o no en [$Section], linea $Line."
    }
    if (-not $Values.ContainsKey('ruta') -or
        [string]::IsNullOrWhiteSpace($Values['ruta'])) {
        throw "Falta Ruta en [$Section], linea $Line."
    }

    $displayName = $Section
    if ($Values.ContainsKey('nombre') -and $Values['nombre'].Trim()) {
        $displayName = $Values['nombre'].Trim()
    }

    $composeValue = 'compose.yml'
    if ($Values.ContainsKey('compose') -and $Values['compose'].Trim()) {
        $composeValue = $Values['compose']
    }
    $composeFiles = @(($composeValue -split ',') |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ })

    $profiles = @()
    if ($Values.ContainsKey('perfiles') -and $Values['perfiles'].Trim()) {
        $profiles = @(($Values['perfiles'] -split ',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ })
    }

    return [pscustomobject]@{
        ProjectName  = $Section
        Name         = $displayName
        RootPath     = $Values['ruta'].Trim().Trim('"').Trim("'")
        TestingPath  = if ($Values.ContainsKey('pruebas') -and $Values['pruebas'].Trim()) { $Values['pruebas'].Trim().Trim('"').Trim("'") } else { Join-Path $Values['ruta'].Trim().Trim('"').Trim("'") 'pruebas' }
        Database     = $Values
        ComposeFiles = $composeFiles
        Profiles     = $profiles
    }
}

function Read-Projects {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        throw "No existe $ConfigFile"
    }

    $projects = @()
    $section = $null
    $sectionLine = 0
    $values = @{}
    $lineNumber = 0

    foreach ($rawLine in Get-Content -LiteralPath $ConfigFile -Encoding UTF8) {
        $lineNumber++
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }

        if ($line -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') {
            if ($section) {
                $parsed = Convert-SectionToProject $section $values $sectionLine
                if ($null -ne $parsed) { $projects += $parsed }
            }
            $section = $Matches[1]
            $sectionLine = $lineNumber
            $values = @{}
            continue
        }

        if (-not $section) { throw "Propiedad fuera de una seccion en la linea $lineNumber." }
        if ($line -notmatch '^([^=]+)=(.*)$') { throw "Linea $lineNumber incorrecta." }

        $key = $Matches[1].Trim().ToLowerInvariant()
        $value = $Matches[2].Trim()
        if ($key -notin @('nombre', 'ruta', 'pruebas', 'compose', 'perfiles', 'activo', 'funnel', 'bd', 'bdservicio', 'bdnombre', 'bdusuario', 'bddetener')) {
            throw "Propiedad desconocida '$key' en la linea $lineNumber."
        }
        if ($values.ContainsKey($key)) { throw "Propiedad repetida '$key' en [$section]." }
        $values[$key] = $value
    }

    if ($section) {
        $parsed = Convert-SectionToProject $section $values $sectionLine
        if ($null -ne $parsed) { $projects += $parsed }
    }
    if ($projects.Count -eq 0) { throw 'No hay proyectos activos en el TXT.' }
    return $projects
}

function Find-Project {
    param([object[]]$Projects, [string]$ProjectName)
    $matches = @($Projects | Where-Object { $_.ProjectName -eq $ProjectName })
    if ($matches.Count -ne 1) {
        throw "No se encontro un proyecto activo llamado '$ProjectName'."
    }
    return $matches[0]
}

function Get-EnvironmentPath {
    param($SelectedProject, [string]$Environment)
    if ($Environment -eq 'pruebas') { return $SelectedProject.TestingPath }
    return Join-Path $SelectedProject.RootPath $Environment
}

function Move-DirectoryContents {
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "No existe la carpeta de origen $Source"
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        throw "No existe la carpeta de destino $Destination"
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force)) {
        Move-Item -LiteralPath $item.FullName -Destination $Destination
    }
}

function Get-VersionName {
    param([string]$Directory)
    $versionFile = Join-Path $Directory 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        throw "Falta VERSION.txt en $Directory"
    }
    $version = (Get-Content -LiteralPath $versionFile -Encoding UTF8 |
        Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
    if (-not $version) { throw "VERSION.txt esta vacio en $Directory" }
    return $version
}

function ConvertTo-SafeVersion {
    param([string]$Version)
    $safe = $Version -replace '[^a-zA-Z0-9._-]', '_'
    if (-not $safe) { return 'sin-version' }
    return $safe
}

function Get-ComposeArguments {
    param($SelectedProject, [string]$EnvironmentPath, [string[]]$Command)
    $arguments = @('compose', '--project-name', $SelectedProject.ProjectName)
    foreach ($file in $SelectedProject.ComposeFiles) {
        $arguments += '--file'
        $arguments += (Join-Path $EnvironmentPath $file)
    }
    foreach ($profile in @($SelectedProject.Profiles)) {
        if ($profile) {
            $arguments += '--profile'
            $arguments += $profile
        }
    }
    $arguments += $Command
    return $arguments
}

function Test-ComposeEnvironment {
    param($SelectedProject, [string]$EnvironmentPath)
    if (-not (Test-Path -LiteralPath $EnvironmentPath -PathType Container)) {
        throw "No existe la carpeta $EnvironmentPath"
    }
    foreach ($file in $SelectedProject.ComposeFiles) {
        $path = Join-Path $EnvironmentPath $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "No existe el archivo Compose $path"
        }
    }
    $arguments = Get-ComposeArguments $SelectedProject $EnvironmentPath @('config', '--quiet')
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw "La configuracion Compose no es valida en $EnvironmentPath" }
}

function Stop-Environment {
    param($SelectedProject, [string]$EnvironmentPath)
    $arguments = Get-ComposeArguments $SelectedProject $EnvironmentPath @('down')
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo detener la produccion actual.' }
}

function Start-Environment {
    param($SelectedProject, [string]$EnvironmentPath)
    Set-OperationStage -Phase 'Arrancando aplicacion' -Detail 'Esperando a que los servicios esten disponibles.' -ProjectName $SelectedProject.Name
    $arguments = Get-ComposeArguments $SelectedProject $EnvironmentPath @('up', '--detach')
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo arrancar la produccion.' }
    Wait-EnvironmentReady $SelectedProject $EnvironmentPath
}

function Wait-EnvironmentReady {
    param($SelectedProject, [string]$EnvironmentPath)
    $serviceArguments = Get-ComposeArguments $SelectedProject $EnvironmentPath @('config', '--services')
    $services = @(& docker @serviceArguments | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0 -or $services.Count -eq 0) {
        throw 'No se pudieron determinar los servicios esperados.'
    }

    $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
    do {
        $allReady = $true
        foreach ($service in $services) {
            $idArguments = Get-ComposeArguments $SelectedProject $EnvironmentPath @('ps', '--all', '--quiet', $service)
            $ids = @(& docker @idArguments | Where-Object { $_ })
            if ($ids.Count -eq 0) { $allReady = $false; continue }

            foreach ($id in $ids) {
                $state = (& docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $id).Trim()
                if ($LASTEXITCODE -ne 0) { $allReady = $false; continue }
                if ($state -eq 'unhealthy' -or $state -eq 'exited' -or $state -eq 'dead') {
                    throw "El servicio '$service' termino con estado '$state'."
                }
                if ($state -notin @('healthy', 'running')) { $allReady = $false }
            }
        }
        if ($allReady) { return }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "Los servicios no estuvieron listos tras $StartupTimeoutSeconds segundos."
}

function Get-NewBackupPath {
    param($SelectedProject, [string]$Version)
    $oldPath = Get-EnvironmentPath $SelectedProject 'old'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeVersion = ConvertTo-SafeVersion $Version
    $candidate = Join-Path $oldPath "${stamp}__${safeVersion}"
    if (Test-Path -LiteralPath $candidate) {
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $candidate = "${candidate}__${suffix}"
    }
    return $candidate
}

function Confirm-Operation {
    param([string]$Prompt, [string]$RequiredText)
    if ($Force) { return }
    $answer = Read-Host "$Prompt Escribe $RequiredText para continuar"
    if ($answer -cne $RequiredText) { throw 'Operacion cancelada por el usuario.' }
}

function Invoke-Promote {
    param($SelectedProject)
    $production = Get-EnvironmentPath $SelectedProject 'produccion'
    $testing = Get-EnvironmentPath $SelectedProject 'pruebas'

    Test-ComposeEnvironment $SelectedProject $production
    Test-ComposeEnvironment $SelectedProject $testing
    $oldVersion = Get-VersionName $production
    $newVersion = Get-VersionName $testing
    $backupPath = Get-NewBackupPath $SelectedProject $oldVersion

    Write-Host "`nProyecto:          $($SelectedProject.Name)"
    Write-Host "Version actual:    $oldVersion"
    Write-Host "Version nueva:     $newVersion"
    Write-Host "Respaldo anterior: $backupPath`n"

    if (-not $PSCmdlet.ShouldProcess($SelectedProject.Name, "Promover $newVersion a produccion")) { return }
    Confirm-Operation 'Se detendra produccion y se movera el contenido de pruebas.' 'ACTUALIZAR'

    Write-DeployLog "Actualizando $($SelectedProject.ProjectName): $oldVersion -> $newVersion"
    $oldRoot = Split-Path -Parent $backupPath
    if (-not (Test-Path -LiteralPath $oldRoot)) {
        New-Item -ItemType Directory -Path $oldRoot -Force | Out-Null
    }
    Stop-WithDatabaseBackup $SelectedProject $production $backupPath

    try {
        Move-Item -LiteralPath $production -Destination $backupPath
        New-Item -ItemType Directory -Path $production -Force | Out-Null
        Move-DirectoryContents -Source $testing -Destination $production
        Start-Environment $SelectedProject $production

        $info = @(
            "Proyecto=$($SelectedProject.ProjectName)"
            "Version=$oldVersion"
            "Archivado=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "SustituidoPor=$newVersion"
        )
        Set-Content -LiteralPath "${backupPath}.info.txt" -Value $info -Encoding UTF8
        Write-DeployLog "Actualizacion completada. Produccion=$newVersion; respaldo=$backupPath"
    }
    catch {
        $failure = $_.Exception.Message
        Write-DeployLog "Fallo la nueva version: $failure. Restaurando $oldVersion..." 'ERROR'

        if ((Test-Path -LiteralPath $backupPath) -and (Test-Path -LiteralPath $production)) {
            try { Stop-Environment $SelectedProject $production } catch {}
            Move-DirectoryContents -Source $production -Destination $testing
            if (@(Get-ChildItem -LiteralPath $production -Force).Count -eq 0) {
                Remove-Item -LiteralPath $production -Force
            }
        }
        if (Test-Path -LiteralPath $backupPath) {
            Move-Item -LiteralPath $backupPath -Destination $production
        }
        Start-Environment $SelectedProject $production
        Write-DeployLog "Se restauro automaticamente $oldVersion." 'WARN'
        throw "La actualizacion fallo y se restauro la version anterior. Motivo: $failure"
    }
}

function Get-Backups {
    param($SelectedProject)
    $oldPath = Get-EnvironmentPath $SelectedProject 'old'
    if (-not (Test-Path -LiteralPath $oldPath)) { return @() }
    return @(Get-ChildItem -LiteralPath $oldPath -Directory |
        Sort-Object Name -Descending)
}

function Show-Backups {
    param($SelectedProject)
    $backups = @(Get-Backups $SelectedProject)
    Write-Host "`nVersiones de $($SelectedProject.Name):"
    if ($backups.Count -eq 0) { Write-Host '  No hay versiones en old.'; return }
    for ($i = 0; $i -lt $backups.Count; $i++) {
        $version = try { Get-VersionName $backups[$i].FullName } catch { 'sin VERSION.txt' }
        Write-Host ("  [{0}] {1}  (version {2})" -f ($i + 1), $backups[$i].Name, $version)
    }
}

function Select-Backup {
    param($SelectedProject, [string]$RequestedBackup)
    $backups = @(Get-Backups $SelectedProject)
    if ($backups.Count -eq 0) { throw 'No hay versiones disponibles en old.' }

    if ($RequestedBackup) {
        $match = @($backups | Where-Object { $_.Name -eq $RequestedBackup })
        if ($match.Count -ne 1) { throw "No existe el respaldo '$RequestedBackup'." }
        return $match[0]
    }

    Show-Backups $SelectedProject
    $selection = Read-Host 'Numero de la version que quieres restaurar'
    $index = 0
    if (-not [int]::TryParse($selection, [ref]$index) -or
        $index -lt 1 -or $index -gt $backups.Count) {
        throw 'Seleccion de version incorrecta.'
    }
    return $backups[$index - 1]
}

function Invoke-Rollback {
    param($SelectedProject, [string]$RequestedBackup)
    $production = Get-EnvironmentPath $SelectedProject 'produccion'
    Test-ComposeEnvironment $SelectedProject $production
    $selectedBackup = Select-Backup $SelectedProject $RequestedBackup
    Test-ComposeEnvironment $SelectedProject $selectedBackup.FullName

    $currentVersion = Get-VersionName $production
    $targetVersion = Get-VersionName $selectedBackup.FullName
    $currentBackup = Get-NewBackupPath $SelectedProject $currentVersion
    $originalBackupPath = $selectedBackup.FullName

    Write-Host "`nProyecto:       $($SelectedProject.Name)"
    Write-Host "Version actual: $currentVersion"
    Write-Host "Restaurar:      $targetVersion"
    Write-Host "La version actual se guardara en: $currentBackup`n"

    if (-not $PSCmdlet.ShouldProcess($SelectedProject.Name, "Restaurar $targetVersion")) { return }
    Confirm-Operation 'Se detendra produccion y se intercambiaran las versiones.' 'RESTAURAR'

    Write-DeployLog "Restaurando $($SelectedProject.ProjectName): $currentVersion -> $targetVersion"
    $oldRoot = Split-Path -Parent $currentBackup
    if (-not (Test-Path -LiteralPath $oldRoot)) {
        New-Item -ItemType Directory -Path $oldRoot -Force | Out-Null
    }
    Stop-WithDatabaseBackup $SelectedProject $production $currentBackup

    try {
        Move-Item -LiteralPath $production -Destination $currentBackup
        Move-Item -LiteralPath $originalBackupPath -Destination $production
        Start-Environment $SelectedProject $production

        $info = @(
            "Proyecto=$($SelectedProject.ProjectName)"
            "Version=$currentVersion"
            "Archivado=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "Restaurado=$targetVersion"
        )
        Set-Content -LiteralPath "${currentBackup}.info.txt" -Value $info -Encoding UTF8
        Write-DeployLog "Restauracion completada. Produccion=$targetVersion; respaldo=$currentBackup"
    }
    catch {
        $failure = $_.Exception.Message
        Write-DeployLog "Fallo la restauracion: $failure. Recuperando $currentVersion..." 'ERROR'

        if ((Test-Path -LiteralPath $currentBackup) -and (Test-Path -LiteralPath $production)) {
            try { Stop-Environment $SelectedProject $production } catch {}
            Move-Item -LiteralPath $production -Destination $originalBackupPath
        }
        if (Test-Path -LiteralPath $currentBackup) {
            Move-Item -LiteralPath $currentBackup -Destination $production
        }
        Start-Environment $SelectedProject $production
        Write-DeployLog "Se recupero automaticamente $currentVersion." 'WARN'
        throw "La restauracion fallo y se recupero la version actual. Motivo: $failure"
    }
}

function Get-LatestValidBackup {
    param($SelectedProject)
    foreach ($candidate in @(Get-Backups $SelectedProject)) {
        try {
            Get-VersionName $candidate.FullName | Out-Null
            $allComposeFilesExist = $true
            foreach ($file in $SelectedProject.ComposeFiles) {
                if (-not (Test-Path -LiteralPath (Join-Path $candidate.FullName $file) -PathType Leaf)) {
                    $allComposeFilesExist = $false
                    break
                }
            }
            if ($allComposeFilesExist) { return $candidate }
        }
        catch {}
    }
    return $null
}

function Invoke-RestoreAllProjects {
    param([object[]]$Projects)
    $restored = 0
    $failed = 0
    $skipped = 0

    foreach ($item in $Projects) {
        $latest = Get-LatestValidBackup $item
        if ($null -eq $latest) {
            $skipped++
            Write-DeployLog "$($item.ProjectName): omitido, no hay copias validas en old." 'WARN'
            continue
        }

        try {
            Write-DeployLog "$($item.ProjectName): restaurando su copia mas reciente $($latest.Name)."
            Invoke-Rollback $item $latest.Name
            $restored++
        }
        catch {
            $failed++
            Write-DeployLog "$($item.ProjectName): no se pudo restaurar. $($_.Exception.Message)" 'ERROR'
        }
    }

    Write-DeployLog "Restauracion global terminada. Restaurados=$restored; fallidos=$failed; omitidos=$skipped."
    if ($restored -eq 0) { throw 'No se pudo restaurar ningun proyecto.' }
    if ($failed -gt 0) { throw "La restauracion global termino con $failed proyecto(s) fallido(s)." }
}

function Show-Status {
    param([object[]]$Projects)
    foreach ($item in $Projects) {
        $production = Get-EnvironmentPath $item 'produccion'
        $testing = Get-EnvironmentPath $item 'pruebas'
        $productionVersion = try { Get-VersionName $production } catch { 'no disponible' }
        $testingVersion = try { Get-VersionName $testing } catch { 'no disponible' }
        $backupCount = @(Get-Backups $item).Count

        Write-Host "`n[$($item.ProjectName)] $($item.Name)"
        Write-Host "  Produccion: $productionVersion"
        Write-Host "  Pruebas:    $testingVersion"
        Write-Host "  En old:     $backupCount version(es)"
    }
}

function Select-ProjectFromMenu {
    param([object[]]$Projects)
    Write-Host "`nProyectos disponibles:"
    for ($i = 0; $i -lt $Projects.Count; $i++) {
        Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $Projects[$i].Name, $Projects[$i].ProjectName)
    }
    $selection = Read-Host 'Numero del proyecto'
    $index = 0
    if (-not [int]::TryParse($selection, [ref]$index) -or
        $index -lt 1 -or $index -gt $Projects.Count) {
        throw 'Seleccion de proyecto incorrecta.'
    }
    return $Projects[$index - 1]
}

function Invoke-Menu {
    param([object[]]$Projects)
    Show-Status $Projects
    $selected = Select-ProjectFromMenu $Projects

    Write-Host "`n  [1] Actualizar: pruebas -> produccion"
    Write-Host '  [2] Restaurar una version de old'
    Write-Host '  [3] Listar versiones de old'
    Write-Host '  [4] Salir'
    $choice = Read-Host 'Seleccion'

    switch ($choice) {
        '1' { Invoke-Promote $selected }
        '2' { Invoke-Rollback $selected $null }
        '3' { Show-Backups $selected }
        '4' { return }
        default { throw 'Seleccion incorrecta.' }
    }
}

try {
    if ($Action -notin @('VerifyBackup', 'VerifyAllBackups')) {
    Set-OperationStage -Phase 'Comprobando Docker' -Detail 'Esperando respuesta del motor Docker.'
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'No se encuentra docker.exe. Inicia Docker Desktop.'
    }
    & docker info --format '{{.ServerVersion}}' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker no esta disponible.' }
    }

    Enter-UpdaterLock
    $allProjects = @(Read-Projects)

    switch ($Action) {
        'Menu'     { Invoke-Menu $allProjects }
        'Status'   { Show-Status $allProjects }
        'Promote'  { Invoke-Promote (Find-Project $allProjects $Project) }
        'Rollback' { Invoke-Rollback (Find-Project $allProjects $Project) $Backup }
        'RestoreAll' { Invoke-RestoreAllProjects $allProjects }
        'VerifyBackup' {
            $selected = Find-Project $allProjects $Project
            if ($PSCmdlet.ShouldProcess($Backup, 'Verificar integridad y guardar resultado')) {
                Test-DatabaseBackup $selected.RootPath $selected.ProjectName $Backup
            }
        }
        'VerifyAllBackups' {
            $failures = 0; $verified = 0
            foreach ($selected in $allProjects) {
                foreach ($file in @(Get-DatabaseBackupFiles $selected.RootPath | Where-Object { -not $_.Name.EndsWith('.partial') })) {
                    try {
                        if ($PSCmdlet.ShouldProcess($file.Name, 'Verificar integridad y guardar resultado')) {
                            Test-DatabaseBackup $selected.RootPath $selected.ProjectName $file.Name
                            $verified++
                        }
                    }
                    catch { $failures++; Write-DeployLog $_.Exception.Message 'ERROR' }
                }
            }
            Write-DeployLog "Verificacion terminada. Correctas=$verified; fallidas=$failures. Restauraciones no probadas."
            if ($failures -gt 0) { throw "Fallaron $failures verificaciones." }
        }
        'BackupAllDatabases' {
            $failures = 0; $created = 0
            foreach ($selected in $allProjects) {
                if (-not $selected.Database['bd'] -or $selected.Database['bd'] -eq 'no') { continue }
                try {
                    $production = Get-EnvironmentPath $selected 'produccion'
                    Test-ComposeEnvironment $selected $production
                    $path = Get-NewBackupPath $selected (Get-VersionName $production)
                    if ($PSCmdlet.ShouldProcess($selected.Name, 'Copiar base de datos pausando escritores')) {
                        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                        Stop-WithDatabaseBackup $selected $production $path -BackupOnly
                        $created++
                    }
                }
                catch { $failures++; Write-DeployLog "$($selected.Name): $($_.Exception.Message)" 'ERROR' }
            }
            Write-DeployLog "Copias terminadas. Creadas=$created; fallidas=$failures."
            if ($failures -gt 0) { throw "Fallaron $failures copias." }
        }
        'BackupDatabase' {
            $selected = Find-Project $allProjects $Project
            $production = Get-EnvironmentPath $selected 'produccion'
            Test-ComposeEnvironment $selected $production
            $path = Get-NewBackupPath $selected (Get-VersionName $production)
            if ($PSCmdlet.ShouldProcess($selected.Name, 'Copiar la base de datos pausando los escritores')) {
                $parent = Split-Path -Parent $path
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
                Stop-WithDatabaseBackup $selected $production $path -BackupOnly
            }
        }
        'List'     { Show-Backups (Find-Project $allProjects $Project) }
    }
}
catch {
    try { Write-DeployLog $_.Exception.Message 'ERROR' } catch { Write-Error $_.Exception.Message }
    exit 1
}
finally {
    Exit-UpdaterLock
}
