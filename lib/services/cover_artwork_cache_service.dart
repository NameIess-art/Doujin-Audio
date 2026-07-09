import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/music_track.dart';
import '../models/audio_detail.dart';
import '../platform/app_platform.dart';
import 'app_cache_service.dart';
import 'app_log_service.dart';
import 'audio_database_repository.dart';
import 'audio_detail_cache_service.dart';
import 'audio_state_services.dart';
import 'embedded_cover_artwork_service.dart';
import 'file_cache_platform_gateway.dart';
import 'path_matcher.dart';
import 'windows_ffmpeg_service.dart';

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

class CoverArtworkCacheService {
  CoverArtworkCacheService({
    required LibraryService libraryService,
    AudioDatabaseRepository? databaseRepository,
    AudioDetailCacheService? audioDetailCacheService,
    FileCachePlatformGateway? fileCacheGateway,
    Future<String?> Function(String remoteUrl)? remoteCoverDownloader,
    bool Function(String coverSearchKey)? isActiveCoverKey,
    VoidCallback? onActiveCoverChanged,
  }) : _libraryService = libraryService,
       _databaseRepository = databaseRepository,
       _audioDetailCacheService = audioDetailCacheService,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _remoteCoverDownloader = remoteCoverDownloader,
       _isActiveCoverKey = isActiveCoverKey,
       _onActiveCoverChanged = onActiveCoverChanged;

  final LibraryService _libraryService;
  final AudioDatabaseRepository? _databaseRepository;
  final AudioDetailCacheService? _audioDetailCacheService;
  final FileCachePlatformGateway _fileCacheGateway;
  final Future<String?> Function(String remoteUrl)? _remoteCoverDownloader;
  final bool Function(String coverSearchKey)? _isActiveCoverKey;
  final VoidCallback? _onActiveCoverChanged;

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
  final Map<String, bool> _manualCoverPathValidityCache = <String, bool>{};
  final Map<String, Future<String?>> _manualCoverValidationFutures =
      <String, Future<String?>>{};
  final Map<String, String> _folderCoverSelections = <String, String>{};
  Future<void>? _folderCoverSelectionsLoadFuture;
  int _generation = 0;

  int get generation => _generation;

  @visibleForTesting
  int get manualCoverPathValidityCacheSize =>
      _manualCoverPathValidityCache.length;

  String? resolvedForTrack(MusicTrack? track, {String? trackPath}) {
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
    final pathValue = track?.path ?? trackPath;
    if (pathValue != null &&
        pathValue.isNotEmpty &&
        !PathMatcher.isRemoteUri(pathValue)) {
      return _resolvedTrackCovers[PathMatcher.normalize(pathValue)];
    }
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (coverSearchKey == null) return null;
    return _resolvedTrackCovers[coverSearchKey];
  }

  String? resolvedForPlaybackTrack(MusicTrack? track, {String? trackPath}) {
    final trackCoverPath = resolvedForTrack(track, trackPath: trackPath);
    if (trackCoverPath != null) return trackCoverPath;
    final folderScope = _playbackFallbackFolderScopeForTrack(
      track,
      trackPath: trackPath,
    );
    if (folderScope == null) return null;
    return resolvedForFolder(folderScope);
  }

