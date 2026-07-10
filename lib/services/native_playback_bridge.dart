// ignore_for_file: use_null_aware_elements

import 'dart:async';

import 'package:flutter/services.dart';

import 'native_result.dart';
import 'app_log_service.dart';
import 'platform_channels.dart';
import '../models/audio_effects.dart';

class NativePlaybackSnapshot {
  const NativePlaybackSnapshot({
    required this.sessionId,
    required this.playing,
    required this.playWhenReady,
    required this.processingState,
    required this.position,
    required this.bufferedPosition,
    required this.volume,
    this.speed = 1.0,
    required this.boostGain,
    required this.channelSwapEnabled,
    this.hasChannelSwapPayload = true,
    this.audioEffects = AudioEffectsState.flat,
    this.hasAudioEffectsPayload = true,
    this.eqCapabilities = EqCapabilities.unsupported,
    this.uri,
    this.path,
    this.title,
    this.subtitle,
    this.artUri,
    this.duration,
    this.error,
    this.queueIndex = 0,
    this.transportCommandId,
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
  final double speed;
  final double boostGain;
  final bool channelSwapEnabled;
  final bool hasChannelSwapPayload;
  final AudioEffectsState audioEffects;
  final bool hasAudioEffectsPayload;
  final EqCapabilities eqCapabilities;
  final String? error;
  final int queueIndex;
  final int? transportCommandId;

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
    double? speed,
    double? boostGain,
    bool? channelSwapEnabled,
    bool? hasChannelSwapPayload,
    AudioEffectsState? audioEffects,
    bool? hasAudioEffectsPayload,
    EqCapabilities? eqCapabilities,
    String? error,
    bool clearError = false,
    int? queueIndex,
    int? transportCommandId,
    bool clearTransportCommandId = false,
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
      speed: speed ?? this.speed,
      boostGain: boostGain ?? this.boostGain,
      channelSwapEnabled: channelSwapEnabled ?? this.channelSwapEnabled,
      hasChannelSwapPayload:
          hasChannelSwapPayload ??
          (channelSwapEnabled != null ? true : this.hasChannelSwapPayload),
      audioEffects: audioEffects ?? this.audioEffects,
      hasAudioEffectsPayload:
          hasAudioEffectsPayload ??
          (audioEffects != null ? true : this.hasAudioEffectsPayload),
      eqCapabilities: eqCapabilities ?? this.eqCapabilities,
      error: clearError ? null : (error ?? this.error),
      queueIndex: queueIndex ?? this.queueIndex,
      transportCommandId: clearTransportCommandId
          ? null
          : (transportCommandId ?? this.transportCommandId),
    );
  }

  factory NativePlaybackSnapshot.fromMap(Map<dynamic, dynamic> map) {
    final sessionId = map['sessionId'] as String?;
    if (sessionId == null || sessionId.trim().isEmpty) {
      throw const FormatException(
        'Native playback snapshot is missing sessionId.',
      );
    }
    final hasChannelSwapPayload = map.containsKey('channelSwap');
    final hasAudioEffectsPayload = map.containsKey('audioEffects');
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
      speed: (map['speed'] as num?)?.toDouble() ?? 1.0,
      boostGain: (map['boostGain'] as num?)?.toDouble() ?? 1.0,
      channelSwapEnabled: map['channelSwap'] as bool? ?? false,
      hasChannelSwapPayload: hasChannelSwapPayload,
      audioEffects: AudioEffectsState.fromPlatformMap(map['audioEffects']),
      hasAudioEffectsPayload: hasAudioEffectsPayload,
      eqCapabilities: EqCapabilities.fromJson(map['eqCapabilities']),
      error: map['error'] as String?,
      queueIndex: (map['queueIndex'] as num?)?.toInt() ?? 0,
      transportCommandId: (map['transportCommandId'] as num?)?.toInt(),
    );
  }
}

class NativePlaybackProgressUpdate {
  const NativePlaybackProgressUpdate({
    required this.sessionId,
    required this.position,
    required this.bufferedPosition,
    required this.nativeElapsedRealtimeMs,
    this.duration,
  });

  final String sessionId;
  final Duration position;
  final Duration bufferedPosition;
  final Duration? duration;
  final int nativeElapsedRealtimeMs;

  factory NativePlaybackProgressUpdate.fromMap(Map<dynamic, dynamic> map) {
    final sessionId = (map['sessionId'] as String?)?.trim();
    if (sessionId == null || sessionId.isEmpty) {
      throw const FormatException(
        'Native playback progress is missing sessionId.',
      );
    }
    return NativePlaybackProgressUpdate(
      sessionId: sessionId,
      position: Duration(
        milliseconds: (map['positionMs'] as num?)?.round() ?? 0,
      ),
      bufferedPosition: Duration(
        milliseconds: (map['bufferedPositionMs'] as num?)?.round() ?? 0,
      ),
      duration: map['durationMs'] == null
          ? null
          : Duration(milliseconds: (map['durationMs'] as num).round()),
      nativeElapsedRealtimeMs:
          (map['nativeElapsedRealtimeMs'] as num?)?.round() ?? 0,
    );
  }
}

