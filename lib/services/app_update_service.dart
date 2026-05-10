import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

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
  static const MethodChannel _channel = MethodChannel('nameless_audio/update');

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
      final apkAsset = _selectApkAsset(assets);
      if (apkAsset == null) {
        throw const FormatException(
          'No APK asset was found in the latest release.',
        );
      }
      final assetUrl = apkAsset['browser_download_url'] as String? ?? '';
      if (assetUrl.isEmpty) {
        throw const FormatException('APK asset does not have a download URL.');
      }
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersionName: latestVersionName,
        tagName: tagName,
        releaseName: data['name'] as String?,
        assetName: apkAsset['name'] as String? ?? 'NamelessAudio-$tagName.apk',
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
        'getAppVersion',
      );
      final versionName = raw?['versionName'] as String? ?? '0.0.0';
      final buildNumber = (raw?['buildNumber'] as num?)?.toInt() ?? 0;
      return AppVersionInfo(versionName: versionName, buildNumber: buildNumber);
    } catch (_) {
      return const AppVersionInfo(versionName: '0.8.1', buildNumber: 801);
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
        throw const HttpException('APK download failed.');
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
      onProgress(1);
      return file;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> canInstallUnknownApps() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallUnknownApps') ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> openInstallPermissionSettings() async {
    try {
      return await _channel.invokeMethod<bool>(
            'openInstallPermissionSettings',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<UpdateInstallResult> installApk(File file) async {
    final raw = await _channel.invokeMapMethod<String, Object?>('installApk', {
      'path': file.path,
    });
    return UpdateInstallResult(
      ok: raw?['ok'] == true,
      needsPermission: raw?['needsPermission'] == true,
      message: raw?['message'] as String?,
    );
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
    final cleaned = value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (cleaned.isEmpty) return 'NamelessAudio-update.apk';
    return cleaned.endsWith('.apk') ? cleaned : '$cleaned.apk';
  }
}
