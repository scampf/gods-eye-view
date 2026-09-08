@echo off
setlocal
title God's Eye View - A2zz Installer

echo.
echo God's Eye View - A2zz Windows installer
echo This will install locally under your Windows user account.
echo No administrator rights are required.
echo.

set "INSTALLER=%TEMP%\a2zz-gods-eye-view-install.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/scampf/gods-eye-view/main/scripts/a2zz-windows-install.ps1' -OutFile '%INSTALLER%' } catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }"

if errorlevel 1 (
    echo.
    echo Could not download the installer from GitHub.
    echo Send ChatGPT a screenshot of this window.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo Installation did not finish successfully.
    echo Send ChatGPT a screenshot of the message above.
    pause
)

exit /b %RC%
