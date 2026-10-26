import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../logging/app_log_service.dart';
import '../media/cover_image_format.dart';
import '../media/path_matcher.dart';

const String legacyRemoteCoverCacheDirectoryName = 'remote_covers';

class AppCacheService {
  static const int defaultMaxCacheBytes = 300 * 1024 * 1024;
  static const _temporaryDirectoryNames = <String>[
    'updates',
    'asmr_downloads',
    'asmr_playback_cache',
    'asmr_subtitles',
    'embedded_covers',
    'notification_covers',
    'video_frames',
    'doujin_audio_covers',
    'exports',
    'page_translations',
  ];

  static int _maxCacheBytes = defaultMaxCacheBytes;
  static Future<void> _operations = Future<void>.value();
  static Future<void>? _enforceFuture;
  static Future<int>? _clearFuture;
  static Future<int>? _estimateFuture;
  static bool _enforceRequested = false;
  static bool _enforceAfterLeaseRelease = false;
  static Timer? _scheduledEnforceTimer;
  static DateTime? _scheduledEnforceStartedAt;
  static final Map<String, ({String path, int count})> _protectedPaths = {};
  static Future<List<Directory>> Function() _temporaryDirectories =
      _platformTemporaryDirectories;
  static Future<void> Function(String)? _beforeDelete;

  static int get maxCacheBytes => _maxCacheBytes;
  static bool scheduledEnforceEnabled = true;

  static CachePathLease protectPaths(Iterable<String> paths) {
    final normalized = <String, String>{
      for (final value in paths)
        if (value.trim().isNotEmpty)
          PathMatcher.equivalenceKey(value): PathMatcher.normalize(value),
    };
    for (final entry in normalized.entries) {
      final existing = _protectedPaths[entry.key];
      _protectedPaths[entry.key] = (
        path: entry.value,
        count: (existing?.count ?? 0) + 1,
      );
    }
    return CachePathLease._(normalized.keys.toSet());
  }

  /// Native artwork APIs choose their own output names. Keep their registered
  /// directories alive until generation and the durable copy both finish.
  static Future<CachePathLease> protectTemporaryDirectories(
    Set<String> names,
  ) async => protectPaths([
    for (final root in await _cacheRoots())
      if (names.contains(path.basename(root.path))) root.path,
  ]);

