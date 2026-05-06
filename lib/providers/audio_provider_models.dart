part of 'audio_provider.dart';

class PlaybackSession {
  PlaybackSession({
    required this.id,
    required this.currentTrackPath,
    required this.loopMode,
    required this.nonSingleLoopMode,
    required this.volume,
    required this.createdAt,
    required this.state,
  });

  final String id;
  final DateTime createdAt;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  final StreamController<PlayerState> _stateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<Duration> _bufferedPositionController =
      StreamController<Duration>.broadcast();
  String currentTrackPath;
  String? loadedPath;
  SessionLoopMode loopMode;
  SessionLoopMode nonSingleLoopMode;
  double volume;
  bool channelSwapEnabled = false;
  bool isLoading = false;
  bool isPlaybackStarting = false;
  int loadGeneration = 0;
  int playbackCommandGeneration = 0;
  int lastHandledCompletionGeneration = -1;
  bool isAdvancingAfterCompletion = false;
  Duration lastKnownPosition = Duration.zero;
  Duration? duration;
  Duration bufferedPosition = Duration.zero;
  double speed = 1.0;
  int lastPersistedPositionBucket = 0;
  PlayerState state;
  PlayerState? _previousStateBeforeLastStateEvent;

  Stream<PlayerState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionController.stream;
  Duration get position => lastKnownPosition;

  void applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    if (snapshot.sessionId != id) return;
    // Once native confirms playback, clear the startup guard so
    // subsequent legitimate pause/stop events are not suppressed.
    if (isPlaybackStarting && snapshot.playing) {
      isPlaybackStarting = false;
    }
    var effectivePlaying = snapshot.playing;
    if (isPlaybackStarting && !effectivePlaying && snapshot.error == null) {
      effectivePlaying = true;
    }
    final nextState = PlayerState(
      effectivePlaying,
      _nativeProcessingState(snapshot.processingState),
    );
    if (state != nextState) {
      _previousStateBeforeLastStateEvent = state;
      state = nextState;
      _stateController.add(state);
    }
    if (lastKnownPosition != snapshot.position) {
      lastKnownPosition = snapshot.position;
      _positionController.add(lastKnownPosition);
    }
    if (duration != snapshot.duration) {
      duration = snapshot.duration;
      _durationController.add(duration);
    }
    if (bufferedPosition != snapshot.bufferedPosition) {
      bufferedPosition = snapshot.bufferedPosition;
      _bufferedPositionController.add(bufferedPosition);
    }
    if ((volume - snapshot.volume).abs() >= 0.001) {
      volume = snapshot.volume;
    }
    channelSwapEnabled = snapshot.channelSwapEnabled;
    if (snapshot.uri != null) {
      loadedPath = currentTrackPath;
    }
  }

  void setOptimisticState({bool? playing, ProcessingState? processingState}) {
    final nextState = PlayerState(
      playing ?? state.playing,
      processingState ?? state.processingState,
    );
    if (state == nextState) return;
    _previousStateBeforeLastStateEvent = state;
    state = nextState;
    _stateController.add(state);
  }

  void setOptimisticPosition(Duration position) {
    lastKnownPosition = position;
    _positionController.add(position);
  }

  void resetStreamsForNewTrack() {
    lastKnownPosition = Duration.zero;
    _positionController.add(Duration.zero);
    duration = null;
    _durationController.add(null);
    bufferedPosition = Duration.zero;
    _bufferedPositionController.add(Duration.zero);
  }

  void dispose() {
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
    subscriptions.clear();
    _stateController.close();
    _positionController.close();
    _durationController.close();
    _bufferedPositionController.close();
  }
}

ProcessingState _nativeProcessingState(String state) {
  switch (state) {
    case 'buffering':
      return ProcessingState.buffering;
    case 'ready':
      return ProcessingState.ready;
    case 'completed':
      return ProcessingState.completed;
    case 'idle':
      return ProcessingState.idle;
    case 'loading':
      return ProcessingState.loading;
    default:
      return ProcessingState.idle;
  }
}
