import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'music_track.dart';
import '../services/native_playback_bridge.dart';
import 'playback_mode.dart';

class PlaybackSession {
  PlaybackSession({
    required this.id,
    required this.currentTrackPath,
    required this.loopMode,
    required this.nonSingleLoopMode,
    required this.volume,
    required this.createdAt,
    required this.state,
    this.customQueueTracks,
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
  final List<MusicTrack>? customQueueTracks;
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
  double nativeBoostGain = 1.0;
  int lastPersistedPositionBucket = 0;
  PlayerState state;
  PlayerState? previousStateBeforeLastStateEvent;

  Stream<PlayerState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;
  Stream<Duration> get bufferedPositionStream =>
      _bufferedPositionController.stream;
  Duration get position => lastKnownPosition;

  void applyNativeSnapshot(NativePlaybackSnapshot snapshot) {
    if (snapshot.sessionId != id) return;
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
      previousStateBeforeLastStateEvent = state;
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
    final nativePath = snapshot.path ?? _pathFromUri(snapshot.uri);
    if (nativePath != null && nativePath.isNotEmpty) {
      currentTrackPath = nativePath;
      loadedPath = nativePath;
    }
    if ((volume - snapshot.volume).abs() >= 0.001) {
      volume = snapshot.volume;
    }
    nativeBoostGain = snapshot.boostGain;
    channelSwapEnabled = snapshot.channelSwapEnabled;
    if (snapshot.uri != null && loadedPath == null) {
      loadedPath = currentTrackPath;
    }
  }

  void setOptimisticState({bool? playing, ProcessingState? processingState}) {
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
    lastKnownPosition = position;
    _positionController.add(position);
  }

  void setOptimisticDuration(Duration? nextDuration) {
    if (duration == nextDuration) return;
    duration = nextDuration;
    _durationController.add(duration);
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

String? _pathFromUri(String? uriValue) {
  if (uriValue == null || uriValue.isEmpty) return null;
  final uri = Uri.tryParse(uriValue);
  if (uri == null) return uriValue;
  if (uri.scheme == 'file') return uri.toFilePath(windows: false);
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

class TimerInfo {
  const TimerInfo({
    this.duration,
    this.remaining,
    this.active = false,
    this.mode,
  });

  final Duration? duration;
  final Duration? remaining;
  final bool active;
  final TimerMode? mode;
}

class ScanInfo {
  const ScanInfo({
    this.isScanning = false,
    this.isBackgroundScanning = false,
    this.currentFolder = '',
    this.foundCount = 0,
    this.duplicateCount = 0,
    this.failureCount = 0,
  });

  final bool isScanning;
  final bool isBackgroundScanning;
  final String currentFolder;
  final int foundCount;
  final int duplicateCount;
  final int failureCount;
}