  static String formatBytes(int bytes) {
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
      final gb = mb / 1024;
      return '${gb.toStringAsFixed(gb.truncateToDouble() == gb ? 0 : 1)} GB';
    }
    return '${mb.round()} MB';
  }

  static Future<void> setMaxCacheBytes(
    int bytes, {
    bool enforceImmediately = true,
  }) async {
    _cancelScheduledEnforce();
    _maxCacheBytes = bytes <= 0 ? defaultMaxCacheBytes : bytes;
    if (enforceImmediately) await enforceLimit();
  }

  /// Persistent artwork must be cleared by its owner while requests are blocked.
  static Future<int> clearTemporaryCaches() {
    _cancelScheduledEnforce();
    return _clearFuture ??= _enqueue(() async {
      var deletedBytes = 0;
      for (final directory in await _cacheRoots()) {
        deletedBytes += await _deleteDirectoryChildren(directory);
      }
      return deletedBytes;
    }).whenComplete(() => _clearFuture = null);
  }

  static Future<int> estimateCacheBytes() {
    final pending = _estimateFuture;
    if (pending != null) return pending;
    late final Future<int> result;
    result = _operations.then((_) => _estimateCacheBytes()).whenComplete(() {
      if (identical(_estimateFuture, result)) _estimateFuture = null;
    });
    return _estimateFuture = result;
  }

  static Future<int> _estimateCacheBytes() async {
    var totalBytes = 0;
    for (final root in await _cacheRoots(includePersistent: true)) {
      await for (final file in _files(root)) {
        try {
          totalBytes += await file.length();
        } on FileSystemException {
          // Entries may disappear while usage is being measured.
        }
      }
    }
    return totalBytes;
  }

  static Future<Directory> persistentImportDirectory() async => Directory(
    path.join(
      (await getApplicationSupportDirectory()).path,
      'doujin_audio_imports',
    ),
  );

  static Future<CachePathLease> protectPersistentImports({
    Directory? importDirectory,
  }) async {
    if (!Platform.isAndroid && importDirectory == null) return protectPaths([]);
    final directory = importDirectory ?? await persistentImportDirectory();
    return protectPaths([directory.path]);
  }

  static Future<int> cleanupOrphanedPersistentImports(
    bool Function(String path) isRetained, {
    Directory? importDirectory,
  }) async {
    if (!Platform.isAndroid && importDirectory == null) return 0;
    final directory = importDirectory ?? await persistentImportDirectory();
    return _enqueue(() async {
      var deletedBytes = 0;
      if (!await directory.exists()) return 0;
      await for (final entity in directory.list(followLinks: false)) {
        // Recheck after the deletion's async reads: an import may have committed
        // while this operation was queued or inspecting another file.
        deletedBytes += await _deleteEntity(
          entity,
          canDelete: (candidate) => !isRetained(candidate),
        );
      }
      return deletedBytes;
    });
  }

  static Future<void> enforceLimit() {
    _cancelScheduledEnforce();
    _enforceRequested = true;
    return _enforceFuture ??= _enqueue(() async {
      while (_enforceRequested) {
        _enforceRequested = false;
        await _enforceLimitOnce();
      }
    }).whenComplete(() => _enforceFuture = null);
  }

  static void scheduleEnforce({
    Duration idleDelay = const Duration(seconds: 2),
    Duration maxDelay = const Duration(seconds: 30),
  }) {
    if (!scheduledEnforceEnabled) return;
    final now = DateTime.now();
    final startedAt = _scheduledEnforceStartedAt ??= now;
    final remaining = maxDelay - now.difference(startedAt);
    _scheduledEnforceTimer?.cancel();
    if (remaining <= Duration.zero) {
      unawaited(enforceLimit());
      return;
    }
    _scheduledEnforceTimer = Timer(
      idleDelay < remaining ? idleDelay : remaining,
      () => unawaited(enforceLimit()),
    );
  }

  static void _cancelScheduledEnforce() {
    _scheduledEnforceTimer?.cancel();
    _scheduledEnforceTimer = null;
    _scheduledEnforceStartedAt = null;
  }

  @visibleForTesting
  static void resetForTest({
    Future<List<Directory>> Function()? temporaryDirectories,
    Future<void> Function(String)? beforeDelete,
  }) {
    _cancelScheduledEnforce();
    scheduledEnforceEnabled = true;
    _maxCacheBytes = defaultMaxCacheBytes;
    _enforceAfterLeaseRelease = false;
    _enforceRequested = false;
    _estimateFuture = null;
    _protectedPaths.clear();
    _temporaryDirectories =
        temporaryDirectories ?? _platformTemporaryDirectories;
    _beforeDelete = beforeDelete;
  }

  static Future<T> _enqueue<T>(Future<T> Function() operation) {
    // Estimates requested after maintenance must wait for it instead of joining
    // an older scan. Completed results are never retained between requests.
    _estimateFuture = null;
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        AppLogService.warning(
          'cache_maintenance_failed',
          error: error,
          stackTrace: stack,
        );
      },
    );
    return result;
  }

  static Future<List<Directory>> _platformTemporaryDirectories() async {
    final roots = <Directory>[await getTemporaryDirectory()];
    if (Platform.isAndroid) {
      try {
        roots.addAll(await getExternalCacheDirectories() ?? const []);
      } on Exception catch (error, stack) {
        AppLogService.warning(
          'external_cache_roots_unavailable',
          error: error,
          stackTrace: stack,
        );
      }
    }
    return roots;
  }

  static Future<List<Directory>> _cacheRoots({
    bool includePersistent = false,
  }) async {
    final roots = <Directory>[];
    try {
      for (final parent in await _temporaryDirectories()) {
        for (final name in _temporaryDirectoryNames) {
          roots.add(Directory(path.join(parent.path, name)));
        }
      }
    } catch (error, stack) {
      AppLogService.warning(
        'temporary_cache_roots_unavailable',
        error: error,
        stackTrace: stack,
      );
    }
    if (includePersistent) {
      try {
        final support = await getApplicationSupportDirectory();
        roots.addAll([
          Directory(
            path.join(support.path, legacyRemoteCoverCacheDirectoryName),
          ),
          Directory(path.join(support.path, coverArtworkStoreDirectoryName)),
        ]);
      } catch (error, stack) {
        AppLogService.warning(
          'persistent_cache_roots_unavailable',
          error: error,
          stackTrace: stack,
        );
      }
    }
    roots.add(
      Directory(path.join(Directory.systemTemp.path, 'doujin_audio_imports')),
    );
    final unique = <Directory>[];
    for (final root in roots) {
      if (unique.any(
        (other) => PathMatcher.isWithinOrEqual(root.path, other.path),
      )) {
        continue;
      }
      unique.removeWhere(
        (other) => PathMatcher.isWithinOrEqual(other.path, root.path),
      );
      unique.add(root);
    }
    return unique;
  }

  static Stream<File> _files(Directory root) async* {
    try {
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) yield entity;
      }
    } on FileSystemException catch (error, stack) {
      AppLogService.warning(
        'cache_directory_scan_failed',
        error: error,
        stackTrace: stack,
      );
    }
  }

  static Future<int> _deleteDirectoryChildren(Directory directory) async {
    var deletedBytes = 0;
    try {
      if (await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return 0;
      }
      await for (final entity in directory.list(followLinks: false)) {
        deletedBytes += await _deleteEntity(entity);
      }
      return deletedBytes;
    } on FileSystemException catch (error, stack) {
      AppLogService.warning(
        'cache_directory_clear_failed',
        error: error,
        stackTrace: stack,
      );
      return deletedBytes;
    }
  }

  static Future<int> _deleteEntity(
    FileSystemEntity entity, {
    bool Function(String path)? canDelete,
  }) async {
    var deletedBytes = 0;
    try {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        final length = await File(entity.path).length();
        await _beforeDelete?.call(entity.path);
        if (_isProtected(entity.path) ||
            !(canDelete?.call(entity.path) ?? true)) {
          return 0;
        }
        await File(entity.path).delete();
        return length;
      }
      if (type == FileSystemEntityType.directory) {
        final directory = Directory(entity.path);
        await for (final child in directory.list(followLinks: false)) {
          deletedBytes += await _deleteEntity(child, canDelete: canDelete);
        }
        if (!_containsProtectedPath(directory.path) &&
            await directory.list().isEmpty) {
          await directory.delete();
        }
        return deletedBytes;
      }
    } on FileSystemException {
      // Locked or vanished cache entries can be retried in later maintenance.
    }
    return deletedBytes;
  }

  static Future<void> _enforceLimitOnce() async {
    final entries = <_CacheFileEntry>[];
    var totalBytes = 0;
    for (final root in await _cacheRoots()) {
      await for (final file in _files(root)) {
        try {
          final stat = await file.stat();
          totalBytes += stat.size;
          entries.add(_CacheFileEntry(file: file, modified: stat.modified));
        } on FileSystemException {
          // Files may disappear while scanning.
        }
      }
    }
    if (totalBytes <= _maxCacheBytes) return;
    final target = applicationCacheTrimTargetBytes(_maxCacheBytes);
    entries.removeWhere((entry) => _isProtected(entry.file.path));
    // A lease can end while another candidate is being deleted. Arrange its
    // retry before awaiting deletion so that the skipped files are revisited.
    _enforceAfterLeaseRelease = _protectedPaths.isNotEmpty;
    entries.sort((a, b) {
      final order = a.modified.compareTo(b.modified);
      return order == 0 ? a.file.path.compareTo(b.file.path) : order;
    });
    for (final entry in entries) {
      if (totalBytes <= target) break;
      totalBytes -= await _deleteEntity(entry.file);
    }
    _enforceAfterLeaseRelease =
        totalBytes > target && _protectedPaths.isNotEmpty;
  }

  static bool _isProtected(String candidate) => _protectedPaths.values.any(
    (entry) => PathMatcher.isWithinOrEqual(candidate, entry.path),
  );

  static bool _containsProtectedPath(String directory) => _protectedPaths.values
      .any((entry) => PathMatcher.isWithinOrEqual(entry.path, directory));

  static void _releaseProtectedPaths(Set<String> keys) {
    for (final key in keys) {
      final entry = _protectedPaths[key];
      if (entry == null) continue;
      if (entry.count == 1) {
        _protectedPaths.remove(key);
      } else {
        _protectedPaths[key] = (path: entry.path, count: entry.count - 1);
      }
    }
    if (_enforceAfterLeaseRelease) {
      _enforceAfterLeaseRelease = false;
      scheduleEnforce();
    }
  }
}

class CachePathLease {
  CachePathLease._(this._keys);
  final Set<String> _keys;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    AppCacheService._releaseProtectedPaths(_keys);
  }
}

int applicationCacheTrimTargetBytes(int maxBytes) {
  final normalized = maxBytes < 1 ? 1 : maxBytes;
  return (normalized * 9 ~/ 10).clamp(1, normalized);
}

class _CacheFileEntry {
  const _CacheFileEntry({required this.file, required this.modified});
  final File file;
  final DateTime modified;
}
