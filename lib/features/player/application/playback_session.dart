import 'dart:async';

import '../../../core/media/music_track.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_mode.dart';
import '../domain/playback_queue.dart';
import 'native_playback_bridge.dart';

class PlaybackSession {
  static const loadingIndicatorThreshold = Duration(milliseconds: 600);

  PlaybackSession({
    required this.id,
    required this.currentTrackPath,
    required this.loopMode,
    required this.nonSingleLoopMode,
    required this.volume,
    required this.createdAt,
    required this.state,
    this.lastPlayedAt,
    this.customQueueTracks,
    this.playbackQueue,
    this.currentQueueIndex = 0,
  });

  final String id;
  final DateTime createdAt;
  DateTime? lastPlayedAt;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  final StreamController<PlayerState> _stateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<Duration> _bufferedPositionController =
      StreamController<Duration>.broadcast();
  Timer? _loadingIndicatorTimer;
  bool _suppressTransientLoading = false;
  List<MusicTrack>? customQueueTracks;
  PlaybackQueueDefinition? playbackQueue;
  int currentQueueIndex;
  bool get isPlaybackQueue => playbackQueue != null;
  String currentTrackPath;
  String? loadedPath;
  String? _pendingNativeTrackPath;
  SessionLoopMode loopMode;
  SessionLoopMode nonSingleLoopMode;
  double volume;
  bool channelSwapEnabled = false;
  bool _isLoading = false;
  bool _isPlaybackStarting = false;
  int _loadGeneration = 0;
  int _playbackCommandGeneration = 0;
  int _transportCommandId = 0;
  bool? _pendingPlayingIntent;
  int _lastHandledCompletionGeneration = -1;
  bool _isAdvancingAfterCompletion = false;
  int? nativePlaybackQueueCacheKey;
  List<Map<String, Object?>>? nativePlaybackQueueCache;
  Duration lastKnownPosition = Duration.zero;
  Duration? duration;
  Duration bufferedPosition = Duration.zero;
  double speed = 1.0;
  AudioEffectsState audioEffects = AudioEffectsState.flat;
  NativeAudioEffects? pendingNativeAudioEffects;
  NativeAudioEffects? confirmedNativeAudioEffects;
  int audioEffectsSyncRevision = 0;
  Future<void>? audioEffectsSyncFuture;
  String audioEffectsSyncErrorLabel = 'setAudioEffects';
  EqCapabilities eqCapabilities = EqCapabilities.unsupported;
  double nativeBoostGain = 1.0;
  int lastPersistedPositionBucket = 0;
  PlayerState state;
  String? _playbackError;
  PlayerState? previousStateBeforeLastStateEvent;
  bool isDisposed = false;
  Future<void>? _shutdownFuture;

  String? get pendingNativeTrackPath => _pendingNativeTrackPath;
  bool get isLoading => _isLoading;
  bool get isPlaybackStarting => _isPlaybackStarting;
  int get loadGeneration => _loadGeneration;
  int get playbackCommandGeneration => _playbackCommandGeneration;
  int get transportCommandId => _transportCommandId;
  bool? get pendingPlayingIntent => _pendingPlayingIntent;
  int get lastHandledCompletionGeneration => _lastHandledCompletionGeneration;
  bool get isAdvancingAfterCompletion => _isAdvancingAfterCompletion;
  String? get playbackError => _playbackError;

  Stream<PlayerState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionController.stream;
  Duration get position => lastKnownPosition;
  bool get effectivePlaying => _pendingPlayingIntent ?? state.playing;
  bool get playbackRequested =>
      _pendingPlayingIntent ?? (_isPlaybackStarting || state.playing);
  bool get isPlaybackLoading {
    final processingState = state.processingState;
    return _isLoading ||
        (!_suppressTransientLoading &&
            (_isPlaybackStarting ||
                processingState == ProcessingState.loading ||
                processingState == ProcessingState.buffering));
  }

  bool get hasPendingAudioEffectsSync => pendingNativeAudioEffects != null;

