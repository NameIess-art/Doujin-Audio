part of 'audio_provider.dart';

extension AudioProviderNativeBridge on AudioProvider {
  void _handleNativePlaybackSnapshot(NativePlaybackSnapshot snapshot) {
    _playbackService.applyNativeSnapshot(snapshot);
  }
}
