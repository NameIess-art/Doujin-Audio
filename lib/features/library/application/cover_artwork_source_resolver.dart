import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import '../../../core/cache/app_cache_service.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/app_platform.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import 'cover_artwork_store.dart';
import 'cover_image_cache_policy.dart';
import 'embedded_cover_artwork_service.dart';
import 'library_service.dart';
import 'library_organizer.dart';

const Set<String> folderCoverImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
  '.gif',
};
const int _maxConcurrentFolderCandidateResolutions = 4;
const int _coverTrackIndexThreshold = 512;

class _FolderImageIndex {
  late Future<List<CoverImageReference>> result;
  List<CoverImageReference>? _indexedSource;
  List<({String key, int index})>? _sortedByKey;
  bool refreshing = false;
  int users = 0;

  List<CoverImageReference> filterWithin(
    List<CoverImageReference> images,
    String normalizedFolder, {
    required bool firstOnly,
    bool preferDirect = false,
  }) {
    if (images.isEmpty) return const <CoverImageReference>[];
    if (!identical(_indexedSource, images)) {
      _indexedSource = images;
      _sortedByKey = [
        for (var i = 0; i < images.length; i++)
          (key: PathMatcher.equivalenceKey(images[i].displayPath), index: i),
      ]..sort((a, b) => a.key.compareTo(b.key));
    }
    final sorted = _sortedByKey!;
    final folderKey = PathMatcher.equivalenceKey(normalizedFolder);
    final prefix = folderKey.endsWith('/') ? folderKey : '$folderKey/';
    var low = 0;
    var high = sorted.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      if (sorted[mid].key.compareTo(prefix) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    if (firstOnly) {
      var minDirectIndex = -1;
      var minAnyIndex = -1;
      for (var i = low; i < sorted.length; i++) {
        final entry = sorted[i];
        if (!entry.key.startsWith(prefix)) break;
        if (preferDirect && entry.key.indexOf('/', prefix.length) < 0) {
          if (minDirectIndex < 0 || entry.index < minDirectIndex) {
            minDirectIndex = entry.index;
          }
        }
        if (minAnyIndex < 0 || entry.index < minAnyIndex) {
          minAnyIndex = entry.index;
        }
      }
      final chosen = minDirectIndex >= 0 ? minDirectIndex : minAnyIndex;
      if (chosen < 0) return const <CoverImageReference>[];
      return List<CoverImageReference>.unmodifiable(<CoverImageReference>[
        images[chosen],
      ]);
    }
    final matchedIndices = <int>[];
    for (var i = low; i < sorted.length; i++) {
      final entry = sorted[i];
      if (!entry.key.startsWith(prefix)) break;
      matchedIndices.add(entry.index);
    }
    if (matchedIndices.isEmpty) return const <CoverImageReference>[];
    matchedIndices.sort();
    return List<CoverImageReference>.unmodifiable([
      for (final index in matchedIndices) images[index],
    ]);
  }
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
        PathMatcher.equivalenceEquals(first.rootPath, second.rootPath),
    hashCode: (key) => Object.hash(
      PathMatcher.equivalenceHashCode(key.rootPath),
      key.recursive,
      key.preferredOnly,
    ),
  );
  final Map<String, Map<String, String>> _folderImageSourceByDisplayKey = {};
  final Map<String, String> _folderImageDisplayBySourceKey = {};

  @visibleForTesting
  int get folderImageIndexCount => _folderImageIndexFutures.length;

  final Map<String, Future<String?>> _platformCoverFutures = {};
  final _missingPlatformCovers = <String, String>{};
  ({
    List<MusicTrack> tracks,
    int generation,
    int length,
    Future<_CoverTrackIndex?> future,
  })?
  _coverTrackIndex;
  int _sourceEpoch = 0;
  static const _maxMissingPlatformCovers = 2048;
  Iterable<Future<String?>> get pendingPlatformCovers =>
      _platformCoverFutures.values;

  String? _mostSpecificWatchedFolder(String value) =>
      _libraryService.mostSpecificWatchedFolder(value);

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
        _mostSpecificWatchedFolder(pathValue) ??
        (groupKey.isEmpty ? null : _mostSpecificWatchedFolder(groupKey));
    if (watchedFolder != null && watchedFolder.isNotEmpty) {
      return watchedFolder;
    }

    final watchedLibrary =
        (groupKey.isEmpty
            ? null
            : _libraryService.mostSpecificWatchedLibrary(groupKey)) ??
        _libraryService.mostSpecificWatchedLibrary(pathValue);
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

