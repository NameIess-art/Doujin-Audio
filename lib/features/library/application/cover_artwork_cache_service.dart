import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/media_file_support.dart';
import '../domain/library_persistence_repository.dart';
import 'audio_detail_cache_service.dart';
import 'cover_artwork_store.dart';
import 'remote_cover_downloader.dart';
export 'remote_cover_downloader.dart' show remoteCoverRequestHeadersForUrl;
import 'library_organizer.dart';
import 'library_service.dart';
import 'cover_artwork_source_resolver.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';

const String _folderCoverSelectionsKey = 'folder_cover_selections_v1';
const int _resolvedTrackCoverLimit = 600;
const int _resolvedFolderCoverLimit = 300;
const int _resolvedRemoteCoverLimit = 300;
const int _manualCoverValidityLimit = 1200;

class CoverArtworkCacheService {
  CoverArtworkCacheService({
    required LibraryService libraryService,
    LibraryPersistenceRepository? databaseRepository,
    AudioDetailCacheService? audioDetailCacheService,
    FileCachePlatformGateway? fileCacheGateway,
    Future<List<String>> Function(String rootPath, bool recursive)?
    filesystemImageScanner,
    Future<String?> Function(String remoteUrl)? remoteCoverDownloader,
    Duration requestTimeout = const Duration(seconds: 15),
    Duration downloadIdleTimeout = const Duration(seconds: 30),
    DateTime Function()? now,
    Future<Directory> Function()? persistentDirectory,
    Future<Directory> Function()? temporaryDirectory,
    CoverArtworkStore? artworkStore,
    bool Function(String coverSearchKey)? isActiveCoverKey,
    VoidCallback? onActiveCoverChanged,
    bool Function()? preferEmbeddedCover,
  }) : _libraryService = libraryService,
       _databaseRepository = databaseRepository,
       _audioDetailCacheService = audioDetailCacheService,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _remoteCoverDownloader = remoteCoverDownloader,
       _now = now ?? DateTime.now,
       _artworkStore =
           artworkStore ??
           CoverArtworkStore(
             persistentDirectory: persistentDirectory,
             temporaryDirectory: temporaryDirectory,
           ),
       _isActiveCoverKey = isActiveCoverKey,
       _onActiveCoverChanged = onActiveCoverChanged,
       _preferEmbeddedCover = preferEmbeddedCover {
    _remoteDownloads = RemoteCoverDownloader(
      requestTimeout: requestTimeout,
      downloadIdleTimeout: downloadIdleTimeout,
      artworkStore: _artworkStore,
      isClearingPersistentCache: () => _isClearingPersistentCache,
    );
    _sourceResolver = CoverArtworkSourceResolver(
      libraryService: libraryService,
      fileCacheGateway: _fileCacheGateway,
      artworkStore: _artworkStore,
      isClearingPersistentCache: () => _isClearingPersistentCache,
      filesystemImageScanner: filesystemImageScanner,
    );
  }

  final LibraryService _libraryService;
  final LibraryPersistenceRepository? _databaseRepository;
  final AudioDetailCacheService? _audioDetailCacheService;
  final FileCachePlatformGateway _fileCacheGateway;
  final Future<String?> Function(String remoteUrl)? _remoteCoverDownloader;
  late final RemoteCoverDownloader _remoteDownloads;
  final DateTime Function() _now;
  final CoverArtworkStore _artworkStore;
  late final CoverArtworkSourceResolver _sourceResolver;
  final bool Function(String coverSearchKey)? _isActiveCoverKey;
  final VoidCallback? _onActiveCoverChanged;
  final bool Function()? _preferEmbeddedCover;

  final Map<String, Future<String?>> _folderCoverFutures =
      <String, Future<String?>>{};
  final Map<String, String?> _resolvedFolderCovers = <String, String?>{};
  final Map<String, Future<String?>> _resolvedFolderCoverFutures =
      <String, Future<String?>>{};
  final Map<String, Future<String?>> _trackCoverFutures =
      <String, Future<String?>>{};
  final Map<String, Future<String?>> _playbackTrackCoverFutures =
      <String, Future<String?>>{};
  final Map<String, String?> _resolvedTrackCovers = <String, String?>{};
  final Map<String, Future<String?>> _resolvedTrackCoverFutures =
      <String, Future<String?>>{};
  final Map<String, Future<String?>> _remoteCoverFutures =
      <String, Future<String?>>{};
  final Map<String, String?> _resolvedRemoteCovers = <String, String?>{};
  final Map<String, Future<String?>> _resolvedRemoteCoverFutures =
      <String, Future<String?>>{};
  final Map<String, _RemoteCoverFailure> _remoteCoverFailures = {};
  final Map<String, bool> _manualCoverPathValidityCache = <String, bool>{};
  final Map<String, Future<String?>> _manualCoverValidationFutures =
      <String, Future<String?>>{};
  final Map<String, String> _folderCoverSelections = <String, String>{};
  final Map<String, int> _coverKeyRevisions = <String, int>{};
  Future<void>? _folderCoverSelectionsLoadFuture;
  int _generation = 0;
  bool _disposed = false;
  Future<int>? _clearPersistentCacheFuture;
  bool _isClearingPersistentCache = false;

  int get generation => _generation;

  Future<void> initialize() async {
    await Future.wait<void>(<Future<void>>[
      _initializeArtworkStore(),
      _ensureFolderCoverSelections(),
    ]);
  }

