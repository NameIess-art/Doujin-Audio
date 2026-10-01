import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/errors/native_result.dart';
import '../../../core/immutable_collections.dart';
import '../domain/audio_effects.dart';
import 'native_playback_bridge.dart';

part 'windows_playback_session.dart';

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
  final _retiring = <Future<void>>{};
  String? _focusedSessionId;
  bool _listening = false;
  bool _pauseOnDisconnect = true;
  bool _disposed = false;

  Player? playerForSession(String sessionId) => _sessions[sessionId]?.player;
  VideoController? videoControllerForSession(String sessionId) {
    final session = _sessions[sessionId];
    final player = session?.player;
    if (session == null || player == null || !session.wantsPlay) return null;
    if (session.videoController == null) {
      session.videoController = VideoController(player);
      unawaited(
        _change(sessionId, (current) async {
          await player.platform!.waitForVideoControllerInitializationIfAttached;
          if (current.wantsPlay) await _playIfIdle(current);
        }),
      );
    }
    return session.videoController;
  }

  Future<void> _playIfIdle(_WindowsPlaybackSession session) async {
    if (!_isCurrent(session) || !session.wantsPlay) return;
    final player = session.player;
    if (player == null) return;
    final generation = session.generation;
    final native = player.platform;
    if (session.videoController != null &&
        native is NativePlayer &&
        !player.state.completed &&
        await native.getProperty('playlist-pos') == '-1') {
      if (!_isCurrent(session) ||
          generation != session.generation ||
          !session.wantsPlay) {
        return;
      }
      await player.jump(session.index);
      if (_isCurrent(session) &&
          generation == session.generation &&
          session.wantsPlay) {
        await player.play();
      }
    }
  }

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _snapshots.stream;
  @override
  Stream<NativePlaybackProgressUpdate> get progressUpdates => _progress.stream;
  @override
  void startListening() => _listening = true;
  @override
  Future<void> stopListening() async => _listening = false;

  void _emit(_WindowsPlaybackSession session) {
    if (!_listening ||
        session.opening ||
        session.eventPending ||
        !_isCurrent(session)) {
      return;
    }
    session.eventPending = true;
    scheduleMicrotask(() {
      session.eventPending = false;
      if (!_listening ||
          session.opening ||
          !_isCurrent(session) ||
          _snapshots.isClosed ||
          session.queue.isEmpty) {
        return;
      }
      final snapshot = session.snapshot(
        includeRetainedUris:
            session.emittedQueueRevision != session.queueRevision,
      );
      final key = (
        snapshot.uri,
        snapshot.path,
        snapshot.title,
        snapshot.subtitle,
        snapshot.artUri,
        snapshot.playing,
        snapshot.playWhenReady,
        snapshot.processingState,
        snapshot.duration,
        snapshot.volume,
        snapshot.speed,
        snapshot.audioEffects,
        snapshot.channelSwapEnabled,
        snapshot.error,
        snapshot.queueIndex,
        snapshot.transportCommandId,
        session.queueRevision,
      );
      if (key == session.lastEventKey) return;
      session.lastEventKey = key;
      session.emittedQueueRevision = session.queueRevision;
      _snapshots.add(snapshot);
    });
  }

  bool _isCurrent(_WindowsPlaybackSession session) =>
      !session.retired && identical(_sessions[session.id], session);

  void _focus(String sessionId) {
    _focusedSessionId = sessionId;
  }

  Future<void> _releaseIfIdle(_WindowsPlaybackSession session) async {
    if (session.wantsPlay) {
      return;
    }
    await session.releasePlayer();
  }

  Future<NativeResult<T>> _run<T>(Future<T?> Function() action) async {
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
  }

  Future<NativeResult<NativePlaybackSnapshot>> _change(
    String id,
    Future<void> Function(_WindowsPlaybackSession) action,
  ) {
    final session = _sessions[id];
    if (session == null || _disposed) {
      return Future.value(
        NativeFailure(
          'Unknown session: $id',
          code: NativeErrorCode.invalidArgument,
        ),
      );
    }
    return session.enqueue(
      () => _run(() async {
        if (!_isCurrent(session)) {
          throw ArgumentError.value(id, 'sessionId', 'Session was removed');
        }
        try {
          await action(session);
          if (!_isCurrent(session)) {
            throw ArgumentError.value(id, 'sessionId', 'Session was removed');
          }
          _emit(session);
          return session.snapshot(includeRetainedUris: false);
        } catch (error) {
          if (_isCurrent(session) && error is! ArgumentError) {
            session.error = error.toString();
            _emit(session);
          }
          rethrow;
        }
      }),
    );
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
    bool isTemporary = false,
  }) {
    try {
      if (sessionId.trim().isEmpty || uri.toString().isEmpty) {
        throw ArgumentError('sessionId and uri are required');
      }
      if (_disposed) throw ArgumentError('Playback bridge was disposed');
      final items = queue?.isNotEmpty == true
          ? queue!
          : <Map<String, Object?>>[
              {
                'uri': uri.toString(),
                'path': path,
                'title': title,
                'subtitle': subtitle,
                'artUri': artUri?.toString(),
                'candidateUris': candidateUris
                    ?.map((u) => u.toString())
                    .toList(),
              },
            ];
      _validateQueue(items);
      final session = _sessions.putIfAbsent(
        sessionId,
        () => _WindowsPlaybackSession(sessionId),
      );
      final generation = ++session.generation;
      session.wantsPlay = autoPlay;
      session.cancelRetry();
      _focus(sessionId);
      return _change(sessionId, (session) async {
        if (generation != session.generation) {
          throw ArgumentError('Playback preparation was superseded');
        }
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
        session.error = null;
        session.completed = false;
        session.retryAttempt = 0;
        session.retryStartedAt = null;
        session.hasRetainedCurrent = false;
        session.externalQueueRevision = 0;
        if (session.wantsPlay) {
          await _open(session);
        } else {
          await session.releasePlayer();
        }
      });
    } on ArgumentError catch (error) {
      return Future.value(
        NativeFailure(error.toString(), code: NativeErrorCode.invalidArgument),
      );
    }
  }

  static void _validateQueue(List<Map<String, Object?>> queue) {
    if (queue.isEmpty ||
        queue.any(
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
    final generation = session.generation;
    session.pendingStart = session.position > Duration.zero
        ? session.position
        : null;
    try {
      final playlist = Playlist([
        for (var i = 0; i < session.queue.length; i++)
          Media(session.queue[i]['uri'] as String),
      ], index: session.index);
      await player.open(playlist, play: false);
      if (!_isCurrent(session) || generation != session.generation) {
        throw ArgumentError('Playback preparation was superseded');
      }
      await _applyMode(session);
      await _applyEffects(session);
      await player.setVolume(session.volume * session.fade * 100);
      await player.setRate(session.temporarySpeed ?? session.speed);
      if (_isCurrent(session) &&
          generation == session.generation &&
          session.wantsPlay &&
          session.pendingStart == null) {
        await player.play();
      }
      if (!_isCurrent(session) || generation != session.generation) {
        throw ArgumentError('Playback preparation was superseded');
      }
    } finally {
      session.opening = false;
    }
  }

  void _subscribe(_WindowsPlaybackSession session, Player player) {
    session.subscriptions.addAll([
      player.stream.playlist.listen((playlist) {
        if (!_isCurrent(session) ||
            !identical(session.player, player) ||
            session.opening ||
            playlist.medias.isEmpty) {
          return;
        }
        final index = playlist.index;
        if (index >= 0 &&
            index < session.queue.length &&
            index != session.index) {
          session.index = index;
          session.position = Duration.zero;
          session.retryAttempt = 0;
          session.error = null;
          if (session.hasRetainedCurrent && index != 0) {
            final generation = session.generation;
            unawaited(
              _change(session.id, (current) async {
                if (generation != current.generation ||
                    !current.hasRetainedCurrent ||
                    current.index == 0) {
                  return;
                }
                current.hasRetainedCurrent = false;
                current.opening = true;
                try {
                  await current.player?.remove(0);
                  current.queue.removeAt(0);
                  current.invalidateRetainedUris();
                  current.index--;
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
        if (!_isCurrent(session) || !identical(session.player, player)) return;
        if (completed && !session.opening && session.error == null) {
          session.wantsPlay = false;
          session.completed = true;
        }
        _emit(session);
        if (completed) unawaited(_change(session.id, _releaseIfIdle));
      }),
      player.stream.buffering.listen((_) => _emit(session)),
      player.stream.duration.listen((duration) {
        if (!_isCurrent(session) || !identical(session.player, player)) return;
        session.duration = duration;
        if (duration > Duration.zero && session.pendingStart != null) {
          final generation = session.generation;
          unawaited(
            _change(session.id, (current) async {
              if (generation != current.generation ||
                  !identical(current.player, player) ||
                  current.pendingStart == null) {
                return;
              }
              final position = current.pendingStart!;
              current.pendingStart = null;
              await player.seek(position);
              if (_isCurrent(current) &&
                  generation == current.generation &&
                  current.wantsPlay) {
                await player.play();
              }
            }),
          );
        }
        _emit(session);
      }),
      player.stream.position.listen((position) {
        if (!_isCurrent(session) ||
            !identical(session.player, player) ||
            session.opening ||
            session.pendingStart != null) {
          return;
        }
        if (position > session.position &&
            player.state.playing &&
            session.error == null) {
          session.retryAttempt = 0;
          session.retryStartedAt = null;
        }
        session.position = position;
        if (_listening &&
            !_progress.isClosed &&
            (player.state.playing || session.wantsPlay) &&
            position != session.lastProgressPosition) {
          session.lastProgressPosition = position;
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
      player.stream.error.listen((error) {
        if (identical(session.player, player)) _handleError(session, error);
      }),
    ]);
  }

  void _handleError(_WindowsPlaybackSession session, String error) {
    if (!_isCurrent(session)) return;
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
    if (_clock.elapsed - session.retryStartedAt! >=
        const Duration(minutes: 10)) {
      return;
    }
    final generation = session.generation;
    final retryGeneration = session.retryGeneration;
    session.retryAttempt++;
    session.retryTimer = Timer(
      Duration(milliseconds: (500 * session.retryAttempt).clamp(500, 15000)),
      () {
        unawaited(
          _change(session.id, (currentSession) async {
            if (currentSession.generation != generation ||
                currentSession.retryGeneration != retryGeneration ||
                !currentSession.wantsPlay) {
              return;
            }
            if (canFallback) {
              item['uri'] = candidates[next];
              currentSession.invalidateRetainedUris();
            }
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
  }) {
    final current = _sessions[sessionId];
    if (current == null || _disposed) {
      return Future.value(
        NativeFailure(
          'Unknown session: $sessionId',
          code: NativeErrorCode.invalidArgument,
        ),
      );
    }
    current.wantsPlay = true;
    current.commandId = transportCommandId;
    _focus(sessionId);
    final pausedOthers = exclusive
        ? Future.wait([
            for (final other in _sessions.values.toList())
              if (other.id != sessionId &&
                  (other.wantsPlay || other.player?.state.playing == true))
                pause(other.id),
          ])
        : Future.value(const <NativeResult<NativePlaybackSnapshot>>[]);
    return _change(sessionId, (session) async {
      final results = await pausedOthers;
      final failure = results.where((result) => result.isFailure).firstOrNull;
      if (failure != null) throw StateError(failure.errorOrNull!);
      if (!session.wantsPlay) return;
      if (session.completed) {
        session.position = Duration.zero;
        session.completed = false;
      }
      if (session.player == null || session.error != null) {
        session.retryAttempt = 0;
        session.generation++;
        await _open(session);
      } else if (session.pendingStart == null) {
        await session.player!.play();
        await _playIfIdle(session);
      }
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) {
    final current = _sessions[sessionId];
    if (current != null) {
      current.commandId = transportCommandId;
      current.wantsPlay = false;
      current.cancelRetry();
    }
    return _change(sessionId, (session) async {
      if (session.wantsPlay) return;
      await session.player?.pause();
      await _releaseIfIdle(session);
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) {
    final current = _sessions[sessionId];
    current?.wantsPlay = false;
    current?.cancelRetry();
    return _change(sessionId, (session) async {
      if (session.wantsPlay) return;
      session.pendingStart = null;
      session.completed = false;
      await session.player?.pause();
      await session.player?.seek(Duration.zero);
      session.position = Duration.zero;
      await _releaseIfIdle(session);
    });
  }

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
  }) {
    final current = _sessions[sessionId];
    if (queue != null && queue.isNotEmpty && current != null) {
      current.cancelRetry();
    }
    return _change(sessionId, (session) async {
      session.repeatOne = repeatOne;
      session.repeatAll = repeatAll;
      session.shuffle = shuffle;
      if (queue != null && queue.isNotEmpty) {
        await _updateQueue(session, queue, queueStartIndex: queueStartIndex);
      }
      await _applyMode(session);
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> updateQueue(
    String sessionId, {
    required List<Map<String, Object?>> queue,
    int? queueStartIndex,
    int queueRevision = 0,
    bool repeatOne = false,
    bool repeatAll = false,
    bool shuffle = false,
  }) {
    final current = _sessions[sessionId];
    if (current != null &&
        (queueRevision == 0 || queueRevision > current.externalQueueRevision)) {
      current.cancelRetry();
    }
    return _change(sessionId, (session) async {
      if (queueRevision > 0 && queueRevision <= session.externalQueueRevision) {
        return;
      }
      if (queueRevision < 0) {
        throw ArgumentError('queueRevision must be nonnegative');
      }
      await _updateQueue(session, queue, queueStartIndex: queueStartIndex);
      session.externalQueueRevision = queueRevision;
      session.repeatOne = repeatOne;
      session.repeatAll = repeatAll;
      session.shuffle = shuffle;
      await _applyMode(session);
    });
  }

  Future<void> _updateQueue(
    _WindowsPlaybackSession session,
    List<Map<String, Object?>> queue, {
    int? queueStartIndex,
  }) async {
    _validateQueue(queue);
    if (queueStartIndex != null &&
        (queueStartIndex < 0 || queueStartIndex >= queue.length)) {
      throw ArgumentError('queueStartIndex is outside the queue');
    }
    await session.updateQueue(
      queue,
      queueStartIndex: queueStartIndex,
      isCurrent: () => _isCurrent(session),
    );
  }

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
  Future<NativeResult<void>> removeSession(String sessionId) {
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.retired = true;
      session.wantsPlay = false;
      session.generation++;
      session.cancelRetry();
    }
    if (_focusedSessionId == sessionId) {
      _focusedSessionId = _sessions.keys.firstOrNull;
    }
    return _run(() async {
      if (session == null) return;
      final retiring = session.enqueue(session.releasePlayer);
      _retiring.add(retiring);
      try {
        await retiring;
      } finally {
        _retiring.remove(retiring);
      }
    });
  }

  @override
  Future<NativeResult<void>> pauseAll() => _run(() async {
    final results = await Future.wait([
      for (final session in _sessions.values.toList()) pause(session.id),
    ]);
    final failure = results.where((result) => result.isFailure).firstOrNull;
    if (failure != null) throw StateError(failure.errorOrNull!);
  });
  @override
  Future<NativeResult<void>> clearAll() => _run(() async {
    final results = await Future.wait([
      for (final id in _sessions.keys.toList()) removeSession(id),
    ]);
    final failure = results.where((result) => result.isFailure).firstOrNull;
    if (failure != null) throw StateError(failure.errorOrNull!);
  });
  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() => _run(
    () async => NativePlaybackBundleSnapshot(
      sessions: _sessions.values
          .where((s) => s.queue.isNotEmpty)
          .map((s) => s.snapshot())
          .toList(),
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

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _listening = false;
    await clearAll();
    await Future.wait(_retiring.toList());
    await _snapshots.close();
    await _progress.close();
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
  minGainDb: -18,
  maxGainDb: 18,
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
          'equalizer=f=${entry.key}:t=o:w=1:g=${_finite(entry.value, windowsEqCapabilities.minGainDb, windowsEqCapabilities.maxGainDb)}',
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
