import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_cache_service.dart';
import 'app_log_service.dart';
import 'path_display.dart';
import 'platform_channels.dart';

class AppVersionInfo {
  const AppVersionInfo({required this.versionName, required this.buildNumber});

  final String versionName;
  final int buildNumber;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersionName,
    required this.tagName,
    required this.assetName,
    required this.assetUrl,
    required this.checksumAssetUrl,
    required this.releaseUrl,
    required this.isUpdateAvailable,
    this.releaseName,
    this.publishedAt,
  });

  final AppVersionInfo currentVersion;
  final String latestVersionName;
  final String tagName;
  final String? releaseName;
  final String assetName;
  final String assetUrl;
  final String? checksumAssetUrl;
  final String releaseUrl;
  final DateTime? publishedAt;
  final bool isUpdateAvailable;
}

class UpdateInstallResult {
  const UpdateInstallResult({
    required this.ok,
    required this.needsPermission,
    this.message,
  });

  final bool ok;
  final bool needsPermission;
  final String? message;
}

class AppUpdateService {
  AppUpdateService._();

  static const String owner = 'NameIess-art';
  static const String repo = 'nameless-audio';
  static const String latestReleaseApi =
      'https://api.github.com/repos/$owner/$repo/releases/latest';
  static const String latestReleasePage =
      'https://github.com/$owner/$repo/releases/latest';
  static const String releasesPage = 'https://github.com/$owner/$repo/releases';
  static const MethodChannel _channel = MethodChannel(UpdateChannel.name);

