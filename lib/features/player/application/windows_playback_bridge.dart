import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/errors/native_result.dart';
import '../domain/audio_effects.dart';
import 'native_playback_bridge.dart';

/// The desktop implementation of the existing playback transport. Each session
/// owns one libmpv player; video surfaces borrow it without opening another source.
class WindowsPlaybackBridge implements NativePlaybackBridgeBase {
  WindowsPlaybackBridge({Player Function()? createPlayer})
    : _createPlayer = createPlayer ?? _defaultPlayer;

  static WindowsPlaybackBridge? _instance;
  static WindowsPlaybackBridge get instance {
    if (_instance == null || _instance!._disposed) {
      _instance = WindowsPlaybackBridge();
    }
    return _instance!;
  }

  static Player _defaultPlayer() {
    final player = Player(
      configuration: const PlayerConfiguration(
        title: 'Doujin Audio',
        vo: 'libmpv',
      ),
    );
    if (const bool.fromEnvironment('WINDOWS_TEST_NULL_AUDIO')) {
      (player.platform! as NativePlayer).setProperty('ao', 'null');
    }
    return player;
  }

  final Player Function() _createPlayer;
  final _sessions = <String, _WindowsPlaybackSession>{};
  final _snapshots = StreamController<NativePlaybackSnapshot>.broadcast();
  final _progress = StreamController<NativePlaybackProgressUpdate>.broadcast();
  final _clock = Stopwatch()..start();
  Future<void> _serial = Future.value();
  String? _focusedSessionId;
  bool _listening = false;
  bool _pauseOnDisconnect = true;
  bool _disposed = false;

  Player? playerForSession(String sessionId) => _sessions[sessionId]?.player;
  VideoController? videoControllerForSession(String sessionId) {
    final session = _sessions[sessionId];
    final player = session?.player;
    if (session == null || player == null) return null;
    return session.videoController ??= VideoController(player);
  }

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<NativePlaybackProgressUpdate> get progressUpdates => _progress.stream;
  @override
  bool get supportsDeferredSessionRegistration => true;
  @override
  void startListening() => _listening = true;
  @override
  Future<void> stopListening() async => _listening = false;

  void _emit(_WindowsPlaybackSession session) {
    if (_listening && !session.opening && !_snapshots.isClosed) {
      _snapshots.add(session.snapshot);
    }
  }

  Future<NativeResult<T>> _run<T>(Future<T?> Function() action) {
    final result = _serial.then((_) async {
      try {
        return NativeSuccess<T>(await action());
      } on ArgumentError catch (error) {
        return NativeFailure<T>(
          error.toString(),
          code: NativeErrorCode.invalidArgument,
        );
      } catch (error) {
        return NativeFailure<T>(
          error.toString(),
          code: NativeErrorCode.playerError,
        );
      }
    });
    _serial = result.then((_) {});
    return result;
  }

  Future<NativeResult<NativePlaybackSnapshot>> _change(
    String id,
    Future<void> Function(_WindowsPlaybackSession) action,
  ) => _run(() async {
    final session = _sessions[id];
    if (session == null) {
      throw ArgumentError.value(id, 'sessionId', 'Unknown session');
    }
    try {
      await action(session);
      _emit(session);
      return session.snapshot;
    } catch (error) {
      session.error = error.toString();
      _emit(session);
      rethrow;
    }
  });

