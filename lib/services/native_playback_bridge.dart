import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_result.dart';
import 'platform_channels.dart';

class NativePlaybackSnapshot {
  const NativePlaybackSnapshot({
    required this.sessionId,
    required this.playing,
    required this.playWhenReady,
    required this.processingState,
    required this.position,
    required this.bufferedPosition,
    required this.volume,
    required this.boostGain,
    required this.channelSwapEnabled,
    this.uri,
    this.path,
    this.title,
    this.subtitle,
    this.artUri,
    this.duration,
    this.error,
  });

  final String sessionId;
  final String? uri;
  final String? path;
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
  final double boostGain;
  final bool channelSwapEnabled;
  final String? error;

  NativePlaybackSnapshot copyWith({
    String? sessionId,
    String? uri,
    bool clearUri = false,
    String? path,
    bool clearPath = false,
    String? title,
    bool clearTitle = false,
    String? subtitle,
    bool clearSubtitle = false,
    String? artUri,
    bool clearArtUri = false,
    bool? playing,
    bool? playWhenReady,
    String? processingState,
    Duration? position,
    Duration? bufferedPosition,
    Duration? duration,
    bool clearDuration = false,
    double? volume,
    double? boostGain,
    bool? channelSwapEnabled,
    String? error,
    bool clearError = false,
  }) {
    return NativePlaybackSnapshot(
      sessionId: sessionId ?? this.sessionId,
      uri: clearUri ? null : (uri ?? this.uri),
      path: clearPath ? null : (path ?? this.path),
      title: clearTitle ? null : (title ?? this.title),
      subtitle: clearSubtitle ? null : (subtitle ?? this.subtitle),
      artUri: clearArtUri ? null : (artUri ?? this.artUri),
      playing: playing ?? this.playing,
      playWhenReady: playWhenReady ?? this.playWhenReady,
      processingState: processingState ?? this.processingState,
      position: position ?? this.position,
      bufferedPosition: bufferedPosition ?? this.bufferedPosition,
      duration: clearDuration ? null : (duration ?? this.duration),
      volume: volume ?? this.volume,
      boostGain: boostGain ?? this.boostGain,
      channelSwapEnabled: channelSwapEnabled ?? this.channelSwapEnabled,
      error: clearError ? null : (error ?? this.error),
    );
  }

  factory NativePlaybackSnapshot.fromMap(Map<dynamic, dynamic> map) {
    final sessionId = map['sessionId'] as String?;
    if (sessionId == null || sessionId.trim().isEmpty) {
      throw const FormatException(
        'Native playback snapshot is missing sessionId.',
      );
    }
    return NativePlaybackSnapshot(
      sessionId: sessionId,
      uri: map['uri'] as String?,
      path: map['path'] as String?,
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
      boostGain: (map['boostGain'] as num?)?.toDouble() ?? 1.0,
      channelSwapEnabled: map['channelSwap'] as bool? ?? false,
      error: map['error'] as String?,
    );
  }
}

class NativePlaybackBundleSnapshot {
  const NativePlaybackBundleSnapshot({
    required this.sessions,
    this.focusedSessionId,
  });

  final List<NativePlaybackSnapshot> sessions;
  final String? focusedSessionId;

  factory NativePlaybackBundleSnapshot.fromMap(Map<dynamic, dynamic> map) {
    final rawSessions = map['sessions'];
    return NativePlaybackBundleSnapshot(
      sessions: rawSessions is List
          ? rawSessions
                .whereType<Map<dynamic, dynamic>>()
                .map(NativePlaybackSnapshot.fromMap)
                .toList(growable: false)
          : const <NativePlaybackSnapshot>[],
      focusedSessionId: map['focusedSessionId'] as String?,
    );
  }
}

class NativePlaybackBridge {
  NativePlaybackBridge._();

  static final NativePlaybackBridge instance = NativePlaybackBridge._();

  static const MethodChannel _methods = MethodChannel(
    NativePlaybackChannel.name,
  );
  static const EventChannel _events = EventChannel(
    NativePlaybackChannel.eventName,
  );

  StreamController<NativePlaybackSnapshot>? _snapshotController;
  StreamController<NativePlaybackSnapshot> get _controller =>
      _snapshotController ??=
          StreamController<NativePlaybackSnapshot>.broadcast();
  StreamSubscription<dynamic>? _eventSubscription;
  Timer? _reconnectTimer;
  bool _listeningEnabled = false;
  int _reconnectAttempt = 0;
  static const int _maxReconnectAttempts = 5;

  Stream<NativePlaybackSnapshot> get snapshots => _controller.stream;

  void startListening() {
    _listeningEnabled = true;
    if (_eventSubscription != null) return;
    _reconnectAttempt = 0;
    _attachEventListener();
  }

