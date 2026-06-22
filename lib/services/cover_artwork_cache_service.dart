import 'dart:async';
import 'dart:io';

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
    bool Function(String coverSearchKey)? isActiveCoverKey,
    VoidCallback? onActiveCoverChanged,
  }) : _libraryService = libraryService,
       _fileCacheGateway =
           fileCacheGateway ?? FileCachePlatformGateway.instance,
       _supportedImageExtensions = supportedImageExtensions,
       _isActiveCoverKey = isActiveCoverKey,
       _onActiveCoverChanged = onActiveCoverChanged;

  final LibraryService _libraryService;
  final FileCachePlatformGateway _fileCacheGateway;
  final Set<String> _supportedImageExtensions;
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
  final Set<String> _coverSearchMisses = <String>{};
  final Map<String, String?> _manualCoverByScopeCache = <String, String?>{};
  final Map<String, List<String>> _discoveredImagesByScopeCache =
      <String, List<String>>{};
  int _generation = 0;

  int get generation => _generation;

  String? resolvedForTrack(MusicTrack? track, {String? trackPath}) {
    if (track?.manualCoverPath != null) {
      return track!.manualCoverPath;
    }
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: trackPath);
    if (coverSearchKey == null) return null;
    return _resolvedTrackCovers[coverSearchKey];
  }

  String? resolvedForFolder(String folderPath) {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    _ensureManualCoverCache();
    return _manualCoverByScopeCache[normalizedFolderPath] ??
        _resolvedFolderCovers[normalizedFolderPath] ??
        _resolvedTrackCovers[normalizedFolderPath];
  }

  Future<String?> futureForTrack(MusicTrack? track, {String? trackPath}) {
    return _resolveCoverPathForTrack(track, trackPath: trackPath);
  }

  Future<String?> futureForFolder(String folderPath) {
    return _resolveCoverPathForFolder(folderPath);
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
          : 'remote-cover:$remoteCoverUrl';
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
    final normalizedScope = PathMatcher.normalize(scope);
    _generation++;
    _folderCoverFutures.remove(normalizedScope);
    _resolvedFolderCovers.remove(normalizedScope);
    _resolvedFolderCoverFutures.remove(normalizedScope);
    _trackCoverFutures.remove(normalizedScope);
    _resolvedTrackCovers.remove(normalizedScope);
    _resolvedTrackCoverFutures.remove(normalizedScope);
    _coverSearchMisses.remove(normalizedScope);
    _manualCoverByScopeCache.remove(normalizedScope);
    _discoveredImagesByScopeCache.remove(normalizedScope);
  }

  void invalidateFolders(Iterable<String?> scopes) {
    final normalizedScopes = scopes
        .whereType<String>()
        .map(PathMatcher.normalize)
        .where((scope) => scope.isNotEmpty)
        .toSet();
    if (normalizedScopes.isEmpty) {
      invalidateAll();
      return;
    }
    _generation++;
    for (final scope in normalizedScopes) {
      _folderCoverFutures.remove(scope);
      _resolvedFolderCovers.remove(scope);
      _resolvedFolderCoverFutures.remove(scope);
      _trackCoverFutures.remove(scope);
      _resolvedTrackCovers.remove(scope);
      _resolvedTrackCoverFutures.remove(scope);
      _coverSearchMisses.remove(scope);
      _manualCoverByScopeCache.remove(scope);
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
    _coverSearchMisses.clear();
    _manualCoverByScopeCache.clear();
    _discoveredImagesByScopeCache.clear();
  }

  void _ensureManualCoverCache() {
    if (_manualCoverByScopeCache.isNotEmpty) return;
    for (final track in _libraryService.library) {
      final manualCoverPath = track.manualCoverPath;
      if (manualCoverPath == null || manualCoverPath.isEmpty) continue;
      final scope = coverSearchKeyForTrack(track);
      if (scope == null || scope.isEmpty) continue;
      _manualCoverByScopeCache[scope] = manualCoverPath;
    }
  }

  Future<String?> _resolveCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    final pathValue = track?.path ?? trackPath;
    final coverSearchKey = coverSearchKeyForTrack(track, trackPath: pathValue);
    if (coverSearchKey == null) return Future<String?>.value();
    if (track?.manualCoverPath != null) {
      final manualPath = track!.manualCoverPath;
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
        coverPath = await _downloadRemoteCover(remoteCoverUrl);
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
            coverPath = await _resolveContentCoverPathForTrack(
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
        }
        if (coverPath == null && track?.isVideo == true) {
          coverPath = await _resolveVideoFramePathForTrack(track!);
        }
      }

      unawaited(_trackCoverFutures.remove(coverSearchKey) ?? Future.value());
      final previous = _resolvedTrackCovers[coverSearchKey];
      _resolvedTrackCovers[coverSearchKey] = coverPath;
      _resolvedTrackCoverFutures[coverSearchKey] = SynchronousFuture<String?>(
        coverPath,
      );

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
          _manualCoverByScopeCache[normalizedFolderPath] ??
          (PathMatcher.isContentUri(normalizedFolderPath)
              ? await _resolveContentCoverPathForFolder(normalizedFolderPath)
              : await _findCoverPath(normalizedFolderPath));
      unawaited(
        _folderCoverFutures.remove(normalizedFolderPath) ?? Future.value(),
      );

      _resolvedFolderCovers[normalizedFolderPath] = coverPath;
      _resolvedFolderCoverFutures[normalizedFolderPath] =
          SynchronousFuture<String?>(coverPath);

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
        path.join(coverDirectory.path, '${remoteUrl.hashCode}.image'),
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
    } catch (e) {
      debugPrint(
        'CoverArtworkCacheService._resolveVideoFramePathForTrack error: $e',
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

  Future<String?> _resolveContentCoverPathForTrack(
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
    } catch (e) {
      debugPrint(
        'CoverArtworkCacheService._resolveContentCoverPathForTrack error: $e',
      );
      return null;
    }
  }

  Future<String?> _resolveContentCoverPathForFolder(String folderPath) async {
    MusicTrack? firstTrack;
    for (final track in _libraryService.library) {
      if (PathMatcher.isWithinOrEqual(track.path, folderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, folderPath)) {
        firstTrack = track;
        break;
      }
    }

    try {
      return await _fileCacheGateway.resolveTrackCover(
        path: firstTrack?.path ?? folderPath,
        groupKey: firstTrack?.groupKey,
        rootFolder: folderPath,
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint(
        'CoverArtworkCacheService._resolveContentCoverPathForFolder error: $e',
      );
      return null;
    }
  }

  Future<String?> _findCoverPath(String folderPath) async {
    final normalizedFolderPath = path.normalize(folderPath);
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
    } catch (e) {
      debugPrint('Error discovering content images in root $rootFolder: $e');
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
    } catch (e) {
      debugPrint('Error discovering images in root $folderPath: $e');
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
