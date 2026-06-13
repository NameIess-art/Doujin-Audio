param(
    [switch]$ReplaceSignature
)

$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$appId = 'com.nameless.audio'
$apkPath = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'

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

    Run-Command 'flutter' @(
        'build', 'apk',
        '--target-platform', 'android-arm64',
        '--release',
        '--split-per-abi',
        '--no-pub',
        '--no-version-check'
    )
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
            if (-not $ReplaceSignature) {
                throw @'
Existing app uses a different signing key.
Export a .nalbackup first, then rerun with -ReplaceSignature.
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
        '-s', $device, 'shell', 'am', 'start', '-n', "$appId/.MainActivity"
    )
    Write-Host '[OK] Nameless Audio release deployment completed.'
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    Set-Location $repoRoot
}
