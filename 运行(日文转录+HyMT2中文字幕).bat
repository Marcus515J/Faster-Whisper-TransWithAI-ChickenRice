@echo off
chcp 65001 >nul
set "root=%~dp0"

if "%~1"=="" goto prompt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%root%run_full_pipeline_local.ps1" %*
goto end

:prompt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%root%run_full_pipeline_local.ps1"

:end
echo.
pause
