#requires -Version 5.1
# Mantiene vivo el trabajador local. No controla Docker ni ejecuta operaciones:
# solo vuelve a crear el proceso del trabajador si este termina inesperadamente.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$base = $PSScriptRoot
$bridge = Join-Path $base 'Gui-Docker'
$worker = (Join-Path $base 'Trabajador-GUI-Docker.ps1')
$workerPattern = [regex]::Escape($worker)
$log = Join-Path $bridge 'worker-supervisor.log'
$stdout = Join-Path $bridge 'worker-process.stdout.log'
$stderr = Join-Path $bridge 'worker-process.stderr.log'

function Write-SupervisorLog([string]$Message, [string]$Level = 'INFO') {
    if (-not (Test-Path -LiteralPath $bridge)) { New-Item -ItemType Directory -Path $bridge -Force | Out-Null }
    Add-Content -LiteralPath $log -Encoding UTF8 -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { Write-SupervisorLog "No existe $worker" 'ERROR'; exit 1 }
Write-SupervisorLog 'Supervisor iniciado.'
while ($true) {
    try {
        $existing = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $workerPattern })
        if ($existing.Count -gt 0) {
            Write-SupervisorLog 'Ya hay un trabajador activo; se mantiene la supervision.'
            Start-Sleep -Seconds 5
            continue
        }
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker,'-Action','Run') -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $code = $process.ExitCode
        $process.Dispose()
        Write-SupervisorLog "El trabajador termino con codigo $code. Se reintentara en 5 segundos." 'WARN'
    }
    catch { Write-SupervisorLog "No se pudo iniciar el trabajador: $($_.Exception.Message)" 'ERROR' }
    Start-Sleep -Seconds 5
}
