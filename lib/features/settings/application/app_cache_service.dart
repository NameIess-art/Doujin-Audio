import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/platform/file_cache_platform_gateway.dart';

const String persistentRemoteCoverCacheDirectoryName = 'remote_covers';

class AppCacheService {
  static const int defaultMaxCacheBytes = 300 * 1024 * 1024;
  static final FileCachePlatformGateway _fileCache =
      FileCachePlatformGateway.instance;

  static int _maxCacheBytes = defaultMaxCacheBytes;
  static Future<void>? _enforceFuture;
  static bool _enforceRequested = false;
  static Timer? _scheduledEnforceTimer;
  static DateTime? _scheduledEnforceStartedAt;
  static final Map<String, int> _protectedPaths = <String, int>{};
  static bool _enforceAfterLeaseRelease = false;

  static int get maxCacheBytes => _maxCacheBytes;

  static CachePathLease protectPaths(Iterable<String> paths) {
    final normalized = paths
        .where((value) => value.trim().isNotEmpty)
        .map((value) => path.normalize(value))
        .toSet();
    if (normalized.isNotEmpty && _scheduledEnforceTimer != null) {
      _cancelScheduledEnforce();
      _enforceAfterLeaseRelease = true;
    }
    for (final protectedPath in normalized) {
      _protectedPaths.update(
        protectedPath,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return CachePathLease._(normalized);
  }

  static String formatBytes(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
      final gb = mb / 1024;
      return '${gb.toStringAsFixed(gb.truncateToDouble() == gb ? 0 : 1)} GB';
    }
    return '${mb.round()} MB';
  }

  static Future<void> setMaxCacheBytes(int bytes) async {
    _maxCacheBytes = bytes <= 0 ? defaultMaxCacheBytes : bytes;
    if (Platform.isAndroid && _protectedPaths.isEmpty) {
      try {
        await _fileCache.setApplicationCacheLimit(_maxCacheBytes);
      } on MissingPluginException {
        // Non-Android platforms do not expose the native cache channel.
      } catch (_) {
        // Cache limits are best-effort; playback and downloads should continue.
      }
    }
    await enforceLimit();
  }

  static Future<int> clearAllCaches() async {
    _cancelScheduledEnforce();
    var deletedBytes = 0;
    if (Platform.isAndroid && _protectedPaths.isEmpty) {
      try {
        deletedBytes += await _fileCache.clearApplicationCache();
      } on MissingPluginException {
        // Non-Android platforms do not expose the native cache channel.
      } catch (_) {
        // Fall back to Dart-visible cache directories below.
      }
    } else if (Platform.isAndroid) {
      _enforceAfterLeaseRelease = true;
    }

    for (final directory in await _dartCacheRoots(includePersistent: true)) {
      deletedBytes += await _deleteDirectoryChildren(directory);
    }
    return deletedBytes;
  }

  static Future<int> estimateDartCacheBytes() async {
    var totalBytes = 0;
    for (final root in await _dartCacheRoots(includePersistent: true)) {
      if (!await root.exists()) continue;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          totalBytes += await entity.length();
        } catch (_) {
          // Cache accounting is best effort when entries change mid-scan.
        }
      }
    }
    return totalBytes;
  }

  static Future<int> cleanupOrphanedPersistentImports(
    Iterable<String> retainedPaths, {
    Directory? importDirectory,
  }) async {
    if (!Platform.isAndroid && importDirectory == null) return 0;
    try {
      final directory =
          importDirectory ??
          Directory(
            path.join(
              (await getApplicationSupportDirectory()).path,
              'doujin_audio_imports',
            ),
          );
      if (!await directory.exists()) return 0;
      final retained = retainedPaths
          .where((value) => value.isNotEmpty && !value.contains('://'))
          .map(path.normalize)
          .toSet();
      var deletedBytes = 0;
      await for (final entity in directory.list(followLinks: false)) {
        if (retained.contains(path.normalize(entity.path))) continue;
        deletedBytes += await _deleteEntity(entity);
      }
      return deletedBytes;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> enforceLimit() {
    _cancelScheduledEnforce();
    _enforceRequested = true;
    final inFlight = _enforceFuture;
    if (inFlight != null) return inFlight;
    final future = _drainEnforceRequests();
    _enforceFuture = future;
    return future;
  }

  static void scheduleEnforce({
    Duration idleDelay = const Duration(seconds: 2),
    Duration maxDelay = const Duration(seconds: 30),
  }) {
    if (_protectedPaths.isNotEmpty) {
      _enforceAfterLeaseRelease = true;
      return;
    }
    final now = DateTime.now();
    final startedAt = _scheduledEnforceStartedAt ??= now;
    final remaining = maxDelay - now.difference(startedAt);
    if (remaining <= Duration.zero) {
      _cancelScheduledEnforce();
      unawaited(enforceLimit());
      return;
    }
    _scheduledEnforceTimer?.cancel();
    final delay = idleDelay < remaining ? idleDelay : remaining;
    _scheduledEnforceTimer = Timer(delay, () {
      _scheduledEnforceTimer = null;
      _scheduledEnforceStartedAt = null;
      unawaited(enforceLimit());
    });
  }

  static void _cancelScheduledEnforce() {
    _scheduledEnforceTimer?.cancel();
    _scheduledEnforceTimer = null;
    _scheduledEnforceStartedAt = null;
  }

  static Future<void> _drainEnforceRequests() async {
    try {
      while (_enforceRequested) {
        _enforceRequested = false;
        await _enforceLimitOnce();
      }
    } finally {
      _enforceFuture = null;
    }
  }

  static Future<void> _enforceLimitOnce() async {
    if (Platform.isAndroid && _protectedPaths.isEmpty) {
      try {
        await _fileCache.enforceApplicationCacheLimit(_maxCacheBytes);
        return;
      } on MissingPluginException {
        // Non-Android platforms do not expose the native cache channel.
      } catch (_) {
        // Fall back to Dart-visible cache directories below.
      }
    }
    if (Platform.isAndroid && _protectedPaths.isNotEmpty) {
      _enforceAfterLeaseRelease = true;
    }
    await _enforceDartCacheLimit(_maxCacheBytes);
  }

  static Future<List<Directory>> _dartCacheRoots({
    bool includePersistent = false,
  }) async {
    final roots = <Directory>[];
    try {
      final tempDir = await getTemporaryDirectory();
      roots.add(Directory(path.join(tempDir.path, 'updates')));
      roots.add(Directory(path.join(tempDir.path, 'asmr_downloads')));
      roots.add(Directory(path.join(tempDir.path, 'asmr_playback_cache')));
      roots.add(Directory(path.join(tempDir.path, 'embedded_covers')));
      roots.add(Directory(path.join(tempDir.path, 'notification_covers')));
      roots.add(Directory(path.join(tempDir.path, 'video_frames')));
      roots.add(Directory(path.join(tempDir.path, 'exports')));
    } catch (_) {
      // Temporary cache roots are optional and may be unavailable on startup.
    }
    if (includePersistent) {
      try {
        final supportDir = await getApplicationSupportDirectory();
        roots.add(
          Directory(
            path.join(supportDir.path, persistentRemoteCoverCacheDirectoryName),
          ),
        );
      } catch (_) {
        // Persistent cover cache may be unavailable during early startup.
      }
    }
    roots.add(
      Directory(path.join(Directory.systemTemp.path, 'doujin_audio_imports')),
    );
    return roots;
  }

  static Future<int> _deleteDirectoryChildren(Directory directory) async {
    if (!await directory.exists()) return 0;
    var deletedBytes = 0;
    await for (final entity in directory.list(followLinks: false)) {
      deletedBytes += await _deleteEntity(entity);
    }
    return deletedBytes;
  }

  static Future<int> _deleteEntity(FileSystemEntity entity) async {
    try {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        if (_isProtected(entity.path)) return 0;
        final file = File(entity.path);
        final length = await file.length();
        await file.delete();
        return length;
      }
      if (type == FileSystemEntityType.directory) {
        final directory = Directory(entity.path);
        var deletedBytes = 0;
        await for (final child in directory.list(followLinks: false)) {
          deletedBytes += await _deleteEntity(child);
        }
        if (!_containsProtectedPath(directory.path) &&
            await directory.list().isEmpty) {
          await directory.delete();
        }
        return deletedBytes;
      }
    } catch (_) {
      // Cache cleanup is best effort; inaccessible files are left untouched.
    }
    return 0;
  }

  static Future<void> _enforceDartCacheLimit(int maxBytes) async {
    final files = <File>[];
    for (final root in await _dartCacheRoots()) {
      if (!await root.exists()) continue;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          files.add(entity);
        }
      }
    }
    final entries = <_CacheFileEntry>[];
    var totalBytes = 0;
    for (final file in files) {
      try {
        if (_isProtected(file.path)) continue;
        final stat = await file.stat();
        totalBytes += stat.size;
        entries.add(
          _CacheFileEntry(file: file, size: stat.size, modified: stat.modified),
        );
      } catch (_) {
        // Skip cache entries that disappear or become inaccessible mid-scan.
      }
    }
    if (totalBytes <= maxBytes) return;

    final trimTargetBytes = applicationCacheTrimTargetBytes(maxBytes);
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (totalBytes <= trimTargetBytes) break;
      try {
        await entry.file.delete();
        totalBytes -= entry.size;
      } catch (_) {
        // Cache eviction is best effort; a locked file can be retried later.
      }
    }
  }

  static bool _isProtected(String candidate) {
    final normalized = path.normalize(candidate);
    return _protectedPaths.keys.any(
      (protectedPath) =>
          protectedPath == normalized ||
          path.isWithin(protectedPath, normalized),
    );
  }

  static bool _containsProtectedPath(String directory) {
    final normalized = path.normalize(directory);
    return _protectedPaths.keys.any(
      (protectedPath) =>
          protectedPath == normalized ||
          path.isWithin(normalized, protectedPath),
    );
  }

  static void _releaseProtectedPaths(Set<String> paths) {
    for (final protectedPath in paths) {
      final count = _protectedPaths[protectedPath];
      if (count == null || count <= 1) {
        _protectedPaths.remove(protectedPath);
      } else {
        _protectedPaths[protectedPath] = count - 1;
      }
    }
    if (_protectedPaths.isEmpty && _enforceAfterLeaseRelease) {
      _enforceAfterLeaseRelease = false;
      enforceLimit();
    }
  }
}

class CachePathLease {
  CachePathLease._(this._paths);

  final Set<String> _paths;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    AppCacheService._releaseProtectedPaths(_paths);
  }
}

int applicationCacheTrimTargetBytes(int maxBytes) {
  final normalizedMaxBytes = maxBytes < 1 ? 1 : maxBytes;
  return (normalizedMaxBytes * 9 ~/ 10).clamp(1, normalizedMaxBytes);
}

class _CacheFileEntry {
  const _CacheFileEntry({
    required this.file,
    required this.size,
    required this.modified,
  });

  final File file;
  final int size;
  final DateTime modified;
}
