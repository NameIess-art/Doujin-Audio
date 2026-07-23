import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as path;

import '../../../core/immutable_collections.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_display.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_matcher.dart';

class LibraryEntryDiskSnapshot {
  LibraryEntryDiskSnapshot({
    required List<String> audioFilePaths,
    required Set<String> scannedFolderPaths,
    required this.authoritative,
  }) : audioFilePaths = immutableList(audioFilePaths),
       scannedFolderPaths = immutableSet(scannedFolderPaths);

  final List<String> audioFilePaths;
  final Set<String> scannedFolderPaths;
  final bool authoritative;

  Set<String> get audioFilePathSet => immutableSet(audioFilePaths);
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

  Future<String?> renameAudioDetailTarget(
    AudioDetailTarget target,
    String safeName,
  ) async {
    final oldPath = PathMatcher.normalize(target.targetPath);
    if (PathMatcher.isContentUri(oldPath)) {
      final name = target.isLibraryRootFolder
          ? safeName
          : '$safeName${_contentFileExtension(oldPath)}';
      final currentName = PathMatcher.lastContentPathSegment(oldPath);
      if (currentName != null &&
          PathMatcher.safeDecodeComponent(currentName) == name) {
        return oldPath;
      }
      final renamed = await _fileCacheGateway.renameDocument(
        path: oldPath,
        name: name,
      );
      final renamedPath = renamed?['path'] as String?;
      return renamedPath == null || renamedPath.isEmpty ? null : renamedPath;
    }

    final newPath = target.isLibraryRootFolder
        ? path.join(path.dirname(oldPath), safeName)
        : path.join(
            path.dirname(oldPath),
            '$safeName${path.extension(oldPath)}',
          );
    if (PathMatcher.equalsNormalized(oldPath, newPath)) return newPath;
    if (target.isLibraryRootFolder) {
      await Directory(oldPath).rename(newPath);
    } else {
      await File(oldPath).rename(newPath);
    }
    return newPath;
  }

  Future<List<MusicTrack>> loadRestorableTracks(String folderPath) {
    return PathMatcher.isContentUri(folderPath)
        ? _loadRestorableContentTracks(folderPath)
        : _loadRestorableFileTracks(folderPath);
  }

  Future<List<MusicTrack>> _loadRestorableFileTracks(String folderPath) async {
    final snapshot = await _loadFileSystemSnapshot(folderPath);
    final tracks = <MusicTrack>[];
    for (final mediaPath in snapshot.audioFilePaths) {
      FileStat? stat;
      try {
        stat = await File(mediaPath).stat();
      } catch (_) {
        // File metadata is optional for restored library entries.
      }
      final parentFolder = path.dirname(mediaPath);
      final folderName = path.basename(parentFolder);
      tracks.add(
        MusicTrack(
          path: mediaPath,
          displayName: path.basenameWithoutExtension(mediaPath),
          groupKey: parentFolder,
          groupTitle: folderName.isEmpty ? parentFolder : folderName,
          groupSubtitle: parentFolder,
          isSingle: false,
          isVideo: isVideoMediaFile(mediaPath),
          scannedAt: DateTime.now(),
          fileSizeBytes: stat?.size,
          modifiedAt: stat?.modified,
        ),
      );
    }
    return tracks;
  }

  Future<List<MusicTrack>> _loadRestorableContentTracks(
    String folderPath,
  ) async {
    try {
      final data = await _fileCacheGateway.scanFolderPayload(folderPath);
      if (data == null) return const <MusicTrack>[];
      final tracks = <MusicTrack>[];
      for (final item in data) {
        if (item is! Map) continue;
        final map = item.cast<Object?, Object?>();
        final rawPath = map['path']?.toString().trim();
        if (rawPath == null ||
            rawPath.isEmpty ||
            !isSupportedMediaFile(rawPath)) {
          continue;
        }
        final mediaPath = PathMatcher.isContentUri(rawPath)
            ? rawPath
            : path.normalize(rawPath);
        final nativeGroupKey = map['groupKey']?.toString().trim();
        final nativeGroupTitle = map['groupTitle']?.toString().trim();
        final nativeGroupSubtitle = map['groupSubtitle']?.toString().trim();
        final groupKey = (nativeGroupKey?.isNotEmpty ?? false)
            ? nativeGroupKey!
            : path.dirname(mediaPath);
        final groupTitle = (nativeGroupTitle?.isNotEmpty ?? false)
            ? nativeGroupTitle!
            : PathDisplay.folderName(groupKey);
        final groupSubtitle = (nativeGroupSubtitle?.isNotEmpty ?? false)
            ? nativeGroupSubtitle!
            : groupKey;
        final displayName = map['title']?.toString().trim();
        final scannedAtMs = map['scannedAtMs'] as num?;
        final modifiedAtMs = map['modifiedAtMs'] as num?;
        tracks.add(
          MusicTrack(
            path: mediaPath,
            displayName: displayName?.isEmpty ?? true
                ? PathDisplay.fileName(mediaPath, withoutExtension: true)
                : displayName!,
            groupKey: groupKey,
            groupTitle: groupTitle,
            groupSubtitle: groupSubtitle,
            isSingle: false,
            isVideo: map['isVideo'] as bool? ?? isVideoMediaFile(mediaPath),
            scannedAt: scannedAtMs == null
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(scannedAtMs.toInt()),
            fileSizeBytes: (map['fileSizeBytes'] as num?)?.toInt(),
            modifiedAt: modifiedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(modifiedAtMs.toInt()),
          ),
        );
      }
      return tracks;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'library_entry_restore_scan_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return const <MusicTrack>[];
    }
  }

  String _contentFileExtension(String targetPath) {
    final segment = PathMatcher.lastContentPathSegment(targetPath);
    final decoded = segment == null
        ? targetPath
        : PathMatcher.safeDecodeComponent(segment).replaceAll('\\', '/');
    return path.extension(decoded);
  }

  Future<LibraryEntryDiskSnapshot> _loadFileSystemSnapshot(
    String libraryPath,
  ) async {
    final directory = Directory(libraryPath);
    if (!await directory.exists()) {
      return LibraryEntryDiskSnapshot(
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
      return LibraryEntryDiskSnapshot(
        audioFilePaths: <String>[],
        scannedFolderPaths: <String>{},
        authoritative: false,
      );
    }
    try {
      final payload = await _fileCacheGateway.scanFolderPayload(libraryPath);
      if (payload == null) {
        return LibraryEntryDiskSnapshot(
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
      return LibraryEntryDiskSnapshot(
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
