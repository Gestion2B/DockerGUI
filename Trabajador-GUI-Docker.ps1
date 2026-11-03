#requires -Version 5.1
# Trabajador local: no abre puertos ni atiende HTTP. La API Docker deja trabajos
# en gui-jobs y este proceso los ejecuta usando los scripts PowerShell existentes.

[CmdletBinding()]
param(
    [ValidateSet('Run', 'Status', 'Diagnose')]
    [string]$Action = 'Run'
)

$ErrorActionPreference = 'Stop'
$BaseDirectory = $PSScriptRoot
$ConfigFile = Join-Path $BaseDirectory 'proyectos-produccion.txt'
$RunnerFile = Join-Path $BaseDirectory 'Ejecutar-Operacion-GUI.ps1'
$JobsDirectory = Join-Path $BaseDirectory 'gui-jobs'
$BridgeDirectory = Join-Path $BaseDirectory 'gui-docker'
$HeartbeatFile = Join-Path $BridgeDirectory 'bridge.json'
$DashboardFile = Join-Path $BridgeDirectory 'dashboard.json'
$WorkerLogFile = Join-Path $BridgeDirectory 'worker.log'

function Write-WorkerLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        if (-not (Test-Path -LiteralPath $BridgeDirectory)) { New-Item -ItemType Directory -Path $BridgeDirectory -Force | Out-Null }
        Add-Content -LiteralPath $WorkerLogFile -Encoding UTF8 -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    }
    catch {}
}

function Write-JsonAtomic {
    param([string]$Path, [object]$Value)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-VersionOrNull {
    param([string]$Path)
    $version = Join-Path $Path 'VERSION.txt'
    if (-not (Test-Path -LiteralPath $version -PathType Leaf)) { return $null }
    $line = Get-Content -LiteralPath $version -Encoding UTF8 | Where-Object { $_.Trim() } | Select-Object -First 1
    if ($null -eq $line) { return $null }
    return $line.Trim()
}

function Read-BridgeProjects {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { throw "No existe $ConfigFile" }
    $items = @(); $section = $null; $values = @{}
    foreach ($raw in Get-Content -LiteralPath $ConfigFile -Encoding UTF8) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line -match '^\[([a-z0-9][a-z0-9_.-]*)\]$') {
            if ($section) { $items += [pscustomobject]@{ Id=$section; Values=$values } }
            $section=$Matches[1]; $values=@{}; continue
        }
        if ($section -and $line -match '^([^=]+)=(.*)$') { $values[$Matches[1].Trim().ToLowerInvariant()]=$Matches[2].Trim() }
    }
    if ($section) { $items += [pscustomobject]@{ Id=$section; Values=$values } }
    foreach ($item in $items) {
        $v=$item.Values; $active=if($v.ContainsKey('activo')){$v['activo'].ToLowerInvariant()}else{'si'}
        if ($active -in @('no','false','0')) { continue }
        if (-not $v.ContainsKey('ruta')) { continue }
        $compose=if($v.ContainsKey('compose') -and $v['compose']){@($v['compose'] -split ',' | ForEach-Object {$_.Trim()} | Where-Object {$_})}else{@('compose.yml')}
        $root=$v['ruta'].Trim([char[]]@('"', "'"))
        $testing=if($v.ContainsKey('pruebas') -and $v['pruebas']){$v['pruebas'].Trim([char[]]@('"', "'"))}else{Join-Path $root 'pruebas'}
        [pscustomobject]@{
            Id=$item.Id; Name=if($v.ContainsKey('nombre')){$v['nombre']}else{$item.Id}; Root=$root; TestingPath=$testing; TestingPathCustom=($v.ContainsKey('pruebas') -and [bool]$v['pruebas'])
            Compose=$compose; Engine=if($v.ContainsKey('bd')){$v['bd'].ToLowerInvariant()}else{'no'}
        }
    }
}

function Test-ProjectFiles { param($Project,[string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container) -or -not (Get-VersionOrNull $Path)) { return $false }
    foreach($compose in $Project.Compose) { if(-not (Test-Path -LiteralPath (Join-Path $Path $compose) -PathType Leaf)){return $false} }
    return $true
}

