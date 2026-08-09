param(
    [string[]]$Task = @('doctor', 'list'),
    [string]$DeviceId,
    [string]$EmulatorId,
    [string]$IntegrationTarget = 'integration_test/app_smoke_test.dart',
    [string]$OutputDir = 'build/android-test',
    [int]$LogcatSeconds = 20,
    [int]$ScreenshotDelaySeconds = 2,
    [switch]$ReplaceExisting,
    [switch]$ReleaseReplaceSignature,
    [switch]$WipeEmulator,
    [switch]$RequireArm64,
    [switch]$NoPub
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$appId = 'com.doujin.audio'
$mainActivity = "$appId/com.doujin.audio.MainActivity"
$debugApkPath = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-debug.apk'
$arm64DebugApkPath = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-arm64-v8a-debug.apk'
$arm64ReleaseApkPath = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
$arm64SplitVersionCodeOffset = 2000
$validTasks = @(
    'doctor',
    'list',
    'start-emulator',
    'build-debug',
    'install-debug',
    'build-release-arm64',
    'install-release-arm64',
    'build-debug-arm64',
    'install-debug-arm64',
    'launch',
    'smoke',
    'logcat',
    'screenshot',
    'all'
)

function Normalize-Tasks {
    $normalized = @()
    foreach ($entry in $Task) {
        foreach ($part in ($entry -split ',')) {
            $name = $part.Trim()
            if (-not $name) {
                continue
            }
            if ($validTasks -notcontains $name) {
                throw "Unknown task '$name'. Valid tasks: $($validTasks -join ', ')"
            }
            $normalized += $name
        }
    }
    return $normalized
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Find-Executable {
    param(
        [string]$Name,
        [string[]]$CandidatePaths = @()
    )
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    foreach ($candidate in $CandidatePaths) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }
    throw "Could not find executable: $Name"
}

function Get-AndroidSdkRoot {
    foreach ($candidate in @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        (Join-Path $env:LOCALAPPDATA 'Android\sdk')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
            return $candidate
        }
    }
    return $null
}

$androidSdkRoot = Get-AndroidSdkRoot
$adbPath = Find-Executable 'adb' @(
    $(if ($androidSdkRoot) { Join-Path $androidSdkRoot 'platform-tools\adb.exe' })
)
$emulatorPath = $null
try {
    $emulatorPath = Find-Executable 'emulator' @(
        $(if ($androidSdkRoot) { Join-Path $androidSdkRoot 'emulator\emulator.exe' })
    )
} catch {
    $emulatorPath = $null
}

