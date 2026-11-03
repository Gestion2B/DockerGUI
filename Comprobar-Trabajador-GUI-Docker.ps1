#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(3, 30)] [int]$TimeoutSeconds = 10
)

$bridge = Join-Path $PSScriptRoot 'Gui-Docker\bridge.json'
$workerLog = Join-Path $PSScriptRoot 'Gui-Docker\worker.log'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    try {
        $heartbeat = Get-Content -LiteralPath $bridge -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($heartbeat.updatedAt -and ((Get-Date) - [datetime]$heartbeat.updatedAt).TotalSeconds -lt 5) { exit 0 }
    }
    catch {}
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

Write-Host 'El trabajador local no ha creado su estado.' -ForegroundColor Red
if (Test-Path -LiteralPath $workerLog) {
    Write-Host 'Ultimo registro del trabajador:' -ForegroundColor Yellow
    Get-Content -LiteralPath $workerLog -Tail 40
}
exit 1