  @override
  Future<NativeResult<NativePlaybackSnapshot>> prepareSession({
    required String sessionId,
    required Uri uri,
    required String title,
    String? path,
    String? subtitle,
    Uri? artUri,
    Duration startPosition = Duration.zero,
    double volume = 1,
    bool repeatOne = false,
    bool autoPlay = false,
    double speed = 1,
    NativeAudioEffects? audioEffects,
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
    List<Uri>? candidateUris,
    bool deferPlayerCreation = false,
  }) => _run(() async {
    if (sessionId.trim().isEmpty || uri.toString().isEmpty) {
      throw ArgumentError('sessionId and uri are required');
    }
    final items = queue?.isNotEmpty == true
        ? queue!
        : <Map<String, Object?>>[
            {
              'uri': uri.toString(),
              'path': path,
              'title': title,
              'subtitle': subtitle,
              'artUri': artUri?.toString(),
              'candidateUris': candidateUris?.map((u) => u.toString()).toList(),
            },
          ];
    _validateQueue(items);
    final session = _sessions.putIfAbsent(
      sessionId,
      () => _WindowsPlaybackSession(sessionId),
    );
    session.queue = items
        .map((item) => Map<String, Object?>.from(item))
        .toList();
    session.index = (queueStartIndex ?? 0).clamp(0, items.length - 1);
    session.volume = _finite(volume, 0, 3);
    session.speed = _finite(speed, 0.25, 3);
    session.effects =
        audioEffects ??
        NativeAudioEffects(
          state: AudioEffectsState.flat,
          channelSwapEnabled: false,
        );
    session.repeatOne = repeatOne;
    session.repeatAll = repeatAll;
    session.shuffle = shuffle;
    session.position = startPosition < Duration.zero
        ? Duration.zero
        : startPosition;
    session.wantsPlay = autoPlay;
    session.error = null;
    session.retryAttempt = 0;
    session.retryStartedAt = null;
    session.retainedUri = null;
    session.retryTimer?.cancel();
    if (!deferPlayerCreation || autoPlay || session.player != null) {
      await _open(session);
    }
    _focusedSessionId = sessionId;
    _emit(session);
    return session.snapshot;
  });

  static void _validateQueue(List<Map<String, Object?>> queue) {
    if (queue.any(
      (item) => item['uri'] is! String || (item['uri'] as String).isEmpty,
    )) {
      throw ArgumentError('Every queue item requires a nonempty uri');
    }
  }

  Future<void> _open(_WindowsPlaybackSession session) async {
    final player = session.player ??= _createPlayer();
    if (session.subscriptions.isEmpty) _subscribe(session, player);
    session.opening = true;
    session.error = null;
    session.generation++;
    session.pendingStart = session.position > Duration.zero
        ? session.position
        : null;
    try {
      final playlist = Playlist([
        for (var i = 0; i < session.queue.length; i++)
          Media(session.queue[i]['uri'] as String),
      ], index: session.index);
      session.mediaUris = playlist.medias.map((media) => media.uri).toList();
      await player.open(playlist, play: false);
      await _applyMode(session);
      await _applyEffects(session);
      await player.setVolume(session.volume * session.fade * 100);
      await player.setRate(session.temporarySpeed ?? session.speed);
      if (session.wantsPlay && session.pendingStart == null) {
        await player.play();
      }
    } finally {
      session.opening = false;
    }
  }

  void _subscribe(_WindowsPlaybackSession session, Player player) {
    session.subscriptions.addAll([
      player.stream.playlist.listen((playlist) {
        if (session.opening || playlist.medias.isEmpty) return;
        final uri = playlist.medias[playlist.index].uri;
        final index = session.mediaUris.indexOf(uri);
        if (index >= 0 && index != session.index) {
          session.index = index;
          session.position = Duration.zero;
          session.retryAttempt = 0;
          session.error = null;
          if (session.retainedUri != null && uri != session.retainedUri) {
            unawaited(
              _change(session.id, (current) async {
                final removed = current.retainedUri;
                if (removed == null) return;
                current.retainedUri = null;
                final at = current.mediaUris.indexOf(removed);
                if (at < 0 || at == current.index) return;
                current.opening = true;
                try {
                  final nativeAt = player.state.playlist.medias.indexWhere(
                    (media) => media.uri == removed,
                  );
                  if (nativeAt >= 0) await player.remove(nativeAt);
                  current.queue.removeAt(at);
                  current.mediaUris.removeAt(at);
                  if (at < current.index) current.index--;
                } finally {
                  current.opening = false;
                }
              }),
            );
          }
        }
        _emit(session);
      }),
      player.stream.playing.listen((_) => _emit(session)),
      player.stream.completed.listen((completed) {
        if (completed && !session.opening && session.error == null) {
          session.wantsPlay = false;
        }
        _emit(session);
      }),
      player.stream.buffering.listen((_) => _emit(session)),
      player.stream.duration.listen((duration) {
        if (duration > Duration.zero && session.pendingStart != null) {
          final generation = session.generation;
          unawaited(
            _change(session.id, (current) async {
              if (generation != current.generation ||
                  current.pendingStart == null) {
                return;
              }
              final position = current.pendingStart!;
              current.pendingStart = null;
              await player.seek(position);
              if (current.wantsPlay) await player.play();
            }),
          );
        }
        _emit(session);
      }),
      player.stream.position.listen((position) {
        if (session.opening || session.pendingStart != null) return;
        if (position > session.position &&
            player.state.playing &&
            session.error == null) {
          session.retryAttempt = 0;
          session.retryStartedAt = null;
        }
        session.position = position;
        if (_listening && !_progress.isClosed) {
          _progress.add(
            NativePlaybackProgressUpdate(
              sessionId: session.id,
              position: position,
              bufferedPosition: player.state.buffer,
              duration: player.state.duration,
              nativeElapsedRealtimeMs: _clock.elapsedMilliseconds,
            ),
          );
        }
      }),
      player.stream.error.listen((error) => _handleError(session, error)),
    ]);
  }