  Future<void> _initializeArtworkStore() async {
    try {
      await _artworkStore.initialize();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to initialize persistent cover artwork storage.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<int> migrateLegacyCaches({bool Function()? shouldCancel}) =>
      _artworkStore.migrateLegacyCaches(shouldCancel: shouldCancel);

  Future<int> clearPersistentCache() =>
      _clearPersistentCacheFuture ??= _clearPersistentCache();

  Future<int> _clearPersistentCache() async {
    _isClearingPersistentCache = true;
    final pending = <Future<String?>>{
      ..._trackCoverFutures.values,
      ..._folderCoverFutures.values,
      ..._remoteCoverFutures.values,
    };
    invalidateAll();
    try {
      await Future.wait<void>(
        pending.map((future) => future.then<void>((_) {}, onError: (_, _) {})),
      );
      invalidateAll();
      return await _artworkStore.clear();
    } finally {
      _isClearingPersistentCache = false;
      _clearPersistentCacheFuture = null;
    }
  }

  @visibleForTesting
  int get manualCoverPathValidityCacheSize =>
      _manualCoverPathValidityCache.length;

  String? resolvedForTrack(MusicTrack? track, {String? trackPath}) {
    final preferEmbedded = _preferTrackEmbeddedCover(
      track,
      trackPath: trackPath,
    );
    if (!preferEmbedded) {
      final folderCoverPath = _resolvedExplicitFolderCoverForTrack(
        track,
        trackPath: trackPath,
      );
      if (folderCoverPath != null) return folderCoverPath;
    }

    final manualCoverPath = track?.isSingle == true
        ? _cachedManualCoverPath(track?.manualCoverPath)
        : null;
    if (manualCoverPath != null) {
      return manualCoverPath;
    }
    final cachedCoverPath = _cachedManualCoverPath(track?.coverCachePath);
    if (cachedCoverPath != null) {
      return cachedCoverPath;
    }
    final pathValue = trackPath ?? track?.path;
    if (pathValue != null &&
        pathValue.isNotEmpty &&
        !PathMatcher.isRemoteUri(pathValue)) {
      final resolved = _resolvedTrackCovers[PathMatcher.normalize(pathValue)];
      if (resolved != null) return resolved;
    }
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (coverSearchKey != null) {
      final resolved =
          _resolvedTrackCovers[coverSearchKey] ??
          _artworkStore.resolvedPath(_trackStoreKey(coverSearchKey, track));
      if (resolved != null) return resolved;
    }

    if (preferEmbedded) {
      final folderCoverPath = _resolvedExplicitFolderCoverForTrack(
        track,
        trackPath: trackPath,
      );
      if (folderCoverPath != null) return folderCoverPath;
    }

    return null;
  }

  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) {
    final preferEmbedded = _preferTrackEmbeddedCover(
      track,
      trackPath: trackPath,
    );
    if (!preferEmbedded) {
      final folderScope = _playbackFallbackFolderScopeForTrack(
        track,
        trackPath: trackPath,
      );
      if (folderScope != null) {
        final folderCoverPath = resolvedForFolder(folderScope);
        if (folderCoverPath != null) return folderCoverPath;
      }
    }
    final trackCover = resolvedForTrack(track, trackPath: trackPath);
    if (trackCover != null) return trackCover;
    if (preferEmbedded) {
      final folderScope = _playbackFallbackFolderScopeForTrack(
        track,
        trackPath: trackPath,
      );
      if (folderScope != null) {
        final folderCoverPath = resolvedForFolder(folderScope);
        if (folderCoverPath != null) return folderCoverPath;
      }
    }
    return null;
  }

  String? resolvedForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final resolved =
        _resolvedFolderCovers[normalizedFolderPath] ??
        _artworkStore.resolvedPath(_folderStoreKey(normalizedFolderPath));
    if (resolved != null) return resolved;
    final selected = _folderCoverSelections[normalizedFolderPath];
    if (selected != null) {
      final display =
          _sourceResolver.displayPathForSource(selected) ?? selected;
      if (!PathMatcher.isContentUri(display) &&
          !PathMatcher.isRemoteUri(display) &&
          path.isAbsolute(display)) {
        return display;
      }
    }
    return null;
  }

  String? resolvedForRemoteCover(String url) {
    final remoteKey = remoteCoverSearchKey(url);
    if (remoteKey == null) return null;
    return _resolvedRemoteCovers[remoteKey] ??
        _artworkStore.resolvedPath(remoteKey) ??
        _artworkStore.resolvedArtifact(
          CoverArtworkNamespace.remote,
          '${_remoteCoverFileStem(url)}.image',
        );
  }

