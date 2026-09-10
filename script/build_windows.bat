@echo off
setlocal
call "%~dp0..\tool\build_windows.bat" %*
exit /b %errorlevel%
