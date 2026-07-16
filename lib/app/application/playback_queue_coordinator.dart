import '../../core/media/music_track.dart';
import '../../core/media/path_matcher.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/playback_facade.dart';

/// Coordinates queue commands that need both library grouping and playback.
final class PlaybackQueueCoordinator {
  const PlaybackQueueCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
  }) : _library = library,
       _playback = playback;

  final LibraryFacade _library;
  final PlaybackFacade _playback;

  Future<void> addWork(String sessionId, MusicTrack track) async {
    if (track.isSingle) {
      await _playback.addTrackToPlaybackQueue(sessionId, track);
      return;
    }

    final groupTracks = _library.tracksInGroup(track.groupKey);
    final workRootPath = _workRootPath(track);
    final workTracks = workRootPath == null
        ? const <MusicTrack>[]
        : (_library.library
              .where(
                (candidate) =>
                    PathMatcher.isWithinOrEqual(candidate.path, workRootPath) ||
                    PathMatcher.isWithinOrEqual(
                      candidate.groupKey,
                      workRootPath,
                    ),
              )
              .toList(growable: false)
            ..sort(_library.compareTracks));
    final tracks = workTracks.isNotEmpty ? workTracks : groupTracks;
    if (tracks.isEmpty) return;

    await _playback.addWorkToPlaybackQueue(
      sessionId,
      title: track.groupTitle,
      tracks: tracks,
      workRootPath: workRootPath ?? _normalizedGroupPath(track),
    );
  }

  String? _workRootPath(MusicTrack track) {
    if (PathMatcher.isRemoteUri(track.path)) return null;
    final path = _library.audioDetailTargetForTrack(track).targetPath;
    return path.isEmpty ? null : PathMatcher.normalize(path);
  }

  String? _normalizedGroupPath(MusicTrack track) {
    final groupKey = track.groupKey.trim();
    if (groupKey.isEmpty || groupKey == '__single_files__') return null;
    return PathMatcher.normalize(groupKey);
  }
}
