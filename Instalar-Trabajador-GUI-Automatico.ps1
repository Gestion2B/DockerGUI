#requires -Version 5.1
# Instala un supervisor de la GUI para el usuario actual. No necesita elevarse.
[CmdletBinding()]
param([ValidateSet('Install','Uninstall','Status')] [string]$Action = 'Install')

$ErrorActionPreference = 'Stop'
$taskName = 'Supervisor GUI Docker'
$supervisor = Join-Path $PSScriptRoot 'Supervisor-Trabajador-GUI-Docker.ps1'
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

if ($Action -eq 'Uninstall') {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host 'Supervisor eliminado.' }
    else { Write-Host 'El supervisor no estaba instalado.' }
    exit 0
}
if ($Action -eq 'Status') {
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Select-Object TaskName,State
    exit 0
}
if (-not (Test-Path -LiteralPath $supervisor -PathType Leaf)) { throw "No existe $supervisor" }

$taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$supervisor`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$trigger.Delay = 'PT10S'
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365)
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Settings $settings -Principal $principal -Description 'Mantiene activo el trabajador local de la GUI Docker.' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "Supervisor instalado e iniciado: $taskName" -ForegroundColor Green