function Invoke-Checked {
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    & $Name @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

function Invoke-Captured {
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Name @Arguments 2>&1
        return @{
            ExitCode = $LASTEXITCODE
            Output = $output
        }
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
}

function Get-AuthorizedDevices {
    $lines = & $adbPath devices -l
    return $lines |
        Select-Object -Skip 1 |
        Where-Object { $_ -match '^\S+\s+device\s+' } |
        ForEach-Object { ($_ -split '\s+')[0] }
}

function Resolve-Device {
    if ($DeviceId) {
        $state = (& $adbPath -s $DeviceId get-state 2>$null)
        if ($LASTEXITCODE -eq 0 -and $state -eq 'device') {
            return $DeviceId
        }
        throw "Device is not authorized or connected: $DeviceId"
    }
    $devices = @(Get-AuthorizedDevices)
    if ($devices.Count -gt 0) {
        return $devices[0]
    }
    throw 'No authorized Android device found. Connect a USB device, or run -Task start-emulator first.'
}

function Get-DeviceAbiList {
    param([string]$Serial)
    $abiList = (& $adbPath -s $Serial shell getprop ro.product.cpu.abilist 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read Android ABI list from device: $Serial"
    }
    return ($abiList | ForEach-Object { $_.ToString().Trim() }) -join ','
}

function Get-DevicePrimaryAbi {
    param([string]$Serial)
    $abi = (& $adbPath -s $Serial shell getprop ro.product.cpu.abi 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read Android primary ABI from device: $Serial"
    }
    return ($abi | Select-Object -First 1).ToString().Trim()
}

function Assert-Arm64Device {
    param([string]$Serial)
    $primaryAbi = Get-DevicePrimaryAbi $Serial
    $abiList = Get-DeviceAbiList $Serial
    if (-not $abiList -or ($abiList -split ',') -notcontains 'arm64-v8a') {
        throw @"
Device $Serial is not arm64-v8a compatible.
ro.product.cpu.abi=$primaryAbi
ro.product.cpu.abilist=$abiList
Use an AVD/device whose ABI list contains arm64-v8a.
"@
    }
    Write-Host "[OK] Device supports arm64-v8a: $Serial ($abiList)"
    if ($primaryAbi -ne 'arm64-v8a') {
        Write-Host "[INFO] Primary ABI is $primaryAbi; installing the arm64 APK through device compatibility."
    }
}

function Wait-ForDeviceBoot {
    param([string]$Serial)
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $devices = @(Get-AuthorizedDevices)
        if ($devices -contains $Serial) {
            $bootCompleted = (& $adbPath -s $Serial shell getprop sys.boot_completed 2>$null)
            if ($LASTEXITCODE -eq 0 -and $bootCompleted -and $bootCompleted.Trim() -eq '1') {
                return
            }
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out waiting for Android boot completion: $Serial"
}

function Stop-Emulator {
    param([string]$Serial)
    Write-Step "Stopping emulator $Serial"
    & $adbPath -s $Serial emu kill 2>$null | Out-Null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $devices = @(Get-AuthorizedDevices)
        if ($devices -notcontains $Serial) {
            return
        }
        Start-Sleep -Seconds 1
    }
}

function Start-AndroidEmulator {
    if (-not $EmulatorId) {
        throw 'Pass -EmulatorId <id>. Run -Task list to see Flutter emulator IDs.'
    }
    if (-not $emulatorPath) {
        throw 'Android emulator executable was not found. Install Android Emulator from Android Studio SDK Manager.'
    }

    $before = @(Get-AuthorizedDevices)
    $runningEmulator = $before | Where-Object { $_ -like 'emulator-*' } | Select-Object -First 1
    if ($runningEmulator) {
        if ($WipeEmulator) {
            Stop-Emulator $runningEmulator
            $before = @(Get-AuthorizedDevices)
        } else {
            Wait-ForDeviceBoot $runningEmulator
            if ($RequireArm64) {
                Assert-Arm64Device $runningEmulator
            }
            Write-Host "[OK] Emulator already running: $runningEmulator"
            return $runningEmulator
        }
    }

    Write-Step "Starting emulator $EmulatorId"
    $emulatorArgs = @('-avd', $EmulatorId)
    if ($WipeEmulator) {
        $emulatorArgs += '-wipe-data'
    }
    Start-Process -FilePath $emulatorPath -ArgumentList $emulatorArgs -WindowStyle Hidden

    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $after = @(Get-AuthorizedDevices)
        $newEmulator = $after |
            Where-Object { $_ -like 'emulator-*' -and $before -notcontains $_ } |
            Select-Object -First 1
        if ($newEmulator) {
            Wait-ForDeviceBoot $newEmulator
            if ($RequireArm64) {
                Assert-Arm64Device $newEmulator
            }
            Write-Host "[OK] Emulator ready: $newEmulator"
            return $newEmulator
        }

        $anyEmulator = $after | Where-Object { $_ -like 'emulator-*' } | Select-Object -First 1
        if ($anyEmulator) {
            Wait-ForDeviceBoot $anyEmulator
            if ($RequireArm64) {
                Assert-Arm64Device $anyEmulator
            }
            Write-Host "[OK] Emulator ready: $anyEmulator"
            return $anyEmulator
        }
        Start-Sleep -Seconds 2
    }
    throw "Timed out starting emulator: $EmulatorId"
}

