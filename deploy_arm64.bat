@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

:: Set app variables
set APP_ID=com.nameless.audio
set APK_PATH_ARM64=build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
set APK_PATH_GENERIC=build\app\outputs\flutter-apk\app-release.apk

echo ============================================
echo   NL Audio - Pro Deploy Tool (arm64)
echo ============================================
echo.

:: 1. Check dependencies
echo [STEP 1] Checking environment...
where flutter >nul 2>&1 || (echo [ERROR] flutter not found. & goto :end)
where adb >nul 2>&1 || (echo [ERROR] adb not found. & goto :end)
echo [OK]    Environment ready.

:: 2. Find and prepare device
echo [STEP 2] Connecting to device...
adb wait-for-device
set DEVICE=
for /f "tokens=1" %%d in ('adb devices ^| findstr /r /c:"[0-9a-fA-F].*device$"') do (
    set DEVICE=%%d
    goto :device_found
)

echo [ERROR] No authorized device found. 
echo         Please check USB/Wireless debugging and authorize this PC.
adb devices
goto :end

:device_found
echo [INFO]  Target Device: %DEVICE%
adb -s %DEVICE% shell getprop ro.product.model

:: 3. Clean environment (Optional but helps with file locks)
echo [STEP 3] Optimizing build environment...
:: Kill lingering Gradle/Java processes that might lock files
taskkill /F /IM java.exe /T >nul 2>&1
taskkill /F /IM gradle.exe /T >nul 2>&1
echo [OK]    Environment cleaned.

:: 4. Build APK
echo [STEP 4] Building arm64 release APK...
echo.

:: Try incremental build first
call flutter build apk --target-platform android-arm64 --release --split-per-abi
if %errorlevel% neq 0 (
    echo.
    echo [WARN]  Incremental build failed. Trying deep clean build...
    call flutter clean
    call flutter pub get
    call flutter build apk --target-platform android-arm64 --release --split-per-abi
    if %errorlevel% neq 0 (
        echo.
        echo [ERROR] Build failed. Please check the logs above.
        goto :end
    )
)

:: 5. Find APK
set FINAL_APK=
if exist "%APK_PATH_ARM64%" (
    set FINAL_APK=%APK_PATH_ARM64%
) else if exist "%APK_PATH_GENERIC%" (
    set FINAL_APK=%APK_PATH_GENERIC%
)

if "%FINAL_APK%"=="" (
    echo [ERROR] Could not find generated APK.
    goto :end
)
echo [INFO]  Using APK: %FINAL_APK%

:: 6. Install
echo [STEP 5] Installing to device...
:: -r: replace existing
:: -d: allow downgrade
:: -g: grant all permissions
adb -s %DEVICE% install -r -d -g "%FINAL_APK%"
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Installation failed. 
    echo         Possible reasons:
    echo         - Device storage full
    echo         - Screen locked/Protected by Knox/Security
    echo         - Package signature mismatch (Uninstall old version manually)
    goto :end
)
echo [OK]    Install succeeded.

:: 7. Launch
echo [STEP 6] Launching app...
adb -s %DEVICE% shell am start -n %APP_ID%/.MainActivity >nul 2>&1
if %errorlevel% neq 0 (
    :: Fallback to monkey launch if activity name changed
    adb -s %DEVICE% shell monkey -p %APP_ID% 1 >nul 2>&1
)

if %errorlevel% neq 0 (
    echo [WARN]  Launch failed, please start the app manually.
) else (
    echo [OK]    App launched successfully.
)

echo.
echo ============================================
echo   Deployment Complete!
echo ============================================

:end
echo.
echo Closing in 5 seconds...
timeout /t 5 >nul
exit /b
