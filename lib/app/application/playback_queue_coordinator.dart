import '../../core/media/music_track.dart';
import '../../features/player/application/playback_facade.dart';
import 'audio_path_coordinator.dart';

/// Coordinates queue commands that need both library grouping and playback.
final class PlaybackQueueCoordinator {
  const PlaybackQueueCoordinator({
    required PlaybackFacade playback,
    required AudioPathCoordinator paths,
  }) : _playback = playback,
       _paths = paths;

  final PlaybackFacade _playback;
  final AudioPathCoordinator _paths;

  Future<void> addWork(String sessionId, MusicTrack track) async {
    if (track.isSingle) {
      await _playback.addTrackToPlaybackQueue(sessionId, track);
      return;
    }

    final workRootPath = _paths.workRootForTrack(track.path);
    final tracks = _paths.tracksInSameWork(track.path);
    if (tracks.isEmpty) return;

    await _playback.addWorkToPlaybackQueue(
      sessionId,
      title: track.groupTitle,
      tracks: tracks,
      workRootPath: workRootPath,
    );
  }
}
