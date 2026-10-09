@echo off
rem EventKit offline installer: double-click this file. No administrator rights needed.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1" %*
set EK_EXIT=%ERRORLEVEL%
echo.
pause
exit /b %EK_EXIT%
