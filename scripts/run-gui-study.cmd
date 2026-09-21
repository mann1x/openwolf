@echo off
REM Measures whether a GUI-subsystem launcher removes the console flash while
REM keeping the hook contract. Must run in an interactive desktop session:
REM over SSH Windows puts this at session 0, which cannot show a window, and
REM the script then refuses to draw any conclusion.
setlocal
cd /d "%~dp0.."
echo Running GUI-launcher study... console windows may briefly appear. That is the measurement.
pwsh -NoProfile -ExecutionPolicy Bypass -File "scripts\study-gui-launcher.ps1" > "%~dp0..\gui-study-result.txt" 2>&1
echo Exit code: %ERRORLEVEL% >> "%~dp0..\gui-study-result.txt"
type "%~dp0..\gui-study-result.txt"
echo.
echo Transcript: %~dp0..\gui-study-result.txt
pause
