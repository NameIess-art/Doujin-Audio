import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../models/music_track.dart';
import '../platform/app_platform.dart';
import 'app_cache_service.dart';
import 'app_log_service.dart';
import 'audio_state_services.dart';
import 'file_cache_platform_gateway.dart';
import 'path_matcher.dart';
import 'windows_ffmpeg_service.dart';

const List<String> _preferredCoverBasenames = <String>[
  'cover',
  'folder',
  'front',
  'album',
  'artwork',
  'poster',
];

class CoverArtworkCacheService {
  CoverArtworkCacheService({
    required LibraryService libraryService,
    FileCachePlatformGateway? fileCacheGateway,
    Set<String> supportedImageExtensions = const <String>{
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.bmp',
      '.gif',
    },
    Future<String?> Function(String remoteUrl)? remoteCoverDownloader,
    bool Function(String coverSearchKey)? isActiveCoverKey,
    VoidCallback? onActiveCoverChanged,
  }) : _libraryService = libraryService,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _supportedImageExtensions = supportedImageExtensions,
       _remoteCoverDownloader = remoteCoverDownloader,
       _isActiveCoverKey = isActiveCoverKey,
       _onActiveCoverChanged = onActiveCoverChanged;

  final LibraryService _libraryService;
  final FileCachePlatformGateway _fileCacheGateway;
  final Set<String> _supportedImageExtensions;
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
  final Map<String, String?> _resolvedTrackCovers = <String, String?>{};
  final Map<String, Future<String?>> _resolvedTrackCoverFutures =
      <String, Future<String?>>{};
  final Map<String, Future<String?>> _remoteCoverFutures =
      <String, Future<String?>>{};
  final Map<String, String?> _resolvedRemoteCovers = <String, String?>{};
  final Map<String, Future<String?>> _resolvedRemoteCoverFutures =
      <String, Future<String?>>{};
  final Set<String> _coverSearchMisses = <String>{};
  final Map<String, String?> _manualCoverByScopeCache = <String, String?>{};
  bool _manualCoverCachePrimed = false;
  final Map<String, List<String>> _discoveredImagesByScopeCache =
      <String, List<String>>{};
  int _generation = 0;

  int get generation => _generation;

  String? resolvedForTrack(MusicTrack? track, {String? trackPath}) {
    final manualCoverPath = _validatedManualCoverPathSync(
      track?.manualCoverPath,
    );
    if (manualCoverPath != null) {
      return manualCoverPath;
    }
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (coverSearchKey == null) return null;
    return _resolvedTrackCovers[coverSearchKey];
  }