    final parent = PathMatcher.parentPath(pathValue);
    // Video cover selections follow the file's real folder, including videos
    // listed under the synthetic Imported Files group.
    if (parent != null && track != null && _isVideoTrack(track)) {
      return PathMatcher.normalize(parent);
    }
    final groupKey = track?.groupKey.trim();
    if (groupKey != null && groupKey.isNotEmpty) {
      return PathMatcher.normalize(groupKey);
    }
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
      var current = PathMatcher.parentPath(enclosing);
      while (current != null &&
          current.isNotEmpty &&
          current != '.' &&
          current != path.rootPrefix(current)) {
        final normalizedCurrent = PathMatcher.normalize(current);
        addScope(normalizedCurrent);
        if (_libraryService.watchedFolders.contains(normalizedCurrent) ||
            _libraryService.containsWatchedLibrary(normalizedCurrent)) {
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
      final rootFolder = _rootPathForTrack(track);
      addScope(rootFolder);
    }

    addScope(coverScopeFolderForTrack(track, trackPath: pathValue));

    return List<String>.unmodifiable(scopes);
  }

  String _rootPathForTrack(MusicTrack track) {
    if (track.isSingle) return track.path;
    final groupLibrary = track.groupKey.isEmpty
        ? null
        : _libraryService.mostSpecificWatchedLibrary(track.groupKey);
    final pathLibrary = _libraryService.mostSpecificWatchedLibrary(track.path);
    final libraryMatch = groupLibrary == null
        ? pathLibrary
        : pathLibrary == null || groupLibrary.length >= pathLibrary.length
        ? groupLibrary
        : pathLibrary;
    if (libraryMatch != null) {
      return const LibraryOrganizer().workScopeFolderPath(
            libraryMatch,
            track.groupKey,
          ) ??
          libraryMatch;
    }
    final groupFolder = _mostSpecificWatchedFolder(track.groupKey);
    final pathFolder = _mostSpecificWatchedFolder(track.path);
    if (groupFolder == null) return pathFolder ?? track.groupKey;
    if (pathFolder == null) return groupFolder;
    return pathFolder.length > groupFolder.length ? pathFolder : groupFolder;
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
    _sourceEpoch++;
    _coverTrackIndex = null;
    _missingPlatformCovers.clear();
    _folderImageIndexFutures.clear();
    _platformCoverFutures.clear();
    _folderImageSourceByDisplayKey.clear();
    _folderImageDisplayBySourceKey.clear();
  }

