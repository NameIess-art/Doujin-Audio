import '../../../core/media/music_track.dart';
import '../domain/playback_mode.dart';
import 'playback_facade.dart';

abstract interface class PlaybackSessionLauncher {
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  });
}

final class PlaybackFacadeSessionLauncher implements PlaybackSessionLauncher {
  const PlaybackFacadeSessionLauncher(this._facade);

  final PlaybackFacade _facade;

  @override
  Future<bool> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) {
    return _facade.launchQueue(tracks, autoPlay: autoPlay, loopMode: loopMode);
  }
}
