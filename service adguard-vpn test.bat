@echo off
chcp 65001 > nul

:: 65001 - UTF-8
:: Guided compatibility test for Zapret + AdGuard VPN.
:: Verifies the Kill Switch state at the tunnel level (from AdGuard VPN logs),
:: walks through the test sequence and gives a verdict from AdGuard VPN logs.
:: Does not require administrator rights.

cd /d "%~dp0"

:: Require PowerShell 3.0+
powershell -NoProfile -Command "if ($PSVersionTable -and $PSVersionTable.PSVersion -and $PSVersionTable.PSVersion.Major -ge 3) { exit 0 } else { exit 1 }" >nul 2>&1
if %errorlevel% neq 0 (
    echo PowerShell 3.0 or newer is required.
    echo Please upgrade PowerShell and rerun this script.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utilsdguard vpn test.ps1"
pause
