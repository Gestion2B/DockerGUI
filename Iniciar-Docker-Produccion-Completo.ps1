#requires -Version 5.1

<#
.SYNOPSIS
    Inicia todos los proyectos Docker Compose de produccion configurados.

.DESCRIPTION
    - Admite cualquier numero de proyectos independientes.
    - Admite uno o varios archivos Compose por proyecto.
    - Inicia Docker Desktop y espera a que el motor responda.
    - Configura las rutas publicas de Tailscale Funnel despues de Docker.
    - Puede instalar una tarea programada al iniciar sesion.

.EXAMPLE
    .\Iniciar-Docker-Produccion-Completo.ps1 -Action Run
    .\Iniciar-Docker-Produccion-Completo.ps1 -Action Status
    .\Iniciar-Docker-Produccion-Completo.ps1 -Action Install
    .\Iniciar-Docker-Produccion-Completo.ps1 -Action Uninstall
#>

[CmdletBinding()]
param(
    [ValidateSet('Run', 'Install', 'Uninstall', 'Status')]
    [string]$Action = 'Run',

    [ValidateRange(30, 1800)]
    [int]$DockerTimeoutSeconds = 300,

    [ValidateRange(15, 600)]
    [int]$TailscaleTimeoutSeconds = 120
)

# Configuracion unica situada junto al script.
$ConfigFile = Join-Path $PSScriptRoot 'proyectos-produccion.txt'
$TaskName = 'Arrancar Docker de produccion'
$LogDirectory = Join-Path $env:ProgramData 'DockerProductionStartup'
$LogFile = Join-Path $LogDirectory 'startup.log'
$MaximumLogSizeBytes = 5MB
# =================================================================

$ErrorActionPreference = 'Stop'

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    if ((Test-Path -LiteralPath $LogFile) -and
        (Get-Item -LiteralPath $LogFile).Length -ge $MaximumLogSizeBytes) {
        $previousLog = "$LogFile.1"
        Move-Item -LiteralPath $LogFile -Destination $previousLog -Force
    }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DockerReady {
    try {
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Wait-Docker {
    if (Test-DockerReady) {
        Write-Log 'Docker ya esta disponible.'
        return
    }

    $desktopCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Docker\Docker Desktop.exe')
    )
    $desktopPath = $desktopCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -First 1

    if (-not $desktopPath) {
        throw 'No se encontro Docker Desktop en las rutas habituales.'
    }

    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Write-Log 'Iniciando Docker Desktop...'
        Start-Process -FilePath $desktopPath | Out-Null
    }
    else {
        Write-Log 'Docker Desktop esta abierto; esperando al motor.'
    }

    $deadline = (Get-Date).AddSeconds($DockerTimeoutSeconds)
    do {
        Start-Sleep -Seconds 5
        if (Test-DockerReady) {
            Write-Log 'Docker esta listo.'
            return
        }
    } while ((Get-Date) -lt $deadline)

    throw "Docker no respondio tras $DockerTimeoutSeconds segundos."
}

function Get-TailscaleExecutable {
    $command = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe')
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Tailscale\tailscale.exe')
    }

    $executable = $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    if (-not $executable) {
        throw 'No se encuentra tailscale.exe. Instala Tailscale o anadelo al PATH.'
    }

    return $executable
}

function Wait-Tailscale {
    param(
        [Parameter(Mandatory)] [string]$Executable
    )

    $deadline = (Get-Date).AddSeconds($TailscaleTimeoutSeconds)
    do {
        try {
            $statusJson = (& $Executable status --json 2>$null | Out-String)
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($statusJson)) {
                $status = $statusJson | ConvertFrom-Json
                if ($status.BackendState -eq 'Running') {
                    Write-Log 'Tailscale esta conectado.'
                    return
                }
            }
        }
        catch {
            # Durante el arranque, el servicio puede tardar unos segundos.
        }

        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    throw "Tailscale no se conecto tras $TailscaleTimeoutSeconds segundos. Abre Tailscale y comprueba que la sesion siga iniciada."
}

