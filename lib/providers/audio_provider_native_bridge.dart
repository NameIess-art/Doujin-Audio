part of 'audio_provider.dart';

extension AudioProviderNativeBridge on AudioProvider {
  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    final session = _sessions[snapshot.sessionId];
    if (session == null) return;
    session.applyNativeSnapshot(snapshot);
  }
}
