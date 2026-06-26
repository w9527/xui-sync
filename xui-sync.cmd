@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "POWERSHELL_EXE=powershell.exe"

where pwsh.exe >nul 2>nul && set "POWERSHELL_EXE=pwsh.exe"

if not exist "%SCRIPT_DIR%xui-sync.ps1" (
  echo xui-sync: launcher script not found: %SCRIPT_DIR%xui-sync.ps1 >&2
  exit /b 1
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%xui-sync.ps1" %*
exit /b %ERRORLEVEL%
