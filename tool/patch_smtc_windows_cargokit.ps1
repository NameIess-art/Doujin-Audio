param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$packageConfigPath = Join-Path $projectRoot '.dart_tool/package_config.json'

if (-not (Test-Path -LiteralPath $packageConfigPath -PathType Leaf)) {
  throw "Missing .dart_tool/package_config.json. Run 'flutter pub get' first."
}

$packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw | ConvertFrom-Json
$smtcPackage = $packageConfig.packages | Where-Object { $_.name -eq 'smtc_windows' } | Select-Object -First 1
if (-not $smtcPackage) {
  Write-Host 'smtc_windows is not in package_config.json; no patch needed.'
  exit 0
}

$rootUri = [string]$smtcPackage.rootUri
if ($rootUri.StartsWith('file:///')) {
  $packageRoot = [System.Uri]$rootUri
  $packageRootPath = $packageRoot.LocalPath
} elseif ([System.IO.Path]::IsPathRooted($rootUri)) {
  $packageRootPath = $rootUri
} else {
  $packageRootPath = Join-Path (Split-Path -Parent $packageConfigPath) $rootUri
}

$resolveScriptPath = Join-Path $packageRootPath 'cargokit/cmake/resolve_symlinks.ps1'
if (-not (Test-Path -LiteralPath $resolveScriptPath -PathType Leaf)) {
  throw "smtc_windows cargokit script not found: $resolveScriptPath"
}

$script = Get-Content -LiteralPath $resolveScriptPath -Raw
$patched = $script.Replace('Get-Item $realPath', 'Get-Item -Force $realPath')
if ($patched -eq $script) {
  Write-Host "smtc_windows cargokit symlink resolver already patched: $resolveScriptPath"
  exit 0
}

Set-Content -LiteralPath $resolveScriptPath -Value $patched -Encoding utf8NoBOM
Write-Host "Patched smtc_windows cargokit symlink resolver: $resolveScriptPath"