function Read-TailscaleFunnels {
    $routes = @()
    $seen = @{}
    foreach ($project in @(Read-ProductionProjects)) {
        foreach ($entry in @(($project.Funnel -split ',') | Where-Object { $_.Trim() })) {
            if ($entry.Trim() -notmatch '^(/[a-zA-Z0-9/_-]*)\s*=\s*(?:http://)?(localhost|127\.0\.0\.1):([0-9]{1,5})$') {
                throw "Funnel incorrecto en '$($project.Name)'. Usa /ruta=localhost:puerto"
            }
            $path = $Matches[1]
            $port = [int]$Matches[3]
            if ($port -lt 1 -or $port -gt 65535 -or $seen.ContainsKey($path)) {
                throw "Puerto incorrecto o ruta Funnel repetida: $path"
            }
            $seen[$path] = $true
            $routes += [pscustomobject]@{ Path = $path; Target = "localhost:$port" }
        }
    }
    return $routes
}

function Show-TailscaleFunnelStatus {
    param(
        [Parameter(Mandatory)] [string]$Executable,
        [switch]$WriteToLog
    )

    $statusLines = @(& $Executable funnel status)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "tailscale funnel status termino con codigo $exitCode."
    }

    foreach ($statusLine in $statusLines) {
        if (-not [string]::IsNullOrWhiteSpace($statusLine)) {
            if ($WriteToLog) {
                Write-Log "Funnel: $statusLine"
            }
            else {
                Write-Host $statusLine
            }
        }
    }
}

function Start-TailscaleFunnels {
    $routes = @(Read-TailscaleFunnels)
    if ($routes.Count -eq 0) { Write-Log 'No hay rutas Funnel configuradas.'; return }
    $tailscale = Get-TailscaleExecutable
    Wait-Tailscale -Executable $tailscale

    foreach ($route in $routes) {
        Write-Log "Configurando Tailscale Funnel $($route.Path) -> $($route.Target)..."

        # --bg guarda la configuracion en segundo plano y --yes evita preguntas.
        # No se usa 'funnel reset' para conservar cualquier otra ruta existente.
        & $tailscale funnel --bg --yes --set-path $route.Path $route.Target
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "Tailscale Funnel $($route.Path) termino con codigo $exitCode."
        }

        Write-Log "Tailscale Funnel $($route.Path) esta configurado."
    }

    Show-TailscaleFunnelStatus -Executable $tailscale -WriteToLog
}

