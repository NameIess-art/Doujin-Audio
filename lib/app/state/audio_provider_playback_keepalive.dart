part of 'audio_provider.dart';

extension AudioProviderPlaybackKeepAlive on AudioProvider {
  bool get _hasPlayingSession => _keepAliveCoordinator.hasPlayingSession;

  bool get _hasPlaybackToKeepAlive =>
      _keepAliveCoordinator.hasPlaybackToKeepAlive;

  void _syncKeepCpuAwake() {
    _keepAliveCoordinator.sync();
  }

  void syncKeepAliveBeforeBackground() {
    _keepAliveCoordinator.enterBackground();
  }

  void syncKeepAliveAfterForegroundResume() {
    _keepAliveCoordinator.resumeForeground();
  }

  Future<bool> _activateAudioSessionForPlayback() async {
    return _keepAliveCoordinator.activateAudioSession();
  }

}