function Build-DebugApk {
    param([string]$Serial)
    Write-Step 'Building Android debug APK'
    $args = @('build', 'apk', '--debug')
    if ($Serial) {
        $installedVersionCode = Get-InstalledVersionCode $Serial
        $projectBuildNumber = Get-ProjectBuildNumber
        if ($null -ne $installedVersionCode -and $installedVersionCode -ge $projectBuildNumber) {
            $temporaryBuildNumber = $installedVersionCode + 1
            $args += @('--build-number', "$temporaryBuildNumber")
            Write-Host "[INFO] Using temporary debug build number: $temporaryBuildNumber"
        }
    }
    if ($NoPub) {
        $args += '--no-pub'
    }
    Invoke-Checked 'flutter' $args
    if (-not (Test-Path -LiteralPath $debugApkPath -PathType Leaf)) {
        throw "Debug APK was not generated: $debugApkPath"
    }
    Write-Host "[OK] $debugApkPath"
}

function Install-DebugApk {
    param([string]$Serial)
    Build-DebugApk $Serial

    Write-Step "Installing debug APK on $Serial"
    $install = Invoke-Captured $adbPath @('-s', $Serial, 'install', '-r', '-g', $debugApkPath)
    if ($install.ExitCode -eq 0) {
        Write-Host '[OK] APK installed.'
        return
    }

    $installText = ($install.Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    Write-Host $installText
    if ($installText.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE') -and $ReplaceExisting) {
        Write-Warning 'Replacing existing app. This uninstalls the app and deletes local app data.'
        Invoke-Checked $adbPath @('-s', $Serial, 'uninstall', $appId)
        Invoke-Checked $adbPath @('-s', $Serial, 'install', '-g', $debugApkPath)
        return
    }

    if ($installText.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
        throw 'Existing app is signed with a different key. Export a .dabackup first, then rerun with -ReplaceExisting if data loss is acceptable.'
    }
    throw 'Debug APK installation failed.'
}

function Get-TemporaryReleaseBuildNumberArgs {
    param([string]$Serial)
    if (-not $Serial) {
        return @()
    }

    $projectBuildNumber = Get-ProjectBuildNumber
    $installedVersionCode = Get-InstalledVersionCode $Serial
    if ($null -eq $installedVersionCode) {
        return @()
    }

    $installedBuildNumber = $installedVersionCode - $arm64SplitVersionCodeOffset
    $nextBuildNumber = [Math]::Max($projectBuildNumber, $installedBuildNumber) + 1
    Write-Host "[INFO] Using temporary release build number: $nextBuildNumber"
    return @('--build-number', "$nextBuildNumber")
}

function Get-TemporaryDebugBuildNumberArgs {
    param([string]$Serial)
    if (-not $Serial) {
        return @()
    }

    $installedVersionCode = Get-InstalledVersionCode $Serial
    $projectBuildNumber = Get-ProjectBuildNumber
    if ($null -ne $installedVersionCode -and $installedVersionCode -ge $projectBuildNumber) {
        $temporaryBuildNumber = $installedVersionCode + 1
        Write-Host "[INFO] Using temporary arm64 debug build number: $temporaryBuildNumber"
        return @('--build-number', "$temporaryBuildNumber")
    }
    return @()
}

function Ensure-ReleaseSigning {
    Write-Step 'Preparing Android release signing'
    Invoke-Checked 'powershell' @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Join-Path $PSScriptRoot 'setup_local_release_signing.ps1')
    )
    Invoke-Checked 'android\gradlew.bat' @(
        '-p',
        'android',
        ':app:validateReleaseSigning'
    )
}

function Build-Arm64ReleaseApk {
    param([string]$Serial)
    Ensure-ReleaseSigning

    Write-Step 'Building Android arm64 release APK'
    $args = @(
        'build',
        'apk',
        '--release',
        '--target-platform',
        'android-arm64',
        '--split-per-abi',
        '--no-version-check'
    )
    $args += Get-TemporaryReleaseBuildNumberArgs $Serial
    if ($NoPub) {
        $args += '--no-pub'
    }
    Invoke-Checked 'flutter' $args
    if (-not (Test-Path -LiteralPath $arm64ReleaseApkPath -PathType Leaf)) {
        throw "Strict arm64 release APK was not generated: $arm64ReleaseApkPath"
    }
    Write-Host "[OK] $arm64ReleaseApkPath"
}

