param([switch]$SkipBuild, [switch]$PrepareOnly, [string]$InnoCompiler)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dependencyRoot = Join-Path $projectRoot '.dart_tool/windows_dependencies'
$distRoot = Join-Path $projectRoot 'dist/windows'
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows_dependencies.json') -Raw | ConvertFrom-Json

function Get-VerifiedDependency($Dependency, [string]$Name) {
    $destination = Join-Path $dependencyRoot $Name
    if (!(Test-Path -LiteralPath $destination)) {
        Write-Host "Downloading pinned dependency: $Name"
        $partial = "$destination.part"
        # SourceForge serves an HTML landing page to PowerShell's browser-like default user agent.
        Invoke-WebRequest -Uri $Dependency.url -OutFile $partial -UserAgent 'DoujinAudio-build' -UseBasicParsing
        if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Dependency.sha256) {
            throw "Checksum mismatch: $Name"
        }
        Move-Item -LiteralPath $partial -Destination $destination -Force
    }
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Dependency.sha256) {
        throw "Cached dependency checksum mismatch: $destination. Remove this file and retry."
    }
    return $destination
}

function Remove-StagingDirectory([string]$Directory) {
    $resolved = [IO.Path]::GetFullPath($Directory)
    if ($resolved -ne [IO.Path]::GetFullPath((Join-Path $distRoot 'app'))) {
        throw "Refusing to remove non-staging path: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}

$innoRequiredFiles = @('ISCC.exe','ISCmplr.dll','ISPP.dll','Setup.e32','SetupLdr.e32','SetupLdr.e64','islzma64.exe')

function Test-InnoCompilerIntegrity([string]$CompilerRoot, [string]$ExpectedInstallerSha256) {
    $markerPath = Join-Path $CompilerRoot '.verified-inno.json'
    if (!(Test-Path -LiteralPath $markerPath)) { return $false }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    } catch {
        return $false
    }
    if ($marker.installerSha256 -ne $ExpectedInstallerSha256) { return $false }
    foreach ($fileName in $innoRequiredFiles) {
        $filePath = Join-Path $CompilerRoot $fileName
        if (!(Test-Path -LiteralPath $filePath)) { return $false }
        $expectedHash = $marker.files.$fileName
        if (!$expectedHash) { return $false }
        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) { return $false }
    }
    return $true
}