List<NativePlaybackProgressUpdate> parseNativePlaybackProgressEvent(
  Map<dynamic, dynamic> event,
) {
  if (event['eventType'] != 'progress') return const [];
  final updates = event['updates'];
  if (updates is! List) return const [];
  return updates
      .whereType<Map<dynamic, dynamic>>()
      .map(NativePlaybackProgressUpdate.fromMap)
      .toList(growable: false);
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

abstract interface class NativePlaybackBridgeBase {
  Stream<NativePlaybackSnapshot> get snapshots;

  Stream<NativePlaybackProgressUpdate> get progressUpdates;

  bool get supportsDeferredSessionRegistration;

  void startListening();

  Future<void> stopListening();

  Future<void> dispose();

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
    double speed = 1.0,
    NativeAudioEffects audioEffects = const NativeAudioEffects(
      state: AudioEffectsState.flat,
      channelSwapEnabled: false,
    ),
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
    List<Uri>? candidateUris,
    bool deferPlayerCreation = false,
  });

  Future<NativeResult<NativePlaybackSnapshot>> play(
    String sessionId, {
    int transportCommandId = 0,
    bool exclusive = false,
  });

  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  });

  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId);

  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  );

  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  });

  Future<NativeResult<NativePlaybackSnapshot>> setSpeed(
    String sessionId,
    double speed,
  );

  Future<NativeResult<NativePlaybackSnapshot>> setRepeatOne(
    String sessionId,
    bool repeatOne, {
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  });

  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  );

  Future<NativeResult<NativePlaybackSnapshot>> setFadeMultiplier(
    String sessionId,
    double multiplier,
  );

  Future<NativeResult<void>> removeSession(String sessionId);

  Future<NativeResult<void>> pauseAll();

  Future<NativeResult<void>> clearAll();

  Future<NativeResult<void>> setForegroundEnabled(bool enabled);

  Future<NativeResult<void>> dismissNotifications();

  Future<NativeResult<void>> undismissNotifications();

  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot();
}

class NativePlaybackBridge implements NativePlaybackBridgeBase {
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
  StreamController<NativePlaybackProgressUpdate>? _progressController;
  StreamController<NativePlaybackProgressUpdate>
  get _progressUpdatesController => _progressController ??=
      StreamController<NativePlaybackProgressUpdate>.broadcast();
  StreamSubscription<dynamic>? _eventSubscription;
  Timer? _reconnectTimer;
  bool _listeningEnabled = false;
  int _reconnectAttempt = 0;
  int _subscriptionGeneration = 0;
  Future<void> _attachSerial = Future<void>.value();
  bool _attachQueued = false;
  static const int _maxReconnectAttempts = 5;

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _controller.stream;

  @override
  Stream<NativePlaybackProgressUpdate> get progressUpdates =>
      _progressUpdatesController.stream;

  @override
  bool get supportsDeferredSessionRegistration => true;

  @override
  void startListening() {
    _listeningEnabled = true;
    if (_eventSubscription != null || _attachQueued) return;
    _reconnectAttempt = 0;
    unawaited(_queueAttach());
  }

  Future<void> _queueAttach() {
    if (_attachQueued) return _attachSerial;
    _attachQueued = true;
    _attachSerial = _attachSerial
        .then((_) => _attachEventListener())
        .whenComplete(() {
          _attachQueued = false;
        });
    return _attachSerial;
  }