  String? resolvedEmbeddedCoverForPath(String filePath) {
    final track = _libraryService.trackByPath(filePath);
    if (track != null) {
      final embeddedKey = 'embedded:${_trackSourceFingerprint(track)}';
      final nativeKey = 'native:${_trackSourceFingerprint(track)}';
      final embeddedPath =
          _artworkStore.resolvedPath(embeddedKey) ??
          _artworkStore.resolvedPath(nativeKey);
      if (embeddedPath != null) return embeddedPath;
    }
    final normalized = PathMatcher.normalize(filePath);
    return _artworkStore.resolvedPath('embedded:$normalized') ??
        _artworkStore.resolvedPath('native:$normalized');
  }

  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) {
    return _resolveCoverPathForTrack(track, trackPath: trackPath);
  }

  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (coverSearchKey == null) return Future<String?>.value();

    final playbackFuture = _playbackTrackCoverFutures.putIfAbsent(
      coverSearchKey,
      () {
        final future = _resolvePlaybackCoverPathForTrack(
          track,
          trackPath: trackPath,
        );
        unawaited(
          future.then(
            (coverPath) {
              if (coverPath == null &&
                  identical(
                    _playbackTrackCoverFutures[coverSearchKey],
                    future,
                  )) {
                _playbackTrackCoverFutures.remove(coverSearchKey);
              }
            },
            onError: (Object _) {
              if (identical(
                _playbackTrackCoverFutures[coverSearchKey],
                future,
              )) {
                _playbackTrackCoverFutures.remove(coverSearchKey);
              }
            },
          ),
        );
        return future;
      },
    );
    _trimPlaybackTrackCoverFutures();
    return playbackFuture;
  }

  Future<String?> _resolvePlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) async {
    final requestGeneration = _generation;
    await _ensureFolderCoverSelections();
    if (requestGeneration != _generation) {
      return futureForPlaybackTrack(track, trackPath: trackPath);
    }
    final preferEmbedded = _preferTrackEmbeddedCover(
      track,
      trackPath: trackPath,
    );

    Future<String?> resolveFromFolder() async {
      final folderScope = _playbackFallbackFolderScopeForTrack(
        track,
        trackPath: trackPath,
      );
      if (folderScope == null) return null;
      final previousPlaybackCover = resolvedForPlaybackTrack(
        track,
        trackPath: trackPath,
      );
      final folderCoverPath = await futureForFolder(folderScope);
      if (folderCoverPath != null) {
        if (previousPlaybackCover != folderCoverPath) {
          final coverSearchKey = coverSearchKeyForTrack(
            track,
            trackPath: trackPath,
          );
          if (coverSearchKey != null &&
              (_isActiveCoverKey?.call(coverSearchKey) ?? false)) {
            _onActiveCoverChanged?.call();
          }
        }
        return folderCoverPath;
      }
      return null;
    }

    if (!preferEmbedded) {
      final folderCover = await resolveFromFolder();
      if (requestGeneration != _generation) {
        return futureForPlaybackTrack(track, trackPath: trackPath);
      }
      if (folderCover != null) return folderCover;
      final trackCover = await futureForTrack(track, trackPath: trackPath);
      return requestGeneration == _generation
          ? trackCover
          : futureForPlaybackTrack(track, trackPath: trackPath);
    } else {
      final trackCover = await futureForTrack(track, trackPath: trackPath);
      if (requestGeneration != _generation) {
        return futureForPlaybackTrack(track, trackPath: trackPath);
      }
      if (trackCover != null) return trackCover;
      final folderCover = await resolveFromFolder();
      return requestGeneration == _generation
          ? folderCover
          : futureForPlaybackTrack(track, trackPath: trackPath);
    }
  }

  Future<String?> futureForFolder(String folderPath) {
    return _resolveCoverPathForFolder(folderPath);
  }

  Future<String?> futureForRemoteCover(String url) {
    final remoteKey = remoteCoverSearchKey(url);
    if (remoteKey == null) return Future<String?>.value();
    final resolvedFuture = _resolvedRemoteCoverFutures[remoteKey];
    if (resolvedFuture != null) {
      final resolvedPath = _resolvedRemoteCovers[remoteKey];
      if (resolvedPath != null &&
          _isResolvedRemoteCoverPathPresent(resolvedPath)) {
        return resolvedFuture;
      }
      _resolvedRemoteCovers.remove(remoteKey);
      _resolvedRemoteCoverFutures.remove(remoteKey);
    }
    final storedPath =
        _artworkStore.resolvedPath(remoteKey) ??
        _artworkStore.resolvedArtifact(
          CoverArtworkNamespace.remote,
          '${_remoteCoverFileStem(url)}.image',
        );
    if (storedPath != null) {
      _resolvedRemoteCovers[remoteKey] = storedPath;
      final storedFuture = SynchronousFuture<String?>(storedPath);
      _resolvedRemoteCoverFutures[remoteKey] = storedFuture;
      return storedFuture;
    }
    return _resolveRemoteCover(
      remoteKey,
      normalizedRemoteUrlFromKey(remoteKey),
    );
  }

  bool isLoadingForFolder(String folderPath) {
    return _folderCoverFutures.containsKey(PathMatcher.normalize(folderPath));
  }

  String? coverScopeFolderForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = trackPath ?? track?.path;
    if (pathValue == null || pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) return null;
    if (_isStandaloneAudioTrack(track, trackPath: trackPath)) return null;

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

  List<String> _candidateFolderScopesForTrack(
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

  String? _playbackFallbackFolderScopeForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    if (track == null) return null;
    final pathValue = trackPath ?? track.path;
    if (pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) return null;

    final candidateScopes = _candidateFolderScopesForTrack(
      track,
      trackPath: trackPath,
    );
    for (final scope in candidateScopes) {
      if (_folderCoverSelections.containsKey(scope)) {
        return scope;
      }
    }

    if (_isVideoTrack(track, trackPath: trackPath) ||
        _isStandaloneAudioTrack(track, trackPath: trackPath)) {
      return null;
    }
    return coverScopeFolderForTrack(track, trackPath: trackPath);
  }

  bool _preferTrackEmbeddedCover(MusicTrack? track, {String? trackPath}) {
    return track != null && (_preferEmbeddedCover?.call() ?? false);
  }

  bool _isVideoTrack(MusicTrack? track, {String? trackPath}) {
    if (track?.isVideo == true) return true;
    final pathValue = trackPath ?? track?.path;
    return pathValue != null &&
        pathValue.isNotEmpty &&
        isVideoMediaFile(pathValue);
  }

  String? coverSearchKeyForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = trackPath ?? track?.path;
    if (pathValue == null || pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) {
      final remoteCoverUrl = track?.remoteCoverUrl?.trim();
      return remoteCoverUrl == null || remoteCoverUrl.isEmpty
          ? null
          : remoteCoverSearchKey(remoteCoverUrl);
    }
    return PathMatcher.normalize(pathValue);
  }

  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
  }) async {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (normalizedFolder.isEmpty) return const <String>[];
    final candidates = await _sourceResolver.resolveFolderCoverCandidates(
      normalizedFolder,
      includeVideoFrames: includeVideoFrames,
      includeEmbeddedCovers: includeEmbeddedCovers,
    );
    final selectedCover = selectedCoverPath?.trim();
    if (selectedCover == null || selectedCover.isEmpty) return candidates;
    return _sourceResolver.candidatesWithSelectedCover(
      selectedCover,
      candidates,
    );
  }

  Future<String?> setFolderCoverSelection(
    String folderPath,
    String coverPath, {
    bool newlySaved = false,
    String? sourcePath,
  }) async {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final normalizedCover = coverPath.trim();
    if (normalizedFolder.isEmpty || normalizedCover.isEmpty) return null;
    invalidateFolder(normalizedFolder);
    if (!newlySaved) {
      final candidates = await _sourceResolver.resolveFolderCoverCandidates(
        normalizedFolder,
      );
      final hasCandidate = candidates.any(
        (c) =>
            PathMatcher.equalsNormalized(c, normalizedCover) ||
            PathMatcher.equivalenceKey(c) ==
                PathMatcher.equivalenceKey(normalizedCover),
      );
      if (!hasCandidate) {
        final coverContentKey = await _sourceResolver.localCoverContentKey(
          normalizedCover,
        );
        var contentMatched = false;
        if (coverContentKey != null) {
          for (final candidate in candidates) {
            if (await _sourceResolver.localCoverContentKey(candidate) ==
                coverContentKey) {
              contentMatched = true;
              break;
            }
          }
        }
        if (!contentMatched) return null;
      }
    }
    final durableSource = sourcePath?.trim();
    if (durableSource != null && durableSource.isNotEmpty) {
      _sourceResolver.rememberFolderImageSource(normalizedCover, durableSource);
    }
    final selectionGeneration = _generation;
    final selectionRevision = _coverKeyRevision(normalizedFolder);
    await _ensureFolderCoverSelections();
    _folderCoverSelections[normalizedFolder] = normalizedCover;
    final hasDurableSource = _sourceResolver.hasSourceForDisplay(
      normalizedCover,
    );
    final storedCoverPath = await _saveFolderCardCoverPath(
      normalizedFolder,
      normalizedCover,
      selected: true,
      writeDocument: true,
    );
    final effectiveCoverPath = hasDurableSource
        ? normalizedCover
        : storedCoverPath ?? normalizedCover;
    _folderCoverSelections[normalizedFolder] = hasDurableSource
        ? _persistedFolderCoverPath(normalizedCover)
        : effectiveCoverPath;
    await _saveFolderCoverSelections();
    if (!_isCoverKeyCurrent(
      normalizedFolder,
      generation: selectionGeneration,
      revision: selectionRevision,
    )) {
      return _resolvedFolderCovers[normalizedFolder];
    }
    // Playback can resolve the previous cover while selection is being saved.
    // Commit a new generation and discard those lookups before publishing it.
    invalidateFolder(normalizedFolder);
    _resolvedFolderCovers[normalizedFolder] = effectiveCoverPath;
    _resolvedFolderCoverFutures[normalizedFolder] = SynchronousFuture<String?>(
      effectiveCoverPath,
    );
    await _sourceResolver.bindPersistentCover(
      _folderStoreKey(normalizedFolder),
      effectiveCoverPath,
    );
    return effectiveCoverPath;
  }

  Future<void> retargetFolderCoverSelection(
    String oldFolderPath,
    String newFolderPath,
  ) async {
    await _ensureFolderCoverSelections();
    final oldFolder = PathMatcher.normalize(oldFolderPath);
    final newFolder = PathMatcher.normalize(newFolderPath);
    if (oldFolder.isEmpty || newFolder.isEmpty) return;
    final nextSelections = <String, String>{};
    final changedScopes = <String>{};
    var changed = false;
    for (final entry in _folderCoverSelections.entries) {
      final nextFolder = PathMatcher.isWithinOrEqual(entry.key, oldFolder)
          ? PathMatcher.replaceWithinOrEqual(entry.key, oldFolder, newFolder)
          : entry.key;
      final nextCover = PathMatcher.isWithinOrEqual(entry.value, oldFolder)
          ? PathMatcher.replaceWithinOrEqual(entry.value, oldFolder, newFolder)
          : entry.value;
      if (nextFolder != entry.key || nextCover != entry.value) {
        changed = true;
        changedScopes
          ..add(entry.key)
          ..add(nextFolder);
      }
      nextSelections[nextFolder] = nextCover;
    }
    if (!changed) return;
    _folderCoverSelections
      ..clear()
      ..addAll(nextSelections);
    await _saveFolderCoverSelections();
    invalidateFolders(changedScopes);
  }

  Future<void> _saveFolderCoverSelections() async {
    try {
      await _databaseRepository?.saveAppSetting(
        _folderCoverSelectionsKey,
        json.encode(_folderCoverSelections),
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to save folder cover selections.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void invalidateTrack(MusicTrack? track, {String? trackPath}) {
    final key = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (key != null) {
      unawaited(_artworkStore.invalidate(<String>[_trackStoreKey(key, track)]));
    }
    invalidateFolder(key);
  }

  void invalidateFolder(String? scope) {
    if (scope == null || scope.isEmpty) {
      invalidateAll();
      return;
    }
    final normalizedScope = _normalizeCoverCacheKey(scope);
    final trackStoreKeys = <String>[];
    for (final track in _sourceResolver.tracksInCompleteCoverScope(
      normalizedScope,
    )) {
      final key = coverSearchKeyForTrack(track);
      if (key != null) {
        trackStoreKeys.add(_trackStoreKey(key, track));
      }
    }
    unawaited(
      _artworkStore.invalidate(<String>[
        _folderStoreKey(normalizedScope),
        ...trackStoreKeys,
      ]),
    );
    _generation++;
    _coverKeyRevisions.clear();
    _advanceCoverKeyRevision(normalizedScope);
    _advanceTrackCoverRevisionsInScope(normalizedScope);
    _sourceResolver.invalidateFolderImageIndexes(normalizedScope);
    _folderCoverFutures.remove(normalizedScope);
    _resolvedFolderCovers.remove(normalizedScope);
    _resolvedFolderCoverFutures.remove(normalizedScope);
    _playbackTrackCoverFutures.clear();
    _trackCoverFutures.remove(normalizedScope);
    _resolvedTrackCovers.remove(normalizedScope);
    _resolvedTrackCoverFutures.remove(normalizedScope);
    _removeTrackCoverEntriesInScope(normalizedScope);
    _remoteCoverFutures.remove(normalizedScope);
    _resolvedRemoteCovers.remove(normalizedScope);
    _resolvedRemoteCoverFutures.remove(normalizedScope);
    _manualCoverPathValidityCache.clear();
    _manualCoverValidationFutures.clear();
  }

  void invalidateFolders(Iterable<String?> scopes) {
    final normalizedScopes = scopes
        .whereType<String>()
        .map(_normalizeCoverCacheKey)
        .where((scope) => scope.isNotEmpty)
        .toSet();
    if (normalizedScopes.isEmpty) {
      invalidateAll();
      return;
    }
    _generation++;
    _coverKeyRevisions.clear();
    _manualCoverPathValidityCache.clear();
    _manualCoverValidationFutures.clear();
    _playbackTrackCoverFutures.clear();
    final trackStoreKeys = <String>[];
    for (final scope in normalizedScopes) {
      for (final track in _sourceResolver.tracksInCompleteCoverScope(scope)) {
        final key = coverSearchKeyForTrack(track);
        if (key != null) {
          trackStoreKeys.add(_trackStoreKey(key, track));
        }
      }
    }
    unawaited(
      _artworkStore.invalidate(<String>[
        ...normalizedScopes.map(_folderStoreKey),
        ...trackStoreKeys,
      ]),
    );
    for (final scope in normalizedScopes) {
      _advanceCoverKeyRevision(scope);
      _advanceTrackCoverRevisionsInScope(scope);
      _sourceResolver.invalidateFolderImageIndexes(scope);
      _folderCoverFutures.remove(scope);
      _resolvedFolderCovers.remove(scope);
      _resolvedFolderCoverFutures.remove(scope);
      _trackCoverFutures.remove(scope);
      _resolvedTrackCovers.remove(scope);
      _resolvedTrackCoverFutures.remove(scope);
      _removeTrackCoverEntriesInScope(scope);
      _remoteCoverFutures.remove(scope);
      _resolvedRemoteCovers.remove(scope);
      _resolvedRemoteCoverFutures.remove(scope);
      _remoteCoverFailures.remove(scope);
    }
  }

  void invalidateAll() {
    _generation++;
    _coverKeyRevisions.clear();
    _sourceResolver.invalidateAll();
    _folderCoverFutures.clear();
    _resolvedFolderCovers.clear();
    _resolvedFolderCoverFutures.clear();
    _playbackTrackCoverFutures.clear();
    _trackCoverFutures.clear();
    _resolvedTrackCovers.clear();
    _resolvedTrackCoverFutures.clear();
    _remoteCoverFutures.clear();
    _resolvedRemoteCovers.clear();
    _resolvedRemoteCoverFutures.clear();
    _remoteCoverFailures.clear();
    _manualCoverPathValidityCache.clear();
    _manualCoverValidationFutures.clear();
  }

  int _coverKeyRevision(String key) => _coverKeyRevisions[key] ?? 0;

  void _advanceCoverKeyRevision(String key) {
    _coverKeyRevisions[key] = _coverKeyRevision(key) + 1;
  }

  void _advanceTrackCoverRevisionsInScope(String normalizedScope) {
    final keys = <String>{
      ..._trackCoverFutures.keys,
      ..._resolvedTrackCovers.keys,
      ..._resolvedTrackCoverFutures.keys,
    };
    for (final key in keys) {
      if (_isTrackCoverKeyWithinScope(key, normalizedScope)) {
        _advanceCoverKeyRevision(key);
      }
    }
  }

  bool _isCoverKeyCurrent(
    String key, {
    required int generation,
    required int revision,
  }) {
    return !_disposed &&
        generation == _generation &&
        revision == _coverKeyRevision(key);
  }

  void _trimResolvedCache<T>(
    Map<String, T> cache,
    int maxEntries, {
    Map<String, Future<String?>>? futures,
  }) {
    while (cache.length > maxEntries) {
      final keyToRemove = cache.keys.firstWhere(
        (key) => !(_isActiveCoverKey?.call(key) ?? false),
        orElse: () => '',
      );
      if (keyToRemove.isEmpty) return;
      cache.remove(keyToRemove);
      futures?.remove(keyToRemove);
    }
  }

  void _trimResolvedTrackCovers() {
    _trimResolvedCache(
      _resolvedTrackCovers,
      _resolvedTrackCoverLimit,
      futures: _resolvedTrackCoverFutures,
    );
  }

  void _trimResolvedFolderCovers() {
    _trimResolvedCache(
      _resolvedFolderCovers,
      _resolvedFolderCoverLimit,
      futures: _resolvedFolderCoverFutures,
    );
  }

  void _trimResolvedRemoteCovers() {
    _trimResolvedCache(
      _resolvedRemoteCovers,
      _resolvedRemoteCoverLimit,
      futures: _resolvedRemoteCoverFutures,
    );
  }

  void _trimPlaybackTrackCoverFutures() {
    _trimResolvedCache(_playbackTrackCoverFutures, _resolvedTrackCoverLimit);
  }

  void trimMemory() {
    _sourceResolver.trimMemory();
    _manualCoverPathValidityCache.clear();
    _manualCoverValidationFutures.clear();
    _playbackTrackCoverFutures.clear();
    _trimResolvedCache(
      _resolvedTrackCovers,
      _resolvedTrackCoverLimit ~/ 4,
      futures: _resolvedTrackCoverFutures,
    );
    _trimResolvedCache(
      _resolvedFolderCovers,
      _resolvedFolderCoverLimit ~/ 4,
      futures: _resolvedFolderCoverFutures,
    );
    _trimResolvedCache(
      _resolvedRemoteCovers,
      _resolvedRemoteCoverLimit ~/ 4,
      futures: _resolvedRemoteCoverFutures,
    );
  }

  void _removeTrackCoverEntriesInScope(String normalizedScope) {
    final keys = <String>{
      ..._trackCoverFutures.keys,
      ..._resolvedTrackCovers.keys,
      ..._resolvedTrackCoverFutures.keys,
    };
    for (final key in keys) {
      if (!_isTrackCoverKeyWithinScope(key, normalizedScope)) continue;
      final trackFuture = _trackCoverFutures.remove(key);
      if (trackFuture != null) unawaited(trackFuture);
      final resolvedFuture = _resolvedTrackCoverFutures.remove(key);
      if (resolvedFuture != null) unawaited(resolvedFuture);
      _resolvedTrackCovers.remove(key);
    }
  }

  bool _isTrackCoverKeyWithinScope(String key, String normalizedScope) {
    if (key == normalizedScope) return true;
    if (key.startsWith('remote-cover:')) return false;
    return PathMatcher.isWithinOrEqual(key, normalizedScope);
  }

  void _trimManualCoverValidityCache() {
    _trimResolvedCache(
      _manualCoverPathValidityCache,
      _manualCoverValidityLimit,
      futures: _manualCoverValidationFutures,
    );
  }

  Future<void> _ensureFolderCoverSelections() {
    return _folderCoverSelectionsLoadFuture ??= () async {
      try {
        final raw = await _databaseRepository?.loadAppSetting(
          _folderCoverSelectionsKey,
        );
        if (raw == null || raw.isEmpty) return;
        final decoded = json.decode(raw);
        if (decoded is! Map) return;
        for (final entry in decoded.entries) {
          final folder = PathMatcher.normalize(entry.key.toString());
          final cover = entry.value?.toString().trim() ?? '';
          if (folder.isNotEmpty && cover.isNotEmpty) {
            _folderCoverSelections[folder] = cover;
          }
        }
      } catch (error, stackTrace) {
        AppLogService.warning(
          'Unable to load folder cover selections.',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }();
  }

  Future<String?> _resolveCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) async {
    final requestGeneration = _generation;
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: pathValue);
    if (coverSearchKey == null) return Future<String?>.value();

    final preferEmbeddedCover = _preferTrackEmbeddedCover(
      track,
      trackPath: pathValue,
    );
    if (!preferEmbeddedCover) {
      final folderCoverPath = await _explicitFolderCoverFutureForTrack(
        track,
        trackPath: pathValue,
      );
      if (requestGeneration != _generation) {
        return resolvedForTrack(track, trackPath: trackPath);
      }
      if (folderCoverPath != null) {
        _resolvedTrackCovers[coverSearchKey] = folderCoverPath;
        _resolvedTrackCoverFutures[coverSearchKey] = SynchronousFuture<String?>(
          folderCoverPath,
        );
        _trimResolvedTrackCovers();
        return folderCoverPath;
      }
    }

    final storedTrackPath = _artworkStore.resolvedPath(
      _trackStoreKey(coverSearchKey, track),
    );
    if (storedTrackPath != null) {
      _resolvedTrackCovers[coverSearchKey] = storedTrackPath;
      final storedFuture = SynchronousFuture<String?>(storedTrackPath);
      _resolvedTrackCoverFutures[coverSearchKey] = storedFuture;
      return storedFuture;
    }

    final cachedManualPath = track?.isSingle == true
        ? _cachedManualCoverPath(track?.manualCoverPath)
        : null;
    if (cachedManualPath != null) {
      unawaited(_saveTrackCardCoverPath(track, cachedManualPath));
      _resolvedTrackCovers[coverSearchKey] = cachedManualPath;
      final future = _resolvedTrackCoverFutures.putIfAbsent(
        coverSearchKey,
        () => SynchronousFuture<String?>(cachedManualPath),
      );
      _trimResolvedTrackCovers();
      return future;
    }
    final cachedCoverPath = _cachedManualCoverPath(track?.coverCachePath);
    if (cachedCoverPath != null) {
      unawaited(_saveTrackCardCoverPath(track, cachedCoverPath));
      _resolvedTrackCovers[coverSearchKey] = cachedCoverPath;
      final future = _resolvedTrackCoverFutures.putIfAbsent(
        coverSearchKey,
        () => SynchronousFuture<String?>(cachedCoverPath),
      );
      _trimResolvedTrackCovers();
      return future;
    }

    final manualPathFuture = track?.isSingle == true
        ? _validatedManualCoverPath(track?.manualCoverPath)
        : SynchronousFuture<String?>(null);
    final coverCachePathFuture = _validatedManualCoverPath(
      track?.coverCachePath,
    );
    final cachedFuture = _resolvedTrackCoverFutures[coverSearchKey];
    if (cachedFuture != null &&
        _resolvedTrackCovers.containsKey(coverSearchKey)) {
      return cachedFuture;
    }

    return _trackCoverFutures.putIfAbsent(coverSearchKey, () async {
      final manualPath = await manualPathFuture;
      if (manualPath != null) {
        _resolvedTrackCovers[coverSearchKey] = manualPath;
        _resolvedTrackCoverFutures[coverSearchKey] = SynchronousFuture<String?>(
          manualPath,
        );
        _trimResolvedTrackCovers();
        final removedTrackFuture = _trackCoverFutures.remove(coverSearchKey);
        if (removedTrackFuture != null) unawaited(removedTrackFuture);
        return manualPath;
      }
      final coverCachePath = await coverCachePathFuture;
      if (coverCachePath != null) {
        _resolvedTrackCovers[coverSearchKey] = coverCachePath;
        _resolvedTrackCoverFutures[coverSearchKey] = SynchronousFuture<String?>(
          coverCachePath,
        );
        _trimResolvedTrackCovers();
        final removedTrackFuture = _trackCoverFutures.remove(coverSearchKey);
        if (removedTrackFuture != null) unawaited(removedTrackFuture);
        return coverCachePath;
      }

      if (_resolvedTrackCovers.containsKey(coverSearchKey)) {
        return _resolvedTrackCoverFutures.putIfAbsent(
          coverSearchKey,
          () =>
              SynchronousFuture<String?>(_resolvedTrackCovers[coverSearchKey]),
        );
      }

      final cardCoverTarget = _cardCoverTargetForTrack(track);
      final persistedCardCover = cardCoverTarget == null
          ? null
          : (await _loadValidCardCover(cardCoverTarget)).path;
      if (persistedCardCover != null) {
        final removedTrackFuture = _trackCoverFutures.remove(coverSearchKey);
        if (removedTrackFuture != null) unawaited(removedTrackFuture);
        _resolvedTrackCovers[coverSearchKey] = persistedCardCover;
        _resolvedTrackCoverFutures[coverSearchKey] = SynchronousFuture<String?>(
          persistedCardCover,
        );
        await _sourceResolver.bindPersistentCover(
          _trackStoreKey(coverSearchKey, track),
          persistedCardCover,
        );
        _trimResolvedTrackCovers();
        return persistedCardCover;
      }

      var isOwnTrackCover = false;
      String? coverPath;
      final remoteCoverUrl = track?.remoteCoverUrl?.trim();
      if (remoteCoverUrl != null && remoteCoverUrl.isNotEmpty) {
        coverPath = await futureForRemoteCover(remoteCoverUrl);
        isOwnTrackCover = coverPath != null;
      }
      if (coverPath == null &&
          pathValue != null &&
          !PathMatcher.isRemoteUri(pathValue)) {
        if (track != null && _isVideoTrack(track, trackPath: pathValue)) {
          coverPath = await _sourceResolver.resolveVideoFramePathForTrack(
            track,
          );
          isOwnTrackCover = coverPath != null;
        } else if (track != null) {
          coverPath = await _sourceResolver.resolvePlatformCoverPathForTrack(
            track,
            includeGroupCoverFallback: !preferEmbeddedCover,
          );
          isOwnTrackCover = coverPath != null && preferEmbeddedCover;
        }
      }
      if (coverPath == null && preferEmbeddedCover) {
        coverPath = await _explicitFolderCoverFutureForTrack(
          track,
          trackPath: pathValue,
        );
        if (coverPath == null && track != null) {
          coverPath = await _sourceResolver.resolvePlatformCoverPathForTrack(
            track,
          );
        }
      }

      if (requestGeneration != _generation) {
        return resolvedForTrack(track, trackPath: trackPath);
      }

      final removedTrackFuture = _trackCoverFutures.remove(coverSearchKey);
      if (removedTrackFuture != null) unawaited(removedTrackFuture);
      final previous = _resolvedTrackCovers[coverSearchKey];
      if (coverPath == null && coverSearchKey.startsWith('remote-cover:')) {
        _resolvedTrackCovers.remove(coverSearchKey);
        final removedResolvedTrackFuture = _resolvedTrackCoverFutures.remove(
          coverSearchKey,
        );
        if (removedResolvedTrackFuture != null) {
          unawaited(removedResolvedTrackFuture);
        }
      } else {
        _resolvedTrackCovers[coverSearchKey] = coverPath;
        _resolvedTrackCoverFutures[coverSearchKey] = SynchronousFuture<String?>(
          coverPath,
        );
        if (coverPath != null && isOwnTrackCover) {
          await _sourceResolver.bindPersistentCover(
            _trackStoreKey(coverSearchKey, track),
            coverPath,
          );
        }
        _trimResolvedTrackCovers();
      }

      if (previous != coverPath &&
          (_isActiveCoverKey?.call(coverSearchKey) ?? false)) {
        _onActiveCoverChanged?.call();
      }

      if (cardCoverTarget != null) {
        await _saveCardCoverPath(cardCoverTarget, coverPath);
      }

      return coverPath;
    });
  }

  String? _resolvedExplicitFolderCoverForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final candidateScopes = _candidateFolderScopesForTrack(
      track,
      trackPath: trackPath,
    );
    for (final scope in candidateScopes) {
      if (_folderCoverSelections.containsKey(scope)) {
        final resolved = resolvedForFolder(scope);
        if (resolved != null) return resolved;
      }
    }
    return null;
  }

  Future<String?> _explicitFolderCoverFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) async {
    await _ensureFolderCoverSelections();
    final candidateScopes = _candidateFolderScopesForTrack(
      track,
      trackPath: trackPath,
    );
    for (final normalizedFolderScope in candidateScopes) {
      var selectedCover = _folderCoverSelections[normalizedFolderScope];
      var selectedCoverPath = await _displayPathForStoredCover(
        AudioDetailTarget.libraryRootFolder(normalizedFolderScope),
        selectedCover,
      );
      if (selectedCover != null && selectedCoverPath == null) {
        _folderCoverSelections.remove(normalizedFolderScope);
        await _saveFolderCoverSelections();
        invalidateFolder(normalizedFolderScope);
        selectedCover = null;
      }
      if (selectedCoverPath == null) {
        final persistedCover = await _loadValidFolderCardCover(
          normalizedFolderScope,
        );
        if (persistedCover.selected) {
          selectedCover = persistedCover.path;
          if (selectedCover != null) {
            selectedCoverPath = selectedCover;
            _folderCoverSelections[normalizedFolderScope] =
                _persistedFolderCoverPath(selectedCover);
            await _saveFolderCoverSelections();
          }
        }
      }
      if (selectedCoverPath != null) {
        _resolvedFolderCovers[normalizedFolderScope] = selectedCoverPath;
        _resolvedFolderCoverFutures[normalizedFolderScope] =
            SynchronousFuture<String?>(selectedCoverPath);
        _trimResolvedFolderCovers();
        await _saveFolderCardCoverPath(
          normalizedFolderScope,
          selectedCoverPath,
        );
        return selectedCoverPath;
      }
    }
    return null;
  }

  Future<String?> _resolveCoverPathForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);

    final storedFolderPath = _artworkStore.resolvedPath(
      _folderStoreKey(normalizedFolderPath),
    );
    if (storedFolderPath != null) {
      _resolvedFolderCovers[normalizedFolderPath] = storedFolderPath;
      final storedFuture = SynchronousFuture<String?>(storedFolderPath);
      _resolvedFolderCoverFutures[normalizedFolderPath] = storedFuture;
      return storedFuture;
    }

    if (_resolvedFolderCovers.containsKey(normalizedFolderPath)) {
      return _resolvedFolderCoverFutures.putIfAbsent(
        normalizedFolderPath,
        () => SynchronousFuture<String?>(
          _resolvedFolderCovers[normalizedFolderPath],
        ),
      );
    }

    final inFlight = _folderCoverFutures[normalizedFolderPath];
    if (inFlight != null) return inFlight;
    final requestGeneration = _generation;
    final requestRevision = _coverKeyRevision(normalizedFolderPath);
    late final Future<String?> lookup;
    lookup = () async {
      await _ensureFolderCoverSelections();
      if (!_isFolderLookupCurrent(
        normalizedFolderPath,
        requestGeneration,
        requestRevision,
        lookup,
      )) {
        return _resolvedFolderCovers[normalizedFolderPath];
      }
      final selectedCover = _folderCoverSelections[normalizedFolderPath];
      final selectedCoverPath = await _displayPathForStoredCover(
        AudioDetailTarget.libraryRootFolder(normalizedFolderPath),
        selectedCover,
      );
      final persistedCover = selectedCoverPath == null
          ? await _loadValidFolderCardCover(normalizedFolderPath)
          : (path: null, selected: false);
      if (!_isFolderLookupCurrent(
        normalizedFolderPath,
        requestGeneration,
        requestRevision,
        lookup,
      )) {
        return _resolvedFolderCovers[normalizedFolderPath];
      }
      final indexedCoverPath = selectedCoverPath ?? persistedCover.path;
      if (indexedCoverPath != null) {
        var selectionChanged = false;
        if (selectedCover != null && selectedCoverPath == null) {
          _folderCoverSelections.remove(normalizedFolderPath);
          selectionChanged = true;
        }
        if (persistedCover.selected) {
          _folderCoverSelections[normalizedFolderPath] =
              _persistedFolderCoverPath(indexedCoverPath);
          selectionChanged = true;
        }
        if (selectionChanged) {
          await _saveFolderCoverSelections();
        }
        await _saveFolderCardCoverPath(normalizedFolderPath, indexedCoverPath);
        if (!_isFolderLookupCurrent(
          normalizedFolderPath,
          requestGeneration,
          requestRevision,
          lookup,
        )) {
          return _resolvedFolderCovers[normalizedFolderPath];
        }
        _resolvedFolderCovers[normalizedFolderPath] = indexedCoverPath;
        _resolvedFolderCoverFutures[normalizedFolderPath] =
            SynchronousFuture<String?>(indexedCoverPath);
        await _sourceResolver.bindPersistentCover(
          _folderStoreKey(normalizedFolderPath),
          indexedCoverPath,
        );
        _trimResolvedFolderCovers();
        return indexedCoverPath;
      }
      final coverPath = await _sourceResolver.resolvePreferredFolderCover(
        normalizedFolderPath,
      );
      if (!_isFolderLookupCurrent(
        normalizedFolderPath,
        requestGeneration,
        requestRevision,
        lookup,
      )) {
        return _resolvedFolderCovers[normalizedFolderPath];
      }
      if (selectedCover != null && selectedCover != coverPath) {
        _folderCoverSelections.remove(normalizedFolderPath);
        await _saveFolderCoverSelections();
      }
      await _saveFolderCardCoverPath(normalizedFolderPath, coverPath);
      if (!_isFolderLookupCurrent(
        normalizedFolderPath,
        requestGeneration,
        requestRevision,
        lookup,
      )) {
        return _resolvedFolderCovers[normalizedFolderPath];
      }
      _resolvedFolderCovers[normalizedFolderPath] = coverPath;
      _resolvedFolderCoverFutures[normalizedFolderPath] =
          SynchronousFuture<String?>(coverPath);
      if (coverPath != null) {
        await _sourceResolver.bindPersistentCover(
          _folderStoreKey(normalizedFolderPath),
          coverPath,
        );
      }
      _trimResolvedFolderCovers();

      return coverPath;
    }();
    _folderCoverFutures[normalizedFolderPath] = lookup;
    void removeLookup() {
      if (identical(_folderCoverFutures[normalizedFolderPath], lookup)) {
        _folderCoverFutures.remove(normalizedFolderPath);
      }
    }

    unawaited(
      lookup.then<void>(
        (_) => removeLookup(),
        onError: (Object _, StackTrace _) {
          removeLookup();
        },
      ),
    );
    return lookup;
  }

  bool _isFolderLookupCurrent(
    String key,
    int generation,
    int revision,
    Future<String?> lookup,
  ) {
    return _isCoverKeyCurrent(
          key,
          generation: generation,
          revision: revision,
        ) &&
        identical(_folderCoverFutures[key], lookup);
  }

  AudioDetailTarget? _cardCoverTargetForTrack(MusicTrack? track) {
    if (track == null || !_isStandaloneAudioTrack(track)) return null;
    return AudioDetailTarget.singleAudioFile(track.path);
  }

  AudioDetailTarget? _cardCoverTargetForFolder(String folderPath) {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final rootFolder = const LibraryOrganizer().rootFolderPath(
      normalizedFolder,
      _libraryService.watchedFolders,
      watchedLibraries: _libraryService.watchedLibraries,
    );
    if (!PathMatcher.equalsNormalized(normalizedFolder, rootFolder)) {
      return null;
    }
    return AudioDetailTarget.libraryRootFolder(rootFolder);
  }

  Future<void> _saveTrackCardCoverPath(
    MusicTrack? track,
    String coverPath,
  ) async {
    final target = _cardCoverTargetForTrack(track);
    if (target != null) await _saveCardCoverPath(target, coverPath);
  }

  Future<({String? path, bool selected})> _loadValidCardCover(
    AudioDetailTarget target,
  ) async {
    try {
      final cacheService = _audioDetailCacheService;
      if (cacheService == null) return (path: null, selected: false);
      final storedCover = await cacheService.loadCardCoverSelection(target);
      final path = await _displayPathForStoredCover(target, storedCover.path);
      return (path: path, selected: path != null && storedCover.selected);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to load card cover path.',
        error: error,
        stackTrace: stackTrace,
      );
      return (path: null, selected: false);
    }
  }

  Future<({String? path, bool selected})> _loadValidFolderCardCover(
    String folderPath,
  ) {
    final target = _cardCoverTargetForFolder(folderPath);
    return target == null
        ? Future<({String? path, bool selected})>.value((
            path: null,
            selected: false,
          ))
        : _loadValidCardCover(target);
  }

  Future<String?> _saveCardCoverPath(
    AudioDetailTarget target,
    String? coverPath, {
    bool? selected,
    bool writeDocument = false,
  }) async {
    try {
      return await _audioDetailCacheService?.saveCardCoverPath(
        target,
        coverPath,
        selected: selected,
        writeDocument: writeDocument,
      );
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to save card cover path.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<String?> _saveFolderCardCoverPath(
    String folderPath,
    String? coverPath, {
    bool? selected,
    bool writeDocument = false,
  }) {
    final target = _cardCoverTargetForFolder(folderPath);
    final persistedCoverPath = coverPath == null
        ? null
        : _persistedFolderCoverPath(coverPath);
    return target == null
        ? Future<String?>.value()
        : _saveCardCoverPath(
            target,
            persistedCoverPath,
            selected: selected,
            writeDocument: writeDocument,
          );
  }

  String _persistedFolderCoverPath(String displayPath) {
    return _sourceResolver.sourcePathForDisplay(displayPath) ?? displayPath;
  }

  Future<String?> _displayPathForStoredCover(
    AudioDetailTarget target,
    String? storedPath,
  ) async {
    final value = storedPath?.trim();
    if (value == null || value.isEmpty) return null;
    if (!PathMatcher.isContentUri(value)) {
      return _validatedManualCoverPath(value);
    }
    final cached = _sourceResolver.displayPathForSource(value);
    if (cached != null) return _validatedManualCoverPath(cached);
    if (!target.isLibraryRootFolder) return null;
    await _sourceResolver.discoverFolderImages(target.targetPath);
    final discovered = _sourceResolver.displayPathForSource(value);
    return discovered == null
        ? _validatedManualCoverPath(value)
        : _validatedManualCoverPath(discovered);
  }

  Future<String?> _resolveRemoteCover(String remoteKey, String remoteUrl) {
    if (_disposed) return Future<String?>.value();
    final resolvedFuture = _resolvedRemoteCoverFutures[remoteKey];
    if (resolvedFuture != null) return resolvedFuture;
    final inFlight = _remoteCoverFutures[remoteKey];
    if (inFlight != null) return inFlight;
    final failure = _remoteCoverFailures[remoteKey];
    if (failure != null && _now().isBefore(failure.retryAt)) {
      return Future<String?>.value();
    }
    return _remoteCoverFutures.putIfAbsent(remoteKey, () async {
      try {
        final previous = _resolvedRemoteCovers[remoteKey];
        var coverPath = previous;
        if (coverPath == null && _remoteCoverDownloader == null) {
          await _artworkStore.initialize();
          coverPath = _artworkStore.resolvedPath(remoteKey);
        }
        if (coverPath == null ||
            !await _remoteDownloads.isUsablePath(coverPath)) {
          _resolvedRemoteCovers.remove(remoteKey);
          final removedResolvedFuture = _resolvedRemoteCoverFutures.remove(
            remoteKey,
          );
          if (removedResolvedFuture != null) {
            unawaited(removedResolvedFuture);
          }
          final downloader = _remoteCoverDownloader;
          coverPath = await _remoteDownloads.run(
            () => downloader == null
                ? _remoteDownloads.download(remoteUrl, logicalKey: remoteKey)
                : downloader(remoteUrl),
          );
        }

        if (_disposed) return null;
        if (coverPath == null) {
          _resolvedRemoteCovers.remove(remoteKey);
          final removedResolvedFuture = _resolvedRemoteCoverFutures.remove(
            remoteKey,
          );
          if (removedResolvedFuture != null) {
            unawaited(removedResolvedFuture);
          }
          _recordRemoteCoverFailure(remoteKey);
        } else {
          _remoteCoverFailures.remove(remoteKey);
          _resolvedRemoteCovers.remove(remoteKey);
          _resolvedRemoteCovers[remoteKey] = coverPath;
          final resolvedFuture = Future<String?>.value(coverPath);
          _resolvedRemoteCoverFutures[remoteKey] = resolvedFuture;
          await _sourceResolver.bindPersistentCover(remoteKey, coverPath);
          _trimResolvedRemoteCovers();
        }

        if (previous != coverPath &&
            (_isActiveCoverKey?.call(remoteKey) ?? false)) {
          _onActiveCoverChanged?.call();
        }

        return coverPath;
      } finally {
        final removedRemoteFuture = _remoteCoverFutures.remove(remoteKey);
        if (removedRemoteFuture != null) unawaited(removedRemoteFuture);
      }
    });
  }

  void _recordRemoteCoverFailure(String remoteKey) {
    final failureCount = (_remoteCoverFailures[remoteKey]?.count ?? 0) + 1;
    var delaySeconds = 10;
    for (var attempt = 1; attempt < failureCount; attempt++) {
      delaySeconds = (delaySeconds * 2).clamp(10, 300).toInt();
    }
    _remoteCoverFailures.remove(remoteKey);
    _remoteCoverFailures[remoteKey] = _RemoteCoverFailure(
      count: failureCount,
      retryAt: _now().add(Duration(seconds: delaySeconds)),
    );
    while (_remoteCoverFailures.length > _resolvedRemoteCoverLimit) {
      _remoteCoverFailures.remove(_remoteCoverFailures.keys.first);
    }
  }

  bool _isResolvedRemoteCoverPathPresent(String coverPath) {
    if (PathMatcher.isContentUri(coverPath) ||
        PathMatcher.isRemoteUri(coverPath)) {
      return true;
    }
    try {
      return File(coverPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _remoteDownloads.dispose();
    _remoteCoverFutures.clear();
    _resolvedRemoteCoverFutures.clear();
    _resolvedRemoteCovers.clear();
    _remoteCoverFailures.clear();
  }

  String? _cachedManualCoverPath(String? coverPath) {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return null;
    final stored = _artworkStore.resolveStoredPath(value);
    if (stored != null) return stored;
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return value;
    }
    return _manualCoverPathValidityCache[value] == true ? value : null;
  }

  Future<String?> _validatedManualCoverPath(String? coverPath) {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return SynchronousFuture<String?>(null);
    final stored = _artworkStore.resolveStoredPath(value);
    if (stored != null) {
      _manualCoverPathValidityCache[stored] = true;
      _trimManualCoverValidityCache();
      return SynchronousFuture<String?>(stored);
    }
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      _manualCoverPathValidityCache[value] = true;
      _trimManualCoverValidityCache();
      return SynchronousFuture<String?>(value);
    }
    final cached = _manualCoverPathValidityCache[value];
    if (cached != null) {
      return SynchronousFuture<String?>(cached ? value : null);
    }
    return _manualCoverValidationFutures.putIfAbsent(value, () async {
      final exists = await File(value).exists();
      _manualCoverPathValidityCache[value] = exists;
      _trimManualCoverValidityCache();
      unawaited(_manualCoverValidationFutures.remove(value) ?? Future.value());
      return exists ? value : null;
    });
  }

  Future<String?> resolveEmbeddedCoverForPath(String filePath) =>
      _sourceResolver.resolveEmbeddedCoverForPath(filePath);

  String _trackSourceFingerprint(MusicTrack track) =>
      '${PathMatcher.normalize(track.path)}|${track.fileSizeBytes ?? 0}|'
      '${track.modifiedAt?.millisecondsSinceEpoch ?? 0}';

  String _trackStoreKey(String coverSearchKey, MusicTrack? track) =>
      'track:$coverSearchKey|${track?.fileSizeBytes ?? 0}|'
      '${track?.modifiedAt?.millisecondsSinceEpoch ?? 0}|'
      '${_preferTrackEmbeddedCover(track)}';

  String _folderStoreKey(String normalizedFolderPath) =>
      'folder:$normalizedFolderPath';
}

final class _RemoteCoverFailure {
  const _RemoteCoverFailure({required this.count, required this.retryAt});

  final int count;
  final DateTime retryAt;
}

bool _isStandaloneAudioTrack(MusicTrack? track, {String? trackPath}) {
  final pathValue = trackPath ?? track?.path;
  final isVideo =
      track?.isVideo == true ||
      (pathValue?.isNotEmpty == true && isVideoMediaFile(pathValue!));
  return track?.isSingle == true && !isVideo;
}

String? remoteCoverSearchKey(String url) {
  final normalized = normalizeRemoteCoverUrl(url);
  if (normalized == null) return null;
  return 'remote-cover:$normalized';
}

String? normalizeRemoteCoverUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty || !PathMatcher.isRemoteUri(trimmed)) return null;
  return PathMatcher.normalize(trimmed);
}

String normalizedRemoteUrlFromKey(String remoteKey) {
  const prefix = 'remote-cover:';
  return remoteKey.startsWith(prefix)
      ? remoteKey.substring(prefix.length)
      : remoteKey;
}

String _normalizeCoverCacheKey(String value) {
  if (!value.startsWith('remote-cover:')) return PathMatcher.normalize(value);
  return remoteCoverSearchKey(normalizedRemoteUrlFromKey(value)) ?? value;
}

String _remoteCoverFileStem(String remoteUrl) {
  final normalized = normalizeRemoteCoverUrl(remoteUrl) ?? remoteUrl.trim();
  return sha1.convert(utf8.encode(normalized)).toString();
}
