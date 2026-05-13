import 'native_playback_bridge.dart';
import 'native_result.dart';

class NativePlaybackRepository {
  NativePlaybackRepository({NativePlaybackBridge? bridge})
    : _bridge = bridge ?? NativePlaybackBridge.instance;

  final NativePlaybackBridge _bridge;

  Stream<NativePlaybackSnapshot> get snapshots => _bridge.snapshots;

  void startListening() => _bridge.startListening();

  Future<void> stopListening() => _bridge.stopListening();

  Future<void> dispose() => _bridge.dispose();

  Future<NativeResult<NativePlaybackSnapshot>> prepareSession({
    required String sessionId,
    required Uri uri,
    required String title,
    String? path,
    String? subtitle,
    Uri? artUri,
    Duration startPosition = Duration.zero,
    double volume = 1.0,
    bool repeatOne = false,
    bool autoPlay = false,
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  }) {
    return _bridge.prepareSession(
      sessionId: sessionId,
      uri: uri,
      title: title,
      path: path,
      subtitle: subtitle,
      artUri: artUri,
      startPosition: startPosition,
      volume: volume,
      repeatOne: repeatOne,
      autoPlay: autoPlay,
      queue: queue,
      queueStartIndex: queueStartIndex,
      repeatAll: repeatAll,
      shuffle: shuffle,
    );
  }

  Future<NativeResult<NativePlaybackSnapshot>> play(String sessionId) {
    return _bridge.play(sessionId);
  }

  Future<NativeResult<NativePlaybackSnapshot>> pause(String sessionId) {
    return _bridge.pause(sessionId);
  }

  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) {
    return _bridge.stop(sessionId);
  }

  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) {
    return _bridge.seek(sessionId, position);
  }

  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume,
  ) {
    return _bridge.setVolume(sessionId, volume);
  }

  Future<NativeResult<NativePlaybackSnapshot>> setRepeatOne(
    String sessionId,
    bool repeatOne, {
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  }) {
    return _bridge.setRepeatOne(
      sessionId,
      repeatOne,
      queue: queue,
      queueStartIndex: queueStartIndex,
      repeatAll: repeatAll,
      shuffle: shuffle,
    );
  }

  Future<NativeResult<NativePlaybackSnapshot>> setChannelSwap(
    String sessionId,
    bool enabled,
  ) {
    return _bridge.setChannelSwap(sessionId, enabled);
  }

  Future<NativeResult<void>> removeSession(String sessionId) {
    return _bridge.removeSession(sessionId);
  }

  Future<NativeResult<void>> pauseAll() => _bridge.pauseAll();

  Future<NativeResult<void>> clearAll() => _bridge.clearAll();

  Future<NativeResult<void>> setForegroundEnabled(bool enabled) {
    return _bridge.setForegroundEnabled(enabled);
  }

  Future<NativeResult<void>> dismissNotifications() {
    return _bridge.dismissNotifications();
  }

  Future<NativeResult<void>> undismissNotifications() {
    return _bridge.undismissNotifications();
  }

  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() {
    return _bridge.snapshot();
  }
}
