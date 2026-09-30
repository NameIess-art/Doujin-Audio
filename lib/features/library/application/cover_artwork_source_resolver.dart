import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import '../../../core/cache/app_cache_service.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import 'cover_artwork_store.dart';
import 'cover_image_cache_policy.dart';
import 'embedded_cover_artwork_service.dart';
import 'library_service.dart';

const Set<String> _folderCoverImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
  '.gif',
};
const int _maxConcurrentFolderCandidateResolutions = 4;

/// Discovers sources while selection and result caches remain in the cache service.
final class CoverArtworkSourceResolver {
  CoverArtworkSourceResolver({
    required LibraryService libraryService,
    required FileCachePlatformGateway fileCacheGateway,
    required CoverArtworkStore artworkStore,
    required bool Function() isClearingPersistentCache,
    Future<List<String>> Function(String rootPath, bool recursive)?
    filesystemImageScanner,
  }) : _libraryService = libraryService,
       _fileCacheGateway = fileCacheGateway,
       _artworkStore = artworkStore,
       _isClearing = isClearingPersistentCache,
       _filesystemImageScanner = filesystemImageScanner;
  final LibraryService _libraryService;
  final FileCachePlatformGateway _fileCacheGateway;
  final CoverArtworkStore _artworkStore;
  final bool Function() _isClearing;
  bool get _isClearingPersistentCache => _isClearing();
  final Future<List<String>> Function(String rootPath, bool recursive)?
  _filesystemImageScanner;
  final Map<String, Future<List<String>>> _folderImageIndexFutures =
      <String, Future<List<String>>>{};
  final Map<String, String> _folderImageSourceByDisplayKey = <String, String>{};
  final Map<String, String> _folderImageDisplayBySourceKey = <String, String>{};

  bool hasSourceForDisplay(String value) => _folderImageSourceByDisplayKey
      .containsKey(PathMatcher.equivalenceKey(value));
  String? sourcePathForDisplay(String value) =>
      _folderImageSourceByDisplayKey[PathMatcher.equivalenceKey(value)];
  String? displayPathForSource(String value) =>
      _folderImageDisplayBySourceKey[PathMatcher.equivalenceKey(value)];
  void invalidateAll() {
    _folderImageIndexFutures.clear();
    _folderImageSourceByDisplayKey.clear();
    _folderImageDisplayBySourceKey.clear();
  }

