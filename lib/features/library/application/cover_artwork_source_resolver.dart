import 'dart:async';
import 'dart:collection';
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
import 'library_organizer.dart';

const Set<String> _folderCoverImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
  '.gif',
};
const int _maxConcurrentFolderCandidateResolutions = 4;

class _FolderImageIndex {
  late Future<List<CoverImageReference>> result;
  bool refreshing = false;
  int users = 0;
}

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
  final Map<
    ({String rootPath, bool recursive, bool preferredOnly}),
    _FolderImageIndex
  >
  _folderImageIndexFutures = LinkedHashMap(
    equals: (first, second) =>
        first.recursive == second.recursive &&
        first.preferredOnly == second.preferredOnly &&
        PathMatcher.equalsNormalized(first.rootPath, second.rootPath),
    hashCode: (key) => Object.hash(
      PathMatcher.equivalenceKey(key.rootPath),
      key.recursive,
      key.preferredOnly,
    ),
  );
  final Map<String, Map<String, String>> _folderImageSourceByDisplayKey = {};
  final Map<String, String> _folderImageDisplayBySourceKey = {};

  @visibleForTesting
  int get folderImageIndexCount => _folderImageIndexFutures.length;

  final Map<String, Future<String?>> _platformCoverFutures = {};
  Iterable<Future<String?>> get pendingPlatformCovers =>
      _platformCoverFutures.values;

  String? coverScopeFolderForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = trackPath ?? track?.path;
    if (pathValue == null || pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) return null;
    if (isStandaloneCoverAudioTrack(track, trackPath: trackPath)) return null;

    final trackOwnPath = track?.path;
    final pathOverridesTrack =
        trackPath != null &&
        trackOwnPath != null &&
        !PathMatcher.equalsNormalized(trackPath, trackOwnPath);
    final groupKey = pathOverridesTrack ? '' : track?.groupKey.trim() ?? '';
    final watchedFolder =
        mostSpecificContainingCoverRoot(
          _libraryService.watchedFolders,
          pathValue,
        ) ??
        (groupKey.isEmpty
            ? null
            : mostSpecificContainingCoverRoot(
                _libraryService.watchedFolders,
                groupKey,
              ));
    if (watchedFolder != null && watchedFolder.isNotEmpty) {
      return watchedFolder;
    }

    final watchedLibrary =
        (groupKey.isEmpty
            ? null
            : mostSpecificContainingCoverRoot(
                _libraryService.watchedLibraries,
                groupKey,
              )) ??
        mostSpecificContainingCoverRoot(
          _libraryService.watchedLibraries,
          pathValue,
        );
    if (watchedLibrary != null && watchedLibrary.isNotEmpty) {
      final workScope = groupKey.isEmpty
          ? null
          : const LibraryOrganizer().workScopeFolderPath(
              watchedLibrary,
              groupKey,
            );
      return workScope ?? watchedLibrary;
    }

    if (groupKey.isNotEmpty) return PathMatcher.normalize(groupKey);
    final parent = PathMatcher.parentPath(pathValue);
    if (parent != null && parent.isNotEmpty) return parent;

    final directoryPath = path.dirname(pathValue);
    if (directoryPath.isEmpty || directoryPath == '.') return null;
    return directoryPath;
  }

  String? _enclosingFolderForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = trackPath ?? track?.path;
    if (pathValue == null || pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) return null;

    final groupKey = track?.groupKey.trim();
    if (groupKey != null && groupKey.isNotEmpty) {
      return PathMatcher.normalize(groupKey);
    }
    final parent = PathMatcher.parentPath(pathValue);
    if (parent != null && parent.isNotEmpty) {
      return PathMatcher.normalize(parent);
    }
    return null;
  }

  List<String> candidateFolderScopesForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final pathValue = trackPath ?? track?.path;
    if (pathValue == null || pathValue.isEmpty) return const <String>[];
    if (PathMatcher.isRemoteUri(pathValue)) return const <String>[];

    final scopes = <String>[];
    final seen = <String>{};
    void addScope(String? scope) {
      final value = scope?.trim();
      if (value == null || value.isEmpty) return;
      final normalized = PathMatcher.normalize(value);
      if (normalized.isEmpty || !seen.add(normalized)) return;
      scopes.add(normalized);
    }

    final enclosing = _enclosingFolderForTrack(track, trackPath: pathValue);
    addScope(enclosing);

    if (enclosing != null) {
      final roots = <String>[
        ..._libraryService.watchedFolders,
        ..._libraryService.watchedLibraries,
      ];
      var current = PathMatcher.parentPath(enclosing);
      while (current != null &&
          current.isNotEmpty &&
          current != '.' &&
          current != path.rootPrefix(current)) {
        final normalizedCurrent = PathMatcher.normalize(current);
        addScope(normalizedCurrent);
        if (roots.any(
          (r) => PathMatcher.equalsNormalized(r, normalizedCurrent),
        )) {
          break;
        }
        final parent = PathMatcher.parentPath(current);
        if (parent == null || parent == current) break;
        current = parent;
      }
    }

    if (track != null && !track.isSingle && track.groupKey.trim().isNotEmpty) {
      addScope(track.groupKey);
    }

    if (track != null) {
      final rootFolder = const LibraryOrganizer().rootPathForTrack(
        track,
        _libraryService.watchedFolders,
        watchedLibraries: _libraryService.watchedLibraries,
      );
      addScope(rootFolder);
    }

    addScope(coverScopeFolderForTrack(track, trackPath: pathValue));

    return List<String>.unmodifiable(scopes);
  }

  bool hasSourceForDisplay(String value) => _folderImageSourceByDisplayKey
      .containsKey(PathMatcher.equivalenceKey(value));
  String? sourcePathForDisplay(String value) =>
      _folderImageSourceByDisplayKey[PathMatcher.equivalenceKey(value)]
          ?.values
          .last;
  String? displayPathForSource(String value) =>
      _folderImageDisplayBySourceKey[PathMatcher.equivalenceKey(value)];
  void invalidateAll() {
    _folderImageIndexFutures.clear();
    _platformCoverFutures.clear();
    _folderImageSourceByDisplayKey.clear();
    _folderImageDisplayBySourceKey.clear();
  }

  void trimMemory() {
    _folderImageIndexFutures.clear();
    _folderImageSourceByDisplayKey.clear();
    _folderImageDisplayBySourceKey.clear();
  }

  bool _isVideoTrack(MusicTrack track) =>
      track.isVideo || isVideoMediaFile(track.path);
  String _trackSourceFingerprint(MusicTrack track) =>
      '${PathMatcher.normalize(track.path)}|${track.fileSizeBytes ?? 0}|${track.modifiedAt?.millisecondsSinceEpoch ?? 0}';
  static const int _maxFolderImageSources = 500;
  Future<List<String>> _candidatesWithSelectedCover(
    String selectedCover,
    List<String> candidates,
    Future<String?> Function(String) contentKeyFor,
  ) async {
    final selectedPathKey = PathMatcher.equivalenceKey(selectedCover);
    final selectedContentKey = await contentKeyFor(selectedCover);
    final seenPaths = <String>{selectedPathKey};
    final seenContentKeys = <String>{?selectedContentKey};
    final distinct = <String>[selectedCover];
    for (final candidate in candidates) {
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) continue;
      final contentKey = await contentKeyFor(candidate);
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
    final lease = await AppCacheService.protectTemporaryDirectories({
      'video_frames',
      'doujin_audio_covers',
    });
    try {
      final logicalKey =
          'video:${PathMatcher.normalize(track.path)}:'
          '${track.modifiedAt?.millisecondsSinceEpoch ?? 0}:v3';
      final storedFrame = await _artworkStore.validatedPath(logicalKey);
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
    } finally {
      lease.release();
    }
  }

  Future<String?> resolvePlatformCoverPathForTrack(
    MusicTrack track, {
    String? rootFolder,
    bool includeGroupCoverFallback = true,
  }) {
    final grouped = includeGroupCoverFallback && !track.isSingle;
    final nativeKey =
        'native:${_trackSourceFingerprint(track)}${grouped ? '|group' : ''}';
    final requestKey =
        '${PathMatcher.equivalenceKey(track.path)}|${track.fileSizeBytes ?? 0}|${track.modifiedAt?.millisecondsSinceEpoch ?? 0}|$grouped|${rootFolder == null ? '' : PathMatcher.equivalenceKey(rootFolder)}';
    return _platformCoverFutures.putIfAbsent(requestKey, () {
      late final Future<String?> task;
      task =
          (() async {
            final stored =
                await _artworkStore.validatedPath(nativeKey) ??
                await _artworkStore.validatedPath(
                  'embedded:${_trackSourceFingerprint(track)}',
                );
            if (stored != null) return stored;
            return _loadPlatformCoverPathForTrack(
              track,
              nativeKey: nativeKey,
              rootFolder: rootFolder,
              includeGroupCoverFallback: grouped,
            );
          })().whenComplete(() {
            if (identical(_platformCoverFutures[requestKey], task)) {
              _platformCoverFutures.remove(requestKey);
            }
          });
      return task;
    });
  }

  Future<String?> _loadPlatformCoverPathForTrack(
    MusicTrack track, {
    required String nativeKey,
    String? rootFolder,
    required bool includeGroupCoverFallback,
  }) async {
    final lease = await AppCacheService.protectTemporaryDirectories({
      'embedded_covers',
      'doujin_audio_covers',
    });
    try {
      try {
        final scope = rootFolder ?? track.groupKey;
        final sharedSafFolder =
            includeGroupCoverFallback &&
            PathMatcher.isContentUri(track.path) &&
            PathMatcher.isContentUri(scope);
        if (sharedSafFolder) {
          final images = await discoverFolderImages(scope, preferredOnly: true);
          if (images.isNotEmpty) return images.first;
        }
        final nativeCover = await _fileCacheGateway.resolveTrackCover(
          path: track.path,
          // SAF folder discovery is shared by scope above; probing each track
          // must not repeat that directory walk when the folder has no image.
          groupKey: includeGroupCoverFallback && !sharedSafFolder
              ? track.groupKey
              : null,
          rootFolder: sharedSafFolder ? null : rootFolder,
        );
        if (nativeCover != null && nativeCover.isNotEmpty) {
          return await persistBridgeCover(
            logicalKey: nativeKey,
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
        embeddedCover = await EmbeddedCoverArtworkService.resolveForTrack(
          track,
        );
        if (embeddedCover == null && PathMatcher.isContentUri(track.path)) {
          final localPath = await _fileCacheGateway
              .resolveDocumentFileSystemPath(track.path);
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
    } finally {
      lease.release();
    }
  }

  Future<String?> resolveEmbeddedCoverForPath(String filePath) async {
    final track = _libraryService.trackByPath(filePath);
    if (track != null) {
      return resolvePlatformCoverPathForTrack(
        track,
        includeGroupCoverFallback: false,
      );
    }
    final lease = await AppCacheService.protectTemporaryDirectories({
      'embedded_covers',
      'doujin_audio_covers',
    });
    try {
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
          final localPath = await _fileCacheGateway
              .resolveDocumentFileSystemPath(filePath);
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
    } finally {
      lease.release();
    }
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
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
    bool propagateFailure = false,
  }) async {
    final candidates = <String>[];
    final seenPaths = <String>{};
    final seenContentKeys = <String>{};
    // Discovery and selected-cover deduplication share reads only within this
    // operation; a later request must observe changed source bytes.
    final contentKeys = <String, Future<String?>>{};
    Future<String?> contentKeyFor(String candidate) => contentKeys.putIfAbsent(
      PathMatcher.equivalenceKey(candidate),
      () => localCoverContentKey(candidate),
    );
    Future<List<String>> finish() {
      final selected = selectedCoverPath?.trim();
      return selected == null || selected.isEmpty
          ? Future.value(List<String>.unmodifiable(candidates))
          : _candidatesWithSelectedCover(selected, candidates, contentKeyFor);
    }

    for (final imagePath in await discoverFolderImages(
      folderPath,
      propagateFailure: propagateFailure,
    )) {
      final candidate = imagePath.trim();
      if (candidate.isEmpty) continue;
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) continue;
      if (includeEmbeddedCovers) {
        final contentKey = await contentKeyFor(candidate);
        if (contentKey != null) {
          seenContentKeys.add(contentKey);
        }
      }
      candidates.add(candidate);
    }

    Future<void> addEmbeddedCandidate(String? value) async {
      final candidate = value?.trim();
      if (candidate == null || candidate.isEmpty) return;
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) return;
      final contentKey = await contentKeyFor(candidate);
      if (contentKey != null && !seenContentKeys.add(contentKey)) {
        return;
      }
      candidates.add(candidate);
    }

    if (!includeEmbeddedCovers) {
      return finish();
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
    return finish();
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
    final preferredOnly = PathMatcher.isContentUri(folderPath);
    final images = await discoverFolderImages(
      folderPath,
      recursive: false,
      preferredOnly: preferredOnly,
    );
    if (images.isNotEmpty) return images.first;

    final nestedImages = await discoverFolderImages(
      folderPath,
      preferredOnly: preferredOnly,
    );
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
    bool propagateFailure = false,
    bool preferredOnly = false,
  }) async => List<String>.unmodifiable(
    (await discoverFolderImageReferences(
      folderPath,
      recursive: recursive,
      propagateFailure: propagateFailure,
      preferredOnly: preferredOnly,
    )).map((image) => image.displayPath),
  );

  Future<List<CoverImageReference>> discoverFolderImageReferences(
    String folderPath, {
    bool recursive = true,
    bool propagateFailure = false,
    bool refresh = false,
    bool preferredOnly = false,
  }) async {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final isContent = PathMatcher.isContentUri(normalizedFolder);
    final indexRoot = recursive && !isContent
        ? folderImageIndexRoot(normalizedFolder)
        : normalizedFolder;
    final exactKey = (
      rootPath: normalizedFolder,
      recursive: recursive,
      preferredOnly: preferredOnly,
    );
    final key = refresh || _folderImageIndexFutures.containsKey(exactKey)
        ? exactKey
        : (
            rootPath: indexRoot,
            recursive: recursive,
            preferredOnly: preferredOnly,
          );
    if (refresh) {
      _folderImageIndexFutures.removeWhere(
        (other, _) =>
            other.preferredOnly &&
            (PathMatcher.isWithinOrEqual(other.rootPath, normalizedFolder) ||
                PathMatcher.isWithinOrEqual(normalizedFolder, other.rootPath)),
      );
    }
    final lookup = refresh
        ? _refreshFolderImageIndex(key)
        : _folderImageIndexFutures.putIfAbsent(
            key,
            () => _newFolderImageIndex(key),
          );
    lookup.users++;
    try {
      late final List<CoverImageReference> indexedImages;
      try {
        // A sibling refresh can patch a shared root while its scan is pending.
        // Await the latest patch without retiring that root's in-flight scan.
        while (true) {
          final result = lookup.result;
          final images = await result;
          if (identical(result, lookup.result)) {
            indexedImages = images;
            break;
          }
        }
        if (!identical(_folderImageIndexFutures[key], lookup)) {
          throw StateError('folder_image_index_invalidated');
        }
      } catch (_) {
        if (propagateFailure) rethrow;
        return const <CoverImageReference>[];
      }
      if (isContent && identical(_folderImageIndexFutures[key], lookup)) {
        for (final image in indexedImages) {
          rememberFolderImageSource(image.displayPath, image.sourcePath);
        }
      }
      return List<CoverImageReference>.unmodifiable(
        indexedImages.where(
          (image) =>
              isContent ||
              !recursive ||
              PathMatcher.isWithinOrEqual(image.displayPath, normalizedFolder),
        ),
      );
    } finally {
      lookup.users--;
      _trimFolderImageIndexes();
    }
  }

  void _trimFolderImageIndexes() {
    // Keep shared library roots, but bound duplicate subtree snapshots. Active
    // readers and ancestor patches must finish before their indexes retire.
    final subtrees = _folderImageIndexFutures.keys
        .where(
          (key) => !PathMatcher.equalsNormalized(
            key.rootPath,
            folderImageIndexRoot(key.rootPath),
          ),
        )
        .toList();
    var excess = subtrees.length - 32;
    for (final key in subtrees) {
      if (excess <= 0) break;
      if (_folderImageIndexFutures[key]!.users != 0) continue;
      _folderImageIndexFutures.remove(key);
      excess--;
    }
  }

  _FolderImageIndex _newFolderImageIndex(
    ({String rootPath, bool recursive, bool preferredOnly}) key,
  ) {
    final index = _FolderImageIndex();
    index.result =
        _buildFolderImageIndex(
          key.rootPath,
          recursive: key.recursive,
          preferredOnly: key.preferredOnly,
          isCurrent: () => identical(_folderImageIndexFutures[key], index),
        ).catchError((Object error, StackTrace stackTrace) {
          if (identical(_folderImageIndexFutures[key], index)) {
            _folderImageIndexFutures.remove(key);
          }
          if (error is! MissingPluginException) {
            AppLogService.warning(
              'Unable to discover folder cover images.',
              error: error,
              stackTrace: stackTrace,
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        });
    return index;
  }

  _FolderImageIndex _refreshFolderImageIndex(
    ({String rootPath, bool recursive, bool preferredOnly}) key,
  ) {
    final pending = _folderImageIndexFutures[key];
    if (pending?.refreshing == true) return pending!;
    _folderImageIndexFutures.removeWhere(
      (other, _) => key.recursive
          ? PathMatcher.isWithinOrEqual(other.rootPath, key.rootPath)
          : !other.recursive &&
                PathMatcher.equalsNormalized(other.rootPath, key.rootPath),
    );
    final refreshed = _newFolderImageIndex(key)..refreshing = true;
    _folderImageIndexFutures[key] = refreshed;
    refreshed.result = refreshed.result.whenComplete(() {
      refreshed.refreshing = false;
    });
    // Refresh only this subtree, preserving the cached siblings in any root.
    // Each patch captures its predecessor, so concurrent sibling scans merge.
    for (final entry in _folderImageIndexFutures.entries) {
      if (identical(entry.value, refreshed) ||
          entry.key.preferredOnly ||
          key.preferredOnly ||
          !entry.key.recursive ||
          !PathMatcher.isWithinOrEqual(key.rootPath, entry.key.rootPath)) {
        continue;
      }
      final previous = entry.value.result;
      refreshed.users++;
      entry.value.result = () async {
        try {
          final oldImages = await previous;
          final List<CoverImageReference> newImages;
          try {
            newImages = await refreshed.result;
          } catch (_) {
            // Failed discovery must retain the previously authoritative subtree.
            return oldImages;
          }
          if (!identical(_folderImageIndexFutures[key], refreshed)) {
            return oldImages;
          }
          final merged =
              <CoverImageReference>[
                ...oldImages.where((image) {
                  if (key.recursive) {
                    return !PathMatcher.isWithinOrEqual(
                      image.sourcePath,
                      key.rootPath,
                    );
                  }
                  return !PathMatcher.equalsNormalized(
                    PathMatcher.parentPath(image.sourcePath) ?? '',
                    key.rootPath,
                  );
                }),
                ...newImages,
              ]..sort(
                (first, second) =>
                    first.displayPath.compareTo(second.displayPath),
              );
          return List<CoverImageReference>.unmodifiable(merged);
        } finally {
          refreshed.users--;
          _trimFolderImageIndexes();
        }
      }();
      // A warmed root may have no current reader. Observe failures now while
      // preserving the error for callers that later await this patched result.
      entry.value.result.ignore();
    }
    return refreshed;
  }

  String folderImageIndexRoot(String folderPath) {
    final roots = <String>[
      ..._libraryService.watchedLibraries,
      ..._libraryService.watchedFolders,
    ];
    return mostSpecificContainingCoverRoot(roots, folderPath) ?? folderPath;
  }

  Future<List<CoverImageReference>> _buildFolderImageIndex(
    String rootPath, {
    required bool recursive,
    required bool preferredOnly,
    required bool Function() isCurrent,
  }) async {
    if (PathMatcher.isContentUri(rootPath)) {
      final lease = await AppCacheService.protectTemporaryDirectories({
        'doujin_audio_covers',
      });
      try {
        final discovered = await _fileCacheGateway.discoverRootImages(
          path: rootPath,
          rootFolder: rootPath,
          recursive: recursive,
          preferredOnly: preferredOnly,
        );
        // A retired native discovery must not repopulate the cleared index.
        if (!isCurrent()) return const [];
        var paths = List<String?>.filled(discovered.length, null);
        if (_artworkStore.isInitialized && !_isClearingPersistentCache) {
          try {
            paths = await _artworkStore.putFiles([
              for (final image in discovered)
                (
                  logicalKey:
                      'source-image:${PathMatcher.equivalenceKey(image.sourcePath)}',
                  sourcePath: image.displayPath,
                ),
            ], shouldCancel: () => !isCurrent());
          } catch (error, stackTrace) {
            AppLogService.warning(
              'Unable to persist discovered cover artwork.',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        if (!isCurrent()) return const [];
        if (paths.any((value) => value == null)) {
          AppCacheService.scheduleEnforce();
        }
        return List<CoverImageReference>.unmodifiable([
          for (var index = 0; index < discovered.length; index++)
            CoverImageReference(
              displayPath: paths[index] ?? discovered[index].displayPath,
              sourcePath: discovered[index].sourcePath,
            ),
        ]);
      } finally {
        lease.release();
      }
    }
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
    if (!isCurrent()) return const [];
    for (final imagePath in images) {
      rememberFolderImageSource(imagePath, imagePath);
    }
    return List<CoverImageReference>.unmodifiable(
      images.map(
        (image) => CoverImageReference(displayPath: image, sourcePath: image),
      ),
    );
  }

  void rememberFolderImageSource(String displayPath, String sourcePath) {
    final display = displayPath.trim();
    final source = sourcePath.trim();
    if (display.isEmpty || source.isEmpty) return;
    final sourceKey = PathMatcher.equivalenceKey(source);
    final displayKey = PathMatcher.equivalenceKey(display);
    _forgetFolderImageSource(sourceKey);
    _folderImageSourceByDisplayKey.putIfAbsent(
      displayKey,
      () => {},
    )[sourceKey] = source;
    _folderImageDisplayBySourceKey[sourceKey] = display;
    while (_folderImageDisplayBySourceKey.length > _maxFolderImageSources) {
      _forgetFolderImageSource(_folderImageDisplayBySourceKey.keys.first);
    }
  }

  void _forgetFolderImageSource(String sourceKey) {
    final previous = _folderImageDisplayBySourceKey.remove(sourceKey);
    if (previous == null) return;
    final displayKey = PathMatcher.equivalenceKey(previous);
    final sources = _folderImageSourceByDisplayKey[displayKey]!;
    // Content-addressed artwork can serve several original SAF documents.
    // Evicting or moving one source must preserve the remaining aliases.
    sources.remove(sourceKey);
    if (sources.isEmpty) {
      _folderImageSourceByDisplayKey.remove(displayKey);
    }
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
    for (final key in roots) {
      final root = key.rootPath;
      if (PathMatcher.isWithinOrEqual(normalizedScope, root) ||
          PathMatcher.isWithinOrEqual(root, normalizedScope)) {
        _folderImageIndexFutures.remove(key);
      }
    }
  }
}

Future<List<String>> _scanFilesystemFolderImages(
  ({String rootPath, bool recursive}) request,
) async {
  final directory = Directory(request.rootPath);
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

bool isStandaloneCoverAudioTrack(MusicTrack? track, {String? trackPath}) {
  final pathValue = trackPath ?? track?.path;
  final isVideo =
      track?.isVideo == true ||
      (pathValue?.isNotEmpty == true && isVideoMediaFile(pathValue!));
  return track?.isSingle == true && !isVideo;
}