function Build-Arm64DebugApk {
    param([string]$Serial)
    Write-Step 'Building Android arm64 debug APK'
    $args = @(
        'build',
        'apk',
        '--debug',
        '--target-platform',
        'android-arm64',
        '--split-per-abi',
        '--no-version-check'
    )
    $args += Get-TemporaryDebugBuildNumberArgs $Serial
    if ($NoPub) {
        $args += '--no-pub'
    }
    Invoke-Checked 'flutter' $args
    if (-not (Test-Path -LiteralPath $arm64DebugApkPath -PathType Leaf)) {
        throw "Strict arm64 debug APK was not generated: $arm64DebugApkPath. Refusing to install a generic app-debug.apk."
    }
    Write-Host "[OK] $arm64DebugApkPath"
}

function Install-Apk {
    param(
        [string]$Serial,
        [string]$ApkPath,
        [switch]$AllowReplaceSignature,
        [string]$Label = 'APK'
    )

    Write-Step "Installing $Label on $Serial"
    $install = Invoke-Captured $adbPath @('-s', $Serial, 'install', '-r', '-g', $ApkPath)
    if ($install.ExitCode -eq 0) {
        Write-Host '[OK] APK installed.'
        return
    }

    $installText = ($install.Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    Write-Host $installText
    if ($installText.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
        if ($AllowReplaceSignature) {
            Write-Warning 'Replacing existing app. This uninstalls the app and deletes local app data.'
            Invoke-Checked $adbPath @('-s', $Serial, 'uninstall', $appId)
            Invoke-Checked $adbPath @('-s', $Serial, 'install', '-g', $ApkPath)
            return
        }
        throw 'Existing app is signed with a different key. Export a .dabackup first, then rerun with the explicit replace option if data loss is acceptable.'
    }

    if ($installText.Contains('INSTALL_FAILED_VERSION_DOWNGRADE')) {
        throw 'Existing app has a higher versionCode. Rebuild with a higher build number or uninstall the app after backing up data.'
    }
    throw "$Label installation failed."
}

function Install-Arm64ReleaseApk {
    param([string]$Serial)
    Assert-Arm64Device $Serial
    Build-Arm64ReleaseApk $Serial
    Install-Apk $Serial $arm64ReleaseApkPath -AllowReplaceSignature:$ReleaseReplaceSignature -Label 'arm64 release APK'
}

function Install-Arm64DebugApk {
    param([string]$Serial)
    Assert-Arm64Device $Serial
    Build-Arm64DebugApk $Serial
    Install-Apk $Serial $arm64DebugApkPath -AllowReplaceSignature:$ReplaceExisting -Label 'arm64 debug APK'
}

function Get-ProjectBuildNumber {
    $pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
    foreach ($line in Get-Content -LiteralPath $pubspecPath) {
        if ($line -match '^\s*version\s*:\s*[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\+([0-9]+)\s*(?:#.*)?$') {
            return [int64]$Matches[1]
        }
    }
    throw 'Could not read build number from pubspec.yaml.'
}

function Get-InstalledVersionCode {
    param([string]$Serial)
    $packageInfo = & $adbPath -s $Serial shell dumpsys package $appId 2>$null
    foreach ($line in $packageInfo) {
        if ($line -match 'versionCode=([0-9]+)') {
            return [int64]$Matches[1]
        }
    }
    return $null
}

function Launch-App {
    param([string]$Serial)
    Write-Step "Launching $appId on $Serial"
    Invoke-Checked $adbPath @('-s', $Serial, 'shell', 'am', 'start', '-n', $mainActivity)
}

function Run-SmokeTest {
    param([string]$Serial)
    $installedVersionCode = Get-InstalledVersionCode $Serial
    $projectBuildNumber = Get-ProjectBuildNumber
    if ($null -ne $installedVersionCode -and $installedVersionCode -gt $projectBuildNumber) {
        throw "Smoke test would install debug versionCode $projectBuildNumber over installed versionCode $installedVersionCode. Use an emulator, or back up and uninstall the existing app manually first."
    }

    Write-Step "Running Flutter integration smoke test on $Serial"
    $args = @('test', $IntegrationTarget, '-d', $Serial)
    if ($NoPub) {
        $args += '--no-pub'
    }
    Invoke-Checked 'flutter' $args
}

function Save-Logcat {
    param([string]$Serial)
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot $OutputDir) | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $repoRoot (Join-Path $OutputDir "logcat-$timestamp.txt")
    Write-Step "Capturing logcat for $LogcatSeconds seconds"
    & $adbPath -s $Serial logcat -c
    $process = Start-Process -FilePath $adbPath `
        -ArgumentList @('-s', $Serial, 'logcat', '-v', 'time') `
        -NoNewWindow `
        -RedirectStandardOutput $logPath `
        -PassThru
    Start-Sleep -Seconds $LogcatSeconds
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }
    Write-Host "[OK] $logPath"
}

