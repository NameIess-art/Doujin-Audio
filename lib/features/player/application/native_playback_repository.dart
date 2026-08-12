import 'native_playback_bridge.dart';
import '../../../core/errors/native_result.dart';
import '../domain/audio_effects.dart';

class NativePlaybackRepository {
  NativePlaybackRepository({NativePlaybackBridgeBase? bridge})
    : _bridge = bridge ?? NativePlaybackBridge.instance;

  final NativePlaybackBridgeBase _bridge;

  Stream<NativePlaybackSnapshot> get snapshots => _bridge.snapshots;

  Stream<NativePlaybackProgressUpdate> get progressUpdates =>
      _bridge.progressUpdates;

  bool get supportsDeferredSessionRegistration =>
      _bridge.supportsDeferredSessionRegistration;

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
    double speed = 1.0,
    NativeAudioEffects? audioEffects,
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
    List<Uri>? candidateUris,
    bool deferPlayerCreation = false,
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
      speed: speed,
      audioEffects: audioEffects,
      queue: queue,
      queueStartIndex: queueStartIndex,
      repeatAll: repeatAll,
      shuffle: shuffle,
      candidateUris: candidateUris,
      deferPlayerCreation: deferPlayerCreation,
    );
  }

  Future<NativeResult<NativePlaybackSnapshot>> play(
    String sessionId, {
    int transportCommandId = 0,
    bool exclusive = false,
  }) {
    return _bridge.play(
      sessionId,
      transportCommandId: transportCommandId,
      exclusive: exclusive,
    );
  }

  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) {
    return _bridge.pause(sessionId, transportCommandId: transportCommandId);
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
    double volume, {
    bool reloadSource = true,
  }) {
    return _bridge.setVolume(sessionId, volume, reloadSource: reloadSource);
  }

  Future<NativeResult<NativePlaybackSnapshot>> setSpeed(
    String sessionId,
    double speed,
  ) {
    return _bridge.setSpeed(sessionId, speed);
  }

  Future<NativeResult<NativePlaybackSnapshot>> setTemporarySpeed(
    String sessionId,
    double? speed,
  ) {
    return _bridge.setTemporarySpeed(sessionId, speed);
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

  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) {
    return _bridge.setAudioEffects(sessionId, effects);
  }

  Future<NativeResult<NativePlaybackSnapshot>> setFadeMultiplier(
    String sessionId,
    double multiplier,
  ) {
    return _bridge.setFadeMultiplier(sessionId, multiplier);
  }

  Future<NativeResult<void>> removeSession(String sessionId) {
    return _bridge.removeSession(sessionId);
  }

  Future<NativeResult<void>> pauseAll() => _bridge.pauseAll();

  Future<NativeResult<void>> clearAll() => _bridge.clearAll();

  Future<NativeResult<void>> setForegroundEnabled(bool enabled) {
    return _bridge.setForegroundEnabled(enabled);
  }

  Future<NativeResult<void>> setPlaybackBehavior({
    required bool pauseOnAudioDeviceDisconnect,
    required bool requestAudioFocus,
    required bool pauseOnTransientAudioFocusLoss,
    required bool resumeAfterTransientAudioFocusGain,
    required bool resumePlaybackOnStartupRestore,
  }) {
    return _bridge.setPlaybackBehavior(
      pauseOnAudioDeviceDisconnect: pauseOnAudioDeviceDisconnect,
      requestAudioFocus: requestAudioFocus,
      pauseOnTransientAudioFocusLoss: pauseOnTransientAudioFocusLoss,
      resumeAfterTransientAudioFocusGain: resumeAfterTransientAudioFocusGain,
      resumePlaybackOnStartupRestore: resumePlaybackOnStartupRestore,
    );
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