  Future<void> _attachEventListener() async {
    if (!_listeningEnabled) return;
    final generation = ++_subscriptionGeneration;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final previous = _eventSubscription;
    _eventSubscription = null;
    try {
      await previous?.cancel();
    } catch (error, stackTrace) {
      AppLogService.error(
        'native_playback_event_subscription_cancel_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (!_listeningEnabled || generation != _subscriptionGeneration) return;
    late final StreamSubscription<dynamic> subscription;
    subscription = _events.receiveBroadcastStream().listen(
      (event) {
        if (generation != _subscriptionGeneration ||
            !identical(_eventSubscription, subscription)) {
          return;
        }
        _reconnectAttempt = 0;
        if (event is Map) {
          try {
            final eventType = event['eventType'];
            if (eventType == 'progress') {
              for (final update in parseNativePlaybackProgressEvent(event)) {
                _progressUpdatesController.add(update);
              }
            } else if (eventType == null) {
              _controller.add(NativePlaybackSnapshot.fromMap(event));
            } else {
              AppLogService.warning(
                'native_playback_unknown_event type=$eventType',
              );
            }
          } catch (error, stackTrace) {
            AppLogService.error(
              'native_playback_invalid_event',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
      },
      onError: (Object error) {
        AppLogService.error(
          'native_playback_event_channel_failed',
          error: error,
        );
        unawaited(_handleEventDisconnect(generation, subscription));
      },
      onDone: () {
        unawaited(_handleEventDisconnect(generation, subscription));
      },
      cancelOnError: false,
    );
    _eventSubscription = subscription;
  }

  Future<void> _handleEventDisconnect(
    int generation,
    StreamSubscription<dynamic> subscription,
  ) async {
    if (generation != _subscriptionGeneration ||
        !identical(_eventSubscription, subscription)) {
      return;
    }
    _eventSubscription = null;
    final reconnectGeneration = ++_subscriptionGeneration;
    await subscription.cancel();
    if (reconnectGeneration != _subscriptionGeneration) return;
    _scheduleReconnect(reconnectGeneration);
  }

  void _scheduleReconnect(int generation) {
    if (!_listeningEnabled) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) return;
    _reconnectAttempt++;
    final delay = Duration(milliseconds: 200 * _reconnectAttempt);
    AppLogService.warning(
      'native_playback_reconnecting delayMs=${delay.inMilliseconds} '
      'attempt=$_reconnectAttempt max=$_maxReconnectAttempts',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_listeningEnabled ||
          generation != _subscriptionGeneration ||
          _eventSubscription != null) {
        return;
      }
      unawaited(_queueAttach());
    });
  }

  @override
  Future<void> stopListening() async {
    _listeningEnabled = false;
    _subscriptionGeneration++;
    _reconnectAttempt = _maxReconnectAttempts;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _attachSerial;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
  }

  @override
  Future<void> dispose() async {
    await stopListening();
    await _snapshotController?.close();
    _snapshotController = null;
    await _progressController?.close();
    _progressController = null;
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
    double speed = 1.0,
    NativeAudioEffects audioEffects = const NativeAudioEffects(
      state: AudioEffectsState.flat,
      channelSwapEnabled: false,
    ),
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
    List<Uri>? candidateUris,
    bool deferPlayerCreation = false,
  }) {
    return _invokeSnapshot(NativePlaybackMethod.prepareSession, {
      'sessionId': sessionId,
      'uri': uri.toString(),

      if (path != null) 'path': path,
      'title': title,

      if (subtitle != null) 'subtitle': subtitle,

      if (artUri != null) 'artUri': artUri.toString(),
      'startPositionMs': startPosition.inMilliseconds,
      'volume': volume,
      'speed': speed,
      'audioEffects': audioEffects.toPlatformMap(),
      'repeatOne': repeatOne,
      'autoPlay': autoPlay,

      if (queue != null && queue.isNotEmpty) 'queue': queue,

      if (queueStartIndex != null) 'queueStartIndex': queueStartIndex,
      'repeatAll': repeatAll,
      'shuffle': shuffle,
      'deferPlayerCreation': deferPlayerCreation,
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> play(
    String sessionId, {
    int transportCommandId = 0,
    bool exclusive = false,
  }) {
    return _invokeSnapshot(NativePlaybackMethod.play, {
      'sessionId': sessionId,
      'transportCommandId': transportCommandId,
      'exclusive': exclusive,
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) {
    return _invokeSnapshot(NativePlaybackMethod.pause, {
      'sessionId': sessionId,
      'transportCommandId': transportCommandId,
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) {
    return _invokeSnapshot(NativePlaybackMethod.stop, {'sessionId': sessionId});
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) {
    return _invokeSnapshot(NativePlaybackMethod.seek, {
      'sessionId': sessionId,
      'positionMs': position.inMilliseconds,
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  }) {
    return _invokeSnapshot(NativePlaybackMethod.setVolume, {
      'sessionId': sessionId,
      'volume': volume,
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setSpeed(
    String sessionId,
    double speed,
  ) {
    return _invokeSnapshot(NativePlaybackMethod.setSpeed, {
      'sessionId': sessionId,
      'speed': speed,
    });
  }

  @override
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

      if (queue != null && queue.isNotEmpty) 'queue': queue,

      if (queueStartIndex != null) 'queueStartIndex': queueStartIndex,
      'repeatAll': repeatAll,
      'shuffle': shuffle,
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) {
    return _invokeSnapshot(NativePlaybackMethod.setAudioEffects, {
      'sessionId': sessionId,
      'effects': effects.toPlatformMap(),
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setFadeMultiplier(
    String sessionId,
    double multiplier,
  ) {
    return _invokeSnapshot(NativePlaybackMethod.setFadeMultiplier, {
      'sessionId': sessionId,
      'multiplier': multiplier,
    });
  }

  @override
  Future<NativeResult<void>> removeSession(String sessionId) {
    return _invokeVoid(NativePlaybackMethod.removeSession, {
      'sessionId': sessionId,
    });
  }

  @override
  Future<NativeResult<void>> pauseAll() {
    return _invokeVoid(NativePlaybackMethod.pauseAll);
  }

  @override
  Future<NativeResult<void>> clearAll() {
    return _invokeVoid(NativePlaybackMethod.clearAll);
  }

  @override
  Future<NativeResult<void>> setForegroundEnabled(bool enabled) {
    return _invokeVoid(NativePlaybackMethod.setForegroundEnabled, {
      'enabled': enabled,
    });
  }

  @override
  Future<NativeResult<void>> dismissNotifications() {
    return _invokeVoid(NativePlaybackMethod.dismissNotifications);
  }

  @override
  Future<NativeResult<void>> undismissNotifications() {
    return _invokeVoid(NativePlaybackMethod.undismissNotifications);
  }

  @override
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
