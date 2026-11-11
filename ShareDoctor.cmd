@echo off
rem ShareDoctor launcher - double-click this file. Runs ShareDoctor.ps1 without changing your system's script policy.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ShareDoctor.ps1" %*
echo.
pause