  ({int generation, bool changed}) beginPreparation({
    required bool showLoading,
    required bool autoPlay,
  }) {
    if (isDisposed) return (generation: _loadGeneration, changed: false);
    final changed =
        (showLoading && !_isLoading) || (autoPlay && !_isPlaybackStarting);
    _loadGeneration++;
    if (showLoading) _isLoading = true;
    if (autoPlay) _isPlaybackStarting = true;
    return (generation: _loadGeneration, changed: changed);
  }

  bool isPreparationCurrent(int generation) =>
      !isDisposed && _loadGeneration == generation;

  bool markNativePreparation(int generation, String? path) {
    if (!isPreparationCurrent(generation) || _pendingNativeTrackPath == path) {
      return false;
    }
    _pendingNativeTrackPath = path;
    return true;
  }

  bool finishPreparation(
    int generation, {
    required bool prepared,
    required bool autoPlay,
    String? error,
  }) {
    if (!isPreparationCurrent(generation)) return false;
    final changed =
        _pendingNativeTrackPath != null ||
        _isLoading ||
        _isAdvancingAfterCompletion ||
        (!prepared && autoPlay && _isPlaybackStarting) ||
        (error != null && _playbackError != error);
    _pendingNativeTrackPath = null;
    _isLoading = false;
    _isAdvancingAfterCompletion = false;
    if (!prepared && autoPlay) _isPlaybackStarting = false;
    if (error != null) _playbackError = error;
    return changed;
  }

  bool cancelPlaybackStart(int generation) {
    if (!isPreparationCurrent(generation) || !_isPlaybackStarting) return false;
    _isPlaybackStarting = false;
    return true;
  }

  bool invalidatePreparation() {
    if (isDisposed) return false;
    _loadGeneration++;
    final changed =
        _isLoading ||
        _isPlaybackStarting ||
        _isAdvancingAfterCompletion ||
        _pendingNativeTrackPath != null;
    _isLoading = false;
    _isPlaybackStarting = false;
    _isAdvancingAfterCompletion = false;
    _pendingNativeTrackPath = null;
    return changed;
  }

  bool beginCompletionAdvance({
    required int commandGeneration,
    bool markHandled = false,
  }) {
    if (isDisposed ||
        commandGeneration != _playbackCommandGeneration ||
        (markHandled &&
            _lastHandledCompletionGeneration == commandGeneration)) {
      return false;
    }
    final changed = !_isLoading || !_isAdvancingAfterCompletion;
    _isLoading = true;
    _isAdvancingAfterCompletion = true;
    if (markHandled) _lastHandledCompletionGeneration = commandGeneration;
    return changed;
  }

  bool finishCompletionAdvance({
    required int commandGeneration,
    required int preparationGeneration,
    String? error,
  }) {
    // A new preparation may begin before it issues its transport command.
    if (!isPreparationCurrent(preparationGeneration) ||
        commandGeneration != _playbackCommandGeneration) {
      return false;
    }
    final changed =
        _isLoading ||
        _isAdvancingAfterCompletion ||
        (error != null && _playbackError != error);
    _isLoading = false;
    _isAdvancingAfterCompletion = false;
    if (error != null) _playbackError = error;
    return changed;
  }

  bool reconcilePlaybackState() {
    if (isDisposed) return false;
    var changed = false;
    if (!state.playing &&
        (state.processingState == ProcessingState.idle ||
            state.processingState == ProcessingState.completed)) {
      changed = _isPlaybackStarting;
      _isPlaybackStarting = false;
    }
    if (state.processingState != ProcessingState.completed) {
      changed = changed || _isAdvancingAfterCompletion;
      _isAdvancingAfterCompletion = false;
    }
    return changed;
  }

  bool confirmPaused() {
    if (isDisposed) return false;
    final changed = state.playing || _isLoading || _isPlaybackStarting;
    setOptimisticState(playing: false);
    _isLoading = false;
    _isPlaybackStarting = false;
    return changed;
  }