function Get-DatabaseBackups { param($Project)
    $old=Join-Path $Project.Root 'old'; if(-not(Test-Path -LiteralPath $old -PathType Container)){return @()}
    @(Get-ChildItem -LiteralPath $old -File -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '\.(postgres\.dump|mysql\.sql)$'} | Sort-Object Name -Descending | ForEach-Object {
        $report= "$($_.FullName).verify.json"; $status='unchecked'; $message='Pendiente de comprobar el archivo actual.'; $checked=$null
        if(Test-Path -LiteralPath $report){try{$r=Get-Content -LiteralPath $report -Raw -Encoding UTF8|ConvertFrom-Json;$status=if($r.Success){'verified'}else{'failed'};$message=$r.Message;$checked=$r.CheckedAt}catch{}}
        [pscustomobject]@{name=$_.Name;engine=if($_.Name -match '\.mysql\.sql$'){'mysql'}else{'postgres'};bytes=$_.Length;createdAt=$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss');status=$status;checkedAt=$checked;message=$message;canVerify=$true;restorationTested=$false}
    })
}

# Datos para la pestana "Copia a disco externo": ultimo disco usado, resultado de la ultima copia y proyectos que se pueden copiar.
function Get-ExternalBackupInfo {
    $last = Join-Path $BaseDirectory 'copia-externa.ultimo-destino.txt'; $result = Join-Path $BaseDirectory 'copia-externa.ultimo-resultado.json'
    $destination = ''; $lastResult = $null
    try { if (Test-Path -LiteralPath $last -PathType Leaf) { $destination = (Get-Content -LiteralPath $last -Encoding UTF8 | Select-Object -First 1).Trim() } } catch {}
    try { if (Test-Path -LiteralPath $result -PathType Leaf) { $lastResult = Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json } } catch {}
    # De momento solo app-fotos esta preparado para la copia externa (Pool no).
    [pscustomobject]@{ lastDestination=$destination; defaultDestination='D:\BackupsMonzon'; projects=@('app-fotos'); last=$lastResult }
}

