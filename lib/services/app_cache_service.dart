import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'platform_channels.dart';

class AppCacheService {
  static const int defaultMaxCacheBytes = 300 * 1024 * 1024;
  static const MethodChannel _fileCacheChannel = MethodChannel(
    FileCacheChannel.name,
  );

  static int _maxCacheBytes = defaultMaxCacheBytes;

  static int get maxCacheBytes => _maxCacheBytes;

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
    if (Platform.isAndroid) {
      try {
        await _fileCacheChannel.invokeMethod<void>(
          FileCacheMethod.setApplicationCacheLimit,
          {'maxBytes': _maxCacheBytes},
        );
      } on MissingPluginException {
        // Non-Android platforms do not expose the native cache channel.
      } catch (_) {
        // Cache limits are best-effort; playback and downloads should continue.
      }
    }
    await enforceLimit();
  }

  static Future<int> clearAllCaches() async {
    var deletedBytes = 0;
    if (Platform.isAndroid) {
      try {
        deletedBytes +=
            await _fileCacheChannel.invokeMethod<int>(
              FileCacheMethod.clearApplicationCache,
            ) ??
            0;
      } on MissingPluginException {
        // Non-Android platforms do not expose the native cache channel.
      } catch (_) {
        // Fall back to Dart-visible cache directories below.
      }
    }

    for (final directory in await _dartCacheRoots()) {
      deletedBytes += await _deleteDirectoryChildren(directory);
    }
    return deletedBytes;
  }

  static Future<void> enforceLimit() async {
    if (Platform.isAndroid) {
      try {
        await _fileCacheChannel.invokeMethod<void>(
          FileCacheMethod.enforceApplicationCacheLimit,
          {'maxBytes': _maxCacheBytes},
        );
        return;
      } on MissingPluginException {
        // Non-Android platforms do not expose the native cache channel.
      } catch (_) {
        // Fall back to Dart-visible cache directories below.
      }
    }
    await _enforceDartCacheLimit(_maxCacheBytes);
  }

  static Future<List<Directory>> _dartCacheRoots() async {
    final roots = <Directory>[];
    try {
      roots.add(await getTemporaryDirectory());
    } catch (_) {}
    roots.add(
      Directory(path.join(Directory.systemTemp.path, 'nameless_audio_imports')),
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
        await directory.delete();
        return deletedBytes;
      }
    } catch (_) {}
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
    if (files.length <= 1) return;

    final entries = <_CacheFileEntry>[];
    var totalBytes = 0;
    for (final file in files) {
      try {
        final stat = await file.stat();
        totalBytes += stat.size;
        entries.add(
          _CacheFileEntry(file: file, size: stat.size, modified: stat.modified),
        );
      } catch (_) {}
    }
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    var remainingFiles = entries.length;
    for (final entry in entries) {
      if (totalBytes <= maxBytes || remainingFiles <= 1) break;
      try {
        await entry.file.delete();
        totalBytes -= entry.size;
        remainingFiles -= 1;
      } catch (_) {}
    }
  }
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
