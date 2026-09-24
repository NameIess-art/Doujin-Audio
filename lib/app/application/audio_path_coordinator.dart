import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/media/path_matcher.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_track_resolver.dart';

/// Coordinates path changes that affect both the library and active playback.
final class AudioPathCoordinator implements PlaybackTrackResolver {
  const AudioPathCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
  }) : _library = library,
       _playback = playback;

  final LibraryFacade _library;
  final PlaybackFacade _playback;

  LibraryFacade get library => _library;

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
    for (final track in _library.library) {
      if (PathMatcher.equalsNormalized(track.path, trackPath) ||
          PathMatcher.equalsNormalized(track.path, resolvedPath)) {
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
    final libraryTracks = _library.tracksInGroup(track.groupKey, limit: limit);
    if (libraryTracks.isNotEmpty) return libraryTracks;
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    final originalPath = _playback.originalPathForRetargeted(trackPath) ??
        _playback.originalPathForRetargeted(resolvedPath);
    for (final session in _playback.sessions.values) {
      final sessionTrack = session.trackForPath(
            trackPath,
            resolvedPath: resolvedPath,
          ) ??
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

  List<MusicTrack> tracksInSameWork(String trackPath) =>
      _tracksInSameWork(trackPath);

  bool hasOtherTracksInSameWork(String trackPath) =>
      _tracksInSameWork(trackPath, limit: 2).length > 1;

  List<MusicTrack> _tracksInSameWork(String trackPath, {int? limit}) {
    final track = trackByPath(trackPath);
    if (track == null) return const <MusicTrack>[];
    if (track.isSingle) return <MusicTrack>[track];
    if (track.isRemoteAsmr || PathMatcher.isRemoteUri(track.path)) {
      return tracksInSameGroup(trackPath, limit: limit);
    }
    final root = workRootForTrack(trackPath);
    if (root == null) return tracksInSameGroup(trackPath, limit: limit);
    final matches = _library.library.where(
      (candidate) =>
          PathMatcher.isWithinOrEqual(candidate.path, root) ||
          PathMatcher.isWithinOrEqual(candidate.groupKey, root),
    );
    final tracks = (limit == null ? matches : matches.take(limit)).toList(
      growable: false,
    );
    if (tracks.isEmpty) return tracksInSameGroup(trackPath, limit: limit);
    if (limit == null) tracks.sort(_library.compareTracks);
    return tracks;
  }

  List<MusicTrack> tracksForSessionSwitcher(String sessionId) {
    final session = _playback.sessionById(sessionId);
    if (session == null) return const <MusicTrack>[];
    final customQueue = session.customQueueTracks;
    if (customQueue != null && customQueue.isNotEmpty) return customQueue;
    return tracksInSameWork(session.currentTrackPath);
  }

  String? workRootForTrack(String trackPath) {
    final track = trackByPath(trackPath);
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

  String rootFolderName(String trackPath) {
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    final workRoot = workRootForTrack(resolvedPath);
    if (workRoot != null && workRoot.isNotEmpty) {
      return PathDisplay.folderName(workRoot);
    }
    final root = _library.libraryRootForPath(resolvedPath);
    return root == null ? '' : PathDisplay.folderName(root);
  }

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

    final workRoot = workRootForTrack(track.path);
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

    final rootFolder = rootFolderName(track.path);
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
}
