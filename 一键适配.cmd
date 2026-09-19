@echo off
setlocal
cd /d "%~dp0"
echo BSB Client Patcher - one-click adapt
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch.ps1" %*
echo.
pause
