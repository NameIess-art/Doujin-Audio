import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pub_semver/pub_semver.dart' as semver;

import 'app_cache_service.dart';
import '../../../core/errors/native_result.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/path_display.dart';
import '../../../core/platform/update_platform_service.dart';

export 'app_update_models.dart';

import 'app_update_models.dart';

part 'app_update_github_models.dart';

class AppUpdateService {
  AppUpdateService({
    UpdatePlatformService? platform,
    HttpClient Function()? httpClientFactory,
    Future<Directory> Function()? temporaryDirectoryProvider,
    DateTime Function()? clock,
  }) : _platform = platform ?? UpdatePlatformService(),
       _httpClientFactory = httpClientFactory ?? (() => HttpClient()),
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory,
       _clock = clock ?? DateTime.now;

  static const String owner = 'NameIess-art';
  static const String repo = 'nameless-audio';
  static const ReleaseChannelConfig releaseChannel =
      ReleaseChannelConfig.stable;
  static const String releasesApi =
      'https://api.github.com/repos/$owner/$repo/releases?per_page=30';
  static const String latestReleasePage =
      'https://github.com/$owner/$repo/releases/latest';
  static const String repositoryPage = 'https://github.com/$owner/$repo';
  static const String releasesPage = 'https://github.com/$owner/$repo/releases';
  final UpdatePlatformService _platform;
  final HttpClient Function() _httpClientFactory;
  final Future<Directory> Function() _temporaryDirectoryProvider;
  final DateTime Function() _clock;
  String? _activeDownloadIdentity;
  Future<File>? _activeDownload;
  final Set<void Function(double? progress)> _downloadListeners =
      <void Function(double? progress)>{};
  final Map<String, Future<UpdateInstallResult>> _activeInstalls =
      <String, Future<UpdateInstallResult>>{};

  Future<AppUpdateInfo> checkLatest() async {
    final currentVersion = await currentAppVersion();
    final client = _httpClientFactory();
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

  Future<AppUpdateInfo> _checkLatestFromApi(
    HttpClient client,
    AppVersionInfo currentVersion,
  ) async {
    final request = await client.getUrl(Uri.parse(releasesApi));
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
    final decoded = jsonDecode(body);
    if (decoded is! List) {
      throw const FormatException('GitHub releases response is not a list.');
    }
    final releases = decoded
        .map(_GitHubRelease.fromJson)
        .whereType<_GitHubRelease>()
        .toList(growable: false);
    final compatibleRelease = _selectCompatibleRelease(
      releases,
      currentVersion,
    );
    if (compatibleRelease == null) {
      return _noCompatibleRelease(currentVersion);
    }
    return _buildUpdateInfo(
      currentVersion: currentVersion,
      tagName: compatibleRelease.tagName,
      releaseName: compatibleRelease.name,
      releaseUrl: compatibleRelease.htmlUrl,
      publishedAt: compatibleRelease.publishedAt,
      assets: compatibleRelease.assets,
    );
  }

  Future<AppUpdateInfo> _checkLatestFromReleasePage(
    HttpClient client,
    AppVersionInfo currentVersion,
  ) async {
    final tagName = await _resolveLatestReleaseTag(client);
    if (!_isCompatibleTag(tagName, currentVersion)) {
      return _noCompatibleRelease(currentVersion);
    }
    final assets = await _fetchExpandedReleaseAssets(client, tagName);
    return _buildUpdateInfo(
      currentVersion: currentVersion,
      tagName: tagName,
      releaseName: 'Nameless Audio $tagName',
      releaseUrl: Uri.parse(
        'https://github.com/$owner/$repo/releases/tag/$tagName',
      ),
      assets: assets,
    );
  }

  static AppUpdateInfo _noCompatibleRelease(AppVersionInfo currentVersion) {
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersionName: currentVersion.versionName,
      tagName: '',
      assetName: null,
      assetUrl: null,
      checksumAssetUrl: null,
      releaseUrl: releasesPage,
      isUpdateAvailable: false,
      status: AppUpdateStatus.noCompatibleRelease,
    );
  }

