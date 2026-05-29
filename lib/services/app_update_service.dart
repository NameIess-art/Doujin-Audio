import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_cache_service.dart';
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
  static const MethodChannel _channel = MethodChannel(UpdateChannel.name);

  static Future<AppUpdateInfo> checkLatest() async {
    final currentVersion = await currentAppVersion();
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(latestReleaseApi));
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Nameless Audio updater',
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const HttpException('GitHub release request failed.');
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final tagName = (data['tag_name'] as String? ?? '').trim();
      final latestVersionName = _versionNameFromTag(tagName);
      final assets = (data['assets'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      final updateAsset = _selectUpdateAsset(assets);
      if (updateAsset == null) {
        throw const FormatException(
          'No update asset was found in the latest release.',
        );
      }
      final assetUrl = updateAsset['browser_download_url'] as String? ?? '';
      if (assetUrl.isEmpty) {
        throw const FormatException(
          'Update asset does not have a download URL.',
        );
      }
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersionName: latestVersionName,
        tagName: tagName,
        releaseName: data['name'] as String?,
        assetName:
            updateAsset['name'] as String? ??
            'NamelessAudio-$tagName${Platform.isWindows ? '.zip' : '.apk'}',
        assetUrl: assetUrl,
        releaseUrl:
            data['html_url'] as String? ??
            'https://github.com/$owner/$repo/releases/latest',
        publishedAt: DateTime.tryParse(data['published_at'] as String? ?? ''),
        isUpdateAvailable: _isNewerVersion(
          latestVersionName,
          currentVersion.versionName,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<AppVersionInfo> currentAppVersion() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        UpdateMethod.getAppVersion,
      );
      final versionName = raw?['versionName'] as String? ?? '0.0.0';
      final buildNumber = (raw?['buildNumber'] as num?)?.toInt() ?? 0;
      return AppVersionInfo(versionName: versionName, buildNumber: buildNumber);
    } catch (_) {
      return const AppVersionInfo(versionName: '0.9.71', buildNumber: 971);
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
    if (await file.exists()) {
      await file.delete();
    }

    final client = HttpClient();
    try {
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
      final sink = file.openWrite();
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
      await file.setLastModified(DateTime.now());
      await AppCacheService.enforceLimit();
      onProgress(1);
      return file;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> canInstallUnknownApps() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>(
            UpdateMethod.canInstallUnknownApps,
          ) ??
          true;
    } catch (_) {
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
    } catch (_) {
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
    await script.writeAsString(_windowsUpdateScript);

    try {
      await Process.start('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
        file.path,
        installDir,
        exePath,
        pid.toString(),
      ], mode: ProcessStartMode.detached);
      Timer(const Duration(milliseconds: 500), () => exit(0));
      return const UpdateInstallResult(ok: true, needsPermission: false);
    } catch (error) {
      return UpdateInstallResult(
        ok: false,
        needsPermission: false,
        message: error.toString(),
      );
    }
  }

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
    return base
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
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
  [Parameter(Mandatory=$true)][int]$AppProcessId
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $env:TEMP 'nameless_audio_windows_update.log'

function Write-UpdateLog([string]$Message) {
  $timestamp = Get-Date -Format o
  Add-Content -LiteralPath $logPath -Value "$timestamp $Message"
}

try {
  Write-UpdateLog "waiting pid=$AppProcessId"
  Wait-Process -Id $AppProcessId -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 400

  $staging = Join-Path $env:TEMP ("nameless_audio_update_" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  Write-UpdateLog "expanding $ZipPath to $staging"
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $staging -Force

  $exeName = Split-Path -Leaf $ExePath
  $payloadExe = Get-ChildItem -LiteralPath $staging -Filter $exeName -Recurse -File |
    Select-Object -First 1
  if ($null -eq $payloadExe) {
    throw "Cannot find $exeName inside update ZIP."
  }
  $payloadDir = $payloadExe.Directory.FullName
  Write-UpdateLog "copying $payloadDir to $InstallDir"
  Copy-Item -Path (Join-Path $payloadDir '*') -Destination $InstallDir -Recurse -Force

  Write-UpdateLog "restarting $ExePath"
  Start-Process -FilePath $ExePath -WorkingDirectory $InstallDir
  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  Write-UpdateLog 'update complete'
} catch {
  Write-UpdateLog ("update failed: " + $_.Exception.Message)
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show(
    "NL Audio update failed.`n`n$($_.Exception.Message)`n`nLog: $logPath",
    "NL Audio Updater"
  ) | Out-Null
}
''';
