import '../domain/asmr_models.dart';
import '../../../core/media/music_track.dart';
import '../../player/domain/playback_mode.dart';
import '../../player/application/playback_session_launcher.dart';

abstract interface class AsmrPlaybackSource {
  Future<List<MusicTrack>> loadPlayableTracks(AsmrWork work);

  Future<List<MusicTrack>> loadPlayableTracksStartingAt(
    AsmrWork work,
    AsmrTrackFile target,
  );

  Future<void> recordHistory(AsmrWork work);
}

class AsmrPlaybackCoordinator {
  const AsmrPlaybackCoordinator({
    required AsmrPlaybackSource source,
    required PlaybackSessionLauncher launcher,
  }) : _source = source,
       _launcher = launcher;

  final AsmrPlaybackSource _source;
  final PlaybackSessionLauncher _launcher;

  Future<void> playWork(AsmrWork work, {bool? autoPlay}) async {
    final tracks = await _source.loadPlayableTracks(work);
    await _launch(work, tracks, autoPlay: autoPlay);
  }

  Future<void> playTrack(
    AsmrWork work,
    AsmrTrackFile target, {
    bool? autoPlay,
  }) async {
    final tracks = await _source.loadPlayableTracksStartingAt(work, target);
    await _launch(work, tracks, autoPlay: autoPlay);
  }

  Future<void> _launch(
    AsmrWork work,
    List<MusicTrack> tracks, {
    bool? autoPlay,
  }) async {
    if (tracks.isEmpty) {
      return;
    }
    await _source.recordHistory(work);
    await _launcher.launchQueue(
      tracks,
      autoPlay: autoPlay,
      loopMode: tracks.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
  }
}