  static Future<AppUpdateInfo> checkLatest() async {
    final currentVersion = await currentAppVersion();
    final client = HttpClient();
    try {
      try {
        return await _checkLatestFromApi(client, currentVersion);
      } catch (error, stackTrace) {
        AppLogService.warning(
          'update_api_check_failed_falling_back_to_release_page',
          error: error,
          stackTrace: stackTrace,
        );
        return await _checkLatestFromReleasePage(client, currentVersion);
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<AppUpdateInfo> _checkLatestFromApi(
    HttpClient client,
    AppVersionInfo currentVersion,
  ) async {
    final request = await client.getUrl(Uri.parse(latestReleaseApi));
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'Nameless Audio updater');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const HttpException('GitHub release request failed.');
    }
    final data = jsonDecode(body) as Map<String, dynamic>;
    final assets = (data['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    return _buildUpdateInfo(
      currentVersion: currentVersion,
      tagName: (data['tag_name'] as String? ?? '').trim(),
      releaseName: data['name'] as String?,
      releaseUrl:
          data['html_url'] as String? ??
          'https://github.com/$owner/$repo/releases/latest',
      publishedAt: DateTime.tryParse(data['published_at'] as String? ?? ''),
      assets: assets,
    );
  }

  static Future<AppUpdateInfo> _checkLatestFromReleasePage(
    HttpClient client,
    AppVersionInfo currentVersion,
  ) async {
    final tagName = await _resolveLatestReleaseTag(client);
    final assets = await _fetchExpandedReleaseAssets(client, tagName);
    return _buildUpdateInfo(
      currentVersion: currentVersion,
      tagName: tagName,
      releaseName: 'Nameless Audio $tagName',
      releaseUrl: 'https://github.com/$owner/$repo/releases/tag/$tagName',
      assets: assets,
    );
  }

  static Future<String> _resolveLatestReleaseTag(HttpClient client) async {
    final request = await client.getUrl(Uri.parse(latestReleasePage));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'Nameless Audio updater');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final location = response.headers.value(HttpHeaders.locationHeader);
    if (location != null && location.isNotEmpty) {
      final tagName = _tagNameFromReleaseUri(
        Uri.parse(latestReleasePage).resolve(location),
      );
      if (tagName != null) return tagName;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final tagName = _tagNameFromReleaseHtml(body);
      if (tagName != null) return tagName;
    }
    throw const HttpException('GitHub latest release page request failed.');
  }

  static Future<List<Map<String, dynamic>>> _fetchExpandedReleaseAssets(
    HttpClient client,
    String tagName,
  ) async {
    final uri = Uri.parse('$releasesPage/expanded_assets/$tagName');
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'Nameless Audio updater');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const HttpException('GitHub release asset page request failed.');
    }
    final assets = _parseExpandedReleaseAssets(body);
    if (assets.isEmpty) {
      throw const FormatException('No release assets were found.');
    }
    return assets;
  }

  static AppUpdateInfo _buildUpdateInfo({
    required AppVersionInfo currentVersion,
    required String tagName,
    required String releaseUrl,
    required List<Map<String, dynamic>> assets,
    String? releaseName,
    DateTime? publishedAt,
  }) {
    final latestVersionName = _versionNameFromTag(tagName);
    final updateAsset = _selectUpdateAsset(assets);
    if (updateAsset == null) {
      throw const FormatException(
        'No update asset was found in the latest release.',
      );
    }
    final assetUrl = updateAsset['browser_download_url'] as String? ?? '';
    if (assetUrl.isEmpty) {
      throw const FormatException('Update asset does not have a download URL.');
    }
    final assetName =
        updateAsset['name'] as String? ??
        'NamelessAudio-$tagName${Platform.isWindows ? '.zip' : '.apk'}';
    final checksumAsset = assets.cast<Map<String, dynamic>?>().firstWhere(
      (asset) => asset?['name'] == '$assetName.sha256',
      orElse: () => null,
    );
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersionName: latestVersionName,
      tagName: tagName,
      releaseName: releaseName,
      assetName: assetName,
      assetUrl: assetUrl,
      checksumAssetUrl: checksumAsset?['browser_download_url'] as String?,
      releaseUrl: releaseUrl,
      publishedAt: publishedAt,
      isUpdateAvailable: _isNewerVersion(
        latestVersionName,
        currentVersion.versionName,
      ),
    );
  }

  static Future<AppVersionInfo> currentAppVersion() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        UpdateMethod.getAppVersion,
      );
      final versionName = raw?['versionName'] as String? ?? 'unknown';
      final buildNumber = (raw?['buildNumber'] as num?)?.toInt() ?? 0;
      return AppVersionInfo(versionName: versionName, buildNumber: buildNumber);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'app_version_channel_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const AppVersionInfo(versionName: 'unknown', buildNumber: 0);
    }
  }

  static Future<File> downloadUpdate(
    AppUpdateInfo info, {
    required void Function(double? progress) onProgress,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final updateDir = Directory(path.join(tempDir.path, 'updates'));
    if (!await updateDir.exists()) {
      await updateDir.create(recursive: true);
    }
    final file = File(path.join(updateDir.path, _safeFileName(info.assetName)));
    final partialFile = File('${file.path}.part');
    if (await file.exists()) {
      await file.delete();
    }
    if (await partialFile.exists()) {
      await partialFile.delete();
    }

    final client = HttpClient();
    try {
      final checksumUrl = info.checksumAssetUrl;
      if (checksumUrl == null || checksumUrl.isEmpty) {
        throw const FormatException(
          'The release does not provide a checksum for this update.',
        );
      }
      final expectedChecksum = await _downloadExpectedChecksum(
        client,
        checksumUrl,
        info.assetName,
      );
      final request = await client.getUrl(Uri.parse(info.assetUrl));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Nameless Audio updater',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const HttpException('Update download failed.');
      }

      final total = response.contentLength;
      var received = 0;
      final sink = partialFile.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          if (total > 0) {
            onProgress((received / total).clamp(0.0, 1.0));
          } else {
            onProgress(null);
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      final actualChecksum = await sha256.bind(partialFile.openRead()).first;
      if (actualChecksum.toString() != expectedChecksum) {
        throw const FormatException('Update checksum verification failed.');
      }
      await partialFile.rename(file.path);
      await file.setLastModified(DateTime.now());
      await AppCacheService.enforceLimit();
      onProgress(1);
      return file;
    } catch (error) {
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static Future<String> _downloadExpectedChecksum(
    HttpClient client,
    String checksumUrl,
    String assetName,
  ) async {
    final request = await client.getUrl(Uri.parse(checksumUrl));
    request.headers.set(HttpHeaders.userAgentHeader, 'Nameless Audio updater');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const HttpException('Update checksum download failed.');
    }
    return parseExpectedChecksum(body, assetName);
  }

  @visibleForTesting
  static String parseExpectedChecksum(String body, String assetName) {
    final trimmed = body.trim();
    final match = RegExp(
      r'^([a-fA-F0-9]{64})(?:\s+\*?.+)?$',
    ).firstMatch(trimmed);
    if (match == null) {
      throw const FormatException('Update checksum file is invalid.');
    }
    final listedName = trimmed.split(RegExp(r'\s+')).skip(1).join(' ');
    if (listedName.isNotEmpty &&
        listedName.replaceFirst('*', '') != assetName) {
      throw const FormatException(
        'Update checksum does not describe the selected asset.',
      );
    }
    return match.group(1)!.toLowerCase();
  }

  static Future<bool> canInstallUnknownApps() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>(
            UpdateMethod.canInstallUnknownApps,
          ) ??
          true;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'unknown_app_install_permission_check_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return true;
    }
  }

  static Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            UpdateMethod.openInstallPermissionSettings,
          ) ??
          false;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'open_install_permission_settings_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static Future<bool> openReleasePage(String url) async {
    try {
      if (Platform.isAndroid) {
        return await _channel.invokeMethod<bool>(UpdateMethod.openReleasePage, {
              'url': url,
            }) ??
            false;
      }
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url]);
        return true;
      }
      await Process.start('xdg-open', [url]);
      return true;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'open_release_page_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static Future<UpdateInstallResult> installUpdate(File file) async {
    if (Platform.isWindows) return _installWindowsZip(file);
    final raw = await _channel.invokeMapMethod<String, Object?>(
      UpdateMethod.installApk,
      {'path': file.path},
    );
    return UpdateInstallResult(
      ok: raw?['ok'] == true,
      needsPermission: raw?['needsPermission'] == true,
      message: raw?['message'] as String?,
    );
  }

  static Map<String, dynamic>? _selectUpdateAsset(
    List<Map<String, dynamic>> assets,
  ) {
    if (Platform.isWindows) return _selectWindowsZipAsset(assets);
    return _selectApkAsset(assets);
  }

  static Map<String, dynamic>? _selectApkAsset(
    List<Map<String, dynamic>> assets,
  ) {
    final apkAssets = assets
        .where((asset) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          return name.endsWith('.apk');
        })
        .toList(growable: false);
    if (apkAssets.isEmpty) return null;
    apkAssets.sort((left, right) {
      int score(Map<String, dynamic> asset) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        if (name.contains('arm64')) return 0;
        if (name.contains('release')) return 1;
        return 2;
      }

      return score(left).compareTo(score(right));
    });
    return apkAssets.first;
  }

  static Map<String, dynamic>? _selectWindowsZipAsset(
    List<Map<String, dynamic>> assets,
  ) {
    final zipAssets = assets
        .where((asset) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          return name.endsWith('.zip');
        })
        .toList(growable: false);
    if (zipAssets.isEmpty) return null;
    zipAssets.sort((left, right) {
      int score(Map<String, dynamic> asset) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        var score = 10;
        if (name.contains('windows')) score -= 6;
        if (name.contains('win')) score -= 4;
        if (name.contains('x64') || name.contains('amd64')) score -= 2;
        if (name.contains('symbols') || name.contains('debug')) score += 6;
        return score;
      }

      return score(left).compareTo(score(right));
    });
    return zipAssets.first;
  }

  static List<Map<String, dynamic>> _parseExpandedReleaseAssets(String html) {
    final links = RegExp(
      r'href="([^"]*/releases/download/[^"]+)"',
    ).allMatches(html);
    final assets = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final link in links) {
      final rawHref = link.group(1)?.replaceAll('&amp;', '&') ?? '';
      if (rawHref.isEmpty || !seen.add(rawHref)) continue;
      final uri = Uri.parse('https://github.com').resolve(rawHref);
      final name = uri.pathSegments.isNotEmpty
          ? Uri.decodeComponent(uri.pathSegments.last)
          : '';
      if (name.isEmpty) continue;
      assets.add({'name': name, 'browser_download_url': uri.toString()});
    }
    return assets;
  }

  static String? _tagNameFromReleaseHtml(String html) {
    final canonical = RegExp(
      r'<link[^>]+rel="canonical"[^>]+href="([^"]+)"',
    ).firstMatch(html);
    if (canonical != null) {
      final tagName = _tagNameFromReleaseUri(Uri.parse(canonical.group(1)!));
      if (tagName != null) return tagName;
    }
    final releaseLink = RegExp(
      r'''/releases/tag/([^"'<>\s]+)''',
    ).firstMatch(html);
    if (releaseLink == null) return null;
    return Uri.decodeComponent(releaseLink.group(1)!).trim();
  }

  static String? _tagNameFromReleaseUri(Uri uri) {
    final segments = uri.pathSegments;
    final tagIndex = segments.indexOf('tag');
    if (tagIndex < 0 || tagIndex + 1 >= segments.length) return null;
    final tagName = Uri.decodeComponent(segments[tagIndex + 1]).trim();
    return tagName.isEmpty ? null : tagName;
  }

  static Future<UpdateInstallResult> _installWindowsZip(File file) async {
    if (!await file.exists() || await file.length() <= 0) {
      return const UpdateInstallResult(
        ok: false,
        needsPermission: false,
        message: 'Update ZIP does not exist.',
      );
    }

    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final tempDir = await getTemporaryDirectory();
    final script = File(
      path.join(
        tempDir.path,
        'nameless_audio_windows_update_${DateTime.now().millisecondsSinceEpoch}.ps1',
      ),
    );
    final readyFile = File('${script.path}.ready');
    await script.writeAsString(_windowsUpdateScript, flush: true);

    try {
      if (await readyFile.exists()) await readyFile.delete();
      await Process.start(_windowsPowerShellExecutable(), [
        '-WindowStyle',
        'Hidden',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-STA',
        '-File',
        script.path,
        file.path,
        installDir,
        exePath,
        pid.toString(),
        readyFile.path,
      ], mode: ProcessStartMode.detached);

      final readyResult = await _waitForWindowsUpdaterReady(readyFile);
      if (readyResult != null) {
        return UpdateInstallResult(
          ok: false,
          needsPermission: false,
          message: readyResult,
        );
      }
      Timer(const Duration(milliseconds: 500), () => exit(0));
      return const UpdateInstallResult(ok: true, needsPermission: false);
    } catch (error, stackTrace) {
      AppLogService.error(
        'windows_update_install_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return UpdateInstallResult(
        ok: false,
        needsPermission: false,
        message: error.toString(),
      );
    }
  }

  static Future<String?> _waitForWindowsUpdaterReady(File readyFile) async {
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      if (await readyFile.exists()) {
        final status = (await readyFile.readAsString()).trim();
        if (status == 'ready') return null;
        if (status.startsWith('error:')) {
          return status.substring('error:'.length).trim();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return 'Windows updater did not become ready in time.';
  }

  static String _windowsPowerShellExecutable() {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final powerShell = path.join(
      systemRoot,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    return File(powerShell).existsSync() ? powerShell : 'powershell.exe';
  }

  @visibleForTesting
  static String get windowsUpdateScriptForTesting => _windowsUpdateScript;

  static String _versionNameFromTag(String tagName) {
    final normalized = tagName.trim();
    if (normalized.startsWith('v') || normalized.startsWith('V')) {
      return normalized.substring(1);
    }
    return normalized;
  }

  static bool _isNewerVersion(String latest, String current) {
    final latestParts = _versionParts(latest);
    final currentParts = _versionParts(current);
    final length = latestParts.length > currentParts.length
        ? latestParts.length
        : currentParts.length;
    for (var i = 0; i < length; i++) {
      final left = i < latestParts.length ? latestParts[i] : 0;
      final right = i < currentParts.length ? currentParts[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }

  static List<int> _versionParts(String value) {
    final base = value.split('+').first;
    final parts = base
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    if (parts.length == 3 &&
        parts[0] == 0 &&
        parts[1] == 9 &&
        parts[2] >= 70 &&
        parts[2] < 80) {
      return [0, 9, 7, parts[2] - 70];
    }
    return parts;
  }

  static String _safeFileName(String value) {
    final extension = path.extension(value).toLowerCase();
    final updateExtension = extension == '.zip' || extension == '.apk'
        ? extension
        : (Platform.isWindows ? '.zip' : '.apk');
    final cleaned = PathDisplay.safeFileName(
      value,
      replacement: '_',
      collapseWhitespace: false,
      fallback: 'NamelessAudio-update',
    );
    return cleaned.toLowerCase().endsWith(updateExtension)
        ? cleaned
        : '$cleaned$updateExtension';
  }
}

const String _windowsUpdateScript = r'''
param(
  [Parameter(Mandatory=$true)][string]$ZipPath,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [Parameter(Mandatory=$true)][string]$ExePath,
  [Parameter(Mandatory=$true)][int]$AppProcessId,
  [Parameter(Mandatory=$true)][string]$ReadyPath,
  [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $env:TEMP 'nameless_audio_windows_update.log'
$staging = $null

function Write-UpdateLog([string]$Message) {
  $timestamp = Get-Date -Format o
  Add-Content -LiteralPath $logPath -Value "$timestamp $Message"
}

function Wait-AppExit {
  Write-UpdateLog "waiting pid=$AppProcessId"
  $deadline = (Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    $process = Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) {
      Start-Sleep -Seconds 2
      return
    }
    Start-Sleep -Milliseconds 500
  }
  throw 'The application did not exit in time for the update.'
}

function Test-InstallDirWritable {
  try {
    $probe = Join-Path $InstallDir ('.nameless_audio_update_write_test_' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Set-Content -LiteralPath $probe -Value 'test' -Encoding UTF8
    Remove-Item -LiteralPath $probe -Force
    return $true
  } catch {
    return $false
  }
}

function Quote-Argument([string]$Value) {
  return '"' + ($Value -replace '"', '\"') + '"'
}

function Start-ElevatedUpdater {
  $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $powerShell)) {
    $powerShell = 'powershell.exe'
  }
  $args = @(
    '-WindowStyle',
    'Hidden',
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-STA',
    '-File',
    (Quote-Argument $PSCommandPath),
    (Quote-Argument $ZipPath),
    (Quote-Argument $InstallDir),
    (Quote-Argument $ExePath),
    $AppProcessId,
    (Quote-Argument $ReadyPath),
    '-Elevated'
  ) -join ' '
  Write-UpdateLog 'requesting elevated updater'
  Start-Process -FilePath $powerShell -ArgumentList $args -Verb RunAs -WorkingDirectory $InstallDir
}

function Show-Failure([string]$Message) {
  try {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
      "Nameless Audio update failed.`n`n$Message`n`nLog: $logPath",
      'Nameless Audio Updater',
      'OK',
      'Error'
    ) | Out-Null
  } catch {
    Start-Process -FilePath 'notepad.exe' -ArgumentList (Quote-Argument $logPath) -ErrorAction SilentlyContinue
  }
}

try {
  Write-UpdateLog "start zip=$ZipPath install=$InstallDir exe=$ExePath pid=$AppProcessId elevated=$Elevated"
  $staging = Join-Path $env:TEMP ("nameless_audio_update_" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  Write-UpdateLog "expanding $ZipPath to $staging"
  
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $staging)

  $exeName = Split-Path -Leaf $ExePath
  $payloadExe = Get-ChildItem -LiteralPath $staging -Filter $exeName -Recurse -File |
    Select-Object -First 1
  if ($null -eq $payloadExe) {
    throw "Cannot find $exeName inside update ZIP."
  }
  $payloadDir = $payloadExe.Directory.FullName

  if (-not (Test-InstallDirWritable)) {
    if (-not $Elevated) {
      Start-ElevatedUpdater
      Write-UpdateLog 'elevated updater started'
      exit 0
    }
    throw "Cannot write to install directory: $InstallDir"
  }

  Set-Content -LiteralPath $ReadyPath -Value 'ready' -Encoding ASCII
  Write-UpdateLog 'payload verified; waiting for application exit'
  Wait-AppExit

  Write-UpdateLog "copying $payloadDir to $InstallDir with robocopy"
  & robocopy $payloadDir $InstallDir /E /COPY:DAT /R:15 /W:1 /NFL /NDL /NP | Out-Null
  $robocopyExitCode = $LASTEXITCODE
  Write-UpdateLog "robocopy exit code=$robocopyExitCode"
  if ($robocopyExitCode -ge 8) {
    throw "File copy failed with robocopy exit code $robocopyExitCode."
  }

  if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "Updated executable is missing: $ExePath"
  }
  Write-UpdateLog "restarting $ExePath"
  Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir
  Write-UpdateLog 'update complete'
} catch {
  Write-UpdateLog ("update failed: " + $_.Exception.Message)
  Set-Content -LiteralPath $ReadyPath -Value ("error:" + $_.Exception.Message) -Encoding UTF8 -ErrorAction SilentlyContinue
  Show-Failure $_.Exception.Message
} finally {
  if ($null -ne $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
}
''';