  String? resolvedForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    return _resolvedFolderCovers[normalizedFolderPath];
  }

  String? resolvedForRemoteCover(String url) {
    final remoteKey = remoteCoverSearchKey(url);
    if (remoteKey == null) return null;
    return _resolvedRemoteCovers[remoteKey];
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

    return _playbackTrackCoverFutures.putIfAbsent(coverSearchKey, () {
      final future = _resolvePlaybackCoverPathForTrack(
        track,
        trackPath: trackPath,
      );
      unawaited(
        future.then(
          (coverPath) {
            if (coverPath == null &&
                identical(_playbackTrackCoverFutures[coverSearchKey], future)) {
              _playbackTrackCoverFutures.remove(coverSearchKey);
            }
          },
          onError: (Object _) {
            if (identical(_playbackTrackCoverFutures[coverSearchKey], future)) {
              _playbackTrackCoverFutures.remove(coverSearchKey);
            }
          },
        ),
      );
      return future;
    });
  }

  Future<String?> _resolvePlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) async {
    final trackCoverPath = await futureForTrack(track, trackPath: trackPath);
    if (trackCoverPath != null) return trackCoverPath;
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
    if (folderCoverPath != null && previousPlaybackCover != folderCoverPath) {
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

  Future<String?> futureForFolder(String folderPath) {
    return _resolveCoverPathForFolder(folderPath);
  }

  Future<String?> futureForRemoteCover(String url) {
    final remoteKey = remoteCoverSearchKey(url);
    if (remoteKey == null) return Future<String?>.value();
    return _resolveRemoteCover(
      remoteKey,
      normalizedRemoteUrlFromKey(remoteKey),
    );
  }

  bool isLoadingForFolder(String folderPath) {
    return _folderCoverFutures.containsKey(PathMatcher.normalize(folderPath));
  }

  String? coverScopeFolderForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = track?.path ?? trackPath;
    if (pathValue == null || pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) return null;
    if (_isStandaloneAudioTrack(track)) return null;

    final groupKey = track?.groupKey.trim() ?? '';
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
          : _libraryWorkScopeFolderPath(watchedLibrary, groupKey);
      return workScope ?? watchedLibrary;
    }

    if (groupKey.isNotEmpty) return PathMatcher.normalize(groupKey);
    if (PathMatcher.isContentUri(pathValue)) return null;

    final directoryPath = path.dirname(pathValue);
    if (directoryPath.isEmpty || directoryPath == '.') return null;
    return directoryPath;
  }

  String? _playbackFallbackFolderScopeForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    if (track == null) return null;
    final pathValue = track.path;
    if (pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) return null;
    if (track.isVideo || _isStandaloneAudioTrack(track)) return null;
    return coverScopeFolderForTrack(track, trackPath: trackPath);
  }

  String? coverSearchKeyForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = track?.path ?? trackPath;
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
    String folderPath,
  ) async {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (normalizedFolder.isEmpty) return const <String>[];
    return _resolveFolderCoverCandidates(normalizedFolder);
  }

  Future<void> setFolderCoverSelection(
    String folderPath,
    String coverPath, {
    bool newlySaved = false,
  }) async {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final normalizedCover = coverPath.trim();
    if (normalizedFolder.isEmpty || normalizedCover.isEmpty) return;
    if (!newlySaved) {
      final candidates = await _resolveFolderCoverCandidates(normalizedFolder);
      if (!candidates.contains(normalizedCover)) return;
    }
    await _ensureFolderCoverSelections();
    _folderCoverSelections[normalizedFolder] = normalizedCover;
    await _saveFolderCoverSelections();
    await _saveCardCoverPath(
      AudioDetailTarget.libraryRootFolder(normalizedFolder),
      normalizedCover,
    );
    invalidateFolder(normalizedFolder);
    _resolvedFolderCovers[normalizedFolder] = normalizedCover;
    _resolvedFolderCoverFutures[normalizedFolder] = SynchronousFuture<String?>(
      normalizedCover,
    );
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
    invalidateFolder(coverSearchKeyForTrack(track, trackPath: trackPath));
  }

  void invalidateFolder(String? scope) {
    if (scope == null || scope.isEmpty) {
      invalidateAll();
      return;
    }
    final normalizedScope = _normalizeCoverCacheKey(scope);
    _generation++;
    _folderCoverFutures.remove(normalizedScope);
    _resolvedFolderCovers.remove(normalizedScope);
    _resolvedFolderCoverFutures.remove(normalizedScope);
    _playbackTrackCoverFutures.clear();
    _trackCoverFutures.remove(normalizedScope);
    _resolvedTrackCovers.remove(normalizedScope);
    _resolvedTrackCoverFutures.remove(normalizedScope);
    _remoteCoverFutures.remove(normalizedScope);
    _resolvedRemoteCovers.remove(normalizedScope);
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
    _manualCoverPathValidityCache.clear();
    _manualCoverValidationFutures.clear();
    _playbackTrackCoverFutures.clear();
    for (final scope in normalizedScopes) {
      _folderCoverFutures.remove(scope);
      _resolvedFolderCovers.remove(scope);
      _resolvedFolderCoverFutures.remove(scope);
      _trackCoverFutures.remove(scope);
      _resolvedTrackCovers.remove(scope);
      _resolvedTrackCoverFutures.remove(scope);
      _remoteCoverFutures.remove(scope);
      _resolvedRemoteCovers.remove(scope);
    }
  }

  void invalidateAll() {
    _generation++;
    _folderCoverFutures.clear();
    _resolvedFolderCovers.clear();
    _resolvedFolderCoverFutures.clear();
    _playbackTrackCoverFutures.clear();
    _trackCoverFutures.clear();
    _resolvedTrackCovers.clear();
    _resolvedTrackCoverFutures.clear();
    _remoteCoverFutures.clear();
    _resolvedRemoteCovers.clear();
    _manualCoverPathValidityCache.clear();
    _manualCoverValidationFutures.clear();
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
    _trimResolvedCache(_resolvedRemoteCovers, _resolvedRemoteCoverLimit);
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
  }) {
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: pathValue);
    if (coverSearchKey == null) return Future<String?>.value();
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
          : await _loadValidCardCoverPath(cardCoverTarget);
      if (persistedCardCover != null) {
        final removedTrackFuture = _trackCoverFutures.remove(coverSearchKey);
        if (removedTrackFuture != null) unawaited(removedTrackFuture);
        _resolvedTrackCovers[coverSearchKey] = persistedCardCover;
        _resolvedTrackCoverFutures[coverSearchKey] = SynchronousFuture<String?>(
          persistedCardCover,
        );
        _trimResolvedTrackCovers();
        return persistedCardCover;
      }

      String? coverPath;
      final remoteCoverUrl = track?.remoteCoverUrl?.trim();
      if (remoteCoverUrl != null && remoteCoverUrl.isNotEmpty) {
        coverPath = await futureForRemoteCover(remoteCoverUrl);
      }
      if (coverPath == null &&
          pathValue != null &&
          !PathMatcher.isRemoteUri(pathValue)) {
        if (track?.isVideo == true) {
          coverPath = await _resolveVideoFramePathForTrack(track!);
        } else if (track != null) {
          coverPath = await _resolvePlatformCoverPathForTrack(
            track,
            rootFolder: coverScopeFolderForTrack(track, trackPath: pathValue),
          );
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

  Future<String?> _resolveCoverPathForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);

    if (_resolvedFolderCovers.containsKey(normalizedFolderPath)) {
      return _resolvedFolderCoverFutures.putIfAbsent(
        normalizedFolderPath,
        () => SynchronousFuture<String?>(
          _resolvedFolderCovers[normalizedFolderPath],
        ),
      );
    }

    return _folderCoverFutures.putIfAbsent(normalizedFolderPath, () async {
      await _ensureFolderCoverSelections();
      final target = AudioDetailTarget.libraryRootFolder(normalizedFolderPath);
      final selectedCover = _folderCoverSelections[normalizedFolderPath];
      final selectedCoverPath = await _validatedManualCoverPath(selectedCover);
      final persistedCoverPath = selectedCoverPath == null
          ? await _loadValidCardCoverPath(target)
          : null;
      final indexedCoverPath = selectedCoverPath ?? persistedCoverPath;
      if (indexedCoverPath != null) {
        if (selectedCover != null && selectedCoverPath == null) {
          _folderCoverSelections.remove(normalizedFolderPath);
          await _saveFolderCoverSelections();
        }
        await _saveCardCoverPath(target, indexedCoverPath);
        final removedFolderFuture = _folderCoverFutures.remove(
          normalizedFolderPath,
        );
        if (removedFolderFuture != null) unawaited(removedFolderFuture);
        _resolvedFolderCovers[normalizedFolderPath] = indexedCoverPath;
        _resolvedFolderCoverFutures[normalizedFolderPath] =
            SynchronousFuture<String?>(indexedCoverPath);
        _trimResolvedFolderCovers();
        return indexedCoverPath;
      }
      final candidates = await _resolveFolderCoverCandidates(
        normalizedFolderPath,
      );
      final coverPath =
          selectedCover != null && candidates.contains(selectedCover)
          ? selectedCover
          : candidates.firstOrNull;
      if (selectedCover != null && selectedCover != coverPath) {
        _folderCoverSelections.remove(normalizedFolderPath);
        await _saveFolderCoverSelections();
      }
      unawaited(
        _folderCoverFutures.remove(normalizedFolderPath) ?? Future.value(),
      );

      _resolvedFolderCovers[normalizedFolderPath] = coverPath;
      _resolvedFolderCoverFutures[normalizedFolderPath] =
          SynchronousFuture<String?>(coverPath);
      _trimResolvedFolderCovers();
      await _saveCardCoverPath(target, coverPath);

      return coverPath;
    });
  }

  AudioDetailTarget? _cardCoverTargetForTrack(MusicTrack? track) {
    if (track == null || !_isStandaloneAudioTrack(track)) return null;
    return AudioDetailTarget.singleAudioFile(track.path);
  }

  Future<void> _saveTrackCardCoverPath(
    MusicTrack? track,
    String coverPath,
  ) async {
    final target = _cardCoverTargetForTrack(track);
    if (target != null) await _saveCardCoverPath(target, coverPath);
  }

  Future<String?> _loadValidCardCoverPath(AudioDetailTarget target) async {
    try {
      final storedPath = await _audioDetailCacheService?.loadCardCoverPath(
        target,
      );
      return _validatedManualCoverPath(storedPath);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to load card cover path.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> _saveCardCoverPath(
    AudioDetailTarget target,
    String? coverPath,
  ) async {
    try {
      await _audioDetailCacheService?.saveCardCoverPath(target, coverPath);
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to save card cover path.',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<String?> _resolveRemoteCover(String remoteKey, String remoteUrl) {
    return _remoteCoverFutures.putIfAbsent(remoteKey, () async {
      try {
        final previous = _resolvedRemoteCovers[remoteKey];
        var coverPath = previous;
        if (coverPath == null || !await _isUsableRemoteCoverPath(coverPath)) {
          _resolvedRemoteCovers.remove(remoteKey);
          final downloader = _remoteCoverDownloader;
          coverPath = await (downloader == null
              ? _downloadRemoteCover(remoteUrl)
              : downloader(remoteUrl));
        }

        if (coverPath == null) {
          _resolvedRemoteCovers.remove(remoteKey);
        } else {
          _resolvedRemoteCovers.remove(remoteKey);
          _resolvedRemoteCovers[remoteKey] = coverPath;
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

  Future<bool> _isUsableRemoteCoverPath(String? coverPath) async {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return false;
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return true;
    }
    try {
      final file = File(value);
      if (!await file.exists() || await file.length() <= 0) return false;
      await file.setLastModified(DateTime.now());
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _downloadRemoteCover(String remoteUrl) async {
    HttpClient? client;
    try {
      final cacheRoot = await getTemporaryDirectory();
      final coverDirectory = Directory(
        path.join(cacheRoot.path, 'notification_covers'),
      );
      await coverDirectory.create(recursive: true);
      final file = File(
        path.join(
          coverDirectory.path,
          '${_remoteCoverFileStem(remoteUrl)}.image',
        ),
      );
      if (await file.exists() && await file.length() > 0) {
        await file.setLastModified(DateTime.now());
        return file.path;
      }

      client = HttpClient();
      final request = await client.getUrl(Uri.parse(remoteUrl));
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final bytes = await consolidateHttpClientResponseBytes(response);
      if (bytes.isEmpty) return null;
      await file.writeAsBytes(bytes, flush: true);
      unawaited(AppCacheService.enforceLimit());
      return file.path;
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to cache remote notification cover.',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  Future<String?> _resolveVideoFramePathForTrack(MusicTrack track) async {
    try {
      final nativeFrame = await _fileCacheGateway.resolveVideoFrame(
        path: track.path,
        modifiedAtMs: track.modifiedAt?.millisecondsSinceEpoch,
      );
      if (nativeFrame != null && nativeFrame.isNotEmpty) return nativeFrame;
    } on MissingPluginException {
      // Windows generates the frame through its bundled FFmpeg below.
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolveVideoFramePathForTrack error',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (!AppPlatform.isWindows) return null;
    final framePath = await WindowsFfmpegService.resolveVideoFrame(
      videoPath: track.path,
      modifiedAtMs: track.modifiedAt?.millisecondsSinceEpoch,
    );
    if (framePath != null) unawaited(AppCacheService.enforceLimit());
    return framePath;
  }

  String? _cachedManualCoverPath(String? coverPath) {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return null;
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return value;
    }
    return _manualCoverPathValidityCache[value] == true ? value : null;
  }

  Future<String?> _validatedManualCoverPath(String? coverPath) {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return SynchronousFuture<String?>(null);
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
  }) async {
    try {
      final nativeCover = await _fileCacheGateway.resolveTrackCover(
        path: track.path,
        groupKey: track.groupKey,
        rootFolder: rootFolder,
      );
      if (nativeCover != null && nativeCover.isNotEmpty) return nativeCover;
    } on MissingPluginException {
      // Continue with the Dart fallback below.
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolvePlatformCoverPathForTrack error',
        error: e,
        stackTrace: stackTrace,
      );
    }

    if (AppPlatform.isWindows) {
      if (rootFolder != null && rootFolder.isNotEmpty) {
        try {
          final folderCover = await WindowsFfmpegService.findPreferredCoverViaFile(
            folderPath: rootFolder,
            cacheKey: track.path,
          );
          if (folderCover != null) return folderCover;
        } catch (e, stackTrace) {
          AppLogService.warning(
            'CoverArtworkCacheService._resolvePlatformCoverPathForTrack findPreferredCoverViaFile error',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }
    }

    final embeddedCover = await EmbeddedCoverArtworkService.resolveForTrack(
      track,
    );
    if (embeddedCover != null) unawaited(AppCacheService.enforceLimit());
    if (embeddedCover != null) return embeddedCover;

    if (AppPlatform.isWindows) {
      try {
        final ffmpegCover = await WindowsFfmpegService.resolveAudioCover(
          audioPath: track.path,
          modifiedAtMs: track.modifiedAt?.millisecondsSinceEpoch,
        );
        if (ffmpegCover != null) return ffmpegCover;
      } catch (e, stackTrace) {
        AppLogService.warning(
          'CoverArtworkCacheService._resolvePlatformCoverPathForTrack WindowsFfmpegService error',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }

    return null;
  }

  Future<List<String>> _resolveFolderCoverCandidates(String folderPath) async {
    final candidates = <String>[];
    final seen = <String>{};
    void addCandidate(String? value) {
      final candidate = value?.trim();
      if (candidate == null || candidate.isEmpty || !seen.add(candidate)) {
        return;
      }
      candidates.add(candidate);
    }

    for (final imagePath in await _discoverFolderImages(folderPath)) {
      addCandidate(imagePath);
    }
    for (final track in _tracksInCoverScope(folderPath)) {
      if (track.isVideo) {
        addCandidate(await _resolveVideoFramePathForTrack(track));
      } else {
        addCandidate(await _resolvePlatformCoverPathForTrack(track));
      }
    }
    return List<String>.unmodifiable(candidates);
  }

  Future<List<String>> _discoverFolderImages(String folderPath) async {
    if (PathMatcher.isContentUri(folderPath)) {
      try {
        return await _fileCacheGateway.discoverRootImages(
          path: folderPath,
          rootFolder: folderPath,
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

    final images = <String>[];
    try {
      final directory = Directory(folderPath);
      if (!await directory.exists()) return const <String>[];
      await for (final entity in directory.list(
        recursive: true,
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
    } catch (error, stackTrace) {
      AppLogService.warning(
        'Unable to discover folder cover images.',
        error: error,
        stackTrace: stackTrace,
      );
    }
    images.sort();
    return List<String>.unmodifiable(images);
  }

  List<MusicTrack> _tracksInCoverScope(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    if (normalizedFolderPath.isEmpty) return const <MusicTrack>[];
    final tracks = <MusicTrack>[];
    for (final track in _libraryService.library) {
      final groupKey = track.groupKey.trim();
      if (PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
          (groupKey.isNotEmpty &&
              PathMatcher.isWithinOrEqual(groupKey, normalizedFolderPath))) {
        tracks.add(track);
      }
    }
    return tracks;
  }
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

String? _libraryWorkScopeFolderPath(String libraryRoot, String groupKey) {
  final relativePath = PathMatcher.relativeWithin(groupKey, libraryRoot);
  if (relativePath == null || relativePath.isEmpty) return null;

  final firstSegment = relativePath
      .split(RegExp(r'[\\/]+'))
      .firstWhere((segment) => segment.isNotEmpty, orElse: () => '');
  if (firstSegment.isEmpty) return null;

  final normalizedRoot = PathMatcher.normalize(libraryRoot);
  if (PathMatcher.isContentUri(normalizedRoot)) {
    return '$normalizedRoot::$firstSegment';
  }

  return PathMatcher.join(normalizedRoot, firstSegment);
}

bool _isStandaloneAudioTrack(MusicTrack? track) {
  return track?.isSingle == true && track?.isVideo != true;
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
