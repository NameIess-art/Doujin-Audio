part of 'audio_provider.dart';

enum SessionLoopMode {
  single,
  crossRandom,
  folderSequential,
  crossSequential,
  folderRandom,
}

enum TimerMode { manual, trigger }

extension SessionLoopModeExtension on SessionLoopMode {
  String get label {
    switch (this) {
      case SessionLoopMode.single:
        return 'Single loop';
      case SessionLoopMode.crossRandom:
        return 'Shuffle (cross-folder)';
      case SessionLoopMode.folderSequential:
        return 'Sequential (current folder)';
      case SessionLoopMode.crossSequential:
        return 'Sequential (cross-folder)';
      case SessionLoopMode.folderRandom:
        return 'Shuffle (current folder)';
    }
  }
}

class MusicTrack {
  const MusicTrack({
    required this.path,
    required this.displayName,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
  });

  final String path;
  final String displayName;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;

  Map<String, dynamic> toJson() => {
    'path': path,
    'displayName': displayName,
    'groupKey': groupKey,
    'groupTitle': groupTitle,
    'groupSubtitle': groupSubtitle,
    'isSingle': isSingle,
  };

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
    path: json['path'] as String,
    displayName: json['displayName'] as String,
    groupKey: json['groupKey'] as String,
    groupTitle: json['groupTitle'] as String,
    groupSubtitle: json['groupSubtitle'] as String,
    isSingle: json['isSingle'] as bool? ?? false,
  );
}

abstract class LibraryNode {
  String get name;
  String get path;
}

class FolderNode extends LibraryNode {
  @override
  final String name;
  @override
  final String path;
  final int depth;
  final List<LibraryNode> children = [];
  List<MusicTrack>? _allTracksCache;
  MusicTrack? _firstTrackCache;
  int? _cachedTotalTrackCount;
  int? _cachedLeafFolderCount;

  FolderNode(this.name, this.path, {this.depth = 0});

  bool get isModuleNode {
    return depth == 0;
  }

  List<MusicTrack> get allTracks {
    final cached = _allTracksCache;
    if (cached != null) {
      return cached;
    }

    final list = <MusicTrack>[];
    for (final child in children) {
      if (child is TrackNode) {
        list.add(child.track);
      } else if (child is FolderNode) {
        list.addAll(child.allTracks);
      }
    }
    _allTracksCache = list;
    return list;
  }

  MusicTrack? get firstTrack {
    final cached = _firstTrackCache;
    if (cached != null) {
      return cached;
    }

    for (final child in children) {
      if (child is TrackNode) {
        _firstTrackCache = child.track;
        return child.track;
      }
      if (child is FolderNode) {
        final nested = child.firstTrack;
        if (nested != null) {
          _firstTrackCache = nested;
          return nested;
        }
      }
    }
    return null;
  }

  int get totalTrackCount {
    final cached = _cachedTotalTrackCount;
    if (cached != null) {
      return cached;
    }
    return allTracks.length;
  }

  int get leafFolderCount {
    final cached = _cachedLeafFolderCount;
    if (cached != null) {
      return cached;
    }
    if (!children.any((child) => child is FolderNode)) {
      return 1;
    }
    return children.whereType<FolderNode>().fold<int>(
      0,
      (sum, child) => sum + child.leafFolderCount,
    );
  }

  void cacheTreeMetrics({
    required int totalTrackCount,
    required int leafFolderCount,
    required MusicTrack? firstTrack,
  }) {
    _cachedTotalTrackCount = totalTrackCount;
    _cachedLeafFolderCount = leafFolderCount;
    _firstTrackCache = firstTrack;
  }
}

class TrackNode extends LibraryNode {
  final MusicTrack track;
  TrackNode(this.track);

  @override
  String get name => track.displayName;

  @override
  String get path => track.path;
}

class _LibraryTreeSnapshot {
  const _LibraryTreeSnapshot({
    required this.tree,
    required this.leafFolderCount,
  });

  final List<LibraryNode> tree;
  final int leafFolderCount;
}

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
    if (isPlaybackStarting &&
        !effectivePlaying &&
        snapshot.error == null) {
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
