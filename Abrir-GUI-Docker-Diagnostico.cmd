@echo off
title Docker - Diagnostico de la GUI
cd /d "%~dp0"
powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0Diagnosticar-GUI-Docker.ps1"
