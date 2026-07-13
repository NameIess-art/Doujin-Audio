import '../../features/player/application/playback_session_launcher.dart';
import 'audio_provider.dart';

class AudioProviderPlaybackLauncher implements PlaybackSessionLauncher {
  const AudioProviderPlaybackLauncher(this._provider);

  final AudioProvider _provider;

  @override
  Future<void> launchQueue(
    List<MusicTrack> tracks, {
    bool? autoPlay,
    required SessionLoopMode loopMode,
  }) {
    return _provider.spawnSessionWithQueue(
      tracks,
      autoPlay: autoPlay,
      loopMode: loopMode,
    );
  }
}
