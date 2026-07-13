import '../../../core/media/music_track.dart';
import '../domain/playback_mode.dart';

abstract interface class PlaybackSessionLauncher {
  Future<void> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  });
}
