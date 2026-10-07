import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../core/media/music_track.dart';
import '../../../core/state/audio_state_slice.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/media_file_support.dart';
import '../domain/library_persistence_repository.dart';
import 'audio_detail_cache_service.dart';
import 'cover_artwork_store.dart';
import 'remote_cover_cache.dart';
export 'remote_cover_cache.dart'
    show
        remoteCoverSearchKey,
        normalizeRemoteCoverUrl,
        normalizedRemoteUrlFromKey;
export 'remote_cover_downloader.dart' show remoteCoverRequestHeadersForUrl;
import 'library_organizer.dart';
import 'library_service.dart';
import 'cover_artwork_source_resolver.dart';
import '../data/audio_detail_cover_store.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/media/path_matcher.dart';

const String _folderCoverSelectionsKey = 'folder_cover_selections_v1';
int get _resolvedTrackCoverLimit =>
    defaultTargetPlatform == TargetPlatform.windows ? 1200 : 600;
int get _resolvedFolderCoverLimit =>
    defaultTargetPlatform == TargetPlatform.windows ? 1200 : 300;
const int _manualCoverValidityLimit = 1200;

Map<String, T> _coverKeyMap<T>() => LinkedHashMap<String, T>(
  equals: (a, b) => _coverIdentity(a) == _coverIdentity(b),
  hashCode: (value) => _coverIdentity(value).hashCode,
);

