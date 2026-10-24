import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'library_organizer.dart';

import '../../../core/immutable_collections.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_display.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_matcher.dart';

class AudioDetailRenameException implements Exception {
  const AudioDetailRenameException(this.reason);

  final String reason;
}

class LibraryEntryDiskSnapshot {
  LibraryEntryDiskSnapshot({
    required List<String> audioFilePaths,
    required Set<String> scannedFolderPaths,
    required this.authoritative,
    Map<String, String> trackParentPaths = const <String, String>{},
  }) : audioFilePaths = immutableList(audioFilePaths),
       scannedFolderPaths = immutableSet(scannedFolderPaths),
       trackParentPaths = immutableMap(trackParentPaths);

  final List<String> audioFilePaths;
  final Set<String> scannedFolderPaths;
  final bool authoritative;
  final Map<String, String> trackParentPaths;

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
  ) => renameEntry(
    target.targetPath,
    safeName,
    isDirectory: target.isLibraryRootFolder,
  );

  Future<String?> renameEntry(
    String entryPath,
    String safeName, {
    required bool isDirectory,
  }) async {
    final oldPath = PathMatcher.normalize(entryPath);
    if (PathMatcher.isContentUri(oldPath)) {
      final renamed = await _fileCacheGateway.renameDocument(
        path: oldPath,
        name: safeName,
        preserveExtension: !isDirectory,
      );
      final renamedPath = renamed?['path'] as String?;
      return renamedPath == null || renamedPath.isEmpty ? null : renamedPath;
    }

    final newPath = isDirectory
        ? path.join(path.dirname(oldPath), safeName)
        : path.join(
            path.dirname(oldPath),
            '$safeName${path.extension(oldPath)}',
          );
    if (PathMatcher.equalsNormalized(oldPath, newPath)) return newPath;
    if (await FileSystemEntity.type(newPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const AudioDetailRenameException('nameConflict');
    }
    if (isDirectory) {
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
    if (!snapshot.authoritative) return const <MusicTrack>[];
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
      final result = await _fileCacheGateway.scanFolder(folderPath);
      if (!result.isComplete) return const <MusicTrack>[];
      final tracks = <MusicTrack>[];
      for (final scanned in result.tracks) {
        final rawPath = scanned.path.trim();
        if (rawPath.isEmpty) continue;
        final mediaPath = PathMatcher.normalize(rawPath);
        final groupKey = scanned.groupKey.trim().isNotEmpty
            ? scanned.groupKey
            : folderPath;
        final track = MusicTrack(
          path: mediaPath,
          displayName: scanned.displayName?.isNotEmpty == true
              ? scanned.displayName!
              : PathDisplay.fileName(mediaPath, withoutExtension: true),
          groupKey: groupKey,
          groupTitle: scanned.groupTitle.isNotEmpty
              ? scanned.groupTitle
              : PathDisplay.folderName(groupKey),
          groupSubtitle: scanned.groupSubtitle.isNotEmpty
              ? scanned.groupSubtitle
              : groupKey,
          isSingle: false,
          isVideo: scanned.isVideo,
          scannedAt: scanned.scannedAt ?? DateTime.now(),
          fileSizeBytes: scanned.fileSizeBytes,
          modifiedAt: scanned.modifiedAt,
        );
        // The native scanner already filtered supported media by display name
        // and MIME type. A document ID is not a filename or format hint.
        if (const LibraryOrganizer().trackBelongsToLibrary(folderPath, track)) {
          tracks.add(track);
        }
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

  Future<LibraryEntryDiskSnapshot> _loadFileSystemSnapshot(
    String libraryPath,
  ) async {
    final directory = Directory(libraryPath);
    if (!await directory.exists()) {
      return LibraryEntryDiskSnapshot(
        audioFilePaths: <String>[],
        scannedFolderPaths: <String>{},
        authoritative: false,
      );
    }

    final audioFiles = <String>{};
    final folderPaths = <String>{};
    final pendingDirectories = Queue<Directory>()..add(directory);
    var processedEntities = 0;
    var scanFailed = false;
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
            folderPaths.add(normalizedPath);
            pendingDirectories.add(entity);
          } else if (entity is File && isSupportedMediaFile(normalizedPath)) {
            audioFiles.add(normalizedPath);
          }
        }
      } on FileSystemException catch (error, stackTrace) {
        scanFailed = true;
        AppLogService.warning(
          'library_entry_directory_scan_failed',
          error: error,
          stackTrace: stackTrace,
        );
      } catch (error, stackTrace) {
        scanFailed = true;
        AppLogService.warning(
          'library_entry_directory_scan_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    return _snapshot(audioFiles, folderPaths, authoritative: !scanFailed);
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
      final result = await _fileCacheGateway.scanFolder(libraryPath);
      if (!result.isComplete) {
        return LibraryEntryDiskSnapshot(
          audioFilePaths: <String>[],
          scannedFolderPaths: <String>{},
          authoritative: false,
        );
      }
      final audioFiles = <String>{};
      final folderPaths = <String>{};
      final trackParents = <String, String>{};
      for (final track in result.tracks) {
        final scannedPath = track.path.trim();
        if (scannedPath.isEmpty) continue;
        final media = MusicTrack(
          path: track.path,
          displayName: track.displayName ?? '',
          groupKey: track.groupKey,
          groupTitle: track.groupTitle,
          groupSubtitle: track.groupSubtitle,
          isSingle: track.isSingle,
        );
        const organizer = LibraryOrganizer();
        if (!organizer.trackBelongsToLibrary(libraryPath, media)) continue;
        final normalizedPath = PathMatcher.normalize(scannedPath);
        audioFiles.add(normalizedPath);
        trackParents[normalizedPath] =
            organizer.folderPathForLibraryTrack(libraryPath, media) ??
            PathMatcher.normalize(libraryPath);
        final groupKey = track.groupKey.trim();
        if (groupKey.isNotEmpty &&
            !PathMatcher.equalsNormalized(groupKey, libraryPath)) {
          folderPaths.add(PathMatcher.normalize(groupKey));
        }
      }
      return _snapshot(
        audioFiles,
        folderPaths,
        authoritative: true,
        trackParentPaths: trackParents,
      );
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
    Map<String, String> trackParentPaths = const <String, String>{},
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
      trackParentPaths: trackParentPaths,
    );
  }
}