  void _handleError(_WindowsPlaybackSession session, String error) {
    session.error = error;
    _emit(session);
    if (!session.wantsPlay || session.retryTimer?.isActive == true) return;
    final item = session.queue[session.index];
    final candidates =
        (item['candidateUris'] as List?)?.whereType<String>().toList() ?? [];
    final current = candidates.indexOf(item['uri'] as String);
    final next = current + 1;
    final canFallback =
        next < candidates.length && candidates[next] != item['uri'];
    final remote =
        Uri.tryParse(item['uri'] as String)?.scheme.startsWith('http') == true;
    if (!canFallback && !remote) return;
    session.retryStartedAt ??= _clock.elapsed;
    if (_clock.elapsed - session.retryStartedAt! >= const Duration(minutes: 10)) {
      return;
    }
    final generation = session.generation;
    session.retryAttempt++;
    session.retryTimer = Timer(
      Duration(milliseconds: (500 * session.retryAttempt).clamp(500, 15000)),
      () {
        unawaited(
          _change(session.id, (currentSession) async {
            if (currentSession.generation != generation ||
                !currentSession.wantsPlay) {
              return;
            }
            if (canFallback) item['uri'] = candidates[next];
            await _open(currentSession);
          }),
        );
      },
    );
  }

  Future<void> _applyMode(_WindowsPlaybackSession session) async {
    await session.player?.setPlaylistMode(
      session.repeatOne
          ? PlaylistMode.single
          : session.repeatAll
          ? PlaylistMode.loop
          : PlaylistMode.none,
    );
    await session.player?.setShuffle(
      session.shuffle && session.queue.length > 1,
    );
  }

