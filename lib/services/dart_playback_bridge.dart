import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'native_playback_bridge.dart';
import 'native_result.dart';
import 'path_matcher.dart';

class DartPlaybackBridge implements NativePlaybackBridgeBase {
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
      await session.setItems(
        items,
        initialIndex: 0,
        initialPosition: startPosition,
      );
      session.volume = volume;
      await session.player.setVolume(volume.clamp(0.0, 1.0));
      await _applyLoopAndShuffle(
        session.player,
        repeatOne: repeatOne,
        repeatAll: false,
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
    await session.player.pause();
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.player.stop();
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    await session.player.seek(position);
    return NativeSuccess(_emit(sessionId));
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return NativeFailure('Unknown session: $sessionId');
    session.volume = volume;
    await session.player.setVolume(volume.clamp(0.0, 1.0));
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
      session.player,
      repeatOne: repeatOne,
      repeatAll: false,
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
    session.channelSwapEnabled = enabled;
    return NativeSuccess(_emit(sessionId));
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
    await Future.wait(
      _sessions.values.map((session) => session.player.pause()),
    );
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
      await session.player.play();
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
      final selectedIndex = (queueStartIndex ?? 0).clamp(
        0,
        queueItems.length - 1,
      );
      return <_DartPlaybackItem>[queueItems[selectedIndex]];
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
    AudioPlayer player, {
    required bool repeatOne,
    required bool repeatAll,
    required bool shuffle,
  }) async {
    await player.setLoopMode(
      repeatOne ? LoopMode.one : (repeatAll ? LoopMode.all : LoopMode.off),
    );
    await player.setShuffleModeEnabled(shuffle);
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
    final player = session.player;
    final item = session.currentItem;
    return NativePlaybackSnapshot(
      sessionId: sessionId,
      uri: item?.uri.toString(),
      path: item?.path,
      title: item?.title,
      subtitle: item?.subtitle,
      artUri: item?.artUri,
      playing: player.playing,
      playWhenReady: player.playing,
      processingState: _processingStateName(player.processingState),
      position: player.position,
      bufferedPosition: player.bufferedPosition,
      duration: player.duration,
      volume: session.volume,
      boostGain: 1.0,
      channelSwapEnabled: session.channelSwapEnabled,
    );
  }
}

class _DartPlaybackSession {
  _DartPlaybackSession({required this.sessionId, required this.onChanged}) {
    void bind(Stream<dynamic> stream) {
      subscriptions.add(stream.listen(
        (_) => onChanged(),
        onError: (e, st) {
          debugPrint('DartPlaybackSession stream error: $e\n$st');
          onChanged();
        },
      ));
    }

    bind(player.playerStateStream);
    bind(player.positionStream);
    bind(player.bufferedPositionStream);
    bind(player.durationStream);
    bind(player.currentIndexStream);
  }

  final String sessionId;
  final VoidCallback onChanged;
  final AudioPlayer player = AudioPlayer();
  final List<StreamSubscription<dynamic>> subscriptions = [];
  List<_DartPlaybackItem> items = const <_DartPlaybackItem>[];
  double volume = 1.0;
  bool channelSwapEnabled = false;

  _DartPlaybackItem? get currentItem {
    if (items.isEmpty) return null;
    final index = player.currentIndex ?? 0;
    return items[index.clamp(0, items.length - 1)];
  }

  Future<void> setItems(
    List<_DartPlaybackItem> nextItems, {
    required int initialIndex,
    required Duration initialPosition,
  }) async {
    items = List.of(nextItems);
    try {
      debugPrint('DartPlaybackBridge: calling setAudioSources with ${items.length} items');
      for (final item in items) {
        debugPrint('DartPlaybackBridge item: path=${item.path}, uri=${item.uri}, isRemote=${item.path != null ? PathMatcher.isRemoteUri(item.path!) : false}');
      }
      try {
        if (items.length == 1) {
          final item = items.first;
          final source = item.path != null && !PathMatcher.isRemoteUri(item.path!)
              ? _LocalFileStreamAudioSource(item.path!)
              : AudioSource.uri(item.uri);
          
          final logFile = File('dart_playback_bridge.log');
          logFile.writeAsStringSync('Preparing to play: ${item.path} (uri: ${item.uri})\n', mode: FileMode.append);
          
          await player.setAudioSource(
            source,
            initialPosition: initialPosition,
          );
          logFile.writeAsStringSync('setAudioSource SUCCESS\n', mode: FileMode.append);
        } else {
          await player.setAudioSources(
            items.map((item) {
              if (item.path != null && !PathMatcher.isRemoteUri(item.path!)) {
                return _LocalFileStreamAudioSource(item.path!);
              }
              return AudioSource.uri(item.uri);
            }).toList(growable: false),
            initialIndex: initialIndex,
            initialPosition: initialPosition,
          );
        }
      } catch (e, st) {
        final logFile = File('dart_playback_bridge.log');
        logFile.writeAsStringSync('setAudioSource ERROR: $e\n$st\n', mode: FileMode.append);
        rethrow;
      }
      debugPrint('DartPlaybackBridge: setAudioSources success');
    } catch (e, st) {
      debugPrint('DartPlaybackBridge: setAudioSources ERROR: $e\n$st');
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
    return uri.toFilePath(windows: _isWindowsDriveUri(uri));
  }
  if (PathMatcher.isRemoteUri(uri.toString())) return uri.toString();
  return null;
}

bool _isWindowsDriveUri(Uri uri) {
  return Platform.isWindows &&
      uri.pathSegments.isNotEmpty &&
      RegExp(r'^[A-Za-z]:$').hasMatch(uri.pathSegments.first);
}

String _processingStateName(ProcessingState state) {
  switch (state) {
    case ProcessingState.idle:
      return 'idle';
    case ProcessingState.loading:
      return 'loading';
    case ProcessingState.buffering:
      return 'buffering';
    case ProcessingState.ready:
      return 'ready';
    case ProcessingState.completed:
      return 'completed';
  }
}

// added for test

class _LocalFileStreamAudioSource extends StreamAudioSource {
  _LocalFileStreamAudioSource(this.path);

  final String path;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    final file = File(path);
    final length = await file.length();
    final effectiveEnd = end ?? length;
    final stream = file.openRead(start, effectiveEnd);

    final ext = path.split('.').last.toLowerCase();
    String contentType = 'audio/mpeg';
    if (ext == 'm4a' || ext == 'mp4') contentType = 'audio/mp4';
    if (ext == 'flac') contentType = 'audio/flac';
    if (ext == 'wav') contentType = 'audio/wav';
    if (ext == 'ogg') contentType = 'audio/ogg';

    return StreamAudioResponse(
      sourceLength: length,
      contentLength: effectiveEnd - start,
      offset: start,
      stream: stream,
      contentType: contentType,
    );
  }
}

