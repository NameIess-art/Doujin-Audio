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

  Future<MusicTrack?> loadPlayableTrack(AsmrWork work, AsmrTrackFile target);

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

  Future<bool> playDirectTrack(AsmrWork work, AsmrTrackFile target) async {
    // Pass the pending load to the launcher so a later local or remote click
    // supersedes this request before its network work completes.
    final started = await _launcher.playDirect(
      _source.loadPlayableTracksStartingAt(work, target),
    );
    if (started) await _source.recordHistory(work);
    return started;
  }

  Future<bool> addTrackToPlaylist(AsmrWork work, AsmrTrackFile target) async {
    final track = await _source.loadPlayableTrack(work, target);
    if (track == null) throw StateError('The selected media is unavailable.');
    return _launcher.addTrackToPlaylist(track);
  }

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

  Future<void> playTracks(
    AsmrWork work,
    List<MusicTrack> tracks, {
    bool? autoPlay,
  }) => _launch(work, tracks, autoPlay: autoPlay);

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