  Future<void> _applyEffects(_WindowsPlaybackSession session) async {
    final platform = session.player?.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('volume-max', '300');
      await platform.setProperty('af', windowsAudioFilter(session.effects));
      await platform.setProperty('audio-pitch-correction', 'yes');
    }
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> play(
    String sessionId, {
    int transportCommandId = 0,
    bool exclusive = false,
  }) => _change(sessionId, (session) async {
    if (exclusive) {
      for (final other in _sessions.values.where((s) => s != session)) {
        other.wantsPlay = false;
        await other.player?.pause();
        _emit(other);
      }
    }
    session.commandId = transportCommandId;
    session.wantsPlay = true;
    _focusedSessionId = sessionId;
    if (session.player == null || session.error != null) {
      session.retryAttempt = 0;
      await _open(session);
    } else if (session.pendingStart == null) {
      await session.player!.play();
    }
  });

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) => _change(sessionId, (session) async {
    session.commandId = transportCommandId;
    session.wantsPlay = false;
    session.retryTimer?.cancel();
    await session.player?.pause();
  });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) =>
      _change(sessionId, (session) async {
        session.wantsPlay = false;
        session.retryTimer?.cancel();
        session.pendingStart = null;
        await session.player?.pause();
        await session.player?.seek(Duration.zero);
        session.position = Duration.zero;
      });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) => _change(sessionId, (session) async {
    session.position = position < Duration.zero ? Duration.zero : position;
    if (session.pendingStart != null) {
      session.pendingStart = session.position;
    } else {
      await session.player?.seek(session.position);
    }
  });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  }) => _change(sessionId, (session) async {
    session.volume = _finite(volume, 0, 3);
    await session.player?.setVolume(session.volume * session.fade * 100);
  });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setSpeed(
    String sessionId,
    double speed,
  ) => _change(sessionId, (session) async {
    session.speed = _finite(speed, 0.25, 3);
    await session.player?.setRate(session.temporarySpeed ?? session.speed);
  });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setTemporarySpeed(
    String sessionId,
    double? speed,
  ) => _change(sessionId, (session) async {
    session.temporarySpeed = speed == null ? null : _finite(speed, 0.25, 3);
    await session.player?.setRate(session.temporarySpeed ?? session.speed);
  });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setRepeatOne(
    String sessionId,
    bool repeatOne, {
    List<Map<String, Object?>>? queue,
    int? queueStartIndex,
    bool repeatAll = false,
    bool shuffle = false,
  }) => _change(sessionId, (session) async {
    session.repeatOne = repeatOne;
    session.repeatAll = repeatAll;
    session.shuffle = shuffle;
    if (queue != null && queue.isNotEmpty) {
      _validateQueue(queue);
      final previous = session.queue[session.index];
      final items = queue
          .map((item) => Map<String, Object?>.from(item))
          .toList();
      var index = items.indexWhere(
        (item) => item['path'] != null
            ? item['path'] == previous['path']
            : item['uri'] == previous['uri'],
      );
      // A removed current track finishes playing before the new queue advances.
      if (index < 0) {
        session.retainedUri = Media(previous['uri'] as String).uri;
        items.insert(0, previous);
        index = 0;
      } else {
        session.retainedUri = null;
      }
      session.queue = items;
      session.index = index;
      final player = session.player;
      if (player != null) {
        // Keep the current decoder alive: rebuilding via open causes an audible gap.
        session.opening = true;
        try {
          final nativeIndex = player.state.playlist.index;
          for (var i = player.state.playlist.medias.length - 1; i >= 0; i--) {
            if (i != nativeIndex) await player.remove(i);
          }
          for (var i = 0; i < items.length; i++) {
            if (i != index) await player.add(Media(items[i]['uri'] as String));
          }
          if (index != 0) await player.move(0, index);
          session.mediaUris = items
              .map((item) => Media(item['uri'] as String).uri)
              .toList();
          await _applyMode(session);
        } finally {
          session.opening = false;
        }
      }
    } else {
      await _applyMode(session);
    }
  });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) => _change(sessionId, (session) async {
    session.effects = effects;
    await _applyEffects(session);
  });
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setFadeMultiplier(
    String sessionId,
    double multiplier,
  ) => _change(sessionId, (session) async {
    session.fade = _finite(multiplier, 0, 1);
    await session.player?.setVolume(session.volume * session.fade * 100);
  });
  @override
  Future<NativeResult<void>> removeSession(String sessionId) => _run(() async {
    await _sessions.remove(sessionId)?.dispose();
    if (_focusedSessionId == sessionId) {
      _focusedSessionId = _sessions.keys.firstOrNull;
    }
  });
  @override
  Future<NativeResult<void>> pauseAll() => _run(() async {
    for (final session in _sessions.values) {
      session.wantsPlay = false;
      session.retryTimer?.cancel();
      await session.player?.pause();
      _emit(session);
    }
  });
  @override
  Future<NativeResult<void>> clearAll() => _run(() async {
    for (final session in _sessions.values) {
      await session.dispose();
    }
    _sessions.clear();
    _focusedSessionId = null;
  });
  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() => _run(
    () async => NativePlaybackBundleSnapshot(
      sessions: _sessions.values.map((s) => s.snapshot).toList(),
      focusedSessionId: _focusedSessionId,
    ),
  );
  @override
  Future<NativeResult<void>> setPlaybackBehavior({
    required bool pauseOnAudioDeviceDisconnect,
    required bool requestAudioFocus,
    required bool pauseOnTransientAudioFocusLoss,
    required bool resumeAfterTransientAudioFocusGain,
  }) async {
    _pauseOnDisconnect = pauseOnAudioDeviceDisconnect;
    return const NativeSuccess();
  }

  /// Called by the Windows endpoint notification, sharing the saved preference.
  Future<void> handleDeviceDisconnected() async {
    if (_pauseOnDisconnect) await pauseAll();
  }

  // Desktop lifetime and system media UI are owned by the Windows host.
  @override
  Future<NativeResult<void>> setForegroundEnabled(bool enabled) async =>
      const NativeSuccess();
  @override
  Future<NativeResult<void>> dismissNotifications() async =>
      const NativeSuccess();
  @override
  Future<NativeResult<void>> undismissNotifications() async =>
      const NativeSuccess();
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _listening = false;
    await clearAll();
    await _snapshots.close();
    await _progress.close();
  }
}