function Read-ProductionProjects {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
        throw "No existe el archivo de configuracion: $ConfigFile"
    }

    $projects = @()
    $lineNumber = 0
    $currentSection = $null
    $currentSectionLine = 0
    $currentValues = @{}

    function Add-CurrentProject {
        param(
            [string]$Section,
            [hashtable]$Values,
            [int]$SectionLine
        )

        if ([string]::IsNullOrWhiteSpace($Section)) { return $null }

        $activeValue = 'si'
        if ($Values.ContainsKey('activo')) {
            $activeValue = $Values['activo'].Trim().ToLowerInvariant()
        }
        if ($activeValue -in @('no', 'false', '0')) { return $null }
        if ($activeValue -notin @('si', 'yes', 'true', '1')) {
            throw "Activo debe ser si o no en la seccion [$Section], linea $SectionLine."
        }

        if (-not $Values.ContainsKey('ruta') -or
            [string]::IsNullOrWhiteSpace($Values['ruta'])) {
            throw "Falta Ruta en la seccion [$Section], linea $SectionLine."
        }

        $displayName = $Section
        if ($Values.ContainsKey('nombre') -and
            -not [string]::IsNullOrWhiteSpace($Values['nombre'])) {
            $displayName = $Values['nombre'].Trim()
        }

        $rootPath = $Values['ruta'].Trim().Trim('"').Trim("'")
        $productionPath = Join-Path $rootPath 'produccion'

        $composeValue = 'compose.yml'
        if ($Values.ContainsKey('compose') -and
            -not [string]::IsNullOrWhiteSpace($Values['compose'])) {
            $composeValue = $Values['compose']
        }
        $composeFiles = @(($composeValue -split ',') |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        $profiles = @()
        if ($Values.ContainsKey('perfiles') -and
            -not [string]::IsNullOrWhiteSpace($Values['perfiles'])) {
            $profiles = @(($Values['perfiles'] -split ',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        return [pscustomobject]@{
            Name         = $displayName
            Funnel       = $Values['funnel']
            ProjectName  = $Section
            Path         = $productionPath
            ComposeFiles = $composeFiles
            Profiles     = $profiles
            SourceLine   = $SectionLine
        }
    }

    foreach ($rawLine in Get-Content -LiteralPath $ConfigFile -Encoding UTF8) {
        $lineNumber++
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or
            $line.StartsWith('#') -or $line.StartsWith(';')) {
            continue
        }

        if ($line -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') {
            if ($null -ne $currentSection) {
                $project = Add-CurrentProject -Section $currentSection `
                    -Values $currentValues -SectionLine $currentSectionLine
                if ($null -ne $project) { $projects += $project }
            }

            $currentSection = $Matches[1]
            $currentSectionLine = $lineNumber
            $currentValues = @{}
            continue
        }

        if ($null -eq $currentSection) {
            throw "Hay una propiedad fuera de una seccion en la linea $lineNumber."
        }

        if ($line -notmatch '^([^=]+)=(.*)$') {
            throw "Linea $lineNumber incorrecta. Usa Propiedad=Valor."
        }

        $key = $Matches[1].Trim().ToLowerInvariant()
        $value = $Matches[2].Trim()
        $allowedKeys = @('nombre', 'ruta', 'pruebas', 'compose', 'perfiles', 'activo', 'funnel', 'bd', 'bdservicio', 'bdnombre', 'bdusuario', 'bddetener')

        if ($key -notin $allowedKeys) {
            throw "Propiedad desconocida '$key' en la linea $lineNumber."
        }
        if ($currentValues.ContainsKey($key)) {
            throw "Propiedad repetida '$key' en la seccion [$currentSection]."
        }
        $currentValues[$key] = $value
    }

    if ($null -ne $currentSection) {
        $project = Add-CurrentProject -Section $currentSection `
            -Values $currentValues -SectionLine $currentSectionLine
        if ($null -ne $project) { $projects += $project }
    }

    if ($projects.Count -eq 0) {
        throw "No hay proyectos activos en $ConfigFile"
    }

    return $projects
}

function Test-ProductionConfiguration {
    param(
        [Parameter(Mandatory)] [object[]]$Projects
    )

    if (-not $Projects -or $Projects.Count -eq 0) {
        throw 'No hay proyectos de produccion configurados.'
    }

    $knownProjectNames = @{}
    foreach ($project in $Projects) {
        if ([string]::IsNullOrWhiteSpace($project.Name)) {
            throw 'Todos los proyectos necesitan Name.'
        }
        if ([string]::IsNullOrWhiteSpace($project.ProjectName)) {
            throw "El proyecto '$($project.Name)' necesita ProjectName."
        }
        if ($project.ProjectName -cnotmatch '^[a-z0-9][a-z0-9_.-]*$') {
            throw "ProjectName '$($project.ProjectName)' solo puede usar minusculas, numeros, guion, punto y guion bajo."
        }
        if ($knownProjectNames.ContainsKey($project.ProjectName)) {
            throw "ProjectName repetido: $($project.ProjectName)"
        }
        $knownProjectNames[$project.ProjectName] = $true

        if ([string]::IsNullOrWhiteSpace($project.Path) -or
            -not (Test-Path -LiteralPath $project.Path -PathType Container)) {
            throw "No existe la ruta de '$($project.Name)': $($project.Path)"
        }
        if (-not $project.ComposeFiles -or $project.ComposeFiles.Count -eq 0) {
            throw "El proyecto '$($project.Name)' necesita al menos un archivo en ComposeFiles."
        }
        foreach ($composeFile in $project.ComposeFiles) {
            $composePath = Join-Path $project.Path $composeFile
            if (-not (Test-Path -LiteralPath $composePath -PathType Leaf)) {
                throw "No existe el archivo Compose: $composePath"
            }
        }
    }
}

function Get-DockerComposeArguments {
    param(
        [Parameter(Mandatory)] $Project,
        [Parameter(Mandatory)] [string[]]$CommandArguments
    )

    $arguments = @('compose', '--project-name', $Project.ProjectName)

    foreach ($composeFile in $Project.ComposeFiles) {
        $arguments += '--file'
        $arguments += (Join-Path $Project.Path $composeFile)
    }

    foreach ($profile in @($Project.Profiles)) {
        if (-not [string]::IsNullOrWhiteSpace($profile)) {
            $arguments += '--profile'
            $arguments += $profile
        }
    }

    $arguments += $CommandArguments
    return $arguments
}

function Start-Production {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'No se encuentra docker.exe. Instala Docker Desktop o anade Docker al PATH.'
    }

    $projects = @(Read-ProductionProjects)
    Test-ProductionConfiguration -Projects $projects
    Wait-Docker
    $failures = 0

    foreach ($project in $projects) {
        try {
            Write-Log "Arrancando '$($project.Name)'..."
            $dockerArguments = Get-DockerComposeArguments `
                -Project $project `
                -CommandArguments @('up', '--detach')

            # Docker escribe progreso normal en stderr. No se usa 2>&1 para que
            # PowerShell 5.1 no convierta esos mensajes en excepciones.
            & docker @dockerArguments
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                throw "docker compose termino con codigo $exitCode."
            }
            Write-Log "'$($project.Name)' esta funcionando."
        }
        catch {
            $failures++
            Write-Log "'$($project.Name)': $($_.Exception.Message)" 'ERROR'
        }
    }

    if ($failures -gt 0) {
        throw "Fallaron $failures proyecto(s). Revisa $LogFile"
    }

    Write-Log 'Todos los proyectos de produccion estan arrancados. Configurando Tailscale Funnel...'
    Start-TailscaleFunnels
    Write-Log 'Autoarranque completado: Docker y Tailscale Funnel estan listos.'
}

function Show-Status {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'No se encuentra docker.exe.'
    }

    $projects = @(Read-ProductionProjects)
    Test-ProductionConfiguration -Projects $projects
    Wait-Docker

    foreach ($project in $projects) {
        Write-Host "`n--- $($project.Name) [$($project.ProjectName)] ---"
        $dockerArguments = Get-DockerComposeArguments `
            -Project $project `
            -CommandArguments @('ps')
        & docker @dockerArguments

        if ($LASTEXITCODE -ne 0) {
            Write-Log "No se pudo consultar '$($project.Name)'." 'ERROR'
        }
    }

    Write-Host "`n--- Tailscale Funnel ---"
    $tailscale = Get-TailscaleExecutable
    Wait-Tailscale -Executable $tailscale
    Show-TailscaleFunnelStatus -Executable $tailscale
}