function Update-Dashboard {
    $dockerReady=$false
    try { & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; $dockerReady=($LASTEXITCODE -eq 0) } catch {}
    $projects=@(foreach($project in Read-BridgeProjects){
        $production=Join-Path $project.Root 'produccion';$testing=$project.TestingPath;$old=Join-Path $project.Root 'old';$containers=@()
        if($dockerReady){try{$lines=@(& docker ps --filter "label=com.docker.compose.project=$($project.Id)" --format '{{.Names}}|{{.Status}}' 2>$null);if($LASTEXITCODE -eq 0){$containers=@($lines|Where-Object{$_}|ForEach-Object{$p=$_ -split '\|',2;[pscustomobject]@{name=$p[0];status=if($p.Count -gt 1){$p[1]}else{''}}})}}catch{}}
        $appBackups=@();if(Test-Path -LiteralPath $old -PathType Container){$appBackups=@(Get-ChildItem -LiteralPath $old -Directory -ErrorAction SilentlyContinue|Sort-Object Name -Descending|ForEach-Object{[pscustomobject]@{name=$_.Name;version=Get-VersionOrNull $_.FullName;modified=$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss');valid=(Test-ProjectFiles $project $_.FullName)}})}
        [pscustomobject]@{id=$project.Id;name=$project.Name;root=$project.Root;testingPath=$testing;testingPathCustom=$project.TestingPathCustom;productionVersion=Get-VersionOrNull $production;testingVersion=Get-VersionOrNull $testing;productionValid=(Test-ProjectFiles $project $production);promoteReady=(Test-ProjectFiles $project $testing);backups=$appBackups;databaseEngine=$project.Engine;databaseBackups=(Get-DatabaseBackups $project);containers=$containers}
    })
    Write-JsonAtomic $DashboardFile ([pscustomobject]@{generatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss');dockerReady=$dockerReady;projects=$projects;externalBackup=(Get-ExternalBackupInfo)})
}

function Write-Heartbeat {
    Write-JsonAtomic $HeartbeatFile ([pscustomobject]@{updatedAt=(Get-Date).ToString('o');worker='PowerShell';pid=$PID})
}

function Invoke-QueuedJob {
    param([IO.FileInfo]$QueueFile)
    $processing=$QueueFile.FullName -replace '\.queue\.json$','.processing.json'
    try { Move-Item -LiteralPath $QueueFile.FullName -Destination $processing -ErrorAction Stop } catch { return }
    try {
        $job=Get-Content -LiteralPath $processing -Raw -Encoding UTF8|ConvertFrom-Json
        if($job.action -notin @('Promote','Rollback','RestoreAll','BackupDatabase','BackupAllDatabases','VerifyBackup','VerifyAllBackups','ExternalBackup','ExternalVerify')){throw 'Accion de cola no valida.'}
        Write-WorkerLog "Trabajo recibido: $($job.id) | accion=$($job.action) | proyecto=$($job.project)"
        $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$RunnerFile,'-JobId',$job.id,'-Action',$job.action)
        if($job.action -notin @('RestoreAll','BackupAllDatabases','VerifyAllBackups')){$arguments+=@('-Project',$job.project)}
        if($job.action -in @('Rollback','VerifyBackup')){$arguments+=@('-Backup',$job.backup)}
        if($job.action -in @('ExternalBackup','ExternalVerify')){$arguments+=@('-Destination',$job.destination)}
        Write-WorkerLog "Iniciando PowerShell para el trabajo $($job.id)."
        & powershell.exe @arguments | Out-Null
        if($LASTEXITCODE -eq 0){Write-WorkerLog "Trabajo $($job.id) completado correctamente."}
        else{Write-WorkerLog "Trabajo $($job.id) termino con codigo $LASTEXITCODE." 'ERROR'}
    }
    catch { Write-WorkerLog "Trabajo de cola no procesado: $($_.Exception.Message)" 'ERROR' }
    finally { Remove-Item -LiteralPath $processing -Force -ErrorAction SilentlyContinue }
}

$mutex=$null
try {
    foreach($path in @($JobsDirectory,$BridgeDirectory)){if(-not(Test-Path -LiteralPath $path)){New-Item -ItemType Directory -Path $path -Force|Out-Null}}
    if($Action -eq 'Status') {
        [pscustomobject]@{ heartbeat=(Get-Content -LiteralPath $HeartbeatFile -Raw -ErrorAction SilentlyContinue); dashboard=(Get-Content -LiteralPath $DashboardFile -Raw -ErrorAction SilentlyContinue); log=(Get-Content -LiteralPath $WorkerLogFile -Tail 30 -ErrorAction SilentlyContinue) } | ConvertTo-Json -Depth 4
        exit
    }
    if($Action -eq 'Diagnose') {
        Update-Dashboard
        Get-Content -LiteralPath $DashboardFile -Raw -ErrorAction Stop
        exit
    }
    $mutex=New-Object -TypeName Threading.Mutex -ArgumentList @($false,'Local\DockerUpdaterGuiWorker')
    if(-not $mutex.WaitOne(0,$false)){Write-WorkerLog 'Ya hay un trabajador en ejecucion.';exit 0}
    Write-WorkerLog 'Trabajador iniciado.'
    $lastDashboard=[datetime]::MinValue
    $lastHeartbeat=[datetime]::MinValue
    while($true){
        if(((Get-Date)-$lastHeartbeat).TotalSeconds -ge 2){Write-Heartbeat;$lastHeartbeat=Get-Date}
        if(((Get-Date)-$lastDashboard).TotalSeconds -ge 4){try{Update-Dashboard}catch{Write-WorkerLog "No se pudo actualizar el panel: $($_.Exception.Message)" 'ERROR'};$lastDashboard=Get-Date}
        foreach($queue in @(Get-ChildItem -LiteralPath $JobsDirectory -Filter '*.queue.json' -File|Sort-Object CreationTime)){Invoke-QueuedJob $queue}
        Start-Sleep -Milliseconds 350
    }
}
catch {
    Write-WorkerLog "El trabajador se detuvo: $($_.Exception.Message)" 'ERROR'
    exit 1
}
finally {
    if($mutex){try{$mutex.ReleaseMutex()|Out-Null}catch{};$mutex.Dispose()}
}