  void trimMemory() {
    _sourceEpoch++;
    _coverTrackIndex = null;
    _missingPlatformCovers.clear();
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

  Future<String?> localCoverContentKey(String coverPath) {
    if (PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return Future<String?>.value();
    }
    return IOOverrides.current == null
        ? Isolate.run(() => _computeLocalCoverContentKey(coverPath))
        : _computeLocalCoverContentKey(coverPath);
  }

  bool get _supportsPlatformMediaLookup =>
      AppPlatform.isAndroid ||
      AppPlatform.isWindows ||
      !identical(_fileCacheGateway, FileCachePlatformGateway.instance);

  bool get _supportsContentUriLookup =>
      AppPlatform.isAndroid ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ||
      !identical(_fileCacheGateway, FileCachePlatformGateway.instance);

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
      if (_supportsPlatformMediaLookup) {
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
        } catch (e, stackTrace) {
          AppLogService.warning(
            'CoverArtworkCacheService.resolveVideoFramePathForTrack error',
            error: e,
            stackTrace: stackTrace,
          );
        }
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
    if (_missingPlatformCovers.remove(requestKey) case final missingPath?) {
      _missingPlatformCovers[requestKey] = missingPath;
      return Future.value();
    }
    return _platformCoverFutures.putIfAbsent(requestKey, () {
      final epoch = _sourceEpoch;
      late final Future<String?> task;
      task =
          (() async {
            final stored =
                await _artworkStore.validatedPath(nativeKey) ??
                await _artworkStore.validatedPath(
                  'embedded:${_trackSourceFingerprint(track)}',
                );
            if (stored != null) return stored;
            var failed = false;
            final resolved = await _loadPlatformCoverPathForTrack(
              track,
              nativeKey: nativeKey,
              rootFolder: rootFolder,
              includeGroupCoverFallback: grouped,
              onFailure: () => failed = true,
            );
            if (resolved == null && !failed && epoch == _sourceEpoch) {
              _missingPlatformCovers[requestKey] = track.path;
              while (_missingPlatformCovers.length >
                  _maxMissingPlatformCovers) {
                _missingPlatformCovers.remove(
                  _missingPlatformCovers.keys.first,
                );
              }
            }
            return resolved;
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
    required void Function() onFailure,
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
        if (_supportsPlatformMediaLookup) {
          final nativeCover = await _fileCacheGateway.resolveTrackCover(
            path: track.path,
            // SAF folder discovery is shared by scope above; probing each track
            // must not repeat that directory walk when the folder has no image.
            groupKey: includeGroupCoverFallback && !sharedSafFolder
                ? track.groupKey
                : null,
            rootFolder: sharedSafFolder ? null : rootFolder,
            propagateFailure: true,
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
        }
      } catch (e, stackTrace) {
        onFailure();
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
        onFailure();
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
      if (_supportsPlatformMediaLookup) {
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
        } catch (e, stackTrace) {
          AppLogService.warning(
            'CoverArtworkCacheService.resolveEmbeddedCoverForPath native error',
            error: e,
            stackTrace: stackTrace,
          );
        }
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
    bool Function()? isCancelled,
  }) async {
    if (isCancelled?.call() == true) return const [];
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
      if (isCancelled?.call() == true) return const [];
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

    final tracks = await _tracksInCoverScope(folderPath);
    if (isCancelled?.call() == true) return const [];
    for (
      var start = 0;
      start < tracks.length;
      start += _maxConcurrentFolderCandidateResolutions
    ) {
      if (isCancelled?.call() == true) return const [];
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
      if (isCancelled?.call() == true) return const [];
      for (final candidate in resolved) {
        await addEmbeddedCandidate(candidate);
      }
    }
    if (tracks.isEmpty &&
        !PathMatcher.isContentUri(folderPath) &&
        !PathMatcher.isRemoteUri(folderPath)) {
      final audioFiles = await _discoverFolderAudioFiles(folderPath);
      for (
        var start = 0;
        start < audioFiles.length;
        start += _maxConcurrentFolderCandidateResolutions
      ) {
        if (isCancelled?.call() == true) return const [];
        final nextEnd = start + _maxConcurrentFolderCandidateResolutions;
        final end = nextEnd < audioFiles.length ? nextEnd : audioFiles.length;
        final batch = audioFiles.sublist(start, end);
        final resolved = await Future.wait(
          batch.map(resolveEmbeddedCoverForPath),
        );
        if (isCancelled?.call() == true) return const [];
        for (final candidate in resolved) {
          await addEmbeddedCandidate(candidate);
        }
      }
    }
    return finish();
  }

  Future<List<String>> _discoverFolderAudioFiles(String folderPath) async {
    try {
      final request = (
        rootPath: folderPath,
        recursive: true,
        extensions: supportedAudioExtensions,
      );
      final files = IOOverrides.current == null
          ? await compute(_scanFilesystemFiles, request)
          : await _scanFilesystemFiles(request);
      return List<String>.unmodifiable(files);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<String?> resolvePreferredFolderCover(String folderPath) async {
    final preferredOnly = PathMatcher.isContentUri(folderPath);
    if (!preferredOnly) {
      final normalizedFolder = PathMatcher.normalize(folderPath);
      final indexRoot = folderImageIndexRoot(normalizedFolder);
      final sharedRootKey = (
        rootPath: indexRoot,
        recursive: true,
        preferredOnly: false,
      );
      if (!PathMatcher.equalsNormalized(indexRoot, normalizedFolder) &&
          _folderImageIndexFutures.containsKey(sharedRootKey)) {
        final images = await discoverFolderImageReferences(
          folderPath,
          firstOnly: true,
          preferDirect: true,
        );
        if (images.isNotEmpty) return images.first.displayPath;
      } else {
        final images = await discoverFolderImageReferences(
          folderPath,
          recursive: false,
          firstOnly: true,
        );
        if (images.isNotEmpty) return images.first.displayPath;

        final nestedImages = await discoverFolderImageReferences(
          folderPath,
          firstOnly: true,
        );
        if (nestedImages.isNotEmpty) return nestedImages.first.displayPath;
      }
    } else {
      final images = await discoverFolderImageReferences(
        folderPath,
        recursive: false,
        preferredOnly: true,
        firstOnly: true,
      );
      if (images.isNotEmpty) return images.first.displayPath;

      final nestedImages = await discoverFolderImageReferences(
        folderPath,
        preferredOnly: true,
        firstOnly: true,
      );
      if (nestedImages.isNotEmpty) return nestedImages.first.displayPath;
    }

    for (final track in await _tracksInCoverScope(folderPath, limit: 3)) {
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
    bool firstOnly = false,
    bool preferDirect = false,
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
      if (isContent ||
          !recursive ||
          PathMatcher.equalsNormalized(normalizedFolder, key.rootPath)) {
        return firstOnly
            ? List<CoverImageReference>.unmodifiable(indexedImages.take(1))
            : indexedImages;
      }
      return lookup.filterWithin(
        indexedImages,
        normalizedFolder,
        firstOnly: firstOnly,
        preferDirect: preferDirect,
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
          AppLogService.warning(
            'Unable to discover folder cover images.',
            error: error,
            stackTrace: stackTrace,
          );
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
    final libraryMatch = _libraryService.mostSpecificWatchedLibrary(folderPath);
    if (libraryMatch != null) return libraryMatch;
    return _mostSpecificWatchedFolder(folderPath) ?? folderPath;
  }

  Future<List<CoverImageReference>> _buildFolderImageIndex(
    String rootPath, {
    required bool recursive,
    required bool preferredOnly,
    required bool Function() isCurrent,
  }) async {
    if (PathMatcher.isContentUri(rootPath)) {
      if (!_supportsContentUriLookup) return const [];
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
    final request = (
      rootPath: rootPath,
      recursive: recursive,
      extensions: folderCoverImageExtensions,
    );
    final images = scanner == null
        ? IOOverrides.current == null
              ? await compute(
                  _scanFilesystemFiles,
                  request,
                  debugLabel: 'library_folder_cover_index',
                )
              : await _scanFilesystemFiles(request)
        : await scanner(rootPath, recursive);
    if (!isCurrent()) return const [];
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

  Future<List<MusicTrack>> _tracksInCoverScope(
    String folderPath, {
    int? limit,
  }) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (normalizedFolderPath.isEmpty) return const <MusicTrack>[];
    bool matches(MusicTrack track) {
      final group = track.groupKey.trim();
      return PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
          (group.isNotEmpty &&
              PathMatcher.isWithinOrEqual(group, normalizedFolderPath));
    }

    final tracks = _libraryService.library;
    final key =
        tracks.length >= _coverTrackIndexThreshold &&
            _libraryService.libraryBatchDepth == 0
        ? _indexedCoverPathKey(normalizedFolderPath)
        : null;
    Iterable<MusicTrack> candidates = tracks;
    if (key != null) {
      final generation = _libraryService.libraryDerivedGeneration;
      final length = tracks.length;
      bool isCurrent() =>
          _libraryService.libraryBatchDepth == 0 &&
          _libraryService.libraryDerivedGeneration == generation &&
          identical(_libraryService.library, tracks) &&
          tracks.length == length;
      final index = _coverTrackIndex;
      final future =
          index?.generation == generation &&
              identical(index?.tracks, tracks) &&
              index?.length == length
          ? index!.future
          : (_coverTrackIndex = (
              tracks: tracks,
              generation: generation,
              length: length,
              future: _prepareCoverTrackIndex(tracks, isCurrent),
            )).future;
      final _CoverTrackIndex? prepared;
      try {
        prepared = await future;
      } catch (_) {
        if (identical(_coverTrackIndex?.future, future)) {
          _coverTrackIndex = null;
        }
        rethrow;
      }
      if (prepared != null && isCurrent()) {
        final positions = <int>{};
        for (final position in prepared.positionsWithin(key)) {
          positions.add(position);
          if (positions.length >= length ~/ 2) break;
        }
        // Once most of the catalog may match, preserve order via the original
        // list and let the limited lookup stop as soon as it has enough tracks.
        if (positions.length < length ~/ 2) {
          final ordered = positions.toList()..sort();
          candidates = ordered.map((position) => tracks[position]);
        }
      } else {
        if (identical(_coverTrackIndex?.future, future)) {
          _coverTrackIndex = null;
        }
        candidates = _libraryService.library;
      }
    }
    final matching = candidates.where(matches);
    return (limit == null ? matching : matching.take(limit)).toList(
      growable: false,
    );
  }

  void invalidateFolderImageIndexes(String normalizedScope) {
    _sourceEpoch++;
    _missingPlatformCovers.removeWhere(
      (_, trackPath) => PathMatcher.isWithinOrEqual(trackPath, normalizedScope),
    );
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

String? _indexedCoverPathKey(String normalized) {
  final key = PathMatcher.equivalenceKey(normalized);
  if (key.startsWith('windows:') ||
      key.startsWith('remote:') ||
      (key.startsWith('content:') && !key.contains(':content://')) ||
      (!Platform.isWindows && normalized.startsWith('/'))) {
    return key;
  }
  // Opaque content URIs and relative paths can match through their raw paths.
  return null;
}

Future<_CoverTrackIndex?> _prepareCoverTrackIndex(
  List<MusicTrack> tracks,
  bool Function() isCurrent,
) async {
  // Send only path strings. Playback state and artwork metadata stay in the
  // catalog, and lookups use its current track instances in their original order.
  final paths = <(String, String)>[];
  final slice = Stopwatch()..start();
  for (final track in tracks) {
    paths.add((track.path, track.groupKey));
    if (slice.elapsedMicroseconds >= 4000) {
      await Future<void>.delayed(Duration.zero);
      if (!isCurrent()) return null;
      slice.reset();
    }
  }
  return compute(_buildCoverTrackIndex, paths, debugLabel: 'cover_track_index');
}

_CoverTrackIndex _buildCoverTrackIndex(List<(String, String)> tracks) {
  final paths = <({String key, int position})>[];
  final unindexed = <int>[];
  for (final (position, (path, group)) in tracks.indexed) {
    final normalizedPath = PathMatcher.normalize(path);
    final pathKey = _indexedCoverPathKey(normalizedPath);
    final groupPath = group.trim();
    final hasGroupPath =
        groupPath.isNotEmpty &&
        groupPath != path &&
        groupPath != LibraryOrganizer.singleFilesGroupKey;
    final normalizedGroup = hasGroupPath
        ? PathMatcher.normalize(groupPath)
        : normalizedPath;
    final groupKey = normalizedGroup == normalizedPath
        ? pathKey
        : _indexedCoverPathKey(normalizedGroup);
    if (pathKey != null) paths.add((key: pathKey, position: position));
    if (groupKey != null && groupKey != pathKey) {
      paths.add((key: groupKey, position: position));
    }
    if (pathKey == null || (hasGroupPath && groupKey == null)) {
      unindexed.add(position);
    }
  }
  paths.sort((first, second) => first.key.compareTo(second.key));
  return _CoverTrackIndex(paths, unindexed);
}

class _CoverTrackIndex {
  const _CoverTrackIndex(this.paths, this.unindexed);

  final List<({String key, int position})> paths;
  final List<int> unindexed;

  Iterable<int> positionsWithin(String key) sync* {
    if (key.startsWith('remote:')) {
      yield* _positionsInRange(key, prefixMatch: false);
    } else {
      final prefix =
          key.endsWith('/') || (key.startsWith('content:') && key.endsWith(':'))
          ? key
          : '$key/';
      if (prefix != key) yield* _positionsInRange(key, prefixMatch: false);
      yield* _positionsInRange(prefix, prefixMatch: true);
    }
    yield* unindexed;
  }

  Iterable<int> _positionsInRange(
    String lowerBound, {
    required bool prefixMatch,
  }) sync* {
    var low = 0;
    var high = paths.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (paths[middle].key.compareTo(lowerBound) < 0) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    for (; low < paths.length; low++) {
      final candidate = paths[low];
      if (prefixMatch
          ? !candidate.key.startsWith(lowerBound)
          : candidate.key != lowerBound) {
        return;
      }
      yield candidate.position;
    }
  }
}

Future<List<String>> _scanFilesystemFiles(
  ({String rootPath, bool recursive, Set<String> extensions}) request,
) async {
  final directory = Directory(request.rootPath);
  final files = <String>[];
  await for (final entity in directory.list(
    recursive: request.recursive,
    followLinks: false,
  )) {
    if (entity is! File ||
        !request.extensions.contains(
          path.extension(entity.path).toLowerCase(),
        )) {
      continue;
    }
    files.add(entity.path);
  }
  files.sort();
  return files;
}

Future<String?> _computeLocalCoverContentKey(String coverPath) async {
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

String? mostSpecificContainingCoverRoot(Iterable<String> roots, String value) {
  return PathRootIndex(roots).mostSpecificContaining(value);
}

bool isStandaloneCoverAudioTrack(MusicTrack? track, {String? trackPath}) {
  final pathValue = trackPath ?? track?.path;
  final isVideo =
      track?.isVideo == true ||
      (pathValue?.isNotEmpty == true && isVideoMediaFile(pathValue!));
  return track?.isSingle == true && !isVideo;
}
