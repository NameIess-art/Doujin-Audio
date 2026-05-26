import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' as media;

import 'native_playback_bridge.dart';
import 'native_result.dart';
import 'path_matcher.dart';
import '../platform/app_platform.dart';

const String _channelSwapAudioFilter =
    '@channel_swap:lavfi=[pan=stereo|c0=c1|c1=c0]';
const String _channelSwapAudioFilterLabel = '@channel_swap';

class DartPlaybackBridge implements NativePlaybackBridgeBase {
  DartPlaybackBridge() {
    _ensureMediaKitInitialized();
  }

  static bool _mediaKitInitialized = false;

  static void _ensureMediaKitInitialized() {
    if (_mediaKitInitialized) return;
    media.MediaKit.ensureInitialized();
    _mediaKitInitialized = true;
  }

  final Map<String, _DartPlaybackSession> _sessions = {};
  final StreamController<NativePlaybackSnapshot> _snapshots =
      StreamController<NativePlaybackSnapshot>.broadcast();
  String? _focusedSessionId;

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _snapshots.stream;

  @override
  void startListening() {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {
    for (final session in _sessions.values) {
      await session.dispose();
    }
    _sessions.clear();
    await _snapshots.close();
  }

  @override
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
  }) async {
    if (uri.scheme == 'content') {
      return const NativeFailure(
        'Android content URI playback is not supported on Windows.',
      );
    }

    try {
      final session = _sessions.putIfAbsent(
        sessionId,
        () => _DartPlaybackSession(
          sessionId: sessionId,
          onChanged: () => _emit(sessionId),
        ),
      );
      _focusedSessionId = sessionId;
      final items = _itemsFor(
        uri: uri,
        title: title,
        path: path,
        subtitle: subtitle,
        artUri: artUri,
        queue: queue,
        queueStartIndex: queueStartIndex,
      );
      session.volume = _normalizeSessionVolume(volume);
      await session.setItems(
        items,
        initialIndex: queueStartIndex ?? 0,
        initialPosition: startPosition,
      );
      await _applyLoopAndShuffle(
        session,
        repeatOne: repeatOne,
        repeatAll: repeatAll,
        shuffle: shuffle,
      );
      if (autoPlay) {
        unawaited(_playSession(session));
      }
      return NativeSuccess(_emit(sessionId));
    } catch (error) {
      return NativeFailure(error.toString());
    }
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> play(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    _focusedSessionId = sessionId;
    unawaited(_playSession(session));
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.pause();
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.stop();
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.seek(position);
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.setVolume(volume, reloadSource: reloadSource);
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setRepeatOne(
    String sessionId,
    bool repeatOne, {
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await _applyLoopAndShuffle(
      session,
      repeatOne: repeatOne,
      repeatAll: repeatAll,
      shuffle: shuffle,
    );
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setChannelSwap(
    String sessionId,
    bool enabled,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    try {
      await session.setChannelSwapEnabled(enabled);
      return NativeSuccess(_snapshotFor(sessionId));
    } catch (error) {
      return NativeFailure(error.toString());
    }
  }

  @override
  Future<NativeResult<void>> removeSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (_focusedSessionId == sessionId) _focusedSessionId = null;
    await session?.dispose();
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> pauseAll() async {
    await Future.wait(_sessions.values.map((session) => session.pause()));
    for (final sessionId in _sessions.keys) {
      _emit(sessionId);
    }
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> clearAll() async {
    for (final session in _sessions.values) {
      await session.dispose();
    }
    _sessions.clear();
    _focusedSessionId = null;
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> setForegroundEnabled(bool enabled) async {
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> dismissNotifications() async {
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> undismissNotifications() async {
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() async {
    return NativeSuccess(
      NativePlaybackBundleSnapshot(
        sessions: _sessions.keys.map(_snapshotFor).toList(growable: false),
        focusedSessionId: _focusedSessionId,
      ),
    );
  }

  Future<void> _playSession(_DartPlaybackSession session) async {
    try {
      await session.play();
    } catch (error) {
      debugPrint('DartPlaybackBridge.play error: $error');
    } finally {
      if (_sessions.containsKey(session.sessionId)) {
        _emit(session.sessionId);
      }
    }
  }

  List<_DartPlaybackItem> _itemsFor({
    required Uri uri,
    required String title,
    required String? path,
    required String? subtitle,
    required Uri? artUri,
    required List<Map<String, Object?>>? queue,
    required int? queueStartIndex,
  }) {
    final queueItems = queue
        ?.map(_itemFromMap)
        .whereType<_DartPlaybackItem>()
        .toList(growable: false);
    if (queueItems != null && queueItems.isNotEmpty) {
      return queueItems;
    }
    return <_DartPlaybackItem>[
      _DartPlaybackItem(
        uri: uri,
        path: path ?? _pathFromUri(uri),
        title: title,
        subtitle: subtitle,
        artUri: artUri?.toString(),
      ),
    ];
  }

  _DartPlaybackItem? _itemFromMap(Map<String, Object?> map) {
    final rawUri = map['uri']?.toString();
    final uri = rawUri == null ? null : Uri.tryParse(rawUri);
    if (uri == null || uri.scheme == 'content') return null;
    final rawPath = map['path']?.toString();
    return _DartPlaybackItem(
      uri: uri,
      path: rawPath == null || rawPath.isEmpty ? _pathFromUri(uri) : rawPath,
      title: map['title']?.toString(),
      subtitle: map['subtitle']?.toString(),
      artUri: map['artUri']?.toString(),
    );
  }

  Future<void> _applyLoopAndShuffle(
    _DartPlaybackSession session, {
    required bool repeatOne,
    required bool repeatAll,
    required bool shuffle,
  }) async {
    await session.setPlaybackMode(
      repeatOne: repeatOne,
      repeatAll: repeatAll,
      shuffle: shuffle,
    );
  }

  NativePlaybackSnapshot _emit(String sessionId) {
    final snapshot = _snapshotFor(sessionId);
    if (!_snapshots.isClosed) {
      _snapshots.add(snapshot);
    }
    return snapshot;
  }

  NativePlaybackSnapshot _snapshotFor(String sessionId) {
    final session = _sessions[sessionId]!;
    final item = session.currentItem;
    return NativePlaybackSnapshot(
      sessionId: sessionId,
      uri: item?.uri.toString(),
      path: item?.path,
      title: item?.title,
      subtitle: item?.subtitle,
      artUri: item?.artUri,
      playing: session.playing,
      playWhenReady: session.playWhenReady,
      processingState: session.processingState,
      position: session.position,
      bufferedPosition: session.bufferedPosition,
      duration: session.duration,
      volume: session.volume,
      boostGain: _boostGainFor(session.volume),
      channelSwapEnabled: session.channelSwapEnabled,
    );
  }
}

class _DartPlaybackSession {
  _DartPlaybackSession({required this.sessionId, required this.onChanged}) {
    void bind<T>(Stream<T> stream, void Function(T value) update) {
      subscriptions.add(
        stream.listen(
          (value) {
            if (suppressPlaybackEvents) return;
            update(value);
            _notifyChanged();
          },
          onError: (e, st) {
            debugPrint('DartPlaybackSession stream error: $e\n$st');
            error = e.toString();
            _notifyChanged();
          },
        ),
      );
    }

    bind<bool>(player.stream.playing, (value) {
      playing = value;
      if (value) {
        playWhenReady = true;
        completed = false;
        error = null;
      }
    });
    bind<bool>(player.stream.completed, (value) {
      completed = value;
      if (value) {
        playing = false;
        playWhenReady = false;
      }
    });
    bind<bool>(player.stream.buffering, (value) => buffering = value);
    bind<Duration>(player.stream.position, (value) => position = value);
    bind<Duration>(player.stream.buffer, (value) => bufferedPosition = value);
    bind<Duration>(player.stream.duration, (value) {
      duration = value == Duration.zero ? null : value;
    });
    bind<media.Playlist>(player.stream.playlist, (value) {
      currentIndex = value.index.clamp(0, items.isEmpty ? 0 : items.length - 1);
    });
    bind<String>(player.stream.error, (value) {
      error = value;
      playing = false;
      playWhenReady = false;
      opening = false;
      debugPrint('DartPlaybackSession media_kit error: $value');
    });
  }

  final String sessionId;
  final VoidCallback onChanged;
  final media.Player player = media.Player();
  final List<StreamSubscription<dynamic>> subscriptions = [];
  List<_DartPlaybackItem> items = const <_DartPlaybackItem>[];
  int currentIndex = 0;
  double volume = 1.0;
  bool channelSwapEnabled = false;
  bool playing = false;
  bool playWhenReady = false;
  bool buffering = false;
  bool completed = false;
  bool opening = false;
  bool suppressPlaybackEvents = false;
  Duration position = Duration.zero;
  Duration bufferedPosition = Duration.zero;
  Duration? duration;
  String? error;

  Future<void> setVolume(double nextVolume, {bool reloadSource = true}) async {
    volume = _normalizeSessionVolume(nextVolume);
    await player.setVolume(volume * 100);
  }

  _DartPlaybackItem? get currentItem {
    if (items.isEmpty) return null;
    return items[currentIndex.clamp(0, items.length - 1)];
  }

  String get processingState {
    if (error != null) return 'idle';
    if (opening) return 'loading';
    if (completed) return 'completed';
    if (buffering) return 'buffering';
    if (items.isEmpty) return 'idle';
    return 'ready';
  }

  Future<void> setItems(
    List<_DartPlaybackItem> nextItems, {
    required int initialIndex,
    required Duration initialPosition,
  }) async {
    items = List.of(nextItems);
    if (items.isEmpty) {
      await stop();
      return;
    }

    opening = true;
    completed = false;
    error = null;
    currentIndex = initialIndex.clamp(0, items.length - 1);
    onChanged();

    try {
      await player.open(
        media.Playlist(
          items.map(_mediaFor).toList(growable: false),
          index: currentIndex,
        ),
        play: false,
      );
      await player.setVolume(volume * 100);
      await _applyChannelSwap();
      if (initialPosition > Duration.zero) {
        await player.seek(initialPosition);
      }
      position = initialPosition;
    } finally {
      opening = false;
      onChanged();
    }
  }

  Future<void> setChannelSwapEnabled(bool enabled) async {
    if (channelSwapEnabled == enabled) return;
    final previous = channelSwapEnabled;
    final previousPlaying = playing;
    final previousPlayWhenReady = playWhenReady;
    final previousBuffering = buffering;
    final previousCompleted = completed;
    final previousOpening = opening;
    final previousPosition = position;
    final previousBufferedPosition = bufferedPosition;
    final previousDuration = duration;
    final previousError = error;

    void restorePlaybackState() {
      playing = previousPlaying;
      playWhenReady = previousPlayWhenReady;
      buffering = previousBuffering;
      completed = previousCompleted;
      opening = previousOpening;
      position = previousPosition;
      bufferedPosition = previousBufferedPosition;
      duration = previousDuration;
      error = previousError;
    }

    channelSwapEnabled = enabled;
    suppressPlaybackEvents = true;
    try {
      await _applyChannelSwap();
      restorePlaybackState();
    } catch (_) {
      channelSwapEnabled = previous;
      await _applyChannelSwap();
      restorePlaybackState();
      rethrow;
    } finally {
      scheduleMicrotask(() {
        suppressPlaybackEvents = false;
      });
    }
  }

  void _notifyChanged() {
    onChanged();
  }

  Future<void> setPlaybackMode({
    required bool repeatOne,
    required bool repeatAll,
    required bool shuffle,
  }) async {
    await player.setPlaylistMode(
      repeatOne
          ? media.PlaylistMode.single
          : repeatAll
          ? media.PlaylistMode.loop
          : media.PlaylistMode.none,
    );
    await player.setShuffle(shuffle);
  }

  Future<void> play() async {
    playWhenReady = true;
    completed = false;
    error = null;
    onChanged();
    await player.play();
  }

  Future<void> pause() async {
    playWhenReady = false;
    await player.pause();
    playing = false;
    onChanged();
  }

  Future<void> stop() async {
    playWhenReady = false;
    playing = false;
    buffering = false;
    completed = false;
    opening = false;
    position = Duration.zero;
    bufferedPosition = Duration.zero;
    duration = null;
    items = const <_DartPlaybackItem>[];
    currentIndex = 0;
    await player.stop();
    onChanged();
  }

  Future<void> seek(Duration nextPosition) async {
    final shouldResume = playWhenReady || playing;
    completed = false;
    position = nextPosition;
    onChanged();
    await player.seek(nextPosition);
    if (shouldResume) {
      playWhenReady = true;
      await player.play();
    }
  }

  media.Media _mediaFor(_DartPlaybackItem item) {
    final itemPath = item.path;
    if (itemPath == null || PathMatcher.isRemoteUri(itemPath)) {
      return media.Media(item.uri.toString());
    }
    return media.Media(itemPath);
  }

  Future<void> _applyChannelSwap() async {
    final platform = player.platform;
    if (platform is media.NativePlayer) {
      await platform.command([
        'af',
        channelSwapEnabled ? 'add' : 'remove',
        channelSwapEnabled
            ? _channelSwapAudioFilter
            : _channelSwapAudioFilterLabel,
      ]);
    }
  }

  Future<void> dispose() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await player.dispose();
  }
}

double _normalizeSessionVolume(double volume) {
  return volume.clamp(0.0, 2.0);
}

double _boostGainFor(double volume) {
  return _normalizeSessionVolume(volume).clamp(1.0, 2.0);
}

class _DartPlaybackItem {
  const _DartPlaybackItem({
    required this.uri,
    this.path,
    this.title,
    this.subtitle,
    this.artUri,
  });

  final Uri uri;
  final String? path;
  final String? title;
  final String? subtitle;
  final String? artUri;
}

String? _pathFromUri(Uri uri) {
  if (uri.scheme == 'file') {
    return uri.toFilePath(windows: isWindowsDriveFileUri(uri));
  }
  if (PathMatcher.isRemoteUri(uri.toString())) return uri.toString();
  return null;
}
