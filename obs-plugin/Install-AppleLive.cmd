@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_or_update.ps1"
if errorlevel 1 (
  echo.
  echo AppleLive installation failed. Keep this window open and send a screenshot.
  pause
)
