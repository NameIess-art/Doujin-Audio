import 'dart:async';

import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/immutable_collections.dart';
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
    List<MusicTrack>? customQueueTracks,
    PlaybackQueueDefinition? playbackQueue,
    this.currentQueueIndex = 0,
    this.isTemporary = false,
  }) : _customQueueTracks = customQueueTracks == null
           ? null
           : immutableList(customQueueTracks),
       _playbackQueue = playbackQueue;

  final String id;
  bool isTemporary;
  bool retainInNowPlaying = false;
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
  int _queueVersion = 0;
  int get queueVersion => _queueVersion;

  Map<String, MusicTrack>? _trackPathMap;

  List<MusicTrack>? _customQueueTracks;
  List<MusicTrack>? get customQueueTracks => _customQueueTracks;
  set customQueueTracks(List<MusicTrack>? tracks) {
    _customQueueTracks = tracks == null ? null : immutableList(tracks);
    _queueVersion++;
    _trackPathMap = null;
    nativePlaybackQueueCacheKey = null;
    nativePlaybackQueueCache = null;
  }

  PlaybackQueueDefinition? _playbackQueue;
  PlaybackQueueDefinition? get playbackQueue => _playbackQueue;
  set playbackQueue(PlaybackQueueDefinition? queue) {
    if (_playbackQueue == queue) return;
    _playbackQueue = queue;
    _queueVersion++;
    _trackPathMap = null;
    nativePlaybackQueueCacheKey = null;
    nativePlaybackQueueCache = null;
  }

  Map<String, MusicTrack> get _trackMap {
    final existing = _trackPathMap;
    if (existing != null) return existing;
    final map = <String, MusicTrack>{};
    for (final track in _customQueueTracks ?? const <MusicTrack>[]) {
      map[PathMatcher.normalize(track.path)] = track;
    }
    final queue = _playbackQueue;
    if (queue != null) {
      for (final entry in queue.entries) {
        for (final track in entry.tracks) {
          map.putIfAbsent(PathMatcher.normalize(track.path), () => track);
        }
      }
    }
    return _trackPathMap = map;
  }

  MusicTrack? trackForPath(String trackPath, {String? resolvedPath}) {
    if (trackPath.isEmpty) return null;
    final map = _trackMap;
    final normalized = PathMatcher.normalize(trackPath);
    final direct = map[normalized];
    if (direct != null) return direct;
    if (resolvedPath != null && resolvedPath.isNotEmpty && resolvedPath != trackPath) {
      final resolvedNormalized = PathMatcher.normalize(resolvedPath);
      final resolved = map[resolvedNormalized];
      if (resolved != null) return resolved;
    }
    return null;
  }
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
    return !_suppressTransientLoading &&
        (_isLoading ||
            _isPlaybackStarting ||
            processingState == ProcessingState.loading ||
            processingState == ProcessingState.buffering);
  }

  bool get hasPendingAudioEffectsSync => pendingNativeAudioEffects != null;

  ({int generation, bool changed}) beginPreparation({
    required bool showLoading,
    required bool autoPlay,
  }) {
    if (isDisposed) return (generation: _loadGeneration, changed: false);
    final wasPlaybackLoading = isPlaybackLoading;
    final changed =
        (showLoading && !_isLoading) || (autoPlay && !_isPlaybackStarting);
    _loadGeneration++;
    if (showLoading) _isLoading = true;
    if (autoPlay) _isPlaybackStarting = true;
    if (showLoading || autoPlay) beginLoadingIndicatorThreshold();
    return (
      generation: _loadGeneration,
      changed: changed || wasPlaybackLoading != isPlaybackLoading,
    );
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
    beginLoadingIndicatorThreshold();
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
    final nativeProcessingState = _nativeProcessingState(
      snapshot.processingState,
    );
    final pendingIntent = _pendingPlayingIntent;
    final confirmsPendingIntent = pendingIntent == null
        ? false
        : pendingIntent
        ? snapshot.playWhenReady
        : !snapshot.playWhenReady;
    if (snapshot.error != null || confirmsPendingIntent) {
      _pendingPlayingIntent = null;
      _isPlaybackStarting = false;
    }
    if (snapshot.error != null ||
        (confirmsPendingIntent && pendingIntent == false)) {
      _loadingIndicatorTimer?.cancel();
      _loadingIndicatorTimer = null;
      _suppressTransientLoading = false;
    }
    var effectivePlaying = snapshot.playWhenReady;
    if (effectivePlaying) retainInNowPlaying = false;
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
      if (isPlaybackLoading) {
        _stateController.add(state);
      }
    });
  }

  void setOptimisticDuration(Duration? nextDuration) {
    if (isDisposed) return;
    if (duration == nextDuration) return;
    duration = nextDuration;
    _durationController.add(duration);
  }

  void resetStreamsForNewTrack({Duration position = Duration.zero}) {
    if (isDisposed) return;
    lastKnownPosition = position;
    _positionController.add(position);
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