  String? resolvedForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    _ensureManualCoverCache();
    return _validatedManualCoverPathSync(
          _manualCoverByScopeCache[normalizedFolderPath],
        ) ??
        _resolvedFolderCovers[normalizedFolderPath] ??
        _resolvedTrackCovers[normalizedFolderPath];
  }

  String? resolvedForRemoteCover(String url) {
    final remoteKey = remoteCoverSearchKey(url);
    if (remoteKey == null) return null;
    return _resolvedRemoteCovers[remoteKey];
  }

  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) {
    return _resolveCoverPathForTrack(track, trackPath: trackPath);
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

  String? coverSearchKeyForTrack(MusicTrack? track, {String? trackPath}) {
    final pathValue = track?.path ?? trackPath;
    if (pathValue == null || pathValue.isEmpty) return null;
    if (PathMatcher.isRemoteUri(pathValue)) {
      final remoteCoverUrl = track?.remoteCoverUrl?.trim();
      return remoteCoverUrl == null || remoteCoverUrl.isEmpty
          ? null
          : remoteCoverSearchKey(remoteCoverUrl);
    }
    if (track?.isVideo == true) return PathMatcher.normalize(pathValue);
    final scopedFolder = coverScopeFolderForTrack(track, trackPath: pathValue);
    if (scopedFolder != null && scopedFolder.isNotEmpty) {
      return PathMatcher.normalize(scopedFolder);
    }
    final directoryPath = path.dirname(pathValue);
    if (directoryPath.isEmpty || directoryPath == '.') return null;
    return PathMatcher.normalize(directoryPath);
  }

  Future<List<String>> discoverImagesInRoot(
    String trackPath,
    MusicTrack? track,
  ) async {
    final scopeFolder = coverScopeFolderForTrack(track, trackPath: trackPath);
    if (scopeFolder == null || scopeFolder.isEmpty) return [];

    if (PathMatcher.isContentUri(scopeFolder) ||
        PathMatcher.isContentUri(trackPath)) {
      return _discoverContentImages(
        trackPath: trackPath,
        groupKey: track?.groupKey,
        rootFolder: scopeFolder,
      );
    }

    return discoverImagesInFolder(scopeFolder);
  }

  Future<List<String>> discoverImagesInFolder(String folderPath) async {
    if (folderPath.trim().isEmpty) return [];
    final normalizedFolder = PathMatcher.normalize(folderPath);
    if (normalizedFolder.isEmpty) return [];

    if (PathMatcher.isContentUri(normalizedFolder)) {
      return _discoverContentImages(
        trackPath: normalizedFolder,
        rootFolder: normalizedFolder,
      );
    }

    return _discoverFileSystemImages(normalizedFolder);
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
    _trackCoverFutures.remove(normalizedScope);
    _resolvedTrackCovers.remove(normalizedScope);
    _resolvedTrackCoverFutures.remove(normalizedScope);
    _remoteCoverFutures.remove(normalizedScope);
    _resolvedRemoteCovers.remove(normalizedScope);
    _resolvedRemoteCoverFutures.remove(normalizedScope);
    _coverSearchMisses.remove(normalizedScope);
    _manualCoverByScopeCache.clear();
    _manualCoverCachePrimed = false;
    _discoveredImagesByScopeCache.remove(normalizedScope);
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
    _manualCoverByScopeCache.clear();
    _manualCoverCachePrimed = false;
    for (final scope in normalizedScopes) {
      _folderCoverFutures.remove(scope);
      _resolvedFolderCovers.remove(scope);
      _resolvedFolderCoverFutures.remove(scope);
      _trackCoverFutures.remove(scope);
      _resolvedTrackCovers.remove(scope);
      _resolvedTrackCoverFutures.remove(scope);
      _remoteCoverFutures.remove(scope);
      _resolvedRemoteCovers.remove(scope);
      _resolvedRemoteCoverFutures.remove(scope);
      _coverSearchMisses.remove(scope);
      _discoveredImagesByScopeCache.remove(scope);
    }
  }

  void invalidateAll() {
    _generation++;
    _folderCoverFutures.clear();
    _resolvedFolderCovers.clear();
    _resolvedFolderCoverFutures.clear();
    _trackCoverFutures.clear();
    _resolvedTrackCovers.clear();
    _resolvedTrackCoverFutures.clear();
    _remoteCoverFutures.clear();
    _resolvedRemoteCovers.clear();
    _resolvedRemoteCoverFutures.clear();
    _coverSearchMisses.clear();
    _manualCoverByScopeCache.clear();
    _manualCoverCachePrimed = false;
    _discoveredImagesByScopeCache.clear();
  }

  void _ensureManualCoverCache() {
    if (_manualCoverCachePrimed) return;
    _manualCoverByScopeCache.clear();
    for (final track in _libraryService.library) {
      final manualCoverPath = _validatedManualCoverPathSync(
        track.manualCoverPath,
      );
      if (manualCoverPath == null) continue;
      final scope = coverSearchKeyForTrack(track);
      if (scope == null || scope.isEmpty) continue;
      _manualCoverByScopeCache[scope] = manualCoverPath;
    }
    _manualCoverCachePrimed = true;
  }

  Future<String?> _resolveCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: pathValue);
    if (coverSearchKey == null) return Future<String?>.value();
    final manualPath = _validatedManualCoverPathSync(track?.manualCoverPath);
    if (manualPath != null) {
      _resolvedTrackCovers[coverSearchKey] = manualPath;
      return _resolvedTrackCoverFutures.putIfAbsent(
        coverSearchKey,
        () => SynchronousFuture<String?>(manualPath),
      );
    }

    if (_resolvedTrackCovers.containsKey(coverSearchKey)) {
      return _resolvedTrackCoverFutures.putIfAbsent(
        coverSearchKey,
        () => SynchronousFuture<String?>(_resolvedTrackCovers[coverSearchKey]),
      );
    }

    return _trackCoverFutures.putIfAbsent(coverSearchKey, () async {
      String? coverPath;
      final remoteCoverUrl = track?.remoteCoverUrl?.trim();
      if (remoteCoverUrl != null && remoteCoverUrl.isNotEmpty) {
        coverPath = await futureForRemoteCover(remoteCoverUrl);
      }
      if (coverPath == null &&
          pathValue != null &&
          !PathMatcher.isRemoteUri(pathValue)) {
        final coverScopeFolder = coverScopeFolderForTrack(
          track,
          trackPath: pathValue,
        );
        if (track?.isSingle == true && track?.isVideo == true) {
          coverPath = await _resolveVideoFramePathForTrack(track!);
        } else if (PathMatcher.isContentUri(pathValue)) {
          if (track != null) {
            coverPath = await _resolvePlatformCoverPathForTrack(
              track,
              rootFolder: coverScopeFolder,
            );
          } else {
            coverPath = await _resolveContentCoverPathForFolder(
              coverScopeFolder ?? pathValue,
            );
          }
        } else {
          coverPath = await _findCoverPath(coverScopeFolder ?? coverSearchKey);
          if (coverPath == null && track != null) {
            coverPath = await _resolvePlatformCoverPathForTrack(track);
          }
        }
        if (coverPath == null && track?.isVideo == true) {
          coverPath = await _resolveVideoFramePathForTrack(track!);
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
      }

      if (previous != coverPath &&
          (_isActiveCoverKey?.call(coverSearchKey) ?? false)) {
        _onActiveCoverChanged?.call();
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
      _ensureManualCoverCache();
      final coverPath =
          _validatedManualCoverPathSync(
            _manualCoverByScopeCache[normalizedFolderPath],
          ) ??
          (PathMatcher.isContentUri(normalizedFolderPath)
              ? await _resolveContentCoverPathForFolder(normalizedFolderPath)
              : await _resolveFileSystemCoverPathForFolder(
                  normalizedFolderPath,
                ));
      unawaited(
        _folderCoverFutures.remove(normalizedFolderPath) ?? Future.value(),
      );

      _resolvedFolderCovers[normalizedFolderPath] = coverPath;
      _resolvedFolderCoverFutures[normalizedFolderPath] =
          SynchronousFuture<String?>(coverPath);

      return coverPath;
    });
  }

  Future<String?> _resolveRemoteCover(String remoteKey, String remoteUrl) {
    if (_resolvedRemoteCovers.containsKey(remoteKey)) {
      return _resolvedRemoteCoverFutures.putIfAbsent(
        remoteKey,
        () => SynchronousFuture<String?>(_resolvedRemoteCovers[remoteKey]),
      );
    }

    return _remoteCoverFutures.putIfAbsent(remoteKey, () async {
      final downloader = _remoteCoverDownloader;
      String? coverPath;
      try {
        coverPath = await (downloader == null
            ? _downloadRemoteCover(remoteUrl)
            : downloader(remoteUrl));
      } finally {
        final removedRemoteFuture = _remoteCoverFutures.remove(remoteKey);
        if (removedRemoteFuture != null) unawaited(removedRemoteFuture);
      }

      final previous = _resolvedRemoteCovers[remoteKey];
      if (coverPath == null) {
        _resolvedRemoteCovers.remove(remoteKey);
        final removedResolvedRemoteFuture = _resolvedRemoteCoverFutures.remove(
          remoteKey,
        );
        if (removedResolvedRemoteFuture != null) {
          unawaited(removedResolvedRemoteFuture);
        }
      } else {
        _resolvedRemoteCovers[remoteKey] = coverPath;
        _resolvedRemoteCoverFutures[remoteKey] = SynchronousFuture<String?>(
          coverPath,
        );
      }

      if (previous != coverPath &&
          (_isActiveCoverKey?.call(remoteKey) ?? false)) {
        _onActiveCoverChanged?.call();
      }

      return coverPath;
    });
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
      if (await file.exists() && await file.length() > 0) return file.path;

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

  String? _validatedManualCoverPathSync(String? coverPath) {
    final value = coverPath?.trim();
    if (value == null || value.isEmpty) return null;
    if (PathMatcher.isContentUri(value) || PathMatcher.isRemoteUri(value)) {
      return value;
    }
    return File(value).existsSync() ? value : null;
  }

  Future<String?> _resolvePlatformCoverPathForTrack(
    MusicTrack track, {
    String? rootFolder,
  }) async {
    try {
      return await _fileCacheGateway.resolveTrackCover(
        path: track.path,
        groupKey: track.groupKey,
        rootFolder: rootFolder,
      );
    } on MissingPluginException {
      return null;
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolvePlatformCoverPathForTrack error',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<String?> _resolveFileSystemCoverPathForFolder(
    String folderPath,
  ) async {
    final coverPath = await _findCoverPath(folderPath);
    if (coverPath != null && coverPath.isNotEmpty) return coverPath;

    return _resolveCoverPathFromCandidateTracks(folderPath);
  }

  Future<String?> _resolveCoverPathFromCandidateTracks(
    String folderPath,
  ) async {
    for (final track in _tracksInCoverScope(folderPath)) {
      final coverPath = await _resolvePlatformCoverPathForTrack(
        track,
        rootFolder: PathMatcher.isContentUri(folderPath) ? folderPath : null,
      );
      if (coverPath != null && coverPath.isNotEmpty) return coverPath;
    }
    return null;
  }

  Future<String?> _resolveContentCoverPathForFolder(String folderPath) async {
    final candidates = _tracksInCoverScope(folderPath);
    for (final track in candidates) {
      final coverPath = await _resolvePlatformCoverPathForTrack(
        track,
        rootFolder: folderPath,
      );
      if (coverPath != null && coverPath.isNotEmpty) return coverPath;
    }

    if (candidates.isNotEmpty) return null;

    try {
      return await _fileCacheGateway.resolveTrackCover(
        path: folderPath,
        rootFolder: folderPath,
      );
    } on MissingPluginException {
      return null;
    } catch (e, stackTrace) {
      AppLogService.warning(
        'CoverArtworkCacheService._resolveContentCoverPathForFolder error',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
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

  Future<String?> _findCoverPath(String folderPath) async {
    final normalizedFolderPath = path.normalize(folderPath);
    if (normalizedFolderPath.isEmpty) return null;
    if (_coverSearchMisses.contains(normalizedFolderPath)) return null;
    if (_resolvedFolderCovers.containsKey(normalizedFolderPath)) {
      return _resolvedFolderCovers[normalizedFolderPath];
    }
    if (_resolvedTrackCovers.containsKey(normalizedFolderPath)) {
      return _resolvedTrackCovers[normalizedFolderPath];
    }

    final directory = Directory(folderPath);
    if (!await directory.exists()) {
      _coverSearchMisses.add(normalizedFolderPath);
      return null;
    }

    try {
      final candidates = <String>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final extension = path.extension(entity.path).toLowerCase();
        if (!_supportedImageExtensions.contains(extension)) continue;
        candidates.add(entity.path);
      }
      if (candidates.isNotEmpty) {
        candidates.sort(_compareCoverPaths);
        _coverSearchMisses.remove(normalizedFolderPath);
        return candidates.first;
      }
      candidates.addAll(await _discoverFileSystemImages(folderPath));
      if (candidates.isNotEmpty) {
        candidates.sort(_compareCoverPaths);
        _coverSearchMisses.remove(normalizedFolderPath);
        return candidates.first;
      }
    } catch (_) {
      // Cover discovery is optional; UI and notifications render fallbacks.
    }

    _coverSearchMisses.add(normalizedFolderPath);
    return null;
  }

  Future<List<String>> _discoverContentImages({
    required String trackPath,
    required String rootFolder,
    String? groupKey,
  }) async {
    try {
      return _fileCacheGateway.discoverRootImages(
        path: trackPath,
        groupKey: groupKey,
        rootFolder: rootFolder,
      );
    } on MissingPluginException {
      return [];
    } catch (e, stackTrace) {
      AppLogService.warning(
        'Error discovering content images',
        error: e,
        stackTrace: stackTrace,
      );
      return [];
    }
  }

  Future<List<String>> _discoverFileSystemImages(String folderPath) async {
    final normalizedScope = PathMatcher.normalize(folderPath);
    final cached = _discoveredImagesByScopeCache[normalizedScope];
    if (cached != null) return cached;

    final images = <String>[];
    try {
      final dir = Directory(folderPath);
      if (!await dir.exists()) return [];

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final ext = path.extension(entity.path).toLowerCase();
        if (!_supportedImageExtensions.contains(ext)) continue;
        images.add(entity.path);
      }
    } catch (e, stackTrace) {
      AppLogService.warning(
        'Error discovering images',
        error: e,
        stackTrace: stackTrace,
      );
    }

    images.sort((a, b) => a.compareTo(b));
    final snapshot = List<String>.unmodifiable(images);
    _discoveredImagesByScopeCache[normalizedScope] = snapshot;
    return snapshot;
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

int _coverPriority(String baseName) {
  final exactMatchIndex = _preferredCoverBasenames.indexOf(baseName);
  if (exactMatchIndex >= 0) return exactMatchIndex;
  for (var i = 0; i < _preferredCoverBasenames.length; i++) {
    if (baseName.contains(_preferredCoverBasenames[i])) return 100 + i;
  }
  return 200;
}

int _compareCoverPaths(String leftPath, String rightPath) {
  final leftName = path.basename(leftPath);
  final rightName = path.basename(rightPath);
  final leftBase = path.basenameWithoutExtension(leftName).toLowerCase();
  final rightBase = path.basenameWithoutExtension(rightName).toLowerCase();
  final scoreCompare = _coverPriority(
    leftBase,
  ).compareTo(_coverPriority(rightBase));
  if (scoreCompare != 0) return scoreCompare;
  final nameCompare = leftBase.compareTo(rightBase);
  if (nameCompare != 0) return nameCompare;
  return leftPath.toLowerCase().compareTo(rightPath.toLowerCase());
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