  bool applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    if (isDisposed) return false;
    if (snapshot.sessionId != id) return false;
    final snapshotCommandId = snapshot.transportCommandId;
    if (snapshotCommandId != null && snapshotCommandId < _transportCommandId) {
      return false;
    }
    if (snapshotCommandId == null && _pendingPlayingIntent != null) {
      return false;
    }
    if (snapshotCommandId != null && snapshotCommandId > _transportCommandId) {
      _transportCommandId = snapshotCommandId;
      _playbackCommandGeneration = snapshotCommandId;
      _pendingPlayingIntent = null;
      _isPlaybackStarting = false;
    }
    _playbackError = snapshot.error;
    final pendingIntent = _pendingPlayingIntent;
    final confirmsPendingIntent = pendingIntent == null
        ? false
        : pendingIntent
        ? snapshot.playWhenReady
        : !snapshot.playWhenReady;
    if (pendingIntent == true && snapshot.playWhenReady) {
      _isPlaybackStarting = false;
      _loadingIndicatorTimer?.cancel();
      _loadingIndicatorTimer = null;
      _suppressTransientLoading = false;
    }
    if (snapshot.error != null || confirmsPendingIntent) {
      _pendingPlayingIntent = null;
      _isPlaybackStarting = false;
      _loadingIndicatorTimer?.cancel();
      _loadingIndicatorTimer = null;
      _suppressTransientLoading = false;
    }
    final nativeProcessingState = _nativeProcessingState(
      snapshot.processingState,
    );
    var effectivePlaying = snapshot.playWhenReady;
    var effectiveProcessingState = nativeProcessingState;
    final nextState = PlayerState(effectivePlaying, effectiveProcessingState);
    if (state != nextState) {
      previousStateBeforeLastStateEvent = state;
      state = nextState;
      _stateController.add(state);
    }
    if (lastKnownPosition != snapshot.position) {
      lastKnownPosition = snapshot.position;
      _positionController.add(lastKnownPosition);
    }
    if (snapshot.duration != null && duration != snapshot.duration) {
      duration = snapshot.duration;
      _durationController.add(duration);
    }
    if (bufferedPosition != snapshot.bufferedPosition) {
      bufferedPosition = snapshot.bufferedPosition;
      _bufferedPositionController.add(bufferedPosition);
    }
    final nativePath = snapshot.path ?? _pathFromUri(snapshot.uri);
    if (nativePath != null && nativePath.isNotEmpty) {
      currentTrackPath = nativePath;
      loadedPath = nativePath;
    }
    currentQueueIndex = snapshot.queueIndex;
    if ((volume - snapshot.volume).abs() >= 0.001) {
      volume = snapshot.volume;
    }
    if ((speed - snapshot.speed).abs() >= 0.001) {
      speed = snapshot.speed;
    }
    if (!hasPendingAudioEffectsSync && snapshot.hasAudioEffectsPayload) {
      audioEffects = snapshot.audioEffects;
    }
    eqCapabilities = snapshot.eqCapabilities;
    nativeBoostGain = snapshot.boostGain;
    if (!hasPendingAudioEffectsSync && snapshot.hasChannelSwapPayload) {
      channelSwapEnabled = snapshot.channelSwapEnabled;
    }
    if (snapshot.uri != null && loadedPath == null) {
      loadedPath = currentTrackPath;
    }
    return true;
  }

  bool beginTransportCommand({
    required int commandId,
    required bool playing,
    Duration threshold = loadingIndicatorThreshold,
  }) {
    if (isDisposed || commandId < _transportCommandId) return false;
    final wasPlaybackLoading = isPlaybackLoading;
    final changed =
        _transportCommandId != commandId ||
        _pendingPlayingIntent != playing ||
        _isPlaybackStarting != playing ||
        _playbackError != null;
    _transportCommandId = commandId;
    _playbackCommandGeneration = commandId;
    _pendingPlayingIntent = playing;
    _isPlaybackStarting = playing;
    _playbackError = null;
    if (playing) {
      beginLoadingIndicatorThreshold(threshold: threshold);
    } else {
      _loadingIndicatorTimer?.cancel();
      _loadingIndicatorTimer = null;
      _suppressTransientLoading = false;
    }
    return changed || wasPlaybackLoading != isPlaybackLoading;
  }

  bool failTransportCommand(int commandId) {
    if (isDisposed || commandId != _transportCommandId) return false;
    final changed =
        _pendingPlayingIntent != null ||
        _isPlaybackStarting ||
        _suppressTransientLoading;
    _pendingPlayingIntent = null;
    _isPlaybackStarting = false;
    _loadingIndicatorTimer?.cancel();
    _loadingIndicatorTimer = null;
    _suppressTransientLoading = false;
    return changed;
  }

  void applyNativeProgress(NativePlaybackProgressUpdate progress) {
    if (isDisposed) return;
    if (progress.sessionId != id) return;
    if (lastKnownPosition != progress.position) {
      lastKnownPosition = progress.position;
      _positionController.add(lastKnownPosition);
    }
    if (progress.duration != null && duration != progress.duration) {
      duration = progress.duration;
      _durationController.add(duration);
    }
    if (bufferedPosition != progress.bufferedPosition) {
      bufferedPosition = progress.bufferedPosition;
      _bufferedPositionController.add(bufferedPosition);
    }
  }

  void setOptimisticState({bool? playing, ProcessingState? processingState}) {
    if (isDisposed) return;
    final nextState = PlayerState(
      playing ?? state.playing,
      processingState ?? state.processingState,
    );
    if (state == nextState) return;
    previousStateBeforeLastStateEvent = state;
    state = nextState;
    _stateController.add(state);
  }

  void setOptimisticPosition(Duration position) {
    if (isDisposed) return;
    lastKnownPosition = position;
    _positionController.add(position);
  }

  void beginLoadingIndicatorThreshold({
    Duration threshold = loadingIndicatorThreshold,
  }) {
    if (isDisposed) return;
    _loadingIndicatorTimer?.cancel();
    if (threshold <= Duration.zero) {
      _loadingIndicatorTimer = null;
      _suppressTransientLoading = false;
      return;
    }
    _suppressTransientLoading = true;
    _loadingIndicatorTimer = Timer(threshold, () {
      _loadingIndicatorTimer = null;
      if (isDisposed) return;
      _suppressTransientLoading = false;
      _stateController.add(state);
    });
  }

  void setOptimisticDuration(Duration? nextDuration) {
    if (isDisposed) return;
    if (duration == nextDuration) return;
    duration = nextDuration;
    _durationController.add(duration);
  }

  void resetStreamsForNewTrack() {
    if (isDisposed) return;
    lastKnownPosition = Duration.zero;
    _positionController.add(Duration.zero);
    duration = null;
    _durationController.add(null);
    bufferedPosition = Duration.zero;
    _bufferedPositionController.add(Duration.zero);
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();

  Future<void> _shutdown() async {
    invalidatePreparation();
    isDisposed = true;
    _loadingIndicatorTimer?.cancel();
    _loadingIndicatorTimer = null;
    final subscriptionsToCancel = subscriptions.toList(growable: false);
    subscriptions.clear();
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await Future.wait(
      subscriptionsToCancel.map((subscription) => attempt(subscription.cancel)),
    );
    await Future.wait(<Future<void>>[
      attempt(_stateController.close),
      attempt(_positionController.close),
      attempt(_durationController.close),
      attempt(_bufferedPositionController.close),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }
}

String? _pathFromUri(String? uriValue) {
  if (uriValue == null || uriValue.isEmpty) return null;
  final uri = Uri.tryParse(uriValue);
  if (uri == null) return uriValue;
  if (uri.scheme == 'file') {
    return uri.toFilePath(windows: false);
  }
  if (uri.scheme == 'content') return uriValue;
  if (uri.scheme == 'http' || uri.scheme == 'https') return uriValue;
  return null;
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
