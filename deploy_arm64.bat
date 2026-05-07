@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ============================================
echo   AudioPlayer - Deploy arm64 to Android
echo ============================================
echo.

:: Check for flutter
where flutter >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] flutter not found in PATH.
    goto :end
)

:: Check for adb
where adb >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] adb not found in PATH. Is the Android SDK installed?
    goto :end
)

:: Find device
echo [STEP]  Checking connected devices...
set DEVICE=
for /f "tokens=1" %%d in ('adb devices 2^>nul ^| findstr /r /c:"[0-9a-fA-F].*device$"') do (
    set DEVICE=%%d
    goto :device_found
)

echo [ERROR] No authorized Android device connected.
echo         Please check USB connection and authorize debugging on your phone.
echo.
adb devices
goto :end

:device_found
echo [INFO]  Device: %DEVICE%

:: Check device state
adb -s %DEVICE% get-state >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Device is in an invalid state. Try reconnecting.
    goto :end
)
echo.

:: Clean old APKs to avoid deploying stale versions
echo [STEP]  Cleaning old artifacts...
if exist "build\app\outputs\flutter-apk" (
    del /q "build\app\outputs\flutter-apk\*.apk" >nul 2>&1
)

:: Build APK
echo [STEP]  Building arm64 release APK...
echo.
call flutter build apk --target-platform android-arm64 --release --split-per-abi
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Build failed. Check the error messages above.
    goto :end
)

echo.
echo [OK]    Build succeeded.

:: Find APK
set APK=
if exist "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" (
    set APK=build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
) else if exist "build\app\outputs\flutter-apk\app-release.apk" (
    set APK=build\app\outputs\flutter-apk\app-release.apk
)

if not defined APK (
    echo [ERROR] Could not find APK in build\app\outputs\flutter-apk\
    goto :end
)

echo [INFO]  Using APK: %APK%
echo.

:: Install APK
echo [STEP]  Installing to device...
adb -s %DEVICE% install -r "%APK%"
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Install failed. Make sure the screen is unlocked.
    goto :end
)

echo [OK]    Install succeeded.
echo.

:: Launch App
echo [STEP]  Launching app...
:: Try am start first as it is more reliable
adb -s %DEVICE% shell am start -n com.example.music_player/com.example.music_player.MainActivity >nul 2>&1
if %errorlevel% neq 0 (
    :: Fallback to monkey
    adb -s %DEVICE% shell monkey -p com.example.music_player 1 >nul 2>&1
)

if %errorlevel% neq 0 (
    echo [WARN]  Launch command failed, but app was installed. 
    echo         Please open "AudioPlayer" manually.
) else (
    echo [OK]    Launch succeeded.
)

echo.
echo ============================================
echo   Deploy complete!
echo ============================================

:end
echo.
echo Press any key to exit.
pause >nul
