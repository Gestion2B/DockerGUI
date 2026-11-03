@echo off
title Docker - Panel de copias y versiones
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Reiniciar-Trabajador-GUI-Docker.ps1"
if errorlevel 1 (
  echo.
  echo La GUI no se abrira vacia. Corrige primero el error del trabajador mostrado arriba.
  pause
  exit /b 1
)
docker compose -f "%~dp0Gui-Docker\compose.yml" up --detach --build
if errorlevel 1 (
  echo No se pudo iniciar la API Docker. Revisa que Docker Desktop este abierto.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Comprobar-GUI-Docker.ps1"
if errorlevel 1 (
  echo.
  echo La API Docker no ha respondido en http://127.0.0.1:8780.
  echo Estado del contenedor:
  docker compose -f "%~dp0Gui-Docker\compose.yml" ps
  echo.
  echo Ultimos registros de la API:
  docker compose -f "%~dp0Gui-Docker\compose.yml" logs --tail 80
  echo.
  echo Esta ventana se queda abierta para que puedas copiar el error.
  pause
  exit /b 1
)
start "" "http://127.0.0.1:8780/"
