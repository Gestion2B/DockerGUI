#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-f0-9]{32}$')]
    [string]$JobId,

    [Parameter(Mandatory)]
    [ValidateSet('Promote', 'Rollback', 'RestoreAll', 'BackupDatabase', 'BackupAllDatabases', 'VerifyBackup', 'VerifyAllBackups', 'ExternalBackup', 'ExternalVerify')]
    [string]$Action,

    [string]$Project,
    [string]$Backup,
    # Solo ExternalBackup / ExternalVerify: carpeta del disco externo.
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
$UpdaterFile = Join-Path $PSScriptRoot 'Actualizador-Proyectos.ps1'
$ExternalFile = Join-Path $PSScriptRoot 'Copia-Externa.ps1'
$IsExternal = $Action -in @('ExternalBackup', 'ExternalVerify')
$JobDirectory = Join-Path $PSScriptRoot 'gui-jobs'
$ResultFile = Join-Path $JobDirectory "$JobId.result.json"
$TemporaryResult = "$ResultFile.tmp"
$OutputFile = Join-Path $JobDirectory "$JobId.output.log"
$StandardOutputFile = Join-Path $JobDirectory "$JobId.stdout.log"
$StandardErrorFile = Join-Path $JobDirectory "$JobId.stderr.log"
$exitCode = 1
$errorMessage = $null

function ConvertTo-CommandLineArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '([\\]*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

try {
    $ScriptToRun = if ($IsExternal) { $ExternalFile } else { $UpdaterFile }
    if (-not (Test-Path -LiteralPath $ScriptToRun -PathType Leaf)) {
        throw "No existe $ScriptToRun"
    }
    if (-not (Test-Path -LiteralPath $JobDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $JobDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $OutputFile -Encoding UTF8 -Value ('{0} [INFO] Trabajo recibido: {1} ({2})' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $JobId, $Action)
    # La variable solo se hereda por este proceso de actualizacion.
    $env:DOCKER_UPDATER_PROGRESS_FILE = Join-Path $JobDirectory "$JobId.progress.json"

    if ($IsExternal) {
        # Copia completa de UN proyecto al disco externo (o solo su verificacion). No usa el bloqueo del actualizador.
        if ($Destination -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)' -or $Destination -match '[\r\n"]') { throw 'La carpeta del disco externo no es una ruta absoluta de Windows valida.' }
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ExternalFile, '-Proyecto', $Project, '-Destino', $Destination)
        if ($Action -eq 'ExternalVerify') { $arguments += '-SoloVerificar' }
    }
    else {
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $UpdaterFile, '-Action', $Action, '-Force')
        if ($Action -notin @('RestoreAll', 'BackupAllDatabases', 'VerifyAllBackups')) { $arguments += @('-Project', $Project) }
        if ($Action -in @('Rollback', 'VerifyBackup')) { $arguments += @('-Backup', $Backup) }
    }

    # Start-Transcript puede conservar el archivo bloqueado mientras la GUI lo
    # consulta. Redirigimos la salida del proceso hijo a archivos separados:
    # PowerShell los cierra al terminar y luego se unen en output.log.
    Remove-Item -LiteralPath $OutputFile, $StandardOutputFile, $StandardErrorFile -Force -ErrorAction SilentlyContinue
    $childArguments = (($arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    Add-Content -LiteralPath $OutputFile -Encoding UTF8 -Value ('{0} [INFO] Iniciando proceso...' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $childArguments -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput $StandardOutputFile -RedirectStandardError $StandardErrorFile
    $exitCode = $child.ExitCode
    $child.Dispose()
    $lines = @()
    foreach ($path in @($StandardOutputFile, $StandardErrorFile)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $lines += @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)
        }
    }
    if ($lines.Count -gt 0) { Add-Content -LiteralPath $OutputFile -Value $lines -Encoding UTF8 }
    Add-Content -LiteralPath $OutputFile -Encoding UTF8 -Value ('{0} [INFO] Actualizador terminado con codigo {1}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $exitCode)
}
catch {
    $errorMessage = $_.Exception.Message
    $exitCode = 1
    try { Add-Content -LiteralPath $OutputFile -Encoding UTF8 -Value ('{0} [ERROR] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $errorMessage) } catch {}
}
finally {
    $result = [pscustomobject]@{
        jobId = $JobId
        success = ($exitCode -eq 0)
        exitCode = $exitCode
        error = $errorMessage
        finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $result | ConvertTo-Json -Compress | Set-Content -LiteralPath $TemporaryResult -Encoding UTF8
    Move-Item -LiteralPath $TemporaryResult -Destination $ResultFile -Force
}

exit $exitCode
