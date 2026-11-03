#requires -Version 5.1
# Libera trabajos abandonados sin repetir operaciones potencialmente destructivas.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$base = $PSScriptRoot
$jobs = Join-Path $base 'gui-jobs'
$bridge = Join-Path $base 'Gui-Docker'
$worker = Join-Path $base 'Trabajador-GUI-Docker.ps1'
$workerPattern = [regex]::Escape($worker)
$log = Join-Path $bridge 'worker.log'

function Write-RecoveryLog([string]$Message, [string]$Level = 'WARN') {
    if (-not (Test-Path -LiteralPath $bridge)) { New-Item -ItemType Directory -Path $bridge -Force | Out-Null }
    Add-Content -LiteralPath $log -Encoding UTF8 -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

if (-not (Test-Path -LiteralPath $jobs)) { New-Item -ItemType Directory -Path $jobs -Force | Out-Null }
$workers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $workerPattern })
$processing = @(Get-ChildItem -LiteralPath $jobs -Filter '*.processing.json' -File -ErrorAction SilentlyContinue)

Write-Host "Trabajadores activos: $($workers.Count)" -ForegroundColor Cyan
Write-Host "Trabajos marcados como ejecutando: $($processing.Count)" -ForegroundColor Cyan

if ($workers.Count -gt 0 -and $processing.Count -gt 0) {
    Write-Host 'Hay un trabajador activo con una operacion en curso. No se toca para evitar duplicarla.' -ForegroundColor Yellow
    Write-Host 'Abre el diagnostico y revisa el log antes de forzar una detencion.' -ForegroundColor Yellow
    exit 2
}

foreach ($entry in $processing) {
    $id = $entry.Name -replace '\.processing\.json$', ''
    $result = Join-Path $jobs "$id.result.json"
    if (-not (Test-Path -LiteralPath $result)) {
        $payload = [pscustomobject]@{
            jobId = $id; success = $false; exitCode = 1
            error = 'Trabajo liberado por recuperacion: no habia un trabajador local activo. La operacion NO se ha repetido automaticamente.'
            finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        $payload | ConvertTo-Json -Compress | Set-Content -LiteralPath $result -Encoding UTF8
        Write-RecoveryLog "Trabajo abandonado liberado: $id"
        Write-Host "Liberado: $id" -ForegroundColor Yellow
    }
    Remove-Item -LiteralPath $entry.FullName -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { throw "No existe $worker" }
& (Join-Path $base 'Reiniciar-Trabajador-GUI-Docker.ps1')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host 'Recuperacion terminada. Ahora puedes abrir el panel de nuevo.' -ForegroundColor Green
