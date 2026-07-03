param(
    [switch]$ReplaceSignature,
    [switch]$PromptReplaceSignature
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$appId = 'com.nameless.audio.v1'
$mainActivity = 'com.nameless.audio.MainActivity'
$apkPath = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
$arm64SplitVersionCodeOffset = 2000

function Run-Command {
    param(
        [string]$Name,
        [string[]]$Arguments
    )
    & $Name @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

function Find-AuthorizedDevice {
    $line = adb devices |
        Select-Object -Skip 1 |
        Where-Object { $_ -match '\sdevice\s*$' } |
        Select-Object -First 1
    if (-not $line) {
        throw 'No authorized Android device is connected.'
    }
    return ($line -split '\s+')[0]
}

function Invoke-AdbInstall {
    param(
        [string]$Device,
        [string[]]$Arguments
    )
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & adb -s $Device install @Arguments 2>&1
        return @{
            ExitCode = $LASTEXITCODE
            Output = $output
        }
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
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
    param(
        [string]$Device
    )
    $packageInfo = adb -s $Device shell dumpsys package $appId 2>$null
    foreach ($line in $packageInfo) {
        if ($line -match 'versionCode=([0-9]+)') {
            return [int64]$Matches[1]
        }
    }
    return $null
}

function Confirm-SignatureReplacement {
    Write-Warning 'Existing app uses a different signing key.'
    Write-Warning 'This one-time migration uninstalls the old app and deletes its local data.'
    Write-Warning 'Export a .nalbackup from the app before continuing.'
    $answer = Read-Host 'Type REPLACE to uninstall the old app and continue'
    return $answer -ceq 'REPLACE'
}

Set-Location $repoRoot
try {
    Get-Command flutter -ErrorAction Stop | Out-Null
    Get-Command adb -ErrorAction Stop | Out-Null

    & powershell -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $PSScriptRoot 'setup_local_release_signing.ps1')
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not prepare local release signing.'
    }

    Run-Command 'android\gradlew.bat' @(
        '-p', 'android', ':app:validateReleaseSigning'
    )

    $device = Find-AuthorizedDevice
    Write-Host "[OK] Deploying to device: $device"
    adb -s $device shell getprop ro.product.model

    $projectBuildNumber = Get-ProjectBuildNumber
    $installedVersionCode = Get-InstalledVersionCode $device
    $buildNumberArgs = @()
    if ($null -ne $installedVersionCode) {
        $installedBuildNumber = $installedVersionCode - $arm64SplitVersionCodeOffset
        $nextBuildNumber = [Math]::Max($projectBuildNumber, $installedBuildNumber) + 1
        $buildNumberArgs = @('--build-number', "$nextBuildNumber")
        Write-Host "[INFO] Using temporary release build number: $nextBuildNumber"
    }

    $buildArgs = @(
        'build', 'apk',
        '--target-platform', 'android-arm64',
        '--release',
        '--split-per-abi',
        '--no-pub',
        '--no-version-check'
    )
    $buildArgs += $buildNumberArgs
    Run-Command 'flutter' $buildArgs
    if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
        throw "Release APK was not generated: $apkPath"
    }

    $installResult = Invoke-AdbInstall $device @('-r', '-d', '-g', $apkPath)
    if ($installResult.ExitCode -ne 0) {
        $installText = (
            $installResult.Output | ForEach-Object { $_.ToString() }
        ) -join [Environment]::NewLine
        Write-Host $installText
        if ($installText.Contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE')) {
            if (-not $ReplaceSignature -and -not ($PromptReplaceSignature -and (Confirm-SignatureReplacement))) {
                throw @'
Existing app uses a different signing key.
Export a .nalbackup first, then rerun with -ReplaceSignature.
When using script\deploy_arm64.bat interactively, type REPLACE at the prompt
to perform the one-time uninstall/reinstall migration.
That one-time migration uninstalls the old app and deletes its local data.
'@
            }
            Write-Warning 'Replacing the legacy-signed app and deleting its local data.'
            Run-Command 'adb' @('-s', $device, 'uninstall', $appId)
            $replacementResult = Invoke-AdbInstall $device @('-g', $apkPath)
            if ($replacementResult.ExitCode -ne 0) {
                Write-Host (
                    ($replacementResult.Output | ForEach-Object { $_.ToString() }) -join
                        [Environment]::NewLine
                )
                throw 'Replacement APK installation failed.'
            }
        } else {
            throw 'APK installation failed.'
        }
    }

    Run-Command 'adb' @(
        '-s', $device, 'shell', 'am', 'start', '-n', "$appId/$mainActivity"
    )
    Write-Host '[OK] Nameless Audio release deployment completed.'
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Set-Location $repoRoot
}
