@echo off
setlocal
rem Do not inherit incompatible PowerShell 7 module paths from the caller.
set "PSModulePath="
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" %*
exit /b %errorlevel%