class _WindowsPlaybackSession {
  _WindowsPlaybackSession(this.id);
  final String id;
  Player? player;
  VideoController? videoController;
  final subscriptions = <StreamSubscription<dynamic>>[];
  List<Map<String, Object?>> queue = [];
  List<String> mediaUris = [];
  int index = 0;
  Duration position = Duration.zero;
  Duration? pendingStart;
  double volume = 1, speed = 1, fade = 1;
  double? temporarySpeed;
  bool repeatOne = false,
      repeatAll = false,
      shuffle = false,
      wantsPlay = false,
      opening = false;
  NativeAudioEffects effects = NativeAudioEffects(
    state: AudioEffectsState.flat,
    channelSwapEnabled: false,
  );
  String? error;
  String? retainedUri;
  int commandId = 0, retryAttempt = 0, generation = 0;
  Timer? retryTimer;
  Duration? retryStartedAt;

  NativePlaybackSnapshot get snapshot {
    final item = queue[index];
    final state = player?.state;
    return NativePlaybackSnapshot(
      sessionId: id,
      uri: item['uri'] as String?,
      path: item['path'] as String?,
      title: item['title'] as String?,
      subtitle: item['subtitle'] as String?,
      artUri: item['artUri'] as String?,
      playing: state?.playing == true && !opening && error == null,
      playWhenReady: wantsPlay,
      processingState: opening || pendingStart != null
          ? 'loading'
          : state == null
          ? 'idle'
          : state.completed
          ? 'completed'
          : state.buffering
          ? 'buffering'
          : 'ready',
      position: position,
      bufferedPosition: state?.buffer ?? Duration.zero,
      duration: state?.duration,
      volume: volume,
      speed: speed,
      boostGain: volume > 1 ? volume : 1,
      channelSwapEnabled: effects.channelSwapEnabled,
      audioEffects: effects.state,
      eqCapabilities: windowsEqCapabilities,
      error: error,
      queueIndex: index,
      retainedUris: queue.map((i) => i['uri'] as String).toList(),
      hasRetainedUrisPayload: true,
      transportCommandId: commandId,
    );
  }

  Future<void> dispose() async {
    retryTimer?.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player?.dispose();
    videoController = null;
  }
}

double _finite(double value, double min, double max) {
  if (!value.isFinite) {
    throw ArgumentError.value(value, 'value', 'Must be finite');
  }
  return value.clamp(min, max);
}

final windowsEqCapabilities = EqCapabilities(
  supported: true,
  bands: [
    for (final frequency in [60, 170, 310, 600, 1000, 3000, 6000, 12000])
      EqBandInfo(frequencyHz: frequency),
  ],
);

String windowsAudioFilter(NativeAudioEffects effects) {
  final state = effects.state;
  final filters = <String>[];
  if (state.noiseReductionEnabled) filters.add('afftdn=nf=-25');
  if (state.eqEnabled) {
    for (final entry in state.eqBandLevels.entries) {
      if (entry.key > 0) {
        filters.add(
          'equalizer=f=${entry.key}:t=o:w=1:g=${_finite(entry.value, -12, 12)}',
        );
      }
    }
  }
  if (state.volumeNormalizationEnabled) filters.add('dynaudnorm=f=150:g=15');
  if (state.skipSilenceEnabled) {
    filters.add(
      'silenceremove=start_periods=1:start_duration=0.1:start_threshold=-50dB:stop_periods=-1:stop_duration=0.1:stop_threshold=-50dB:timestamp=copy',
    );
  }
  final pan = _finite(state.panning, -1, 1);
  if (effects.channelSwapEnabled || pan != 0) {
    filters.add('aformat=channel_layouts=stereo');
    final left = pan > 0 ? 1 - pan : 1.0;
    final right = pan < 0 ? 1 + pan : 1.0;
    filters.add(
      'pan=args=stereo|c0=$left*${effects.channelSwapEnabled ? 'c1' : 'c0'}|c1=$right*${effects.channelSwapEnabled ? 'c0' : 'c1'}',
    );
  }
  return filters.isEmpty ? '' : 'lavfi=[${filters.join(',')}]';
}
