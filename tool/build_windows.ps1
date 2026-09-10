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
        Invoke-WebRequest -Uri $Dependency.url -OutFile $partial -UseBasicParsing
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

Push-Location -LiteralPath $projectRoot
try {
    $null = Get-Command flutter -ErrorAction Stop
    $null = New-Item -ItemType Directory -Path $dependencyRoot -Force
    $versionMatch = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$')
    if (!$versionMatch.Success) { throw 'pubspec.yaml must contain a stable version and build number.' }
    $version = $versionMatch.Groups[1].Value
    $buildNumber = $versionMatch.Groups[2].Value
    $tag = "v$version"
    if ($env:GITHUB_REF_TYPE -eq 'tag' -and $env:GITHUB_REF_NAME -ne $tag) { throw 'Git tag does not match pubspec.yaml.' }
    $archive = Get-VerifiedDependency $manifest.ffmpeg "ffmpeg-$($manifest.ffmpeg.version).zip"
    $null = Get-VerifiedDependency $manifest.sqlite "sqlite3-$($manifest.sqlite.version).dll"
    $ffmpegRoot = Join-Path $dependencyRoot "ffmpeg-$($manifest.ffmpeg.version)-essentials_build"
    # Re-extract verified input so modified cached binaries cannot enter a package.
    Expand-Archive -LiteralPath $archive -DestinationPath $dependencyRoot -Force
    if ($PrepareOnly) { Write-Host "Media tools ready: $ffmpegRoot"; exit 0 }

    if (!$InnoCompiler) {
        $compilerRoot = Join-Path $dependencyRoot "inno-$($manifest.inno.version)"
        $InnoCompiler = Join-Path $compilerRoot 'ISCC.exe'
        if (!(Test-Path -LiteralPath $InnoCompiler)) {
            $installer = Get-VerifiedDependency $manifest.inno "inno-$($manifest.inno.version).exe"
            $process = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/CURRENTUSER','/NOICONS',('/DIR="' + $compilerRoot + '"')) -WindowStyle Hidden -PassThru -Wait
            if ($process.ExitCode -ne 0) { throw "Inno Setup preparation failed: $($process.ExitCode)" }
        }
    }
    if (!(Test-Path -LiteralPath $InnoCompiler)) { throw "Inno Setup compiler not found: $InnoCompiler" }
    if (!$SkipBuild) {
        & flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows Release build failed.' }
    }
    $release = Join-Path $projectRoot 'build/windows/x64/runner/Release'
    foreach ($native in $manifest.nativeArchives) {
        $nativeArchive = Join-Path $projectRoot "build/windows/x64/$($native.name)"
        if (!(Test-Path -LiteralPath $nativeArchive) -or (Get-FileHash -LiteralPath $nativeArchive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $native.sha256) {
            throw "Native dependency integrity check failed: $($native.name)"
        }
    }
    foreach ($required in @('doujin_audio.exe','flutter_windows.dll','data/app.so')) {
        if (!(Test-Path -LiteralPath (Join-Path $release $required))) { throw "Missing Release file: $required" }
    }
    $appRoot = Join-Path $distRoot 'app'
    Remove-StagingDirectory $appRoot
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
    $licenseRoot = Join-Path $appRoot 'licenses'
    $null = New-Item -ItemType Directory -Path $licenseRoot -Force
    Copy-Item -LiteralPath (Join-Path $ffmpegRoot 'LICENSE') -Destination (Join-Path $licenseRoot 'FFmpeg-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'LICENSE') -Destination (Join-Path $licenseRoot 'DoujinAudio-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_third_party.txt') -Destination $licenseRoot
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows_dependencies.json') -Destination $licenseRoot
    $assetName = "DoujinAudio-windows-x64-$tag-setup"
    & $InnoCompiler "/DAppVersion=$version" "/DBuildNumber=$buildNumber" "/DAppSource=$appRoot" "/DOutputPath=$distRoot" "/DOutputName=$assetName" (Join-Path $PSScriptRoot 'windows_installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $output = Join-Path $distRoot "$assetName.exe"
    $hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$output.sha256", "$hash  $assetName.exe`n", [Text.Encoding]::ASCII)
    Write-Host "Installer: $output"
    Write-Host "Checksum:  $output.sha256"
} catch {
    Write-Error $_
    exit 1
} finally { Pop-Location }
