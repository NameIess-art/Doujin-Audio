import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/media/audio_detail.dart';
import '../../settings/application/app_cache_service.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/media_file_support.dart';
import '../domain/library_persistence_repository.dart';
import 'audio_detail_cache_service.dart';
import 'cover_image_cache_policy.dart';
import 'cover_artwork_store.dart';
import 'library_organizer.dart';
import 'library_service.dart';
import 'embedded_cover_artwork_service.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';

const String _folderCoverSelectionsKey = 'folder_cover_selections_v1';
const Set<String> _folderCoverImageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.bmp',
  '.gif',
};
const int _resolvedTrackCoverLimit = 600;
const int _resolvedFolderCoverLimit = 300;
const int _resolvedRemoteCoverLimit = 300;
const int _manualCoverValidityLimit = 1200;
const int _maxConcurrentRemoteDownloads = 4;
const int _maxConcurrentFolderCandidateResolutions = 4;
const String _asmrOneAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

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
    bool Function()? preferEmbeddedAudioCover,
  }) : _libraryService = libraryService,
       _databaseRepository = databaseRepository,
       _audioDetailCacheService = audioDetailCacheService,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _filesystemImageScanner = filesystemImageScanner,
       _remoteCoverDownloader = remoteCoverDownloader,
       _requestTimeout = requestTimeout,
       _downloadIdleTimeout = downloadIdleTimeout,
       _now = now ?? DateTime.now,
       _artworkStore =
           artworkStore ??
           CoverArtworkStore(
             persistentDirectory: persistentDirectory,
             temporaryDirectory: temporaryDirectory,
           ),
       _isActiveCoverKey = isActiveCoverKey,
       _onActiveCoverChanged = onActiveCoverChanged,
       _preferEmbeddedAudioCover = preferEmbeddedAudioCover;

  final LibraryService _libraryService;
  final LibraryPersistenceRepository? _databaseRepository;
  final AudioDetailCacheService? _audioDetailCacheService;
  final FileCachePlatformGateway _fileCacheGateway;
  final Future<List<String>> Function(String rootPath, bool recursive)?
  _filesystemImageScanner;
  final Future<String?> Function(String remoteUrl)? _remoteCoverDownloader;
  final Duration _requestTimeout;
  final Duration _downloadIdleTimeout;
  final DateTime Function() _now;
  final CoverArtworkStore _artworkStore;
  final bool Function(String coverSearchKey)? _isActiveCoverKey;
  final VoidCallback? _onActiveCoverChanged;
  final bool Function()? _preferEmbeddedAudioCover;

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
  final Queue<Completer<void>> _remoteDownloadWaiters = Queue();
  final Map<String, bool> _manualCoverPathValidityCache = <String, bool>{};
  final Map<String, Future<String?>> _manualCoverValidationFutures =
      <String, Future<String?>>{};
  final Map<String, String> _folderCoverSelections = <String, String>{};
  final Map<String, int> _coverKeyRevisions = <String, int>{};
  final Map<String, Future<List<String>>> _folderImageIndexFutures =
      <String, Future<List<String>>>{};
  final Map<String, String> _folderImageSourceByDisplayKey = <String, String>{};
  final Map<String, String> _folderImageDisplayBySourceKey = <String, String>{};
  Future<void>? _folderCoverSelectionsLoadFuture;
  HttpClient? _remoteHttpClient;
  int _activeRemoteDownloads = 0;
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
      final resolved = _resolvedTrackCovers[coverSearchKey] ??
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
    final resolved = _resolvedFolderCovers[normalizedFolderPath] ??
        _artworkStore.resolvedPath(_folderStoreKey(normalizedFolderPath));
    if (resolved != null) return resolved;
    final selected = _folderCoverSelections[normalizedFolderPath];
    if (selected != null) {
      final display =
          _folderImageDisplayBySourceKey[PathMatcher.equivalenceKey(selected)] ??
          selected;
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
      final embeddedPath = _artworkStore.resolvedPath(embeddedKey) ??
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

    final playbackFuture =
        _playbackTrackCoverFutures.putIfAbsent(coverSearchKey, () {
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
        });
    _trimPlaybackTrackCoverFutures();
    return playbackFuture;
  }

  Future<String?> _resolvePlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) async {
    await _ensureFolderCoverSelections();
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
      if (folderCover != null) return folderCover;
      return futureForTrack(track, trackPath: trackPath);
    } else {
      final trackCover = await futureForTrack(track, trackPath: trackPath);
      if (trackCover != null) return trackCover;
      return resolveFromFolder();
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
        _mostSpecificContainingRoot(
          _libraryService.watchedFolders,
          pathValue,
        ) ??
        (groupKey.isEmpty
            ? null
            : _mostSpecificContainingRoot(
                _libraryService.watchedFolders,
                groupKey,
              ));
    if (watchedFolder != null && watchedFolder.isNotEmpty) {
      return watchedFolder;
    }

    final watchedLibrary =
        (groupKey.isEmpty
            ? null
            : _mostSpecificContainingRoot(
                _libraryService.watchedLibraries,
                groupKey,
              )) ??
        _mostSpecificContainingRoot(
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

  String? _enclosingFolderForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
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
    return track != null &&
        !_isVideoTrack(track, trackPath: trackPath) &&
        (_preferEmbeddedAudioCover?.call() ?? false);
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
  }) async {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (normalizedFolder.isEmpty) return const <String>[];
    final candidates = await _resolveFolderCoverCandidates(normalizedFolder);
    final selectedCover = selectedCoverPath?.trim();
    if (selectedCover == null || selectedCover.isEmpty) return candidates;
    return _candidatesWithSelectedCover(selectedCover, candidates);
  }

  Future<List<String>> _candidatesWithSelectedCover(
    String selectedCover,
    List<String> candidates,
  ) async {
    final selectedPathKey = PathMatcher.equivalenceKey(selectedCover);
    final selectedContentKey = await _localCoverContentKey(selectedCover);
    final seenPaths = <String>{selectedPathKey};
    final seenContentKeys = <String>{
      ?selectedContentKey,
    };
    final distinct = <String>[selectedCover];
    for (final candidate in candidates) {
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) continue;
      final contentKey = await _localCoverContentKey(candidate);
      if (contentKey != null && !seenContentKeys.add(contentKey)) {
        continue;
      }
      distinct.add(candidate);
    }
    return List<String>.unmodifiable(distinct);
  }

  Future<String?> _localCoverContentKey(String coverPath) async {
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
      final candidates = await _resolveFolderCoverCandidates(normalizedFolder);
      final hasCandidate = candidates.any(
        (c) =>
            PathMatcher.equalsNormalized(c, normalizedCover) ||
            PathMatcher.equivalenceKey(c) ==
                PathMatcher.equivalenceKey(normalizedCover),
      );
      if (!hasCandidate) {
        final coverContentKey = await _localCoverContentKey(normalizedCover);
        var contentMatched = false;
        if (coverContentKey != null) {
          for (final candidate in candidates) {
            if (await _localCoverContentKey(candidate) == coverContentKey) {
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
      _rememberFolderImageSource(normalizedCover, durableSource);
    }
    final selectionGeneration = _generation;
    final selectionRevision = _coverKeyRevision(normalizedFolder);
    await _ensureFolderCoverSelections();
    _folderCoverSelections[normalizedFolder] = normalizedCover;
    final hasDurableSource = _folderImageSourceByDisplayKey.containsKey(
      PathMatcher.equivalenceKey(normalizedCover),
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
    await _bindPersistentCover(
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
    final previousCover = _folderCoverSelections.remove(oldFolder);
    if (previousCover == null || newFolder.isEmpty) return;
    final relativeCover = PathMatcher.relativeWithin(previousCover, oldFolder);
    _folderCoverSelections[newFolder] = relativeCover == null
        ? previousCover
        : PathMatcher.join(newFolder, relativeCover);
    await _saveFolderCoverSelections();
    invalidateFolders(<String>[oldFolder, newFolder]);
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
    for (final track in _tracksInCompleteCoverScope(normalizedScope)) {
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
    _invalidateFolderImageIndexes(normalizedScope);
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
      for (final track in _tracksInCompleteCoverScope(scope)) {
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
      _invalidateFolderImageIndexes(scope);
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
    _folderImageIndexFutures.clear();
    _folderImageSourceByDisplayKey.clear();
    _folderImageDisplayBySourceKey.clear();
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

  void _invalidateFolderImageIndexes(String normalizedScope) {
    final roots = _folderImageIndexFutures.keys.toList(growable: false);
    for (final root in roots) {
      if (PathMatcher.isWithinOrEqual(normalizedScope, root) ||
          PathMatcher.isWithinOrEqual(root, normalizedScope)) {
        _folderImageIndexFutures.remove(root);
      }
    }
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
    _trimResolvedCache(
      _playbackTrackCoverFutures,
      _resolvedTrackCoverLimit,
    );
  }

  void trimMemory() {
    _folderImageIndexFutures.clear();
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
        await _bindPersistentCover(
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
          coverPath = await _resolveVideoFramePathForTrack(track);
          isOwnTrackCover = coverPath != null;
        } else if (track != null) {
          coverPath = await _resolvePlatformCoverPathForTrack(
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
          coverPath = await _resolvePlatformCoverPathForTrack(track);
        }
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
          await _bindPersistentCover(
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
        await _saveFolderCardCoverPath(normalizedFolderScope, selectedCoverPath);
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
        await _bindPersistentCover(
          _folderStoreKey(normalizedFolderPath),
          indexedCoverPath,
        );
        _trimResolvedFolderCovers();
        return indexedCoverPath;
      }
      final coverPath = await _resolvePreferredFolderCover(
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
        await _bindPersistentCover(
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
    return _folderImageSourceByDisplayKey[PathMatcher.equivalenceKey(
          displayPath,
        )] ??
        displayPath;
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
    final sourceKey = PathMatcher.equivalenceKey(value);
    final cached = _folderImageDisplayBySourceKey[sourceKey];
    if (cached != null) return _validatedManualCoverPath(cached);
    if (!target.isLibraryRootFolder) return null;
    await _discoverFolderImages(target.targetPath);
    final discovered = _folderImageDisplayBySourceKey[sourceKey];
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
        if (coverPath == null || !await _isUsableRemoteCoverPath(coverPath)) {
          _resolvedRemoteCovers.remove(remoteKey);
          final removedResolvedFuture = _resolvedRemoteCoverFutures.remove(
            remoteKey,
          );
          if (removedResolvedFuture != null) {
            unawaited(removedResolvedFuture);
          }
          final downloader = _remoteCoverDownloader;
          coverPath = await _runRemoteDownload(
            () => downloader == null
                ? _downloadRemoteCover(remoteUrl)
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
          await _bindPersistentCover(remoteKey, coverPath);
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

  Future<String?> _runRemoteDownload(
    Future<String?> Function() download,
  ) async {
    if (_disposed) return null;
    if (_activeRemoteDownloads >= _maxConcurrentRemoteDownloads) {
      final waiter = Completer<void>();
      _remoteDownloadWaiters.add(waiter);
      await waiter.future;
      if (_disposed) return null;
    } else {
      _activeRemoteDownloads++;
    }
    try {
      return await download();
    } finally {
      if (_remoteDownloadWaiters.isNotEmpty) {
        _remoteDownloadWaiters.removeFirst().complete();
      } else {
        _activeRemoteDownloads--;
      }
    }
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

  Future<bool> _isUsableRemoteCoverPath(String? coverPath) async {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return false;
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return true;
    }
    try {
      final file = File(value);
      if (!await file.exists() || await file.length() <= 0) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _downloadRemoteCover(String remoteUrl) async {
    HttpClientRequest? request;
    try {
      final client = _remoteHttpClient ??= HttpClient();
      client.connectionTimeout = _requestTimeout;
      request = await client
          .getUrl(Uri.parse(remoteUrl))
          .timeout(_requestTimeout);
      for (final header in remoteCoverRequestHeadersForUrl(remoteUrl).entries) {
        request.headers.set(header.key, header.value);
      }
      final response = await request.close().timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      if (response.contentLength > maxCoverFileBytes) return null;

      final bytes = BytesBuilder(copy: false);
      final headerBytes = <int>[];
      var totalBytes = 0;
      await for (final chunk in response.timeout(_downloadIdleTimeout)) {
        totalBytes += chunk.length;
        if (totalBytes > maxCoverFileBytes) {
          throw const _RemoteCoverTooLargeException();
        }
        if (headerBytes.length < 64) {
          final remaining = 64 - headerBytes.length;
          headerBytes.addAll(chunk.take(remaining));
        }
        bytes.add(chunk);
      }
      if (totalBytes <= 0 || detectCoverMimeType('', headerBytes) == null) {
        return null;
      }
      if (_isClearingPersistentCache) return null;
      return _artworkStore.putBytes(
        logicalKey: remoteCoverSearchKey(remoteUrl) ?? remoteUrl,
        bytes: bytes.takeBytes(),
        namespace: CoverArtworkNamespace.remote,
      );
    } catch (error, stackTrace) {
      request?.abort(error, stackTrace);
      AppLogService.warning(
        'Unable to cache remote notification cover.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _remoteHttpClient?.close(force: true);
    _remoteHttpClient = null;
    while (_remoteDownloadWaiters.isNotEmpty) {
      _remoteDownloadWaiters.removeFirst().complete();
    }
    _remoteCoverFutures.clear();
    _resolvedRemoteCoverFutures.clear();
    _resolvedRemoteCovers.clear();
    _remoteCoverFailures.clear();
  }

  Future<String?> _resolveVideoFramePathForTrack(MusicTrack track) async {
    try {
      final nativeFrame = await _fileCacheGateway.resolveVideoFrame(
        path: track.path,
        modifiedAtMs: track.modifiedAt?.millisecondsSinceEpoch,
      );
      if (nativeFrame != null && nativeFrame.isNotEmpty) {
        return await _persistBridgeCover(
          logicalKey:
              'video:${PathMatcher.normalize(track.path)}:'
              '${track.modifiedAt?.millisecondsSinceEpoch ?? 0}:v3',
          sourcePath: nativeFrame,
          namespace: CoverArtworkNamespace.generated,
        );
      }
    } on MissingPluginException {
      return null;
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolveVideoFramePathForTrack error',
        error: e,
        stackTrace: stackTrace,
      );
    }
    return null;
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

  Future<String?> _resolvePlatformCoverPathForTrack(
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
        return await _persistBridgeCover(
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
        'CoverArtworkCacheService._resolvePlatformCoverPathForTrack error',
        error: e,
        stackTrace: stackTrace,
      );
    }

    String? embeddedCover;
    try {
      embeddedCover = await EmbeddedCoverArtworkService.resolveForTrack(track);
      if (embeddedCover == null && PathMatcher.isContentUri(track.path)) {
        final localPath =
            await _fileCacheGateway.resolveDocumentFileSystemPath(track.path);
        if (localPath != null && localPath.isNotEmpty) {
          embeddedCover =
              await EmbeddedCoverArtworkService.resolveForPath(localPath);
        }
      }
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolvePlatformCoverPathForTrack embedded cover error',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (embeddedCover != null) {
      return await _persistBridgeCover(
        logicalKey: 'embedded:${_trackSourceFingerprint(track)}',
        sourcePath: embeddedCover,
        namespace: CoverArtworkNamespace.embedded,
      );
    }

    return null;
  }

  Future<String?> resolveEmbeddedCoverForPath(String filePath) =>
      _resolveEmbeddedCoverForPath(filePath);

  Future<String?> _resolveEmbeddedCoverForPath(String filePath) async {
    final track = _libraryService.trackByPath(filePath);
    if (track != null) {
      return _resolvePlatformCoverPathForTrack(
        track,
        includeGroupCoverFallback: false,
      );
    }
    try {
      final nativeCover = await _fileCacheGateway.resolveTrackCover(
        path: filePath,
      );
      if (nativeCover != null && nativeCover.isNotEmpty) {
        return await _persistBridgeCover(
          logicalKey: 'native:${PathMatcher.normalize(filePath)}',
          sourcePath: nativeCover,
          namespace: CoverArtworkNamespace.embedded,
        );
      }
    } on MissingPluginException {
      // Continue with the Dart fallback below.
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolveEmbeddedCoverForPath native error',
        error: e,
        stackTrace: stackTrace,
      );
    }

    String? embeddedCover;
    try {
      embeddedCover = await EmbeddedCoverArtworkService.resolveForPath(filePath);
      if (embeddedCover == null && PathMatcher.isContentUri(filePath)) {
        final localPath =
            await _fileCacheGateway.resolveDocumentFileSystemPath(filePath);
        if (localPath != null && localPath.isNotEmpty) {
          embeddedCover =
              await EmbeddedCoverArtworkService.resolveForPath(localPath);
        }
      }
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolveEmbeddedCoverForPath embedded error',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (embeddedCover != null) {
      return await _persistBridgeCover(
        logicalKey: 'embedded:${PathMatcher.normalize(filePath)}',
        sourcePath: embeddedCover,
        namespace: CoverArtworkNamespace.embedded,
      );
    }

    return null;
  }

  Future<String> _persistBridgeCover({
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
      await _bindPersistentCover(logicalKey, sourcePath);
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

  Future<void> _bindPersistentCover(String logicalKey, String path) async {
    if (_isClearingPersistentCache || !_artworkStore.isInitialized) return;
    await _artworkStore.bind(logicalKey, path);
  }

  String _trackSourceFingerprint(MusicTrack track) =>
      '${PathMatcher.normalize(track.path)}|${track.fileSizeBytes ?? 0}|'
      '${track.modifiedAt?.millisecondsSinceEpoch ?? 0}';

  String _trackStoreKey(String coverSearchKey, MusicTrack? track) =>
      'track:$coverSearchKey|${track?.fileSizeBytes ?? 0}|'
      '${track?.modifiedAt?.millisecondsSinceEpoch ?? 0}|'
      '${_preferTrackEmbeddedCover(track)}';

  String _folderStoreKey(String normalizedFolderPath) =>
      'folder:$normalizedFolderPath';

  Future<List<String>> _resolveFolderCoverCandidates(String folderPath) async {
    final candidates = <String>[];
    final seenPaths = <String>{};
    final seenContentKeys = <String>{};

    for (final imagePath in await _discoverFolderImages(folderPath)) {
      final candidate = imagePath.trim();
      if (candidate.isEmpty) continue;
      final pathKey = PathMatcher.equivalenceKey(candidate);
      if (!seenPaths.add(pathKey)) continue;
      final contentKey = await _localCoverContentKey(candidate);
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
      final contentKey = await _localCoverContentKey(candidate);
      if (contentKey != null && !seenContentKeys.add(contentKey)) {
        return;
      }
      candidates.add(candidate);
    }

    final tracks = _tracksInCompleteCoverScope(folderPath);
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
              ? _resolveVideoFramePathForTrack(track)
              : _resolvePlatformCoverPathForTrack(
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
      final audioFiles = await _discoverFolderAudioFiles(folderPath);
      for (
        var start = 0;
        start < audioFiles.length;
        start += _maxConcurrentFolderCandidateResolutions
      ) {
        final nextEnd = start + _maxConcurrentFolderCandidateResolutions;
        final end = nextEnd < audioFiles.length ? nextEnd : audioFiles.length;
        final batch = audioFiles.sublist(start, end);
        final resolved = await Future.wait(
          batch.map(_resolveEmbeddedCoverForPath),
        );
        for (final candidate in resolved) {
          await addEmbeddedCandidate(candidate);
        }
      }
    }
    return List<String>.unmodifiable(candidates);
  }

  Future<List<String>> _discoverFolderAudioFiles(
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

  Future<String?> _resolvePreferredFolderCover(String folderPath) async {
    final images = await _discoverFolderImages(folderPath, recursive: false);
    if (images.isNotEmpty) return images.first;

    final nestedImages = await _discoverFolderImages(folderPath);
    if (nestedImages.isNotEmpty) return nestedImages.first;

    for (final track in _tracksInCompleteCoverScope(folderPath)) {
      final candidate = _isVideoTrack(track)
          ? await _resolveVideoFramePathForTrack(track)
          : await _resolvePlatformCoverPathForTrack(
              track,
              includeGroupCoverFallback: false,
            );
      if (candidate != null && candidate.trim().isNotEmpty) return candidate;
    }
    return null;
  }

  Future<List<String>> _discoverFolderImages(
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
          _rememberFolderImageSource(image.displayPath, image.sourcePath);
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
      return _buildFolderImageIndex(normalizedFolder, recursive: false);
    }
    final indexRoot = _folderImageIndexRoot(normalizedFolder);
    final indexedImages = await _folderImageIndexFutures.putIfAbsent(
      indexRoot,
      () => _buildFolderImageIndex(indexRoot),
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

  String _folderImageIndexRoot(String folderPath) {
    final roots = <String>[
      ..._libraryService.watchedLibraries,
      ..._libraryService.watchedFolders,
    ];
    return _mostSpecificContainingRoot(roots, folderPath) ?? folderPath;
  }

  Future<List<String>> _buildFolderImageIndex(
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
        _rememberFolderImageSource(imagePath, imagePath);
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

  static const int _maxFolderImageSources = 500;

  void _rememberFolderImageSource(String displayPath, String sourcePath) {
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

  List<MusicTrack> _tracksInCompleteCoverScope(String folderPath) {
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

final class _RemoteCoverFailure {
  const _RemoteCoverFailure({required this.count, required this.retryAt});

  final int count;
  final DateTime retryAt;
}

final class _RemoteCoverTooLargeException implements Exception {
  const _RemoteCoverTooLargeException();
}

String? _mostSpecificContainingRoot(Iterable<String> roots, String value) {
  String? bestMatch;
  for (final root in roots) {
    if (!PathMatcher.isWithinOrEqual(value, root)) continue;
    if (bestMatch == null || root.length > bestMatch.length) {
      bestMatch = root;
    }
  }
  return bestMatch;
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

@visibleForTesting
Map<String, String> remoteCoverRequestHeadersForUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase();
  final isAsmrOne =
      host == 'api.asmr.one' ||
      host == 'api.asmr-100.com' ||
      host == 'api.asmr-200.com' ||
      host == 'api.asmr-300.com';
  return isAsmrOne
      ? const <String, String>{
          HttpHeaders.acceptLanguageHeader: _asmrOneAcceptLanguage,
        }
      : const <String, String>{};
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