function Write-InnoCompilerMarker([string]$CompilerRoot, [string]$InstallerSha256) {
    $files = [ordered]@{}
    foreach ($fileName in $innoRequiredFiles) {
        $filePath = Join-Path $CompilerRoot $fileName
        if (!(Test-Path -LiteralPath $filePath)) {
            throw "Inno Setup installation is missing required binary: $fileName"
        }
        $files[$fileName] = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $marker = [ordered]@{
        installerSha256 = $InstallerSha256
        files = $files
    }
    [IO.File]::WriteAllText((Join-Path $CompilerRoot '.verified-inno.json'), ($marker | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
}

function Assert-NativeArchivesVerified($NativeArchives, [string]$BuildRoot, [switch]$AllowStage) {
    foreach ($native in $NativeArchives) {
        $nativeArchive = Join-Path $BuildRoot $native.name
        if ($AllowStage) {
            $cached = Join-Path $dependencyRoot $native.name
            if (!(Test-Path -LiteralPath $cached) -and (Test-Path -LiteralPath $nativeArchive)) {
                $existingHash = (Get-FileHash -LiteralPath $nativeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($existingHash -eq $native.sha256) {
                    Copy-Item -LiteralPath $nativeArchive -Destination $cached -Force
                }
            }
            if ($native.PSObject.Properties['url'] -and $native.url) {
                $verified = Get-VerifiedDependency $native $native.name
                $null = New-Item -ItemType Directory -Path $BuildRoot -Force
                $needsCopy = !(Test-Path -LiteralPath $nativeArchive)
                if (!$needsCopy) {
                    $currentHash = (Get-FileHash -LiteralPath $nativeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                    $needsCopy = ($currentHash -ne $native.sha256)
                }
                if ($needsCopy) {
                    Copy-Item -LiteralPath $verified -Destination $nativeArchive -Force
                }
            }
        }
        if (!(Test-Path -LiteralPath $nativeArchive) -or (Get-FileHash -LiteralPath $nativeArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $native.sha256) {
            throw "Native dependency integrity check failed: $($native.name)"
        }
    }
}

$pushed = $false
try {
    if ($InnoCompiler) {
        if (!(Test-Path -LiteralPath $InnoCompiler)) {
            throw "Inno Setup compiler not found: $InnoCompiler"
        }
        $InnoCompiler = (Resolve-Path -LiteralPath $InnoCompiler).ProviderPath
        $innoCompilerDir = Split-Path -Parent $InnoCompiler
        if (!(Test-Path -LiteralPath (Join-Path $innoCompilerDir 'ISCmplr.dll'))) {
            throw "Inno Setup compiler directory is missing ISCmplr.dll: $innoCompilerDir"
        }
    }
    Push-Location -LiteralPath $projectRoot
    $pushed = $true
    $null = Get-Command flutter -ErrorAction Stop
    $null = New-Item -ItemType Directory -Path $dependencyRoot -Force
    $versionMatch = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(([0-9]+\.[0-9]+\.[0-9]+)(?:-[0-9A-Za-z.-]+)?)\+([0-9]+)\s*$')
    if (!$versionMatch.Success) { throw 'pubspec.yaml must declare version as x.y.z[-prerelease]+build.' }
    $version = $versionMatch.Groups[1].Value
    $numericVersion = $versionMatch.Groups[2].Value
    $buildNumber = $versionMatch.Groups[3].Value
    $tag = "v$version"
    if ($env:GITHUB_REF_TYPE -eq 'tag' -and $env:GITHUB_REF_NAME -ne $tag) { throw 'Git tag does not match pubspec.yaml.' }
    $archive = Get-VerifiedDependency $manifest.ffmpeg "ffmpeg-$($manifest.ffmpeg.version).zip"
    $null = Get-VerifiedDependency $manifest.sqlite "sqlite3-$($manifest.sqlite.version).dll"
    $mpvArchive = Get-VerifiedDependency $manifest.mpv "mpv-full-$($manifest.mpv.version).7z"
    $windowsBuildRoot = Join-Path $projectRoot 'build/windows/x64'
    Assert-NativeArchivesVerified $manifest.nativeArchives $windowsBuildRoot -AllowStage
    $ffmpegRoot = Join-Path $dependencyRoot "ffmpeg-$($manifest.ffmpeg.version)-essentials_build"
    # Re-extract verified input so modified cached binaries cannot enter a package.
    Expand-Archive -LiteralPath $archive -DestinationPath $dependencyRoot -Force
    if ($PrepareOnly) { Write-Host "Media tools ready: $ffmpegRoot"; exit 0 }

    if (!$InnoCompiler) {
        $compilerRoot = Join-Path $dependencyRoot "inno-$($manifest.inno.version)"
        $InnoCompiler = Join-Path $compilerRoot 'ISCC.exe'
        $installer = Get-VerifiedDependency $manifest.inno "inno-$($manifest.inno.version).exe"
        if (!(Test-InnoCompilerIntegrity $compilerRoot $manifest.inno.sha256)) {
            $process = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CURRENTUSER','/NOICONS',('/DIR="' + $compilerRoot + '"')) -WindowStyle Hidden -PassThru -Wait
            if ($process.ExitCode -ne 0) { throw "Inno Setup preparation failed: $($process.ExitCode)" }
            Write-InnoCompilerMarker $compilerRoot $manifest.inno.sha256
        }
    }
    if (!(Test-Path -LiteralPath $InnoCompiler)) { throw "Inno Setup compiler not found: $InnoCompiler" }
    if (!$SkipBuild) {
        & flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows Release build failed.' }
    }
    Assert-NativeArchivesVerified $manifest.nativeArchives $windowsBuildRoot
    $release = Join-Path $projectRoot 'build/windows/x64/runner/Release'
    $requiredFiles = @(
        'doujin_audio.exe',
        'flutter_windows.dll',
        'data/app.so',
        'crispasr.dll',
        'ggml.dll',
        'ggml-base.dll',
        'ggml-cpu.dll',
        'libmpv-2.dll',
        'sqlite3.dll',
        'libEGL.dll',
        'libGLESv2.dll',
        'd3dcompiler_47.dll',
        'vk_swiftshader.dll',
        'vulkan-1.dll',
        'zlib.dll',
        'tools/ffmpeg.exe',
        'tools/ffprobe.exe'
    )
    foreach ($required in $requiredFiles) {
        if (!(Test-Path -LiteralPath (Join-Path $release $required))) { throw "Missing Release file: $required" }
    }
    $mpvVerifyDir = Join-Path $dependencyRoot "mpv-verify-$($manifest.mpv.version)"
    if (Test-Path -LiteralPath $mpvVerifyDir) { Remove-Item -LiteralPath $mpvVerifyDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $mpvVerifyDir -Force
    try {
        & tar.exe -xf $mpvArchive -C $mpvVerifyDir libmpv-2.dll
        if ($LASTEXITCODE -ne 0) { throw "Failed to extract libmpv-2.dll from verified archive: $mpvArchive" }
        $expectedMpvDll = Join-Path $mpvVerifyDir 'libmpv-2.dll'
        if (!(Test-Path -LiteralPath $expectedMpvDll)) { throw "Verified mpv archive missing libmpv-2.dll: $mpvArchive" }
        $expectedMpvHash = (Get-FileHash -LiteralPath $expectedMpvDll -Algorithm SHA256).Hash.ToLowerInvariant()
    } finally {
        if (Test-Path -LiteralPath $mpvVerifyDir) { Remove-Item -LiteralPath $mpvVerifyDir -Recurse -Force }
    }
    $actualMpvHash = (Get-FileHash -LiteralPath (Join-Path $release 'libmpv-2.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualMpvHash -ne $expectedMpvHash) {
        throw "Release libmpv-2.dll SHA256 mismatch (expected complete build $expectedMpvHash, got $actualMpvHash)."
    }
    $actualSqliteHash = (Get-FileHash -LiteralPath (Join-Path $release 'sqlite3.dll') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSqliteHash -ne $manifest.sqlite.sha256) {
        throw "Release sqlite3.dll SHA256 mismatch (expected $($manifest.sqlite.sha256), got $actualSqliteHash)."
    }
    $appRoot = Join-Path $distRoot 'app'
    Remove-StagingDirectory $appRoot
    if (Test-Path -LiteralPath $distRoot) {
        Get-ChildItem -LiteralPath $distRoot -File | Where-Object {
            $_.Name -like '*-setup.exe' -or $_.Name -like '*-setup.exe.sha256'
        } | Remove-Item -Force
    }
    $null = New-Item -ItemType Directory -Path $appRoot -Force
    Copy-Item -Path (Join-Path $release '*') -Destination $appRoot -Recurse -Force
    $toolRoot = Join-Path $appRoot 'tools'
    $null = New-Item -ItemType Directory -Path $toolRoot -Force
    foreach ($exe in @('ffmpeg.exe','ffprobe.exe')) {
        Copy-Item -LiteralPath (Join-Path $ffmpegRoot "bin/$exe") -Destination $toolRoot -Force
    }
    # App-local VC runtime makes the installation independent of development tools.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
    $vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (!$vsRoot) { throw 'Visual Studio Desktop development with C++ is required.' }
    $crt = Get-ChildItem -Path (Join-Path $vsRoot 'VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT') -Directory | Sort-Object FullName -Descending | Select-Object -First 1
    if (!$crt) { throw 'VC redistributable libraries were not found.' }
    Copy-Item -Path (Join-Path $crt.FullName '*.dll') -Destination $appRoot -Force
    $openMp = Get-ChildItem -Path (Join-Path $crt.Parent.FullName 'Microsoft.VC*.OpenMP/vcomp140.dll') -File | Select-Object -First 1
    if (!$openMp) { throw 'Visual C++ OpenMP runtime vcomp140.dll was not found.' }
    Copy-Item -LiteralPath $openMp.FullName -Destination $appRoot -Force
    $licenseRoot = Join-Path $appRoot 'licenses'
    $null = New-Item -ItemType Directory -Path $licenseRoot -Force
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot 'LICENSE') -Destination (Join-Path $licenseRoot 'FFmpeg-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $licenseRoot 'DoujinAudio-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_third_party.txt') -Destination $licenseRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_dependencies.json') -Destination $licenseRoot
    $assetName = "DoujinAudio-windows-x64-$tag-setup"
    & $InnoCompiler "/DAppVersion=$version" "/DNumericVersion=$numericVersion" "/DBuildNumber=$buildNumber" "/DAppSource=$appRoot" "/DOutputPath=$distRoot" "/DOutputName=$assetName" (Join-Path $PSScriptRoot 'windows_installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $output = Join-Path $distRoot "$assetName.exe"
    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$output.sha256", "$hash  $assetName.exe`n", [Text.Encoding]::ASCII)
    Write-Host "Installer: $output"
    Write-Host "Checksum:  $output.sha256"
} catch {
    Write-Error $_
    exit 1
} finally {
    if ($pushed) { Pop-Location }
}
