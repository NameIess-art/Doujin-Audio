@echo off
setlocal
set "USAGE_EXIT_CODE="
set "REPO_ROOT=%~dp0.."
set "DEPLOY_SCRIPT=%REPO_ROOT%\tool\deploy_android_release.ps1"

if /I "%~1"=="--help" goto :help
if /I "%~1"=="-h" goto :help
if not "%~2"=="" goto :invalid_arguments
if not "%~1"=="" if /I not "%~1"=="--replace-signature" goto :invalid_arguments

if not exist "%DEPLOY_SCRIPT%" (
    echo [ERROR] Deployment script not found: "%DEPLOY_SCRIPT%"
    exit /b 1
)

pushd "%REPO_ROOT%"
if /I "%~1"=="--replace-signature" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DEPLOY_SCRIPT%" -ReplaceSignature
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%DEPLOY_SCRIPT%" -PromptReplaceSignature
)
set "EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %EXIT_CODE%

:invalid_arguments
echo [ERROR] Unsupported arguments: %*
goto :usage

:help
set "USAGE_EXIT_CODE=0"
:usage
echo Usage: %~nx0 [--replace-signature]
echo.
echo   --replace-signature  Uninstall an existing app with an incompatible
echo                        signature, deleting its local data, then install.
if not defined USAGE_EXIT_CODE set "USAGE_EXIT_CODE=2"
exit /b %USAGE_EXIT_CODE%