  static _GitHubRelease? _selectCompatibleRelease(
    List<_GitHubRelease> releases,
    AppVersionInfo currentVersion,
  ) {
    final candidates = releases
        .where((release) {
          if (release.isDraft) return false;
          final tagName = release.tagName;
          if (!_isCompatibleTag(tagName, currentVersion)) return false;
          final version = _parseVersionFromTag(tagName);
          if (version == null) return false;
          final current = _parseVersion(currentVersion.versionName);
          final currentIsPrerelease = current?.isPreRelease == true;
          if (!currentIsPrerelease && version.isPreRelease) return false;
          if (!currentIsPrerelease && release.isPrerelease) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      final leftVersion = _parseVersionFromTag(left.tagName);
      final rightVersion = _parseVersionFromTag(right.tagName);
      if (leftVersion == null && rightVersion == null) return 0;
      if (leftVersion == null) return 1;
      if (rightVersion == null) return -1;
      return rightVersion.compareTo(leftVersion);
    });
    return candidates.first;
  }

  @visibleForTesting
  static Map<String, dynamic>? selectCompatibleReleaseForTesting(
    List<Map<String, dynamic>> releases,
    AppVersionInfo currentVersion,
  ) {
    return _selectCompatibleRelease(
      releases
          .map(_GitHubRelease.fromJson)
          .whereType<_GitHubRelease>()
          .toList(growable: false),
      currentVersion,
    )?.toJson();
  }

  @visibleForTesting
  static AppUpdateInfo buildUpdateInfoForTesting({
    required AppVersionInfo currentVersion,
    required String tagName,
    required String releaseUrl,
    required List<Map<String, dynamic>> assets,
    String? releaseName,
    DateTime? publishedAt,
  }) {
    final releaseUri = _parseGitHubWebUri(releaseUrl);
    if (releaseUri == null) {
      throw ArgumentError.value(releaseUrl, 'releaseUrl', 'Invalid web URL.');
    }
    return _buildUpdateInfo(
      currentVersion: currentVersion,
      tagName: tagName,
      releaseUrl: releaseUri,
      assets: assets
          .map(_GitHubAsset.fromJson)
          .whereType<_GitHubAsset>()
          .toList(growable: false),
      releaseName: releaseName,
      publishedAt: publishedAt,
    );
  }

  static bool _isCompatibleTag(String tagName, AppVersionInfo currentVersion) {
    final version = _parseVersionFromTag(tagName);
    if (version == null || version.major != releaseChannel.major) {
      return false;
    }
    final current = _parseVersion(currentVersion.versionName);
    final currentIsPrerelease = current?.isPreRelease == true;
    return currentIsPrerelease || !version.isPreRelease;
  }

  Future<String> _resolveLatestReleaseTag(HttpClient client) async {
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

  Future<List<_GitHubAsset>> _fetchExpandedReleaseAssets(
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
    required Uri releaseUrl,
    required List<_GitHubAsset> assets,
    String? releaseName,
    DateTime? publishedAt,
  }) {
    final latestVersionName = _versionNameFromTag(tagName);
    final updateAsset = _selectUpdateAsset(assets);
    if (updateAsset == null) {
      return AppUpdateInfo(
        currentVersion: currentVersion,
        latestVersionName: latestVersionName,
        tagName: tagName,
        releaseName: releaseName,
        assetName: null,
        assetUrl: null,
        checksumAssetUrl: null,
        releaseUrl: releaseUrl.toString(),
        publishedAt: publishedAt,
        isUpdateAvailable: false,
        status: AppUpdateStatus.missingAsset,
      );
    }
    final assetUrl = updateAsset.browserDownloadUrl.toString();
    final assetName = updateAsset.name;
    final checksumAsset = assets.cast<_GitHubAsset?>().firstWhere(
      (asset) => asset?.name == '$assetName.sha256',
      orElse: () => null,
    );
    final newer = _isNewerVersion(
      latestVersionName,
      currentVersion.versionName,
    );
    final status = !newer
        ? AppUpdateStatus.upToDate
        : checksumAsset == null
        ? AppUpdateStatus.missingChecksum
        : AppUpdateStatus.updateAvailable;
    return AppUpdateInfo(
      currentVersion: currentVersion,
      latestVersionName: latestVersionName,
      tagName: tagName,
      releaseName: releaseName,
      assetName: assetName,
      assetUrl: assetUrl,
      checksumAssetUrl: checksumAsset?.browserDownloadUrl.toString(),
      releaseUrl: releaseUrl.toString(),
      publishedAt: publishedAt,
      isUpdateAvailable: status == AppUpdateStatus.updateAvailable,
      status: status,
    );
  }

