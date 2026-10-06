@echo off
chcp 65001 >nul
setlocal

if "%~1"=="" (
    echo Drag a Japanese .srt file onto this launcher.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0translate_srt_api.ps1" -InputPath "%~1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Translation failed. Exit code: %RC%
) else (
    echo.
    echo Translation finished successfully.
)

pause
exit /b %RC%
