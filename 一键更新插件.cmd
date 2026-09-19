@echo off
setlocal
cd /d "%~dp0"
echo BSB Client Patcher - update plugin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update-plugin.ps1" %*
echo.
pause
