import '../models/music_track.dart';
import '../models/playback_mode.dart';

abstract interface class PlaybackSessionLauncher {
  Future<void> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  });
}
