#requires -Version 5.1
# Muestra toda la informacion necesaria para diagnosticar la GUI sin cerrar la consola.
[CmdletBinding()]
param()

$base = $PSScriptRoot
$jobs = Join-Path $base 'gui-jobs'
$bridge = Join-Path $base 'Gui-Docker'
$compose = Join-Path $bridge 'compose.yml'
$worker = Join-Path $base 'Trabajador-GUI-Docker.ps1'
$workerPattern = [regex]::Escape($worker)
function Section([string]$Title) { Write-Host "`n========== $Title ==========" -ForegroundColor Cyan }

Section 'Archivos requeridos'
@('proyectos-produccion.txt','Actualizador-Proyectos.ps1','Ejecutar-Operacion-GUI.ps1','Trabajador-GUI-Docker.ps1','Gui-Docker\compose.yml','Gui-Docker\server.js') |
    ForEach-Object { $path = Join-Path $base $_; Write-Host ("{0}: {1}" -f $_, (Test-Path -LiteralPath $path)) }

Section 'Docker'
try { & docker info --format 'Docker: {{.ServerVersion}}'; if ($LASTEXITCODE -ne 0) { throw 'docker info devolvio error' } } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
if (Test-Path -LiteralPath $compose) { & docker compose -f $compose ps; & docker compose -f $compose logs --tail 100 }

Section 'Trabajador PowerShell'
$workers = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -match $workerPattern })
if ($workers) { $workers | Select-Object ProcessId,CommandLine | Format-List } else { Write-Host 'No hay trabajador activo.' -ForegroundColor Red }
if (Test-Path -LiteralPath (Join-Path $bridge 'bridge.json')) { Get-Content -LiteralPath (Join-Path $bridge 'bridge.json') -Raw }
if (Test-Path -LiteralPath (Join-Path $bridge 'worker.log')) { Get-Content -LiteralPath (Join-Path $bridge 'worker.log') -Tail 120 }
if (Test-Path -LiteralPath (Join-Path $bridge 'worker-supervisor.log')) { Write-Host "`n--- Supervisor ---" -ForegroundColor Yellow; Get-Content -LiteralPath (Join-Path $bridge 'worker-supervisor.log') -Tail 80 }
if (Test-Path -LiteralPath (Join-Path $bridge 'worker-process.stderr.log')) { Write-Host "`n--- Errores tecnicos del trabajador ---" -ForegroundColor Yellow; Get-Content -LiteralPath (Join-Path $bridge 'worker-process.stderr.log') -Tail 80 }

Section 'Cola de trabajos'
if (Test-Path -LiteralPath $jobs) {
    $items = @(Get-ChildItem -LiteralPath $jobs -File | Sort-Object LastWriteTime -Descending)
    if ($items) { $items | Select-Object -First 40 Name,LastWriteTime,Length | Format-Table -AutoSize } else { Write-Host 'La cola esta vacia.' }
    Get-ChildItem -LiteralPath $jobs -Filter '*.output.log' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | ForEach-Object {
        Write-Host "`n--- $($_.Name) ---" -ForegroundColor Yellow; Get-Content -LiteralPath $_.FullName -Tail 120
    }
} else { Write-Host 'No existe gui-jobs.' -ForegroundColor Red }

Section 'Prueba HTTP local'
try { (Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8780/api/status' -TimeoutSec 5).Content } catch { Write-Host $_.Exception.Message -ForegroundColor Red }

Write-Host "`nDiagnostico terminado. Copia esta ventana completa si necesitas ayuda." -ForegroundColor Green