String _coverIdentity(String value) => value.startsWith('remote-cover:')
    ? _normalizeCoverCacheKey(value)
    : PathMatcher.equivalenceKey(value);

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
    void Function(List<MusicTrack> tracks)? persistRetargetedManualCovers,
  }) : _libraryService = libraryService,
       _databaseRepository = databaseRepository,
       _audioDetailCacheService = audioDetailCacheService,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _artworkStore =
           artworkStore ??
           CoverArtworkStore(
             persistentDirectory: persistentDirectory,
             temporaryDirectory: temporaryDirectory,
           ),
       _isActiveCoverKey = isActiveCoverKey,
       _onActiveCoverChanged = onActiveCoverChanged,
       _preferEmbeddedCover = preferEmbeddedCover,
       _persistRetargetedManualCovers = persistRetargetedManualCovers {
    _remoteCovers = RemoteCoverCache(
      requestTimeout: requestTimeout,
      downloadIdleTimeout: downloadIdleTimeout,
      artworkStore: _artworkStore,
      isClearingPersistentCache: () => _isClearingPersistentCache,
      download: remoteCoverDownloader,
      now: now,
      isActiveCoverKey: isActiveCoverKey,
      onActiveCoverChanged: onActiveCoverChanged,
      onCoverRepaired: _remoteCoverRepaired,
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
  late final RemoteCoverCache _remoteCovers;
  final CoverArtworkStore _artworkStore;
  late final CoverArtworkSourceResolver _sourceResolver;
  final bool Function(String coverSearchKey)? _isActiveCoverKey;
  final VoidCallback? _onActiveCoverChanged;
  final bool Function()? _preferEmbeddedCover;
  final void Function(List<MusicTrack> tracks)? _persistRetargetedManualCovers;

  final Map<String, Future<String?>> _folderCoverFutures = _coverKeyMap();
  final Map<String, String?> _resolvedFolderCovers = _coverKeyMap();
  final Map<String, Future<String?>> _resolvedFolderCoverFutures =
      _coverKeyMap();
  final Map<String, Future<String?>> _trackCoverFutures = _coverKeyMap();
  final Map<String, Future<String?>> _playbackTrackCoverFutures =
      _coverKeyMap();
  final Map<String, String?> _resolvedTrackCovers = _coverKeyMap();
  final Map<String, Future<String?>> _resolvedTrackCoverFutures =
      _coverKeyMap();
  final Map<String, bool> _manualCoverPathValidityCache = _coverKeyMap();
  final Map<String, Future<String?>> _manualCoverValidationFutures =
      _coverKeyMap();
  final Map<String, String> _folderCoverSelections = _coverKeyMap();
  final Map<String, int> _coverKeyRevisions = _coverKeyMap();
  Future<void>? _folderCoverSelectionsLoadFuture;
  int _generation = 0;
  int _cacheEpoch = 0;
  final Map<String, Future<void>> _artworkRepairs = _coverKeyMap();
  final _generationSlice = AudioStateSlice<int>(0);
  Stream<int> get generationChanges => _generationSlice.stream;
  bool _disposed = false;
  Future<int>? _clearPersistentCacheFuture;
  bool _isClearingPersistentCache = false;

  int get generation => _generation;

  ({int epoch, int revision}) revisionForScope(String scope) {
    final key = PathMatcher.isRemoteUri(scope)
        ? remoteCoverSearchKey(scope) ?? scope
        : _normalizeCoverCacheKey(scope);
    return (epoch: _cacheEpoch, revision: _coverKeyRevision(key));
  }

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
    await prepareManualCoversForCacheClear();
    _isClearingPersistentCache = true;
    final pending = <Future<String?>>{
      ..._trackCoverFutures.values,
      ..._folderCoverFutures.values,
      ..._remoteCovers.pending,
      ..._sourceResolver.pendingPlatformCovers,
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
    if (PathMatcher.isRemoteUri(trackPath ?? track?.path ?? '') &&
        track?.remoteCoverUrl != null) {
      return resolvedForRemoteCover(track!.remoteCoverUrl!);
    }
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
      final resolved = _readResolvedCover(
        _resolvedTrackCovers,
        PathMatcher.normalize(pathValue),
      );
      if (resolved != null) return resolved;
    }
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (coverSearchKey != null) {
      final resolved =
          _readResolvedCover(_resolvedTrackCovers, coverSearchKey) ??
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
    if (PathMatcher.isRemoteUri(trackPath ?? track?.path ?? '') &&
        track?.remoteCoverUrl != null) {
      return resolvedForRemoteCover(track!.remoteCoverUrl!);
    }
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
        _readResolvedCover(_resolvedFolderCovers, normalizedFolderPath) ??
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

  String? resolvedForRemoteCover(String url) => _remoteCovers.resolvedFor(url);

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
    if (PathMatcher.isRemoteUri(trackPath ?? track?.path ?? '') &&
        track?.remoteCoverUrl != null) {
      return futureForRemoteCover(track!.remoteCoverUrl!);
    }
    return cachedFutureForTrack(track, trackPath: trackPath) ??
        _resolveCoverPathForTrack(track, trackPath: trackPath);
  }

  // Display paths can be provisional; only completed lookups may bypass the
  // discovery queue (for example, a folder cover while extracting track art).
  Future<String?>? cachedFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    if (PathMatcher.isRemoteUri(trackPath ?? track?.path ?? '') &&
        track?.remoteCoverUrl != null) {
      return cachedFutureForRemoteCover(track!.remoteCoverUrl!);
    }
    final key = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (key == null || !_resolvedTrackCovers.containsKey(key)) return null;
    final warm = _readResolvedCover(_resolvedTrackCovers, key);
    // Explicit file bindings must still be validated after a previous miss.
    if (warm == null &&
        (track?.manualCoverPath != null || track?.coverCachePath != null)) {
      return null;
    }
    return _resolvedTrackCoverFutures.putIfAbsent(
      key,
      () => SynchronousFuture(warm),
    );
  }

  Future<String?> futureForPlaybackTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    if (PathMatcher.isRemoteUri(trackPath ?? track?.path ?? '') &&
        track?.remoteCoverUrl != null) {
      return futureForRemoteCover(track!.remoteCoverUrl!);
    }
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
    final requestGeneration = _cacheEpoch;
    final key = coverSearchKeyForTrack(track, trackPath: trackPath)!;
    final revision = _coverKeyRevision(key);
    bool isCurrent() => _isCoverKeyCurrent(
      key,
      generation: requestGeneration,
      revision: revision,
    );
    await _ensureFolderCoverSelections();
    if (!isCurrent()) {
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
      if (!isCurrent()) {
        return futureForPlaybackTrack(track, trackPath: trackPath);
      }
      if (folderCover != null) return folderCover;
      final trackCover = await futureForTrack(track, trackPath: trackPath);
      return isCurrent()
          ? trackCover
          : futureForPlaybackTrack(track, trackPath: trackPath);
    } else {
      final trackCover = await futureForTrack(track, trackPath: trackPath);
      if (!isCurrent()) {
        return futureForPlaybackTrack(track, trackPath: trackPath);
      }
      if (trackCover != null) return trackCover;
      final folderCover = await resolveFromFolder();
      return isCurrent()
          ? folderCover
          : futureForPlaybackTrack(track, trackPath: trackPath);
    }
  }

  Future<String?> futureForFolder(String folderPath) {
    return cachedFutureForFolder(folderPath) ??
        _resolveCoverPathForFolder(folderPath);
  }

  Future<String?>? cachedFutureForFolder(String folderPath) {
    final key = PathMatcher.normalize(folderPath);
    if (!_resolvedFolderCovers.containsKey(key)) return null;
    final warm = _readResolvedCover(_resolvedFolderCovers, key);
    return _resolvedFolderCoverFutures.putIfAbsent(
      key,
      () => SynchronousFuture(warm),
    );
  }

  Future<String?>? cachedFutureForRemoteCover(String url) =>
      _remoteCovers.cachedFutureFor(url);

  Future<String?> futureForRemoteCover(String url) =>
      _remoteCovers.resolve(url);

  void _remoteCoverRepaired(String key) {
    _resolvedTrackCovers.remove(key);
    _resolvedTrackCoverFutures.remove(key);
    _playbackTrackCoverFutures.remove(key);
    _advanceCoverKeyRevision(key);
    _generationSlice.update(++_generation);
  }

  /// A decode failure is the explicit signal to revalidate a warm binding.
  void reportArtworkReadFailure(String coverPath) {
    if (_disposed || _isClearingPersistentCache) return;
    _artworkRepairs.putIfAbsent(coverPath, () {
      final epoch = _cacheEpoch;
      late final Future<void> repair;
      repair =
          Future<void>.microtask(() async {
                if (_disposed ||
                    epoch != _cacheEpoch ||
                    _isClearingPersistentCache) {
                  return;
                }
                final folders = _resolvedFolderCovers.entries
                    .where(
                      (entry) => PathMatcher.equalsNormalized(
                        entry.value ?? '',
                        coverPath,
                      ),
                    )
                    .map((entry) => entry.key)
                    .toList();
                final tracks = _resolvedTrackCovers.entries
                    .where(
                      (entry) => PathMatcher.equalsNormalized(
                        entry.value ?? '',
                        coverPath,
                      ),
                    )
                    .map((entry) => entry.key)
                    .toList();
                final keys = _artworkStore
                    .logicalKeysForPath(coverPath)
                    .toList();
                await _artworkStore.discardUnreadableArtifact(
                  coverPath,
                  keys: keys,
                );
                if (_disposed ||
                    epoch != _cacheEpoch ||
                    _isClearingPersistentCache) {
                  return;
                }
                _manualCoverPathValidityCache.remove(coverPath);
                for (final folder in folders) {
                  invalidateFolder(folder);
                }
                for (final track in tracks) {
                  invalidateTrack(
                    _libraryService.trackByPath(track),
                    trackPath: track,
                  );
                }
                await _remoteCovers.reportArtworkReadFailure(
                  coverPath,
                  keys: keys,
                );
              })
              .catchError((Object error, StackTrace trace) {
                AppLogService.warning(
                  'cover_artwork_read_repair_failed',
                  error: error,
                  stackTrace: trace,
                );
              })
              .whenComplete(() {
                if (identical(_artworkRepairs[coverPath], repair)) {
                  _artworkRepairs.remove(coverPath);
                }
              });
      return repair;
    });
  }

  /// User selections are authored data, even when their image originated in cache.
  Future<void> prepareManualCoversForCacheClear() async {
    await initialize();
    final root = _artworkStore.rootPath;
    if (root == null) {
      throw StateError('Cover storage unavailable for cache clear.');
    }
    final portable = Directory(
      path.join(Directory(root).parent.path, 'portable_card_covers'),
    );
    final coverStore = AudioDetailCoverStore(
      portableDirectory: () async => portable,
    );
    Future<String> preserve(AudioDetailTarget target, String value) async {
      final source = _artworkStore.resolveStoredPath(value) ?? value;
      if (!await _artworkStore.isRebuildablePath(source)) return value;
      final original = AudioDetail.empty(
        target,
      ).copyWith(cardCoverPath: source, cardCoverSelected: true);
      final fields = await coverStore.documentFields(original);
      final restored = await coverStore.restore(
        AudioDetail.empty(target),
        fields,
      );
      final saved = restored.cardCoverPath;
      if (saved == null || await _artworkStore.isRebuildablePath(saved)) {
        throw StateError('Unable to preserve selected cover: $source');
      }
      return saved;
    }

    final folders = <String>{
      ..._folderCoverSelections.keys,
      ..._libraryService.watchedFolders,
      ..._libraryService.watchedLibraries,
    };
    for (final folder in folders) {
      final target = AudioDetailTarget.libraryRootFolder(folder);
      final stored = await _audioDetailCacheService?.loadCardCoverSelection(
        target,
      );
      final source =
          _folderCoverSelections[folder] ??
          (stored?.selected == true ? stored?.path : null);
      if (source == null) continue;
      final saved = await preserve(target, source);
      if (saved == source) continue;
      // Persist authored data before any reconstructible directory is removed.
      await _audioDetailCacheService?.saveCardCoverPath(
        target,
        saved,
        selected: true,
        writeDocument: true,
      );
      _folderCoverSelections[folder] = saved;
    }
    final tracks = <MusicTrack>[];
    for (final track in _libraryService.library.where(
      (track) => track.isSingle,
    )) {
      final target = AudioDetailTarget.singleAudioFile(track.path);
      final stored = await _audioDetailCacheService?.loadCardCoverSelection(
        target,
      );
      if (stored?.selected == true && stored?.path != null) {
        final saved = await preserve(target, stored!.path!);
        if (saved != stored.path) {
          await _audioDetailCacheService?.saveCardCoverPath(
            target,
            saved,
            selected: true,
            writeDocument: true,
          );
        }
      }
      final source = track.manualCoverPath;
      if (source == null) continue;
      final saved = await preserve(target, source);
      if (saved != source) tracks.add(track.copyWith(manualCoverPath: saved));
    }
    if (tracks.isNotEmpty) {
      final persist = _persistRetargetedManualCovers;
      if (persist == null) {
        throw StateError('Manual cover retargeting is not attached.');
      }
      persist(tracks);
    }
    await _saveFolderCoverSelections();
  }

  bool isLoadingForFolder(String folderPath) {
    return _folderCoverFutures.containsKey(PathMatcher.normalize(folderPath));
  }

  String? coverScopeFolderForTrack(MusicTrack? track, {String? trackPath}) =>
      _sourceResolver.coverScopeFolderForTrack(track, trackPath: trackPath);

  String? _playbackFallbackFolderScopeForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    if (track == null) return null;
    final pathValue = trackPath ?? track.path;
    if (pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) return null;

    final candidateScopes = _sourceResolver.candidateFolderScopesForTrack(
      track,
      trackPath: trackPath,
    );
    for (final scope in candidateScopes) {
      if (_folderCoverSelections.containsKey(scope)) {
        return scope;
      }
    }

    if (_isVideoTrack(track, trackPath: trackPath) ||
        isStandaloneCoverAudioTrack(track, trackPath: trackPath)) {
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

  Future<List<CoverImageReference>> discoverCoverImageReferencesInFolder(
    String folderPath, {
    bool refresh = false,
  }) {
    if (refresh) {
      _sourceResolver.invalidateFolderImageIndexes(
        PathMatcher.normalize(folderPath),
      );
    }
    return _sourceResolver.discoverFolderImageReferences(
      folderPath,
      propagateFailure: true,
    );
  }

  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
    bool includeVideoFrames = true,
    bool includeEmbeddedCovers = true,
    bool propagateFailure = false,
  }) async {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (normalizedFolder.isEmpty) return const <String>[];
    final candidates = await _sourceResolver.resolveFolderCoverCandidates(
      normalizedFolder,
      includeVideoFrames: includeVideoFrames,
      includeEmbeddedCovers: includeEmbeddedCovers,
      propagateFailure: propagateFailure,
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
    final selectionGeneration = _cacheEpoch;
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
    var effectiveCoverPath = hasDurableSource
        ? normalizedCover
        : storedCoverPath ?? normalizedCover;
    if (hasDurableSource &&
        !PathMatcher.equalsNormalized(
          _persistedFolderCoverPath(normalizedCover),
          normalizedCover,
        )) {
      effectiveCoverPath = await _sourceResolver.persistBridgeCover(
        logicalKey:
            'selected-image:${PathMatcher.equivalenceKey(normalizedFolder)}',
        sourcePath: normalizedCover,
        namespace: CoverArtworkNamespace.embedded,
      );
      _sourceResolver.rememberFolderImageSource(
        effectiveCoverPath,
        _persistedFolderCoverPath(normalizedCover),
      );
    }
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
    final nextSelections = _coverKeyMap<String>();
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

  void invalidateCatalogTracks(Iterable<MusicTrack> tracks) {
    final scopes = <String>{};
    final scopesByGroup = <String, String?>{};
    for (final track in tracks) {
      final key = coverSearchKeyForTrack(track);
      final scope = track.groupKey.isEmpty
          ? coverScopeFolderForTrack(track)
          : scopesByGroup.putIfAbsent(
              track.groupKey,
              () => coverScopeFolderForTrack(track),
            );
      if (scope != null) scopes.add(scope);
      if (key != null &&
          (scope == null || !PathMatcher.isWithinOrEqual(key, scope))) {
        scopes.add(key);
      }
    }
    if (scopes.isNotEmpty) invalidateFolders(scopes);
  }

  void invalidateFolder(String? scope) {
    if (scope == null || scope.isEmpty) {
      invalidateAll();
      return;
    }
    invalidateFolders([scope], clearRemoteFailure: false);
  }

  void invalidateFolders(
    Iterable<String?> scopes, {
    bool clearRemoteFailure = true,
  }) {
    final normalizedScopes = scopes
        .whereType<String>()
        .map(_normalizeCoverCacheKey)
        .where((scope) => scope.isNotEmpty)
        .toSet();
    if (normalizedScopes.isEmpty) {
      invalidateAll();
      return;
    }
    final identities = normalizedScopes.map(_coverIdentity).toSet();
    bool affected(String key) =>
        _isCoverIdentityInScopes(_coverIdentity(key), identities);

    // Scan the catalog once, rather than once for every imported track/scope.
    final storeKeys = <String>{...normalizedScopes.map(_folderStoreKey)};
    for (final track in _libraryService.library) {
      if (!affected(track.path) &&
          (track.groupKey.isEmpty || !affected(track.groupKey))) {
        continue;
      }
      final key = coverSearchKeyForTrack(track);
      if (key != null) storeKeys.add(_trackStoreKey(key, track));
    }
    unawaited(_artworkStore.invalidate(storeKeys));

    final cachedKeys = <String>{
      ...normalizedScopes,
      ..._folderCoverFutures.keys,
      ..._resolvedFolderCovers.keys,
      ..._resolvedFolderCoverFutures.keys,
      ..._playbackTrackCoverFutures.keys,
      ..._trackCoverFutures.keys,
      ..._resolvedTrackCovers.keys,
      ..._resolvedTrackCoverFutures.keys,
    };
    for (final key in cachedKeys) {
      if (affected(key)) _advanceCoverKeyRevision(key);
    }
    final selectedCovers = <String>{
      for (final scope in normalizedScopes)
        if (_folderCoverSelections[scope] case final String selected)
          _coverIdentity(selected),
    };
    bool manualAffected(String key) =>
        affected(key) || selectedCovers.contains(_coverIdentity(key));
    _manualCoverPathValidityCache.removeWhere((key, _) => manualAffected(key));
    _manualCoverValidationFutures.removeWhere((key, _) => manualAffected(key));
    _folderCoverFutures.removeWhere((key, _) => affected(key));
    _resolvedFolderCovers.removeWhere((key, _) => affected(key));
    _resolvedFolderCoverFutures.removeWhere((key, _) => affected(key));
    _trackCoverFutures.removeWhere((key, _) => affected(key));
    _resolvedTrackCovers.removeWhere((key, _) => affected(key));
    _resolvedTrackCoverFutures.removeWhere((key, _) => affected(key));
    _playbackTrackCoverFutures.removeWhere((key, _) => affected(key));
    for (final scope in normalizedScopes) {
      _sourceResolver.invalidateFolderImageIndexes(scope);
      _remoteCovers.invalidate(scope, clearFailure: clearRemoteFailure);
    }
    _generationSlice.update(++_generation);
  }

  void invalidateAll() {
    _cacheEpoch++;
    _artworkRepairs.clear();
    _generation++;
    _generationSlice.update(_generation);
    _coverKeyRevisions.clear();
    _sourceResolver.invalidateAll();
    _folderCoverFutures.clear();
    _resolvedFolderCovers.clear();
    _resolvedFolderCoverFutures.clear();
    _playbackTrackCoverFutures.clear();
    _trackCoverFutures.clear();
    _resolvedTrackCovers.clear();
    _resolvedTrackCoverFutures.clear();
    _remoteCovers.invalidateAll();
    _manualCoverPathValidityCache.clear();
    _manualCoverValidationFutures.clear();
  }

  int _coverKeyRevision(String key) => _coverKeyRevisions[key] ?? 0;

  void _advanceCoverKeyRevision(String key) {
    _coverKeyRevisions[key] = _coverKeyRevision(key) + 1;
  }

  bool _isCoverKeyCurrent(
    String key, {
    required int generation,
    required int revision,
  }) {
    return !_disposed &&
        generation == _cacheEpoch &&
        revision == _coverKeyRevision(key);
  }

  String? _readResolvedCover(Map<String, String?> cache, String key) {
    if (!cache.containsKey(key)) return null;
    final value = cache.remove(key);
    cache[key] = value;
    return value;
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
    _remoteCovers.trimMemory();
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
    final requestGeneration = _cacheEpoch;
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: pathValue);
    if (coverSearchKey == null) return Future<String?>.value();
    final requestRevision = _coverKeyRevision(coverSearchKey);
    bool isCurrent() => _isCoverKeyCurrent(
      coverSearchKey,
      generation: requestGeneration,
      revision: requestRevision,
    );

    final preferEmbeddedCover = _preferTrackEmbeddedCover(
      track,
      trackPath: pathValue,
    );
    if (!preferEmbeddedCover) {
      final folderCoverPath = await _explicitFolderCoverFutureForTrack(
        track,
        trackPath: pathValue,
      );
      if (!isCurrent()) {
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

    final storeKey = _trackStoreKey(coverSearchKey, track);
    final previousStoredPath = _artworkStore.resolvedPath(storeKey);
    final storedTrackPath = await _artworkStore.validatedPath(storeKey);
    if (!isCurrent()) {
      return resolvedForTrack(track, trackPath: trackPath);
    }
    if (storedTrackPath != null) {
      _resolvedTrackCovers[coverSearchKey] = storedTrackPath;
      final storedFuture = SynchronousFuture<String?>(storedTrackPath);
      _resolvedTrackCoverFutures[coverSearchKey] = storedFuture;
      return storedFuture;
    }
    if (previousStoredPath != null &&
        _resolvedTrackCovers[coverSearchKey] == previousStoredPath) {
      _resolvedTrackCovers.remove(coverSearchKey);
      unawaited(_resolvedTrackCoverFutures.remove(coverSearchKey));
    }

    final manualPathFuture = track?.isSingle == true
        ? _validatedManualCoverPath(track?.manualCoverPath)
        : SynchronousFuture<String?>(null);
    final coverCachePathFuture = _validatedManualCoverPath(
      track?.coverCachePath,
    );
    return _trackCoverFutures.putIfAbsent(coverSearchKey, () async {
      final manualPath = await manualPathFuture;
      if (!isCurrent()) {
        return resolvedForTrack(track, trackPath: trackPath);
      }
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
      if (!isCurrent()) {
        return resolvedForTrack(track, trackPath: trackPath);
      }
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

      final cachedPath = _resolvedTrackCovers[coverSearchKey];
      if (cachedPath != null &&
          (cachedPath ==
                  _artworkStore.resolveStoredPath(track?.manualCoverPath) ||
              cachedPath ==
                  _artworkStore.resolveStoredPath(track?.coverCachePath))) {
        _resolvedTrackCovers.remove(coverSearchKey);
        unawaited(_resolvedTrackCoverFutures.remove(coverSearchKey));
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
      if (!isCurrent() || _disposed) {
        return resolvedForTrack(track, trackPath: trackPath);
      }
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

      if (!isCurrent()) {
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
    final candidateScopes = _sourceResolver.candidateFolderScopesForTrack(
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
    final candidateScopes = _sourceResolver.candidateFolderScopesForTrack(
      track,
      trackPath: trackPath,
    );
    for (final normalizedFolderScope in candidateScopes) {
      var requestGeneration = _cacheEpoch;
      var requestRevision = _coverKeyRevision(normalizedFolderScope);
      bool isCurrent() => _isCoverKeyCurrent(
        normalizedFolderScope,
        generation: requestGeneration,
        revision: requestRevision,
      );
      var selectedCover = _folderCoverSelections[normalizedFolderScope];
      var selectedCoverPath = await _displayPathForStoredCover(
        AudioDetailTarget.libraryRootFolder(normalizedFolderScope),
        selectedCover,
      );
      if (!isCurrent()) return resolvedForTrack(track, trackPath: trackPath);
      if (selectedCover != null && selectedCoverPath == null) {
        _folderCoverSelections.remove(normalizedFolderScope);
        await _saveFolderCoverSelections();
        if (!isCurrent()) return resolvedForTrack(track, trackPath: trackPath);
        invalidateFolder(normalizedFolderScope);
        requestGeneration = _cacheEpoch;
        requestRevision = _coverKeyRevision(normalizedFolderScope);
        selectedCover = null;
      }
      if (selectedCoverPath == null) {
        final persistedCover = await _loadValidFolderCardCover(
          normalizedFolderScope,
        );
        if (!isCurrent()) return resolvedForTrack(track, trackPath: trackPath);
        if (persistedCover.selected) {
          selectedCover = persistedCover.path;
          if (selectedCover != null) {
            selectedCoverPath = selectedCover;
            _folderCoverSelections[normalizedFolderScope] =
                _persistedFolderCoverPath(selectedCover);
            await _saveFolderCoverSelections();
            if (!isCurrent()) {
              return resolvedForTrack(track, trackPath: trackPath);
            }
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
        if (!isCurrent()) return resolvedForTrack(track, trackPath: trackPath);
        return selectedCoverPath;
      }
    }
    return null;
  }

  Future<String?> _resolveCoverPathForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);

    final inFlight = _folderCoverFutures[normalizedFolderPath];
    if (inFlight != null) return inFlight;
    final requestGeneration = _cacheEpoch;
    final requestRevision = _coverKeyRevision(normalizedFolderPath);
    late final Future<String?> lookup;
    lookup = () async {
      final storedFolderPath = await _artworkStore.validatedPath(
        _folderStoreKey(normalizedFolderPath),
      );
      if (!_isFolderLookupCurrent(
        normalizedFolderPath,
        requestGeneration,
        requestRevision,
        lookup,
      )) {
        return _resolvedFolderCovers[normalizedFolderPath];
      }
      if (storedFolderPath != null) {
        _resolvedFolderCovers[normalizedFolderPath] = storedFolderPath;
        _resolvedFolderCoverFutures[normalizedFolderPath] =
            SynchronousFuture<String?>(storedFolderPath);
        _trimResolvedFolderCovers();
        return storedFolderPath;
      }
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
    if (track == null || !isStandaloneCoverAudioTrack(track)) return null;
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

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _remoteCovers.dispose();
    await _generationSlice.dispose();
  }

  String? _cachedManualCoverPath(String? coverPath) {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return null;
    final stored = _artworkStore.resolveStoredPath(value);
    if (stored != null && _manualCoverPathValidityCache[stored] == true) {
      return stored;
    }
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return value;
    }
    return _manualCoverPathValidityCache[value] == true ? value : null;
  }

  Future<String?> _validatedManualCoverPath(String? coverPath) {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return SynchronousFuture<String?>(null);
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return SynchronousFuture<String?>(value);
    }
    final inFlight = _manualCoverValidationFutures[value];
    if (inFlight != null) return inFlight;
    late final Future<String?> validation;
    validation = () async {
      final requestGeneration = _cacheEpoch;
      final stored = _artworkStore.resolveStoredPath(value) ?? value;
      try {
        final stat = await File(stored).stat();
        final usable = stat.type == FileSystemEntityType.file && stat.size > 0;
        if (requestGeneration != _cacheEpoch ||
            _disposed ||
            !identical(_manualCoverValidationFutures[value], validation)) {
          return null;
        }
        _manualCoverPathValidityCache[stored] = usable;
        _trimManualCoverValidityCache();
        return usable ? stored : null;
      } finally {
        if (identical(_manualCoverValidationFutures[value], validation)) {
          unawaited(_manualCoverValidationFutures.remove(value));
        }
      }
    }();
    _manualCoverValidationFutures[value] = validation;
    return validation;
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

String _normalizeCoverCacheKey(String value) {
  if (!value.startsWith('remote-cover:')) return PathMatcher.normalize(value);
  return remoteCoverSearchKey(normalizedRemoteUrlFromKey(value)) ?? value;
}

// Equivalence keys retain path separators and canonicalize SAF aliases/Windows
// case. Ancestor lookups cost path depth, independently of the number of scopes.
bool _isCoverIdentityInScopes(String identity, Set<String> scopes) {
  if (scopes.contains(identity)) return true;
  if (identity.startsWith('remote-cover:') || identity.startsWith('remote:')) {
    return false;
  }
  for (
    var at = identity.lastIndexOf('/');
    at >= 0;
    at = identity.lastIndexOf('/', at - 1)
  ) {
    final parent = identity.substring(0, at);
    if (scopes.contains(parent) || scopes.contains('$parent/')) return true;
    if (at == 0) break;
  }
  return false;
}