  Future<AppVersionInfo> currentAppVersion() async {
    final result = await _platform.getAppVersion();
    _logNativeFailure('getAppVersion', result);
    final version = result.valueOrNull;
    return version == null
        ? const AppVersionInfo(versionName: 'unknown', buildNumber: 0)
        : AppVersionInfo(
            versionName: version.versionName,
            buildNumber: version.buildNumber,
          );
  }

  Future<File> downloadUpdate(
    AppUpdateInfo info, {
    required void Function(double? progress) onProgress,
  }) async {
    final identity =
        '${info.assetUrl}|${info.checksumAssetUrl}|${info.assetName}';
    final active = _activeDownload;
    if (active != null) {
      if (_activeDownloadIdentity == identity) {
        _downloadListeners.add(onProgress);
        try {
          return await active;
        } finally {
          _downloadListeners.remove(onProgress);
        }
      }
      try {
        await active;
      } catch (_) {
        // A different failed download must still release the single-flight slot.
      }
      return downloadUpdate(info, onProgress: onProgress);
    }

    _activeDownloadIdentity = identity;
    _downloadListeners.add(onProgress);
    void broadcast(double? progress) {
      for (final listener in List<void Function(double?)>.from(
        _downloadListeners,
      )) {
        listener(progress);
      }
    }

    late final Future<File> future;
    future = _downloadUpdateOnce(info, onProgress: broadcast).whenComplete(() {
      if (identical(_activeDownload, future)) {
        _activeDownload = null;
        _activeDownloadIdentity = null;
        _downloadListeners.clear();
      }
    });
    _activeDownload = future;
    try {
      return await future;
    } finally {
      _downloadListeners.remove(onProgress);
    }
  }

  Future<File> _downloadUpdateOnce(
    AppUpdateInfo info, {
    required void Function(double? progress) onProgress,
  }) async {
    final tempDir = await _temporaryDirectoryProvider();
    final assetName = info.assetName;
    final assetUrl = info.assetUrl;
    if (assetName == null || assetUrl == null || !info.canDownload) {
      throw const FormatException('No downloadable update is available.');
    }
    final updateDir = Directory(path.join(tempDir.path, 'updates'));
    if (!await updateDir.exists()) {
      await updateDir.create(recursive: true);
    }
    final file = File(path.join(updateDir.path, _safeFileName(assetName)));
    final partialFile = File('${file.path}.part');
    final cacheLease = AppCacheService.protectPaths(<String>[
      file.path,
      partialFile.path,
    ]);
    final client = HttpClient();
    try {
      if (await file.exists()) {
        await file.delete();
      }
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      final checksumUrl = info.checksumAssetUrl;
      if (checksumUrl == null || checksumUrl.isEmpty) {
        throw const FormatException(
          'The release does not provide a checksum for this update.',
        );
      }
      final expectedChecksum = await _downloadExpectedChecksum(
        client,
        checksumUrl,
        assetName,
      );
      final request = await client.getUrl(Uri.parse(assetUrl));
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
      await file.setLastModified(_clock());
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
      cacheLease.release();
    }
  }

  Future<String> _downloadExpectedChecksum(
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

  Future<bool> canInstallUnknownApps() async {
    if (!Platform.isAndroid) return true;
    final result = await _platform.canInstallUnknownApps();
    _logNativeFailure('canInstallUnknownApps', result);
    return result.valueOrNull ?? true;
  }

  Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    final result = await _platform.openInstallPermissionSettings();
    _logNativeFailure('openInstallPermissionSettings', result);
    return result.valueOrNull ?? false;
  }

