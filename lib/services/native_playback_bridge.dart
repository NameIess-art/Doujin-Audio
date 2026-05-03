import 'dart:async';

import 'package:flutter/services.dart';

class NativePlaybackSnapshot {
  const NativePlaybackSnapshot({
    required this.sessionId,
    required this.playing,
    required this.playWhenReady,
    required this.processingState,
    required this.position,
    required this.bufferedPosition,
    required this.volume,
    this.uri,
    this.title,
    this.subtitle,
    this.artUri,
    this.duration,
    this.error,
  });

  final String sessionId;
  final String? uri;
  final String? title;
  final String? subtitle;
  final String? artUri;
  final bool playing;
  final bool playWhenReady;
  final String processingState;
  final Duration position;
  final Duration bufferedPosition;
  final Duration? duration;
  final double volume;
  final String? error;

  factory NativePlaybackSnapshot.fromMap(Map<dynamic, dynamic> map) {
    return NativePlaybackSnapshot(
      sessionId: map['sessionId'] as String? ?? '',
      uri: map['uri'] as String?,
      title: map['title'] as String?,
      subtitle: map['subtitle'] as String?,
      artUri: map['artUri'] as String?,
      playing: map['playing'] as bool? ?? false,
      playWhenReady: map['playWhenReady'] as bool? ?? false,
      processingState: map['processingState'] as String? ?? 'idle',
      position: Duration(
        milliseconds: (map['positionMs'] as num?)?.round() ?? 0,
      ),
      bufferedPosition: Duration(
        milliseconds: (map['bufferedPositionMs'] as num?)?.round() ?? 0,
      ),
      duration: map['durationMs'] == null
          ? null
          : Duration(milliseconds: (map['durationMs'] as num).round()),
      volume: (map['volume'] as num?)?.toDouble() ?? 1.0,
      error: map['error'] as String?,
    );
  }
}

class NativePlaybackBridge {
  NativePlaybackBridge._();

  static final NativePlaybackBridge instance = NativePlaybackBridge._();

  static const MethodChannel _methods = MethodChannel(
    'music_player/native_playback',
  );
  static const EventChannel _events = EventChannel(
    'music_player/native_playback/events',
  );

  final StreamController<NativePlaybackSnapshot> _snapshotController =
      StreamController<NativePlaybackSnapshot>.broadcast();
  StreamSubscription<dynamic>? _eventSubscription;

  Stream<NativePlaybackSnapshot> get snapshots => _snapshotController.stream;

  void startListening() {
    _eventSubscription ??= _events.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        _snapshotController.add(NativePlaybackSnapshot.fromMap(event));
      }
    });
  }

  Future<void> stopListening() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
  }

  Future<Map<dynamic, dynamic>> prepareSession({
    required String sessionId,
    required Uri uri,
    required String title,
    String? subtitle,
    Uri? artUri,
    Duration startPosition = Duration.zero,
    double volume = 1.0,
    bool repeatOne = false,
    bool autoPlay = false,
  }) {
    return _invoke('prepareSession', {
      'sessionId': sessionId,
      'uri': uri.toString(),
      'title': title,
      // ignore: use_null_aware_elements
      if (subtitle != null) 'subtitle': subtitle,
      if (artUri != null) 'artUri': artUri.toString(),
      'startPositionMs': startPosition.inMilliseconds,
      'volume': volume,
      'repeatOne': repeatOne,
      'autoPlay': autoPlay,
    });
  }

  Future<Map<dynamic, dynamic>> play(String sessionId) {
    return _invoke('play', {'sessionId': sessionId});
  }

  Future<Map<dynamic, dynamic>> pause(String sessionId) {
    return _invoke('pause', {'sessionId': sessionId});
  }

  Future<Map<dynamic, dynamic>> stop(String sessionId) {
    return _invoke('stop', {'sessionId': sessionId});
  }

  Future<Map<dynamic, dynamic>> seek(String sessionId, Duration position) {
    return _invoke('seek', {
      'sessionId': sessionId,
      'positionMs': position.inMilliseconds,
    });
  }

  Future<Map<dynamic, dynamic>> setVolume(String sessionId, double volume) {
    return _invoke('setVolume', {'sessionId': sessionId, 'volume': volume});
  }

  Future<Map<dynamic, dynamic>> setRepeatOne(String sessionId, bool repeatOne) {
    return _invoke('setRepeatOne', {
      'sessionId': sessionId,
      'repeatOne': repeatOne,
    });
  }

  Future<Map<dynamic, dynamic>> removeSession(String sessionId) {
    return _invoke('removeSession', {'sessionId': sessionId});
  }

  Future<Map<dynamic, dynamic>> pauseAll() {
    return _invoke('pauseAll');
  }

  Future<Map<dynamic, dynamic>> clearAll() {
    return _invoke('clearAll');
  }

  Future<Map<dynamic, dynamic>> setForegroundEnabled(bool enabled) {
    return _invoke('setForegroundEnabled', {'enabled': enabled});
  }

  Future<Map<dynamic, dynamic>> dismissNotifications() {
    return _invoke('dismissNotifications');
  }

  Future<Map<dynamic, dynamic>> undismissNotifications() {
    return _invoke('undismissNotifications');
  }

  Future<Map<dynamic, dynamic>> snapshot() {
    return _invoke('snapshot');
  }

  Future<Map<dynamic, dynamic>> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      method,
      arguments,
    );
    return result ?? const <dynamic, dynamic>{};
  }
}