  void trimMemory() => _folderImageIndexFutures.clear();
  bool _isVideoTrack(MusicTrack track) =>
      track.isVideo || isVideoMediaFile(track.path);
  String _trackSourceFingerprint(MusicTrack track) =>
      '${PathMatcher.normalize(track.path)}|${track.fileSizeBytes ?? 0}|${track.modifiedAt?.millisecondsSinceEpoch ?? 0}';
  static const int _maxFolderImageSources = 500;
  Future<List<String>> candidatesWithSelectedCover(
    String selectedCover,
    List<String> candidates,
  ) async {
    final selectedPathKey = PathMatcher.equivalenceKey(selectedCover);
    final selectedContentKey = await localCoverContentKey(selectedCover);
    final seenPaths = <String>{selectedPathKey};
    final seenContentKeys = <String>{?selectedContentKey};
    final distinct = <String>[selectedCover];
    for (final candidate in candidates) {
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) continue;
      final contentKey = await localCoverContentKey(candidate);
      if (contentKey != null && !seenContentKeys.add(contentKey)) {
        continue;
      }
      distinct.add(candidate);
    }
    return List<String>.unmodifiable(distinct);
  }

  Future<String?> localCoverContentKey(String coverPath) async {
    if (PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return null;
    }
    try {
      final file = File(coverPath);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length <= 0 || length > maxCoverFileBytes) return null;
      final digest = await sha256.bind(file.openRead()).first;
      return '$length:$digest';
    } catch (_) {
      return null;
    }
  }

  Future<String?> resolveVideoFramePathForTrack(MusicTrack track) async {
    final logicalKey =
        'video:${PathMatcher.normalize(track.path)}:'
        '${track.modifiedAt?.millisecondsSinceEpoch ?? 0}:v3';
    final storedFrame = _artworkStore.resolvedPath(logicalKey);
    if (storedFrame != null) return storedFrame;
    try {
      final nativeFrame = await _fileCacheGateway.resolveVideoFrame(
        path: track.path,
        modifiedAtMs: track.modifiedAt?.millisecondsSinceEpoch,
      );
      if (nativeFrame != null && nativeFrame.isNotEmpty) {
        return await persistBridgeCover(
          logicalKey: logicalKey,
          sourcePath: nativeFrame,
          namespace: CoverArtworkNamespace.generated,
        );
      }
    } on MissingPluginException {
      return null;
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService.resolveVideoFramePathForTrack error',
        error: e,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  Future<String?> resolvePlatformCoverPathForTrack(
    MusicTrack track, {
    String? rootFolder,
    bool includeGroupCoverFallback = true,
  }) async {
    try {
      final nativeCover = await _fileCacheGateway.resolveTrackCover(
        path: track.path,
        groupKey: includeGroupCoverFallback ? track.groupKey : null,
        rootFolder: rootFolder,
      );
      if (nativeCover != null && nativeCover.isNotEmpty) {
        return await persistBridgeCover(
          logicalKey: 'native:${_trackSourceFingerprint(track)}',
          sourcePath: nativeCover,
          namespace: includeGroupCoverFallback
              ? CoverArtworkNamespace.generated
              : CoverArtworkNamespace.embedded,
        );
      }
    } on MissingPluginException {
      // Continue with the Dart fallback below.
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService.resolvePlatformCoverPathForTrack error',
        error: e,
        stackTrace: stackTrace,
      );
    }

    String? embeddedCover;
    try {
      embeddedCover = await EmbeddedCoverArtworkService.resolveForTrack(track);
      if (embeddedCover == null && PathMatcher.isContentUri(track.path)) {
        final localPath = await _fileCacheGateway.resolveDocumentFileSystemPath(
          track.path,
        );
        if (localPath != null && localPath.isNotEmpty) {
          embeddedCover = await EmbeddedCoverArtworkService.resolveForPath(
            localPath,
          );
        }
      }
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService.resolvePlatformCoverPathForTrack embedded cover error',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (embeddedCover != null) {
      return await persistBridgeCover(
        logicalKey: 'embedded:${_trackSourceFingerprint(track)}',
        sourcePath: embeddedCover,
        namespace: CoverArtworkNamespace.embedded,
      );
    }

    return null;
  }

  Future<String?> resolveEmbeddedCoverForPath(String filePath) async {
    final track = _libraryService.trackByPath(filePath);
    if (track != null) {
      return resolvePlatformCoverPathForTrack(
        track,
        includeGroupCoverFallback: false,
      );
    }
    try {
      final nativeCover = await _fileCacheGateway.resolveTrackCover(
        path: filePath,
      );
      if (nativeCover != null && nativeCover.isNotEmpty) {
        return await persistBridgeCover(
          logicalKey: 'native:${PathMatcher.normalize(filePath)}',
          sourcePath: nativeCover,
          namespace: CoverArtworkNamespace.embedded,
        );
      }
    } on MissingPluginException {
      // Continue with the Dart fallback below.
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService.resolveEmbeddedCoverForPath native error',
        error: e,
        stackTrace: stackTrace,
      );
    }

    String? embeddedCover;
    try {
      embeddedCover = await EmbeddedCoverArtworkService.resolveForPath(
        filePath,
      );
      if (embeddedCover == null && PathMatcher.isContentUri(filePath)) {
        final localPath = await _fileCacheGateway.resolveDocumentFileSystemPath(
          filePath,
        );
        if (localPath != null && localPath.isNotEmpty) {
          embeddedCover = await EmbeddedCoverArtworkService.resolveForPath(
            localPath,
          );
        }
      }
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService.resolveEmbeddedCoverForPath embedded error',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (embeddedCover != null) {
      return await persistBridgeCover(
        logicalKey: 'embedded:${PathMatcher.normalize(filePath)}',
        sourcePath: embeddedCover,
        namespace: CoverArtworkNamespace.embedded,
      );
    }

    return null;
  }

  Future<String> persistBridgeCover({
    required String logicalKey,
    required String sourcePath,
    required CoverArtworkNamespace namespace,
  }) async {
    if (_isClearingPersistentCache || !_artworkStore.isInitialized) {
      AppCacheService.scheduleEnforce();
      return sourcePath;
    }
    if (PathMatcher.isContentUri(sourcePath) ||
        PathMatcher.isRemoteUri(sourcePath)) {
      await bindPersistentCover(logicalKey, sourcePath);
      return sourcePath;
    }
    try {
      final persisted = await _artworkStore.putFile(
        logicalKey: logicalKey,
        sourcePath: sourcePath,
        namespace: namespace,
      );
      if (persisted != null) return persisted;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to persist generated cover artwork.',
        error: error,
        stackTrace: stackTrace,
      );
    }
    AppCacheService.scheduleEnforce();
    return sourcePath;
  }

  Future<void> bindPersistentCover(String logicalKey, String path) async {
    if (_isClearingPersistentCache || !_artworkStore.isInitialized) return;
    await _artworkStore.bind(logicalKey, path);
  }

  Future<List<String>> resolveFolderCoverCandidates(
    String folderPath, {
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
  }) async {
    final candidates = <String>[];
    final seenPaths = <String>{};
    final seenContentKeys = <String>{};

    for (final imagePath in await discoverFolderImages(folderPath)) {
      final candidate = imagePath.trim();
      if (candidate.isEmpty) continue;
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) continue;
      final contentKey = await localCoverContentKey(candidate);
      if (contentKey != null) {
        seenContentKeys.add(contentKey);
      }
      candidates.add(candidate);
    }

    Future<void> addEmbeddedCandidate(String? value) async {
      final candidate = value?.trim();
      if (candidate == null || candidate.isEmpty) return;
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) return;
      final contentKey = await localCoverContentKey(candidate);
      if (contentKey != null && !seenContentKeys.add(contentKey)) {
        return;
      }
      candidates.add(candidate);
    }

    if (!includeEmbeddedCovers) {
      return List<String>.unmodifiable(candidates);
    }

    final tracks = tracksInCompleteCoverScope(folderPath);
    for (
      var start = 0;
      start < tracks.length;
      start += _maxConcurrentFolderCandidateResolutions
    ) {
      final nextEnd = start + _maxConcurrentFolderCandidateResolutions;
      final end = nextEnd < tracks.length ? nextEnd : tracks.length;
      final batch = tracks.sublist(start, end);
      final resolved = await Future.wait(
        batch.map(
          (track) => _isVideoTrack(track)
              ? includeVideoFrames
                    ? resolveVideoFramePathForTrack(track)
                    : Future<String?>.value()
              : resolvePlatformCoverPathForTrack(
                  track,
                  includeGroupCoverFallback: false,
                ),
        ),
      );
      for (final candidate in resolved) {
        await addEmbeddedCandidate(candidate);
      }
    }
    if (tracks.isEmpty &&
        !PathMatcher.isContentUri(folderPath) &&
        !PathMatcher.isRemoteUri(folderPath)) {
      final audioFiles = await discoverFolderAudioFiles(folderPath);
      for (
        var start = 0;
        start < audioFiles.length;
        start += _maxConcurrentFolderCandidateResolutions
      ) {
        final nextEnd = start + _maxConcurrentFolderCandidateResolutions;
        final end = nextEnd < audioFiles.length ? nextEnd : audioFiles.length;
        final batch = audioFiles.sublist(start, end);
        final resolved = await Future.wait(
          batch.map(resolveEmbeddedCoverForPath),
        );
        for (final candidate in resolved) {
          await addEmbeddedCandidate(candidate);
        }
      }
    }
    return List<String>.unmodifiable(candidates);
  }

  Future<List<String>> discoverFolderAudioFiles(
    String folderPath, {
    bool recursive = true,
  }) async {
    try {
      final directory = Directory(folderPath);
      if (!await directory.exists()) return const <String>[];
      final audioFiles = <String>[];
      await for (final entity in directory.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final ext = path.extension(entity.path).toLowerCase();
        if (supportedAudioExtensions.contains(ext)) {
          audioFiles.add(entity.path);
        }
      }
      audioFiles.sort();
      return List<String>.unmodifiable(audioFiles);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<String?> resolvePreferredFolderCover(String folderPath) async {
    final images = await discoverFolderImages(folderPath, recursive: false);
    if (images.isNotEmpty) return images.first;

    final nestedImages = await discoverFolderImages(folderPath);
    if (nestedImages.isNotEmpty) return nestedImages.first;

    for (final track in tracksInCompleteCoverScope(folderPath)) {
      final candidate = _isVideoTrack(track)
          ? await resolveVideoFramePathForTrack(track)
          : await resolvePlatformCoverPathForTrack(
              track,
              includeGroupCoverFallback: false,
            );
      if (candidate != null && candidate.trim().isNotEmpty) return candidate;
    }
    return null;
  }

  Future<List<String>> discoverFolderImages(
    String folderPath, {
    bool recursive = true,
  }) async {
    if (PathMatcher.isContentUri(folderPath)) {
      try {
        final discovered = await _fileCacheGateway.discoverRootImages(
          path: folderPath,
          rootFolder: folderPath,
          recursive: recursive,
        );
        for (final image in discovered) {
          rememberFolderImageSource(image.displayPath, image.sourcePath);
        }
        return List<String>.unmodifiable(
          discovered.map((image) => image.displayPath),
        );
      } on MissingPluginException {
        return const <String>[];
      } catch (error, stackTrace) {
        AppLogService.warning(
          'Unable to discover content folder images.',
          error: error,
          stackTrace: stackTrace,
        );
        return const <String>[];
      }
    }

    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (!recursive) {
      return buildFolderImageIndex(normalizedFolder, recursive: false);
    }
    final indexRoot = folderImageIndexRoot(normalizedFolder);
    final indexedImages = await _folderImageIndexFutures.putIfAbsent(
      indexRoot,
      () => buildFolderImageIndex(indexRoot),
    );
    return List<String>.unmodifiable(
      indexedImages.where(
        (imagePath) => recursive
            ? PathMatcher.isWithinOrEqual(imagePath, normalizedFolder)
            : PathMatcher.parentEquivalenceKey(imagePath) ==
                  PathMatcher.equivalenceKey(normalizedFolder),
      ),
    );
  }

  String folderImageIndexRoot(String folderPath) {
    final roots = <String>[
      ..._libraryService.watchedLibraries,
      ..._libraryService.watchedFolders,
    ];
    return mostSpecificContainingCoverRoot(roots, folderPath) ?? folderPath;
  }

  Future<List<String>> buildFolderImageIndex(
    String rootPath, {
    bool recursive = true,
  }) async {
    try {
      final scanner = _filesystemImageScanner;
      final images = scanner == null
          ? recursive
                ? await compute(
                    _scanFilesystemFolderImages,
                    (rootPath: rootPath, recursive: true),
                    debugLabel: 'library_folder_cover_index',
                  )
                : await _scanFilesystemFolderImages((
                    rootPath: rootPath,
                    recursive: false,
                  ))
          : await scanner(rootPath, recursive);
      for (final imagePath in images) {
        rememberFolderImageSource(imagePath, imagePath);
      }
      return List<String>.unmodifiable(images);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to discover folder cover images.',
        error: error,
        stackTrace: stackTrace,
      );
      return const <String>[];
    }
  }

  void rememberFolderImageSource(String displayPath, String sourcePath) {
    final display = displayPath.trim();
    final source = sourcePath.trim();
    if (display.isEmpty || source.isEmpty) return;
    if (_folderImageSourceByDisplayKey.length >= _maxFolderImageSources) {
      final oldestKey = _folderImageSourceByDisplayKey.keys.first;
      final mappedSource = _folderImageSourceByDisplayKey.remove(oldestKey);
      if (mappedSource != null) {
        _folderImageDisplayBySourceKey.remove(
          PathMatcher.equivalenceKey(mappedSource),
        );
      }
    }
    _folderImageSourceByDisplayKey[PathMatcher.equivalenceKey(display)] =
        source;
    _folderImageDisplayBySourceKey[PathMatcher.equivalenceKey(source)] =
        display;
  }

  List<MusicTrack> tracksInCompleteCoverScope(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (normalizedFolderPath.isEmpty) return const <MusicTrack>[];
    return _libraryService.library
        .where((track) {
          final groupKey = track.groupKey.trim();
          return PathMatcher.isWithinOrEqual(
                track.path,
                normalizedFolderPath,
              ) ||
              (groupKey.isNotEmpty &&
                  PathMatcher.isWithinOrEqual(groupKey, normalizedFolderPath));
        })
        .toList(growable: false);
  }

  void invalidateFolderImageIndexes(String normalizedScope) {
    final roots = _folderImageIndexFutures.keys.toList(growable: false);
    for (final root in roots) {
      if (PathMatcher.isWithinOrEqual(normalizedScope, root) ||
          PathMatcher.isWithinOrEqual(root, normalizedScope)) {
        _folderImageIndexFutures.remove(root);
      }
    }
  }
}

Future<List<String>> _scanFilesystemFolderImages(
  ({String rootPath, bool recursive}) request,
) async {
  final directory = Directory(request.rootPath);
  if (!await directory.exists()) return const <String>[];

  final images = <String>[];
  await for (final entity in directory.list(
    recursive: request.recursive,
    followLinks: false,
  )) {
    if (entity is! File ||
        !_folderCoverImageExtensions.contains(
          path.extension(entity.path).toLowerCase(),
        )) {
      continue;
    }
    images.add(entity.path);
  }
  images.sort();
  return images;
}

String? mostSpecificContainingCoverRoot(Iterable<String> roots, String value) {
  String? bestMatch;
  for (final root in roots) {
    if (!PathMatcher.isWithinOrEqual(value, root)) continue;
    if (bestMatch == null || root.length > bestMatch.length) {
      bestMatch = root;
    }
  }
  return bestMatch;
}
