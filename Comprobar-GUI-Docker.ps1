#requires -Version 5.1
# Espera a que la API Docker responda. El .cmd usa el codigo de salida para
# conservar la consola abierta con los logs si el contenedor falla.
[CmdletBinding()]
param(
    [string]$Url = 'http://127.0.0.1:8780/api/status',
    [ValidateRange(5, 60)] [int]$TimeoutSeconds = 20
)

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 3
        if ($response.StatusCode -eq 200) { exit 0 }
    }
    catch {}
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

Write-Host "La API no respondio tras $TimeoutSeconds segundos." -ForegroundColor Red
exit 1
