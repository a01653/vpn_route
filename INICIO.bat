@echo off
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d C:\temp\vpn

pwsh -NoExit -ExecutionPolicy Bypass -File "C:\temp\vpn\FINAL.ps1"