  Future<bool> openReleasePage(String url) async {
    try {
      if (Platform.isAndroid) {
        final result = await _platform.openReleasePage(url);
        _logNativeFailure('openReleasePage', result);
        return result.valueOrNull ?? false;
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

  Future<UpdateInstallResult> installUpdate(File file) async {
    final installPath = path.normalize(file.absolute.path);
    final active = _activeInstalls[installPath];
    if (active != null) return active;
    late final Future<UpdateInstallResult> future;
    future = _installUpdateOnce(file).whenComplete(() {
      if (identical(_activeInstalls[installPath], future)) {
        _activeInstalls.remove(installPath);
      }
    });
    _activeInstalls[installPath] = future;
    return future;
  }

  Future<UpdateInstallResult> _installUpdateOnce(File file) async {
    if (Platform.isWindows) return _installWindowsZip(file);
    final result = await _platform.installApk(file.path);
    _logNativeFailure('installApk', result);
    final installResult = result.valueOrNull;
    return installResult == null
        ? UpdateInstallResult(
            ok: false,
            needsPermission: false,
            message: result.errorOrNull,
          )
        : UpdateInstallResult(
            ok: installResult.ok,
            needsPermission: installResult.needsPermission,
            message: installResult.message,
          );
  }

  static void _logNativeFailure<T>(String method, NativeResult<T> result) {
    if (result case NativeFailure<T>(
      :final code,
      :final message,
      :final details,
    )) {
      AppLogService.warning(
        'update_platform_method_failed method=$method code=$code',
        error: <String, Object?>{'message': message, 'details': details},
      );
    }
  }

  static String get windowsUpdateLogPath =>
      path.join(Directory.systemTemp.path, 'nameless_audio_windows_update.log');

  Future<bool> openWindowsUpdateLog() async {
    if (!Platform.isWindows) return false;
    try {
      final logFile = File(windowsUpdateLogPath);
      if (!await logFile.exists()) return false;
      await Process.start('notepad.exe', [logFile.path]);
      return true;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'open_windows_update_log_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static _GitHubAsset? _selectUpdateAsset(List<_GitHubAsset> assets) {
    if (Platform.isWindows) return _selectWindowsZipAsset(assets);
    return _selectApkAsset(assets);
  }

  static _GitHubAsset? _selectApkAsset(List<_GitHubAsset> assets) {
    return assets.cast<_GitHubAsset?>().firstWhere((asset) {
      final name = asset?.name ?? '';
      return name.startsWith(releaseChannel.androidAssetPrefix) &&
          name.toLowerCase().endsWith('.apk');
    }, orElse: () => null);
  }

  @visibleForTesting
  static Map<String, dynamic>? selectApkAssetForTesting(
    List<Map<String, dynamic>> assets,
  ) => _selectApkAsset(
    assets
        .map(_GitHubAsset.fromJson)
        .whereType<_GitHubAsset>()
        .toList(growable: false),
  )?.toJson();

  @visibleForTesting
  static Map<String, dynamic>? selectWindowsZipAssetForTesting(
    List<Map<String, dynamic>> assets,
  ) => _selectWindowsZipAsset(
    assets
        .map(_GitHubAsset.fromJson)
        .whereType<_GitHubAsset>()
        .toList(growable: false),
  )?.toJson();

  static _GitHubAsset? _selectWindowsZipAsset(List<_GitHubAsset> assets) {
    final zipAssets = assets
        .where((asset) {
          final name = asset.name;
          return name.startsWith(releaseChannel.windowsAssetPrefix) &&
              name.toLowerCase().endsWith('.zip');
        })
        .toList(growable: false);
    if (zipAssets.isEmpty) return null;
    zipAssets.sort((left, right) {
      int score(_GitHubAsset asset) {
        final name = asset.name.toLowerCase();
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

  static List<_GitHubAsset> _parseExpandedReleaseAssets(String html) {
    final links = RegExp(
      r'href="([^"]*/releases/download/[^"]+)"',
    ).allMatches(html);
    final assets = <_GitHubAsset>[];
    final seen = <String>{};
    for (final link in links) {
      final rawHref = link.group(1)?.replaceAll('&amp;', '&') ?? '';
      if (rawHref.isEmpty || !seen.add(rawHref)) continue;
      try {
        final uri = Uri.parse('https://github.com').resolve(rawHref);
        final name = uri.pathSegments.isNotEmpty
            ? Uri.decodeComponent(uri.pathSegments.last)
            : '';
        if (name.isEmpty) continue;
        final asset = _GitHubAsset.fromJson(<String, dynamic>{
          'name': name,
          'browser_download_url': uri.toString(),
        });
        if (asset != null) assets.add(asset);
      } on FormatException {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    return assets;
  }

  @visibleForTesting
  static List<Map<String, dynamic>> parseExpandedReleaseAssetsForTesting(
    String html,
  ) => _parseExpandedReleaseAssets(
    html,
  ).map((asset) => asset.toJson()).toList(growable: false);

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

  Future<UpdateInstallResult> _installWindowsZip(File file) async {
    if (!await file.exists() || await file.length() <= 0) {
      return const UpdateInstallResult(
        ok: false,
        needsPermission: false,
        message: 'Update ZIP does not exist.',
      );
    }

    final exePath = Platform.resolvedExecutable;
    final installDir = File(exePath).parent.path;
    final tempDir = await _temporaryDirectoryProvider();
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

  Future<String?> _waitForWindowsUpdaterReady(File readyFile) async {
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
    return 'Windows updater did not become ready in time. Log: $windowsUpdateLogPath';
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
    return normalized.startsWith('v') ? normalized.substring(1) : normalized;
  }

  static bool _isNewerVersion(String latest, String current) {
    final latestVersion = _parseVersion(latest);
    final currentVersion = _parseVersion(current);
    if (latestVersion == null || currentVersion == null) return false;
    return latestVersion.compareTo(currentVersion) > 0;
  }

  static semver.Version? _parseVersionFromTag(String? tagName) {
    if (tagName == null) return null;
    return _parseVersion(_versionNameFromTag(tagName));
  }

  static semver.Version? _parseVersion(String value) {
    try {
      return semver.Version.parse(value.split('+').first.trim());
    } catch (_) {
      return null;
    }
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

function Test-DirectoryWritable([string]$Directory) {
  try {
    $probe = Join-Path $Directory ('.nameless_audio_update_write_test_' + [Guid]::NewGuid().ToString('N') + '.tmp')
    Set-Content -LiteralPath $probe -Value 'test' -Encoding UTF8
    Remove-Item -LiteralPath $probe -Force
    return $true
  } catch {
    return $false
  }
}

function Test-UpdateTargetWritable {
  $parent = Split-Path -Parent $InstallDir
  return (Test-DirectoryWritable $InstallDir) -and (Test-DirectoryWritable $parent)
}

function Quote-Argument([string]$Value) {
  return "'" + ($Value -replace "'", "''") + "'"
}

function Start-ElevatedUpdater {
  $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $powerShell)) {
    $powerShell = 'powershell.exe'
  }
  $command = @(
    '&',
    (Quote-Argument $PSCommandPath),
    (Quote-Argument $ZipPath),
    (Quote-Argument $InstallDir),
    (Quote-Argument $ExePath),
    $AppProcessId,
    (Quote-Argument $ReadyPath),
    '-Elevated'
  ) -join ' '
  $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  $args = @(
    '-WindowStyle', 'Hidden',
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-STA',
    '-EncodedCommand', $encodedCommand
  )
  Write-UpdateLog 'requesting elevated updater'
  Start-Process -FilePath $powerShell -ArgumentList $args -Verb RunAs -WorkingDirectory $env:TEMP
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

function Invoke-RobocopyMirror([string]$Source, [string]$Destination) {
  if (-not (Test-Path -LiteralPath $Destination)) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  }
  Write-UpdateLog "mirroring $Source to $Destination"
  & robocopy $Source $Destination /MIR /COPY:DAT /R:15 /W:1 /NFL /NDL /NP | Out-Null
  $robocopyExitCode = $LASTEXITCODE
  Write-UpdateLog "robocopy exit code=$robocopyExitCode"
  if ($robocopyExitCode -ge 8) {
    throw "File copy failed with robocopy exit code $robocopyExitCode."
  }
}

function Install-WithDirectorySwap([string]$PayloadDir, [string]$TargetExePath) {
  $installParent = Split-Path -Parent $InstallDir
  $installName = Split-Path -Leaf $InstallDir
  $stamp = Get-Date -Format 'yyyyMMddHHmmss'
  $newDir = Join-Path $installParent ($installName + '.new_' + $stamp)
  $backupDir = Join-Path $installParent ($installName + '.old_' + $stamp)

  try {
    Invoke-RobocopyMirror $PayloadDir $newDir
    Write-UpdateLog "renaming current install dir to backup: $backupDir"
    Rename-Item -LiteralPath $InstallDir -NewName (Split-Path -Leaf $backupDir)
    Write-UpdateLog "activating new install dir: $InstallDir"
    Rename-Item -LiteralPath $newDir -NewName $installName
    if (-not (Test-Path -LiteralPath $TargetExePath)) {
      throw "Updated executable is missing: $TargetExePath"
    }
    return $backupDir
  } catch {
    Write-UpdateLog ("directory swap failed: " + $_.Exception.Message)
    if ((Test-Path -LiteralPath $backupDir) -and -not (Test-Path -LiteralPath $InstallDir)) {
      try {
        Rename-Item -LiteralPath $backupDir -NewName $installName
        Write-UpdateLog 'restored backup install directory'
      } catch {
        Write-UpdateLog ("failed to restore backup install directory: " + $_.Exception.Message)
      }
    }
    if (Test-Path -LiteralPath $newDir) {
      Remove-Item -LiteralPath $newDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
  }
}

try {
  Write-UpdateLog "start zip=$ZipPath install=$InstallDir exe=$ExePath pid=$AppProcessId elevated=$Elevated"
  $staging = Join-Path $env:TEMP ("nameless_audio_update_" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  Write-UpdateLog "expanding $ZipPath to $staging"
  
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $staging)

  $currentExeName = Split-Path -Leaf $ExePath
  $payloadExeCandidates = Get-ChildItem -LiteralPath $staging -Filter 'nameless_audio*.exe' -Recurse -File
  $payloadExe = $payloadExeCandidates |
    Where-Object { $_.Name -ieq $currentExeName } |
    Select-Object -First 1
  if ($null -eq $payloadExe) {
    $payloadExe = $payloadExeCandidates |
      Where-Object { $_.Name -ieq 'nameless_audio.exe' } |
      Select-Object -First 1
  }
  if ($null -eq $payloadExe) {
    $payloadExe = $payloadExeCandidates | Select-Object -First 1
  }
  if ($null -eq $payloadExe) {
    throw "Cannot find Nameless Audio executable inside update ZIP."
  }
  if ($payloadExe.Name -ine $currentExeName) {
    Write-UpdateLog "payload executable differs from current executable: $($payloadExe.Name)"
  }
  $payloadDir = $payloadExe.Directory.FullName
  $targetExePath = Join-Path $InstallDir $payloadExe.Name

  if (-not (Test-UpdateTargetWritable)) {
    if (-not $Elevated) {
      Start-ElevatedUpdater
      Set-Content -LiteralPath $ReadyPath -Value 'ready' -Encoding ASCII
      Write-UpdateLog 'elevated updater started'
      exit 0
    }
    throw "Cannot write to install directory or parent directory: $InstallDir"
  }

  Set-Content -LiteralPath $ReadyPath -Value 'ready' -Encoding ASCII
  Write-UpdateLog 'payload verified; waiting for application exit'
  Wait-AppExit

  $backupDir = $null
  try {
    Write-UpdateLog 'installing by directory swap'
    $backupDir = Install-WithDirectorySwap $payloadDir $targetExePath
  } catch {
    Write-UpdateLog ("directory swap unavailable; falling back to in-place mirror: " + $_.Exception.Message)
    Invoke-RobocopyMirror $payloadDir $InstallDir
    if (-not (Test-Path -LiteralPath $targetExePath)) {
      throw "Updated executable is missing: $targetExePath"
    }
  }

  Write-UpdateLog "restarting $targetExePath"
  Start-Process -FilePath $targetExePath -WorkingDirectory $InstallDir
  if ($null -ne $backupDir -and (Test-Path -LiteralPath $backupDir)) {
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Write-UpdateLog 'update complete'
  exit 0
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
