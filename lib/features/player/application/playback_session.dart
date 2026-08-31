import 'dart:async';

import 'package:just_audio/just_audio.dart';

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
  String? pendingNativeTrackPath;
  SessionLoopMode loopMode;
  SessionLoopMode nonSingleLoopMode;
  double volume;
  bool channelSwapEnabled = false;
  bool isLoading = false;
  bool isPlaybackStarting = false;
  int loadGeneration = 0;
  int playbackCommandGeneration = 0;
  int transportCommandId = 0;
  bool? pendingPlayingIntent;
  int lastHandledCompletionGeneration = -1;
  bool isAdvancingAfterCompletion = false;
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
  String? playbackError;
  PlayerState? previousStateBeforeLastStateEvent;
  bool isDisposed = false;
  Future<void>? _shutdownFuture;

  Stream<PlayerState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionController.stream;
  Duration get position => lastKnownPosition;
  bool get effectivePlaying => pendingPlayingIntent ?? state.playing;
  bool get playbackRequested =>
      pendingPlayingIntent ?? (isPlaybackStarting || state.playing);
  bool get isPlaybackLoading {
    final processingState = state.processingState;
    return isLoading ||
        (!_suppressTransientLoading &&
            (isPlaybackStarting ||
                processingState == ProcessingState.loading ||
                processingState == ProcessingState.buffering));
  }

  bool get hasPendingAudioEffectsSync => pendingNativeAudioEffects != null;

  bool applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    if (isDisposed) return false;
    if (snapshot.sessionId != id) return false;
    final snapshotCommandId = snapshot.transportCommandId;
    if (snapshotCommandId != null && snapshotCommandId < transportCommandId) {
      return false;
    }
    if (snapshotCommandId == null && pendingPlayingIntent != null) {
      return false;
    }
    if (snapshotCommandId != null && snapshotCommandId > transportCommandId) {
      transportCommandId = snapshotCommandId;
      playbackCommandGeneration = snapshotCommandId;
      pendingPlayingIntent = null;
      isPlaybackStarting = false;
    }
    playbackError = snapshot.error;
    final pendingIntent = pendingPlayingIntent;
    final confirmsPendingIntent = pendingIntent == null
        ? false
        : pendingIntent
        ? snapshot.playWhenReady
        : !snapshot.playWhenReady;
    if (pendingIntent == true && snapshot.playWhenReady) {
      isPlaybackStarting = false;
    }
    if (snapshot.error != null || confirmsPendingIntent) {
      pendingPlayingIntent = null;
      isPlaybackStarting = false;
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

  void beginTransportCommand({required int commandId, required bool playing}) {
    if (commandId < transportCommandId) return;
    transportCommandId = commandId;
    playbackCommandGeneration = commandId;
    pendingPlayingIntent = playing;
    isPlaybackStarting = playing;
    playbackError = null;
  }

  bool failTransportCommand(int commandId) {
    if (commandId != transportCommandId) return false;
    pendingPlayingIntent = null;
    isPlaybackStarting = false;
    return true;
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
