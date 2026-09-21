@echo off
setlocal
cd /d "%~dp0.."
pwsh -NoProfile -ExecutionPolicy Bypass -File "scripts\watch-console-windows.ps1"
pause
