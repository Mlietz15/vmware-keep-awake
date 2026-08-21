@echo off
title Install - Keep Awake While VMware
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-KeepAwake.ps1"
echo.
pause
