import 'package:flutter/foundation.dart';

import '../../core/logging/app_log_service.dart';
import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/media/path_matcher.dart';
import '../../features/asmr/application/asmr_playback_coordinator.dart';
import '../../features/asmr/domain/asmr_models.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/library/application/library_organizer.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_track_resolver.dart';

/// Coordinates path changes that affect both the library and active playback.
final class AudioPathCoordinator implements PlaybackTrackResolver {
  AudioPathCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
    AsmrPlaybackSource? asmrPlaybackSource,
  }) : _library = library,
       _playback = playback,
       _asmrPlaybackSource = asmrPlaybackSource;

  final LibraryFacade _library;
  final PlaybackFacade _playback;
  final AsmrPlaybackSource? _asmrPlaybackSource;
  static const _maxCachedWorks = 64;
  static const _inlineWorkLookupLimit = 64;
  final Map<String, _WorkTracksCache> _workTracksCache = {};
  int _cachedStructureRevision = -1;

  LibraryFacade get library => _library;

  @override
  MusicTrack? trackByPath(
    String trackPath, {
    bool includeLibraryFallback = true,
  }) {
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    final libraryTrack = _library.trackByPath(resolvedPath);
    if (libraryTrack != null) return libraryTrack;
    // Active sessions own remote and cached queue metadata, so consult them
    // before the normalized full-library compatibility fallback.
    for (final session in _playback.sessions.values) {
      final track = sessionTrackForPath(session.id, resolvedPath);
      if (track != null) return track;
    }
    if (!includeLibraryFallback) return null;
    final sameTarget = resolvedPath == trackPath;
    if (PathMatcher.isContentUri(trackPath) ||
        PathMatcher.isRemoteUri(trackPath) ||
        (!sameTarget &&
            (PathMatcher.isContentUri(resolvedPath) ||
                PathMatcher.isRemoteUri(resolvedPath)))) {
      final trackKey = PathMatcher.equivalenceKey(trackPath);
      final resolvedKey = sameTarget
          ? null
          : PathMatcher.equivalenceKey(resolvedPath);
      for (final track in _library.library) {
        final candidateKey = PathMatcher.equivalenceKey(track.path);
        if (candidateKey == trackKey ||
            (resolvedKey != null && candidateKey == resolvedKey)) {
          return track;
        }
      }
      return null;
    }
    for (final track in _library.library) {
      if (PathMatcher.equivalenceEquals(track.path, trackPath) ||
          (!sameTarget &&
              PathMatcher.equivalenceEquals(track.path, resolvedPath))) {
        return track;
      }
    }
    return null;
  }

  @override
  MusicTrack? sessionTrackForPath(String sessionId, String trackPath) {
    final session = _playback.sessionById(sessionId);
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    if (session == null) {
      return _library.trackByPath(resolvedPath);
    }
    var sessionTrack = session.trackForPath(
      trackPath,
      resolvedPath: resolvedPath,
    );
    if (sessionTrack == null) {
      final originalPath = _playback.originalPathForRetargeted(trackPath) ??
          _playback.originalPathForRetargeted(resolvedPath);
      if (originalPath != null) {
        sessionTrack = session.trackForPath(originalPath);
      }
    }
    if (sessionTrack != null) return sessionTrack;
    return _library.trackByPath(resolvedPath);
  }

  List<MusicTrack> tracksInSameGroup(String trackPath, {int? limit}) {
    final track = trackByPath(trackPath);
    if (track == null) return const <MusicTrack>[];
    return _tracksInGroup(trackPath, track, limit: limit);
  }

  List<MusicTrack> _tracksInGroup(
    String trackPath,
    MusicTrack track, {
    int? limit,
  }) {
    final libraryTracks = _library.tracksInGroup(track.groupKey, limit: limit);
    if (libraryTracks.isNotEmpty) return libraryTracks;
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    final originalPath =
        _playback.originalPathForRetargeted(trackPath) ??
        _playback.originalPathForRetargeted(resolvedPath);
    for (final session in _playback.sessions.values) {
      final sessionTrack =
          session.trackForPath(trackPath, resolvedPath: resolvedPath) ??
          (originalPath != null ? session.trackForPath(originalPath) : null) ??
          session.trackForPath(track.path);
      if (sessionTrack == null) continue;
      final queue = session.customQueueTracks;
      if (queue == null) continue;
      final matches = queue.where(
        (candidate) => candidate.groupKey == track.groupKey,
      );
      return (limit == null ? matches : matches.take(limit)).toList(
        growable: false,
      );
    }
    return const <MusicTrack>[];
  }

  @override
  List<MusicTrack> tracksInSameWork(String trackPath) =>
      _tracksInSameWork(trackPath);

  bool hasOtherTracksInSameWork(String trackPath) {
    final cached = cachedHasOtherTracksInSameWork(trackPath);
    return cached ?? _tracksInSameWork(trackPath, limit: 2).length > 1;
  }

  bool? cachedHasOtherTracksInSameWork(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null || track.isSingle) return false;
    if (track.isRemoteAsmr || PathMatcher.isRemoteUri(track.path)) {
      return tracksInSameGroup(trackPath, limit: 2).length > 1;
    }
    final root = workRootForTrack(trackPath, knownTrack: track);
    if (root == null) return tracksInSameGroup(trackPath, limit: 2).length > 1;
    final cached = _cachedWork(root);
    if (cached != null) return cached.hasSiblings;

    // Two tracks in the indexed group prove sibling presence. A single
    // indexed track cannot rule out tracks in nested groups.
    if (PathMatcher.isWithinOrEqual(track.groupKey, root)) {
      final groupTracks = _library.tracksInGroup(track.groupKey, limit: 2);
      if (groupTracks.length > 1) {
        _cacheWork(root, const _WorkTracksCache(hasSiblings: true));
        return true;
      }
    }
    return null;
  }

  List<MusicTrack> _tracksInSameWork(String trackPath, {int? limit}) {
    final track = trackByPath(trackPath);
    if (track == null) return const <MusicTrack>[];
    if (track.isSingle) return <MusicTrack>[track];
    if (track.isRemoteAsmr || PathMatcher.isRemoteUri(track.path)) {
      return _tracksInGroup(trackPath, track, limit: limit);
    }
    final root = workRootForTrack(trackPath, knownTrack: track);
    if (root == null) return _tracksInGroup(trackPath, track, limit: limit);
    final cached = _cachedWork(root);
    if (cached?.tracks != null) {
      final tracks = cached!.tracks!;
      return limit == null
          ? tracks.toList(growable: false)
          : tracks.take(limit).toList(growable: false);
    }
    final normalizedRoot = PathMatcher.normalize(root);
    final matches = _library.library.where(
      (candidate) => _isTrackInWork(candidate, normalizedRoot),
    );
    final tracks = (limit == null ? matches : matches.take(limit)).toList(
      growable: false,
    );
    if (tracks.isEmpty) {
      final fallback = _tracksInGroup(trackPath, track, limit: limit);
      if (limit == null && fallback.isNotEmpty) {
        _cacheWork(
          root,
          _WorkTracksCache(
            hasSiblings: fallback.length > 1,
            tracks: List<MusicTrack>.unmodifiable(fallback),
          ),
        );
      }
      return fallback;
    }
    if (limit == null) tracks.sort(_library.compareTracks);
    _cacheWork(
      root,
      _WorkTracksCache(
        hasSiblings: tracks.length > 1,
        tracks: limit == null ? List<MusicTrack>.unmodifiable(tracks) : null,
      ),
    );
    return tracks;
  }

  _WorkTracksCache? _cachedWork(String root) {
    _invalidateWorkCacheIfNeeded();
    return _workTracksCache[PathMatcher.equivalenceKey(root)];
  }

  void _cacheWork(String root, _WorkTracksCache result) {
    _invalidateWorkCacheIfNeeded();
    final key = PathMatcher.equivalenceKey(root);
    if (!_workTracksCache.containsKey(key) &&
        _workTracksCache.length >= _maxCachedWorks) {
      _workTracksCache.remove(_workTracksCache.keys.first);
    }
    _workTracksCache[key] = result;
  }

  void _invalidateWorkCacheIfNeeded() {
    if (_cachedStructureRevision == _library.structureRevision) return;
    _cachedStructureRevision = _library.structureRevision;
    _workTracksCache.clear();
  }

  /// Resolves the work for an already selected track without scanning a large
  /// catalog on the UI isolate.
  Future<List<MusicTrack>> tracksInSameWorkAsync(MusicTrack knownTrack) async {
    final trackPath = knownTrack.path;
    while (true) {
      final resolvedPath = _playback.resolveRetargetedPath(trackPath);
      final track = _library.trackByPath(resolvedPath) ?? knownTrack;
      if (track.isSingle) return [track];
      if (track.isRemoteAsmr || PathMatcher.isRemoteUri(track.path)) {
        return _tracksInGroup(trackPath, track);
      }
      final root = workRootForTrack(trackPath, knownTrack: track);
      if (root == null) return _tracksInGroup(trackPath, track);
      final cached = _cachedWork(root)?.tracks;
      if (cached != null) return cached;

      final revision = _library.structureRevision;
      final source = _library.library;
      final request = (tracks: source, root: root);
      final indices = source.length <= _inlineWorkLookupLimit
          ? await Future.microtask(() => _workTrackIndices(request))
          : await compute(_workTrackIndices, request);
      if (revision != _library.structureRevision) continue;

      final tracks = <MusicTrack>[];
      final budget = Stopwatch()..start();
      for (final index in indices) {
        tracks.add(source[index]);
        if (budget.elapsedMicroseconds >= 1000) {
          await Future<void>.delayed(Duration.zero);
          // A scan can reorder the source while this slice yields.
          if (revision != _library.structureRevision) break;
          budget.reset();
        }
      }
      if (revision != _library.structureRevision) continue;
      if (tracks.isEmpty) return _tracksInGroup(trackPath, track);
      final result = List<MusicTrack>.unmodifiable(tracks);
      _cacheWork(
        root,
        _WorkTracksCache(hasSiblings: result.length > 1, tracks: result),
      );
      return result;
    }
  }

  Future<List<MusicTrack>> tracksForQueueSource(
    String sessionId,
    MusicTrack track,
  ) async {
    if (!track.isRemoteAsmr) return tracksInSameWorkAsync(track);

    final metadata = track.remoteMetadata;
    final source = _asmrPlaybackSource;
    if (metadata != null && source != null) {
      try {
        final work = AsmrWork.fromJson(metadata);
        if (work.workCode.isNotEmpty || work.preferredResource.id > 0) {
          final tracks = await source.loadPlayableTracks(work);
          if (tracks.isNotEmpty) return tracks;
        }
      } catch (error, stackTrace) {
        AppLogService.warning(
          'queue_source_online_work_load_failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    // Restored sessions may have playable tracks even when the catalog is offline.
    final savedTracks =
        _playback.sessionById(sessionId)?.customQueueTracks ??
        const <MusicTrack>[];
    return savedTracks
        .where((candidate) => candidate.groupKey == track.groupKey)
        .toList(growable: false);
  }

  Future<List<MusicTrack>> tracksForSessionSwitcher(String sessionId) async {
    while (true) {
      final session = _playback.sessionById(sessionId);
      if (session == null) return const <MusicTrack>[];
      final customQueue = session.customQueueTracks;
      if (customQueue != null && customQueue.isNotEmpty) return customQueue;
      final trackPath = session.currentTrackPath;
      final track = trackByPath(trackPath);
      if (track == null) return const <MusicTrack>[];
      final tracks = await tracksInSameWorkAsync(track);
      if (identical(_playback.sessionById(sessionId), session) &&
          session.currentTrackPath == trackPath &&
          session.customQueueTracks?.isNotEmpty != true) {
        return tracks;
      }
    }
  }

  @override
  String? workRootForTrack(String trackPath, {MusicTrack? knownTrack}) {
    final track = knownTrack == null
        ? trackByPath(trackPath)
        : _library.trackByPath(_playback.resolveRetargetedPath(trackPath)) ??
              knownTrack;
    if (track == null ||
        track.isSingle ||
        PathMatcher.isRemoteUri(track.path)) {
      return null;
    }
    final coverScope = _library.coverArtworkCacheService
        .coverScopeFolderForTrack(track, trackPath: trackPath);
    if (coverScope != null && coverScope.isNotEmpty) return coverScope;
    final detailTargetPath = _library
        .audioDetailTargetForTrack(track)
        .targetPath;
    if (detailTargetPath.isNotEmpty) {
      return PathMatcher.normalize(detailTargetPath);
    }
    final groupKey = track.groupKey.trim();
    if (groupKey.isEmpty || groupKey == '__single_files__') return null;
    return PathMatcher.normalize(groupKey);
  }

  String rootFolderName(String trackPath, {MusicTrack? knownTrack}) {
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    // List rows already resolve their session track. Looking it up again scans
    // unrelated sessions for remote/imported tracks whenever a row mounts.
    final workRoot = workRootForTrack(resolvedPath, knownTrack: knownTrack);
    if (workRoot != null && workRoot.isNotEmpty) {
      return PathDisplay.folderName(workRoot);
    }
    final root = _library.libraryRootForPath(resolvedPath);
    return root == null ? '' : PathDisplay.folderName(root);
  }

  @override
  String workTitleForTrack(MusicTrack track) {
    if (track.isRemoteAsmr) {
      final remoteTitle = track.remoteMetadata?['workTitle'] as String?;
      if (remoteTitle != null && remoteTitle.trim().isNotEmpty) {
        return remoteTitle.trim();
      }
      if (track.groupTitle.trim().isNotEmpty) {
        return track.groupTitle.trim();
      }
      return track.displayName;
    }

    final detailTarget = _library.audioDetailTargetForTrack(track);
    final detail = _library.resolvedAudioDetail(detailTarget) ??
        _library.categorySnapshot?.detailFor(detailTarget);
    if (detail != null && detail.workTitle.trim().isNotEmpty) {
      return detail.workTitle.trim();
    }

    final workRoot = workRootForTrack(track.path, knownTrack: track);
    if (workRoot != null && workRoot.isNotEmpty) {
      final folderName = PathDisplay.folderName(workRoot);
      if (folderName.isNotEmpty) {
        if (track.groupTitle.trim().isNotEmpty &&
            track.groupTitle.trim().toLowerCase() ==
                folderName.trim().toLowerCase()) {
          return track.groupTitle.trim();
        }
        return folderName;
      }
    }

    if (detailTarget.targetPath.isNotEmpty &&
        detailTarget.isLibraryRootFolder) {
      final folderName = PathDisplay.folderName(detailTarget.targetPath);
      if (folderName.isNotEmpty) {
        if (track.groupTitle.trim().isNotEmpty &&
            track.groupTitle.trim().toLowerCase() ==
                folderName.trim().toLowerCase()) {
          return track.groupTitle.trim();
        }
        return folderName;
      }
    }

    final rootFolder = rootFolderName(track.path, knownTrack: track);
    if (rootFolder.isNotEmpty) {
      if (track.groupTitle.trim().isNotEmpty &&
          track.groupTitle.trim().toLowerCase() ==
              rootFolder.trim().toLowerCase()) {
        return track.groupTitle.trim();
      }
      return rootFolder;
    }

    if (track.isSingle) {
      return track.displayName;
    }

    return track.groupTitle.trim().isNotEmpty
        ? track.groupTitle.trim()
        : track.displayName;
  }

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    final oldPath = detail.target.targetPath;
    final result = await _library.renameAudioDetailTargetToName(
      detail,
      targetName,
    );
    if (result.renamed) {
      await _playback.retargetPath(oldPath, result.detail.target.targetPath);
    }
    return result;
  }

  Future<String> renameWorkEntryToName({
    required String libraryRootPath,
    required String entryPath,
    required String targetName,
    required bool isMedia,
    required bool isDirectory,
  }) async {
    final renamedPath = await _library.renameWorkEntryToName(
      libraryRootPath: libraryRootPath,
      entryPath: entryPath,
      targetName: targetName,
      isMedia: isMedia,
      isDirectory: isDirectory,
    );
    if (PathMatcher.normalize(entryPath) !=
        PathMatcher.normalize(renamedPath)) {
      await _playback.retargetPath(entryPath, renamedPath);
    }
    return renamedPath;
  }
}

final class _WorkTracksCache {
  const _WorkTracksCache({required this.hasSiblings, this.tracks});

  final bool hasSiblings;
  final List<MusicTrack>? tracks;
}

List<int> _workTrackIndices(({List<MusicTrack> tracks, String root}) request) {
  final normalizedRoot = PathMatcher.normalize(request.root);
  final indices = <int>[
    for (var i = 0; i < request.tracks.length; i++)
      if (_isTrackInWork(request.tracks[i], normalizedRoot)) i,
  ];
  const organizer = LibraryOrganizer();
  indices.sort(
    (a, b) => organizer.compareTracks(request.tracks[a], request.tracks[b]),
  );
  return indices;
}

bool _isTrackInWork(MusicTrack track, String normalizedRoot) =>
    PathMatcher.isWithinOrEqualNormalized(
      PathMatcher.normalize(track.path),
      normalizedRoot,
    ) ||
    PathMatcher.isWithinOrEqualNormalized(
      PathMatcher.normalize(track.groupKey),
      normalizedRoot,
    );