  void _attachEventListener() {
    if (!_listeningEnabled) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _eventSubscription?.cancel();
    _eventSubscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          try {
            _controller.add(NativePlaybackSnapshot.fromMap(event));
          } catch (error) {
            debugPrint(
              'NativePlaybackBridge: dropping invalid snapshot: $error',
            );
          }
        }
      },
      onError: (error) {
        debugPrint('NativePlaybackBridge EventChannel error: $error');
        _scheduleReconnect();
      },
      onDone: () {
        _scheduleReconnect();
      },
      cancelOnError: false,
    );
  }

  void _scheduleReconnect() {
    _eventSubscription = null;
    if (!_listeningEnabled) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) return;
    _reconnectAttempt++;
    final delay = Duration(milliseconds: 200 * _reconnectAttempt);
    debugPrint(
      'NativePlaybackBridge: reconnecting in ${delay.inMilliseconds}ms '
      '(attempt $_reconnectAttempt/$_maxReconnectAttempts)',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_listeningEnabled || _eventSubscription != null) return;
      _attachEventListener();
    });
  }

  Future<void> stopListening() async {
    _listeningEnabled = false;
    _reconnectAttempt = _maxReconnectAttempts;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
  }

  Future<void> dispose() async {
    await stopListening();
    await _snapshotController?.close();
    _snapshotController = null;
  }

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
  }) {
    return _invokeSnapshot(NativePlaybackMethod.prepareSession, {
      'sessionId': sessionId,
      'uri': uri.toString(),
      // ignore: use_null_aware_elements
      if (path != null) 'path': path,
      'title': title,
      // ignore: use_null_aware_elements
      if (subtitle != null) 'subtitle': subtitle,
      // ignore: use_null_aware_elements
      if (artUri != null) 'artUri': artUri.toString(),
      'startPositionMs': startPosition.inMilliseconds,
      'volume': volume,
      'repeatOne': repeatOne,
      'autoPlay': autoPlay,
      // ignore: use_null_aware_elements
      if (queue != null && queue.isNotEmpty) 'queue': queue,
      // ignore: use_null_aware_elements
      if (queueStartIndex != null) 'queueStartIndex': queueStartIndex,
      'repeatAll': repeatAll,
      'shuffle': shuffle,
    });
  }

  Future<NativeResult<NativePlaybackSnapshot>> play(String sessionId) {
    return _invokeSnapshot(NativePlaybackMethod.play, {'sessionId': sessionId});
  }

  Future<NativeResult<NativePlaybackSnapshot>> pause(String sessionId) {
    return _invokeSnapshot(NativePlaybackMethod.pause, {
      'sessionId': sessionId,
    });
  }

  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) {
    return _invokeSnapshot(NativePlaybackMethod.stop, {'sessionId': sessionId});
  }

  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) {
    return _invokeSnapshot(NativePlaybackMethod.seek, {
      'sessionId': sessionId,
      'positionMs': position.inMilliseconds,
    });
  }

  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume,
  ) {
    return _invokeSnapshot(NativePlaybackMethod.setVolume, {
      'sessionId': sessionId,
      'volume': volume,
    });
  }

  Future<NativeResult<NativePlaybackSnapshot>> setRepeatOne(
    String sessionId,
    bool repeatOne, {
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  }) {
    return _invokeSnapshot(NativePlaybackMethod.setRepeatOne, {
      'sessionId': sessionId,
      'repeatOne': repeatOne,
      // ignore: use_null_aware_elements
      if (queue != null && queue.isNotEmpty) 'queue': queue,
      // ignore: use_null_aware_elements
      if (queueStartIndex != null) 'queueStartIndex': queueStartIndex,
      'repeatAll': repeatAll,
      'shuffle': shuffle,
    });
  }

  Future<NativeResult<NativePlaybackSnapshot>> setChannelSwap(
    String sessionId,
    bool enabled,
  ) {
    return _invokeSnapshot(NativePlaybackMethod.setChannelSwap, {
      'sessionId': sessionId,
      'enabled': enabled,
    });
  }

  Future<NativeResult<void>> removeSession(String sessionId) {
    return _invokeVoid(NativePlaybackMethod.removeSession, {
      'sessionId': sessionId,
    });
  }

  Future<NativeResult<void>> pauseAll() {
    return _invokeVoid(NativePlaybackMethod.pauseAll);
  }

  Future<NativeResult<void>> clearAll() {
    return _invokeVoid(NativePlaybackMethod.clearAll);
  }

  Future<NativeResult<void>> setForegroundEnabled(bool enabled) {
    return _invokeVoid(NativePlaybackMethod.setForegroundEnabled, {
      'enabled': enabled,
    });
  }

  Future<NativeResult<void>> dismissNotifications() {
    return _invokeVoid(NativePlaybackMethod.dismissNotifications);
  }

  Future<NativeResult<void>> undismissNotifications() {
    return _invokeVoid(NativePlaybackMethod.undismissNotifications);
  }

  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() {
    return _invokeValue(
      NativePlaybackMethod.snapshot,
      (value) => value is Map
          ? NativePlaybackBundleSnapshot.fromMap(value)
          : const NativePlaybackBundleSnapshot(
              sessions: <NativePlaybackSnapshot>[],
            ),
    );
  }

  Future<Map<dynamic, dynamic>> _invokeRaw(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
      method,
      arguments,
    );
    return result ?? const <dynamic, dynamic>{};
  }

  Future<NativeResult<void>> _invokeVoid(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final result = await _invokeValue<Object?>(method, (_) => null, arguments);
    return switch (result) {
      NativeSuccess<Object?>() => const NativeSuccess<void>(),
      NativeFailure<Object?>(message: final message) => NativeFailure<void>(
        message,
      ),
    };
  }

  Future<NativeResult<NativePlaybackSnapshot>> _invokeSnapshot(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    return _invokeValue<NativePlaybackSnapshot>(method, (value) {
      if (value is Map) return NativePlaybackSnapshot.fromMap(value);
      return null;
    }, arguments);
  }

  Future<NativeResult<T>> _invokeValue<T>(
    String method,
    T? Function(Object? value) decode, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final raw = await _invokeRaw(method, arguments);
      final ok = raw['ok'] as bool? ?? false;
      if (!ok) {
        final message =
            raw['error'] as String? ??
            'Native playback call failed: $method returned no error message.';
        return NativeFailure<T>(message);
      }
      return NativeSuccess<T>(decode(raw['value']));
    } on PlatformException catch (error) {
      return NativeFailure<T>(error.message ?? error.code);
    } catch (error) {
      return NativeFailure<T>(error.toString());
    }
  }
}