function Install-Task {
    if (-not (Test-IsAdministrator)) {
        throw 'Ejecuta PowerShell como administrador para instalar la tarea.'
    }
    if (-not $PSCommandPath) {
        throw 'Guarda el script como archivo .ps1 antes de instalarlo.'
    }

    $projects = @(Read-ProductionProjects)
    Test-ProductionConfiguration -Projects $projects
    $scriptPath = (Resolve-Path -LiteralPath $PSCommandPath).Path
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    $taskAction = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Run"
    $taskTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $taskTrigger.Delay = 'PT20S'
    $taskSettings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    $taskPrincipal = New-ScheduledTaskPrincipal `
        -UserId $currentUser `
        -LogonType Interactive `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $taskAction `
        -Trigger $taskTrigger `
        -Settings $taskSettings `
        -Principal $taskPrincipal `
        -Description 'Arranca los proyectos Docker Compose de produccion y configura Tailscale Funnel.' `
        -Force | Out-Null

    Write-Host "Tarea instalada: $TaskName"
    Write-Host "Script registrado: $scriptPath"
}

function Uninstall-Task {
    if (-not (Test-IsAdministrator)) {
        throw 'Ejecuta PowerShell como administrador para eliminar la tarea.'
    }

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Tarea eliminada: $TaskName"
    }
    else {
        Write-Host 'La tarea no estaba instalada.'
    }
}

try {
    switch ($Action) {
        'Run'       { Start-Production }
        'Install'   { Install-Task }
        'Uninstall' { Uninstall-Task }
        'Status'    { Show-Status }
    }
}
catch {
    $errorMessage = $_.Exception.Message
    try {
        Write-Log $errorMessage 'ERROR'
    }
    catch {
        Write-Error $errorMessage
    }
    exit 1
}
