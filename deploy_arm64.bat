@echo off
echo Building arm64 release APK...
call flutter build apk --split-per-abi --release
if %errorlevel% neq 0 (
    echo Build failed!
    pause
    exit /b %errorlevel%
)
echo.
echo Installing to device...
adb install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
if %errorlevel% neq 0 (
    echo Install failed!
    pause
    exit /b %errorlevel%
)
echo.
echo Done.
pause
