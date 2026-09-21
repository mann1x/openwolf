@echo off
REM Run the console-flash characterisation in the CURRENT interactive desktop
REM session and keep a transcript. Over SSH this lands in session 0, which is
REM blind and reports INCONCLUSIVE — so this must be launched from a terminal
REM on the machine's own desktop.
setlocal
cd /d "%~dp0.."
echo Running console-flash probe... console windows may briefly appear. That is the point.
pwsh -NoProfile -ExecutionPolicy Bypass -File "scripts\validate-console-flash.ps1" > "%~dp0..\result.txt" 2>&1
echo Exit code: %ERRORLEVEL% >> "%~dp0..\result.txt"
type "%~dp0..\result.txt"
echo.
echo ---------------------------------------------------------------
echo Transcript written to: %~dp0..\result.txt
echo ---------------------------------------------------------------
pause
