@echo off
title Uninstall - Keep Awake While VMware
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-KeepAwake.ps1" -Uninstall
echo.
pause
