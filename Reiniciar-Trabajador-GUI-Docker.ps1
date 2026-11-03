#requires -Version 5.1
# Reinicia solo el proceso PowerShell que ejecuta este trabajador. No toca Docker
# ni otros procesos PowerShell del usuario.
[CmdletBinding()]
param([ValidateRange(3, 30)] [int]$TimeoutSeconds = 10)

$base = $PSScriptRoot
$jobs = Join-Path $base 'gui-jobs'
$bridge = Join-Path $base 'Gui-Docker'
$heartbeat = Join-Path $bridge 'bridge.json'
$workerLog = Join-Path $bridge 'worker.log'
$workerStdout = Join-Path $bridge 'worker-process.stdout.log'
$workerStderr = Join-Path $bridge 'worker-process.stderr.log'
$workerFile = Join-Path $base 'Trabajador-GUI-Docker.ps1'
$workerPattern = [regex]::Escape($workerFile)

if (Get-ChildItem -LiteralPath $jobs -Filter '*.processing.json' -File -ErrorAction SilentlyContinue) {
    Write-Host 'Hay una operacion en curso. No se reinicia el trabajador.' -ForegroundColor Red
    exit 1
}

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $workerPattern } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch {}
    }

# Evita aceptar el heartbeat antiguo de un trabajador que acabamos de cerrar.
Remove-Item -LiteralPath $heartbeat -Force -ErrorAction SilentlyContinue

Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerFile, '-Action', 'Run'
) -RedirectStandardOutput $workerStdout -RedirectStandardError $workerStderr

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    try {
        $state = Get-Content -LiteralPath $heartbeat -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.updatedAt -and ((Get-Date) - [datetime]$state.updatedAt).TotalSeconds -lt 5) {
            Write-Host 'Trabajador local iniciado.' -ForegroundColor Green
            exit 0
        }
    }
    catch {}
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

Write-Host 'El trabajador no pudo iniciar.' -ForegroundColor Red
if (Test-Path -LiteralPath $workerLog) { Get-Content -LiteralPath $workerLog -Tail 40 }
if (Test-Path -LiteralPath $workerStderr) { Get-Content -LiteralPath $workerStderr -Tail 40 }
exit 1
