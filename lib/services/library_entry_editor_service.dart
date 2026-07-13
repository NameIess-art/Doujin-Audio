import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'file_cache_platform_gateway.dart';
import 'app_log_service.dart';
import 'media_file_support.dart';
import 'natural_sort.dart';
import 'path_matcher.dart';

class LibraryEntryDiskSnapshot {
  const LibraryEntryDiskSnapshot({
    required this.audioFilePaths,
    required this.scannedFolderPaths,
    required this.authoritative,
  });

  final List<String> audioFilePaths;
  final Set<String> scannedFolderPaths;
  final bool authoritative;

  Set<String> get audioFilePathSet => audioFilePaths.toSet();
}

class LibraryEntryEditorService {
  LibraryEntryEditorService({
    FileCachePlatformGateway? fileCacheGateway,
    bool Function()? isAndroid,
  }) : _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _isAndroid = isAndroid ?? (() => Platform.isAndroid);

  final FileCachePlatformGateway _fileCacheGateway;
  final bool Function() _isAndroid;

  Future<LibraryEntryDiskSnapshot> loadDiskSnapshot(String libraryPath) {
    if (PathMatcher.isContentUri(libraryPath)) {
      return _loadNativeSnapshot(libraryPath);
    }
    return _loadFileSystemSnapshot(libraryPath);
  }

  Future<LibraryEntryDiskSnapshot> _loadFileSystemSnapshot(
    String libraryPath,
  ) async {
    final directory = Directory(libraryPath);
    if (!await directory.exists()) {
      return const LibraryEntryDiskSnapshot(
        audioFilePaths: <String>[],
        scannedFolderPaths: <String>{},
        authoritative: true,
      );
    }

    final audioFiles = <String>{};
    final pendingDirectories = Queue<Directory>()..add(directory);
    var processedEntities = 0;
    while (pendingDirectories.isNotEmpty) {
      final currentDirectory = pendingDirectories.removeFirst();
      try {
        await for (final entity in currentDirectory.list(followLinks: false)) {
          processedEntities++;
          if (processedEntities % 200 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
          final normalizedPath = PathMatcher.normalize(entity.path);
          if (entity is Directory) {
            pendingDirectories.add(entity);
          } else if (entity is File && isSupportedMediaFile(normalizedPath)) {
            audioFiles.add(normalizedPath);
          }
        }
      } on FileSystemException catch (error, stackTrace) {
        AppLogService.warning(
          'library_entry_directory_scan_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return _snapshot(audioFiles, const <String>{}, authoritative: true);
  }

  Future<LibraryEntryDiskSnapshot> _loadNativeSnapshot(
    String libraryPath,
  ) async {
    if (!_isAndroid()) {
      return const LibraryEntryDiskSnapshot(
        audioFilePaths: <String>[],
        scannedFolderPaths: <String>{},
        authoritative: false,
      );
    }
    try {
      final payload = await _fileCacheGateway.scanFolderPayload(libraryPath);
      if (payload == null) {
        return const LibraryEntryDiskSnapshot(
          audioFilePaths: <String>[],
          scannedFolderPaths: <String>{},
          authoritative: false,
        );
      }
      final audioFiles = <String>{};
      final folderPaths = <String>{};
      for (final item in payload) {
        if (item is! Map) continue;
        final map = item.cast<Object?, Object?>();
        final scannedPath = map['path']?.toString().trim();
        if (scannedPath == null ||
            scannedPath.isEmpty ||
            !isSupportedMediaFile(scannedPath)) {
          continue;
        }
        audioFiles.add(PathMatcher.normalize(scannedPath));
        final groupKey = map['groupKey']?.toString().trim();
        if (groupKey != null &&
            groupKey.isNotEmpty &&
            !PathMatcher.equalsNormalized(groupKey, libraryPath)) {
          folderPaths.add(PathMatcher.normalize(groupKey));
        }
      }
      return _snapshot(audioFiles, folderPaths, authoritative: true);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'library_entry_native_scan_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const LibraryEntryDiskSnapshot(
        audioFilePaths: <String>[],
        scannedFolderPaths: <String>{},
        authoritative: false,
      );
    }
  }

  LibraryEntryDiskSnapshot _snapshot(
    Set<String> audioFiles,
    Set<String> folderPaths, {
    required bool authoritative,
  }) {
    final sortedAudioFiles = audioFiles.toList(growable: false)
      ..sort(
        (first, second) => compareNatural(
          path.basenameWithoutExtension(first),
          path.basenameWithoutExtension(second),
        ),
      );
    return LibraryEntryDiskSnapshot(
      audioFilePaths: sortedAudioFiles,
      scannedFolderPaths: Set<String>.unmodifiable(folderPaths),
      authoritative: authoritative,
    );
  }
}
