import '../../core/media/audio_detail.dart';
import '../../core/media/music_track.dart';
import '../../core/media/path_display.dart';
import '../../core/media/path_matcher.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/playback_facade.dart';

/// Coordinates path changes that affect both the library and active playback.
final class AudioPathCoordinator {
  const AudioPathCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
  }) : _library = library,
       _playback = playback;

  final LibraryFacade _library;
  final PlaybackFacade _playback;

  MusicTrack? trackByPath(String trackPath) {
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    final libraryTrack = _library.trackByPath(resolvedPath);
    if (libraryTrack != null) return libraryTrack;
    for (final track in _library.library) {
      if (PathMatcher.equalsNormalized(track.path, trackPath) ||
          PathMatcher.equalsNormalized(track.path, resolvedPath)) {
        return track;
      }
    }
    for (final session in _playback.service.sessions.values) {
      final track = sessionTrackForPath(session.id, resolvedPath);
      if (track != null) return track;
    }
    return null;
  }

  MusicTrack? sessionTrackForPath(String sessionId, String trackPath) {
    final session = _playback.sessionById(sessionId);
    if (session == null) {
      return _library.trackByPath(_playback.resolveRetargetedPath(trackPath));
    }
    final resolvedPath = _playback.resolveRetargetedPath(trackPath);
    for (final track in session.customQueueTracks ?? const <MusicTrack>[]) {
      if (PathMatcher.equalsNormalized(track.path, trackPath) ||
          PathMatcher.equalsNormalized(
            _playback.resolveRetargetedPath(track.path),
            resolvedPath,
          )) {
        return track;
      }
    }
    return _library.trackByPath(resolvedPath);
  }

  List<MusicTrack> tracksInSameGroup(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null) return const <MusicTrack>[];
    final libraryTracks = _library.tracksInGroup(track.groupKey);
    if (libraryTracks.isNotEmpty) return libraryTracks;
    for (final session in _playback.service.sessions.values) {
      final queue = session.customQueueTracks;
      if (queue == null ||
          !queue.any(
            (candidate) =>
                PathMatcher.equalsNormalized(candidate.path, trackPath) ||
                PathMatcher.equalsNormalized(candidate.path, track.path) ||
                PathMatcher.equalsNormalized(
                  _playback.resolveRetargetedPath(candidate.path),
                  _playback.resolveRetargetedPath(trackPath),
                ),
          )) {
        continue;
      }
      return queue
          .where((candidate) => candidate.groupKey == track.groupKey)
          .toList(growable: false);
    }
    return const <MusicTrack>[];
  }

  List<MusicTrack> tracksInSameWork(String trackPath) {
    final track = trackByPath(trackPath);
    if (track == null) return const <MusicTrack>[];
    if (track.isSingle) return <MusicTrack>[track];
    if (track.remoteMetadataKind == 'asmr.one' ||
        PathMatcher.isRemoteUri(track.path)) {
      return tracksInSameGroup(trackPath);
    }
    final root = workRootForTrack(trackPath);
    if (root == null) return tracksInSameGroup(trackPath);
    final tracks = _library.library
        .where(
          (candidate) =>
              PathMatcher.isWithinOrEqual(candidate.path, root) ||
              PathMatcher.isWithinOrEqual(candidate.groupKey, root),
        )
        .toList(growable: false);
    if (tracks.isEmpty) return tracksInSameGroup(trackPath);
    tracks.sort(_library.compareTracks);
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

  Future<AudioDetailRenameResult> renameAudioDetailTarget(AudioDetail detail) =>
      renameAudioDetailTargetToName(detail, detail.workTitle);

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
