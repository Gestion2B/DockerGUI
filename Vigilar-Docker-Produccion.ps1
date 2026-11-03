#requires -Version 5.1
<#
.SYNOPSIS
  Vigila exclusivamente los proyectos de produccion configurados en el TXT.

.DESCRIPTION
  Cada comprobacion ejecuta docker compose up -d para cada proyecto activo.
  Esto no reinicia los contenedores sanos: Docker Compose solo arranca los que
  falten o hayan quedado detenidos. No lee pruebas ni old.
#>
[CmdletBinding()]
param(
    [ValidateSet('RunOnce','Watch','Install','Uninstall','Status')]
    [string]$Action = 'RunOnce',
    [ValidateRange(1,60)]
    [int]$IntervalMinutes = 5
)

$ErrorActionPreference = 'Stop'
$BaseDirectory = $PSScriptRoot
$ConfigFile = Join-Path $BaseDirectory 'proyectos-produccion.txt'
$StarterFile = Join-Path $BaseDirectory 'Iniciar-Docker-Produccion-Completo.ps1'
$TaskName = 'Vigilar Docker de produccion'
$LogDirectory = Join-Path $env:LOCALAPPDATA 'DockerProductionStartup'
$LogFile = Join-Path $LogDirectory 'monitor.log'

function Write-MonitorLog([string]$Message, [string]$Level = 'INFO') {
    if (-not (Test-Path -LiteralPath $LogDirectory)) { New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value $line
    Write-Host $line
}

function Read-ProductionProjects {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "No existe $ConfigFile" }
    $items=@(); $section=$null; $values=@{}
    foreach ($raw in Get-Content -LiteralPath $ConfigFile -Encoding UTF8) {
        $line=$raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') {
            if ($section) { $items += [pscustomobject]@{ Id=$section; Values=$values } }
            $section=$Matches[1]; $values=@{}; continue
        }
        if ($section -and $line -match '^([^=]+)=(.*)$') { $values[$Matches[1].Trim().ToLowerInvariant()]=$Matches[2].Trim() }
    }
    if ($section) { $items += [pscustomobject]@{ Id=$section; Values=$values } }

    $projects=@()
    foreach ($item in $items) {
        $v=$item.Values; $active=if($v.ContainsKey('activo')){$v['activo'].ToLowerInvariant()}else{'si'}
        if ($active -in @('no','false','0')) { continue }
        if (-not $v.ContainsKey('ruta') -or [string]::IsNullOrWhiteSpace($v['ruta'])) { throw "Falta Ruta en [$($item.Id)]" }
        $root=$v['ruta'].Trim().Trim('"').Trim("'")
        $files=if($v.ContainsKey('compose') -and $v['compose']){@($v['compose'] -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_})}else{@('compose.yml')}
        $profiles=if($v.ContainsKey('perfiles') -and $v['perfiles']){@($v['perfiles'] -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_})}else{@()}
        $projects += [pscustomobject]@{ Id=$item.Id; Name=if($v.ContainsKey('nombre')){$v['nombre']}else{$item.Id}; Path=(Join-Path $root 'produccion'); ComposeFiles=$files; Profiles=$profiles }
    }
    if (-not $projects) { throw 'No hay proyectos activos configurados.' }
    return $projects
}

function Test-DockerReady {
    try { & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Ensure-Production {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'No se encuentra docker.exe.' }
    if (-not (Test-DockerReady)) {
        if (-not (Test-Path -LiteralPath $StarterFile -PathType Leaf)) { throw 'Docker no esta disponible y no existe el script de autoarranque.' }
        Write-MonitorLog 'Docker no responde; se delega el arranque al script de produccion.' 'WARN'
        & $StarterFile -Action Run
        if ($LASTEXITCODE -ne 0) { throw "El autoarranque de produccion termino con codigo $LASTEXITCODE." }
        return
    }

    foreach ($project in @(Read-ProductionProjects)) {
        try {
            if (-not (Test-Path -LiteralPath $project.Path -PathType Container)) { throw "No existe $($project.Path)" }
            $arguments=@('compose','--project-name',$project.Id)
            foreach ($compose in $project.ComposeFiles) {
                $composePath=Join-Path $project.Path $compose
                if (-not (Test-Path -LiteralPath $composePath -PathType Leaf)) { throw "No existe $composePath" }
                $arguments += @('--file',$composePath)
            }
            foreach ($profile in $project.Profiles) { $arguments += @('--profile',$profile) }
            $arguments += @('up','--detach')
            & docker @arguments | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "docker compose termino con codigo $LASTEXITCODE" }
            Write-MonitorLog "Comprobado: '$($project.Name)'."
        }
        catch { Write-MonitorLog "'$($project.Name)': $($_.Exception.Message)" 'ERROR' }
    }
}

function Install-WatchTask {
    $scriptPath=(Resolve-Path -LiteralPath $PSCommandPath).Path
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $taskAction=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Action Watch -IntervalMinutes $IntervalMinutes"
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay='PT30S'
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 365) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Settings $settings -Principal $principal -Description 'Comprueba y arranca exclusivamente Docker Compose de produccion.' -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Vigilante instalado: $TaskName (cada $IntervalMinutes minutos)" -ForegroundColor Green
}

try {
    switch ($Action) {
        'RunOnce' { Ensure-Production }
        'Watch' { Write-MonitorLog "Vigilante iniciado. Intervalo: $IntervalMinutes minutos."; while ($true) { try { Ensure-Production } catch { Write-MonitorLog $_.Exception.Message 'ERROR' }; Start-Sleep -Seconds ($IntervalMinutes*60) } }
        'Install' { Install-WatchTask }
        'Uninstall' { if(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false;Write-Host 'Vigilante eliminado.'}else{Write-Host 'El vigilante no estaba instalado.'} }
        'Status' { Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Select-Object TaskName,State; if(Test-Path -LiteralPath $LogFile){Get-Content -LiteralPath $LogFile -Tail 50} }
    }
}
catch { Write-MonitorLog $_.Exception.Message 'ERROR'; exit 1 }