function Save-Screenshot {
    param([string]$Serial)
    New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot $OutputDir) | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $remotePath = "/sdcard/doujin-audio-$timestamp.png"
    $localPath = Join-Path $repoRoot (Join-Path $OutputDir "screenshot-$timestamp.png")
    if ($ScreenshotDelaySeconds -gt 0) {
        Start-Sleep -Seconds $ScreenshotDelaySeconds
    }
    Write-Step 'Capturing Android screenshot'
    Invoke-Checked $adbPath @('-s', $Serial, 'shell', 'screencap', '-p', $remotePath)
    Invoke-Checked $adbPath @('-s', $Serial, 'pull', $remotePath, $localPath)
    Invoke-Checked $adbPath @('-s', $Serial, 'shell', 'rm', $remotePath)
    Write-Host "[OK] $localPath"
}

Set-Location $repoRoot
try {
    $Task = Normalize-Tasks
    if ($Task -contains 'all') {
        $Task = @('doctor', 'build-debug', 'install-debug', 'launch', 'screenshot', 'logcat')
    }

    if ($Task -contains 'doctor') {
        Write-Step 'Flutter and Android doctor'
        Invoke-Checked 'flutter' @('doctor', '-v')
    }

    if ($Task -contains 'list') {
        Write-Step 'Connected Android devices'
        Invoke-Checked $adbPath @('devices', '-l')
        Write-Step 'Flutter devices'
        Invoke-Checked 'flutter' @('devices')
        Write-Step 'Flutter emulators'
        Invoke-Checked 'flutter' @('emulators')
    }

    $selectedDevice = $null
    if ($Task -contains 'start-emulator') {
        $selectedDevice = Start-AndroidEmulator
    }

    $needsDevice = @('install-debug', 'install-release-arm64', 'install-debug-arm64', 'launch', 'smoke', 'logcat', 'screenshot') |
        Where-Object { $Task -contains $_ }
    if ($needsDevice.Count -gt 0 -and -not $selectedDevice) {
        $selectedDevice = Resolve-Device
        if ($RequireArm64) {
            Assert-Arm64Device $selectedDevice
        }
        Write-Host "[OK] Using Android device: $selectedDevice"
    }

    if ($Task -contains 'build-debug') {
        Build-DebugApk $selectedDevice
    }
    if ($Task -contains 'build-release-arm64') {
        Build-Arm64ReleaseApk $selectedDevice
    }
    if ($Task -contains 'build-debug-arm64') {
        Build-Arm64DebugApk $selectedDevice
    }
    if ($Task -contains 'install-debug') {
        Install-DebugApk $selectedDevice
    }
    if ($Task -contains 'install-release-arm64') {
        Install-Arm64ReleaseApk $selectedDevice
    }
    if ($Task -contains 'install-debug-arm64') {
        Install-Arm64DebugApk $selectedDevice
    }
    if ($Task -contains 'launch') {
        Launch-App $selectedDevice
    }
    if ($Task -contains 'smoke') {
        Run-SmokeTest $selectedDevice
    }
    if ($Task -contains 'screenshot') {
        Save-Screenshot $selectedDevice
    }
    if ($Task -contains 'logcat') {
        Save-Logcat $selectedDevice
    }
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Set-Location $repoRoot
}
