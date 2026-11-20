@echo off
chcp 65001 > nul

:: 65001 - UTF-8
:: Starts the Auto-Rotation + Site Fix monitor (same as service.bat -> 13).
:: The monitor will ASK which base preset to use (last choice pre-selected);
:: per-site overrides from lists/site-overrides.txt are applied on top of it.

cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process 'cmd.exe' -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
    exit /b
)

:admin
:: Require PowerShell 3.0+
powershell -NoProfile -Command "if ($PSVersionTable -and $PSVersionTable.PSVersion -and $PSVersionTable.PSVersion.Major -ge 3) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell 3.0 or newer is required.
    echo Please upgrade PowerShell and rerun this script.
    pause
    exit /b 1
)

echo Starting Auto-Rotation + Site Fix monitor - the base preset will be asked...
start "zapret: auto-rotation + site fix" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\monitor zapret.ps1"
exit /b
