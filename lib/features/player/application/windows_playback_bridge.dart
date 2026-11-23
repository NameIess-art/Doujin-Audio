import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/errors/native_result.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/playback_media_reference.dart';
import '../../../core/network/app_network.dart';
import '../domain/audio_effects.dart';
import '../domain/playback_usage.dart';
import 'playback_usage_ledger.dart';
import 'native_playback_bridge.dart';

part 'windows_playback_session.dart';

/// The desktop implementation of the existing playback transport. Each session
/// owns one libmpv player; video surfaces borrow it without opening another source.
class WindowsPlaybackBridge
    implements NativePlaybackBridgeBase, PlaybackUsageSource {
  static const defaultIdleReleaseDelay = Duration(seconds: 45);

  WindowsPlaybackBridge({
    Player Function()? createPlayer,
    bool persistUsage = false,
    Future<String> Function(Player)? readNativePlaylist,
    Duration Function()? monotonicElapsed,
    VideoControllerConfiguration videoControllerConfiguration =
        const VideoControllerConfiguration(),
    Duration idleReleaseDelay = defaultIdleReleaseDelay,
  }) : _persistUsage = persistUsage,
       _createPlayer = createPlayer ?? _defaultPlayer,
       _readNativePlaylist = readNativePlaylist,
       _monotonicElapsed = monotonicElapsed,
       _videoControllerConfiguration = videoControllerConfiguration,
       _idleReleaseDelay = idleReleaseDelay;

  static WindowsPlaybackBridge? _instance;
  static WindowsPlaybackBridge get instance {
    if (_instance == null || _instance!._disposed) {
      _instance = WindowsPlaybackBridge(persistUsage: true);
    }
    return _instance!;
  }

  static bool _mediaKitInitialized = false;

  static Player _defaultPlayer() {
    if (!_mediaKitInitialized) {
      MediaKit.ensureInitialized();
      _mediaKitInitialized = true;
    }
    final player = Player(
      configuration: const PlayerConfiguration(title: 'Doujin Audio'),
    );
    if (const bool.fromEnvironment('WINDOWS_TEST_NULL_AUDIO')) {
      (player.platform! as NativePlayer).setProperty('ao', 'null');
    }
    return player;
  }

  final bool _persistUsage;
  File? _usageFile;
  bool _usageLoaded = false;
  Future<void> _usageSerial = Future.value();
  Timer? _usageTimer;
  bool _usageStarted = false;
  int? _persistedUsageRevision;

  Future<void> _loadUsage() async {
    if (!_persistUsage) return;
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final file = File('${directory.path}/playback_usage.json');
    _usageFile = file;
    try {
      final encoded = utf8.decode(await file.readAsBytes());
      final stored = jsonDecode(encoded) as Map<String, dynamic>;
      _usage.restoreState(stored);
      _persistedUsageRevision = _usage.revision;
    } on PathNotFoundException {
      _persistedUsageRevision = _usage.revision;
    } catch (error) {
      if (error is! FormatException &&
          error is! TypeError &&
          error is! UnsupportedError) {
        rethrow;
      }
      // Rewrite invalid data even when a reset leaves the ledger empty.
      _persistedUsageRevision = null;
      AppLogService.warning('windows_playback_usage_invalid');
    }
    if (_disposed) return;
    _usageTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(
        _usageOperation(() {
          _refreshUsage();
          _usage.checkpoint();
        }).then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            AppLogService.error(
              'Playback usage checkpoint failed',
              error: error,
              stackTrace: stack,
            );
          },
        ),
      );
    });
  }

  Future<T> _usageOperation<T>(T Function() operation) {
    final result = _usageSerial.then((_) async {
      if (!_usageLoaded) {
        await _loadUsage();
        _usageLoaded = true;
      }
      final value = operation();
      final file = _usageFile;
      final revision = _usage.revision;
      if (file != null && revision != _persistedUsageRevision) {
        final encoded = jsonEncode(_usage.exportState());
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(encoded, flush: true);
        await temporary.rename(file.path);
        _persistedUsageRevision = revision;
      }
      return value;
    });
    _usageSerial = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  final Player Function() _createPlayer;
  final Future<String> Function(Player)? _readNativePlaylist;
  final VideoControllerConfiguration _videoControllerConfiguration;
  final Duration _idleReleaseDelay;
  final _sessions = <String, _WindowsPlaybackSession>{};
  final _configuredProxyUrl = Expando<String>();
  final _appliedAudioFilters = Expando<String>();
  final _snapshots = StreamController<NativePlaybackSnapshot>.broadcast();
  final _progress = StreamController<NativePlaybackProgressUpdate>.broadcast();
  final _clock = Stopwatch()..start();
  final Duration Function()? _monotonicElapsed;
  Duration get _elapsed => _monotonicElapsed?.call() ?? _clock.elapsed;
  late final _usage = PlaybackUsageLedger(elapsed: () => _elapsed);

  void _updateUsage(_WindowsPlaybackSession session) {
    final state = session.player?.state;
    final audible =
        !session.retired &&
        !session.opening &&
        session.pendingStart == null &&
        session.error == null &&
        state?.playing == true &&
        state?.buffering == false &&
        state?.completed == false &&
        session.queue.isNotEmpty;
    if (audible) _usageStarted = true;
    _usage.update(session.id, audible ? session.queue[session.index] : null);
  }

  void _refreshUsage() {
    for (final session in _sessions.values) {
      _updateUsage(session);
    }
  }

  @override
  Future<List<PlaybackUsageBatch>> readUsage() => _usageOperation(() {
    _refreshUsage();
    return _usage.read();
  });

  @override
  Future<void> acknowledgeUsage(List<String> batchIds) =>
      _usageOperation(() {
        _usage.acknowledge(batchIds);
        _usage.checkpoint();
      });

  @override
  Future<void> resetUsage() => _usageOperation(_usage.reset);

  final _retiring = <Future<void>>{};
  String? _focusedSessionId;
  bool _listening = false;
  bool _pauseOnDisconnect = true;
  bool _disposed = false;

  @override
  bool get handlesQueueCompletion => false;

  Player? playerForSession(String sessionId) => _sessions[sessionId]?.player;

  @override
  void attachVideoSurface(String sessionId) {
    final session = _sessions[sessionId];
    if (_disposed || session == null || session.retired) return;
    session.mountedVideoSurfaces++;
    session.hadVideoSurfaceAttached = true;
    session.cancelIdleRelease();
  }

  @override
  void detachVideoSurface(String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.mountedVideoSurfaces > 0) {
      session.mountedVideoSurfaces--;
    }
    if (_disposed ||
        session.retired ||
        session.mountedVideoSurfaces > 0 ||
        session.wantsPlay ||
        session.player == null) {
      return;
    }
    if (_idleReleaseDelay <= Duration.zero) {
      unawaited(
        _change(sessionId, _releaseIfIdle, markPlaybackError: false),
      );
    } else {
      _scheduleIdleRelease(session);
    }
  }

  @override
  VideoController? videoControllerForSession(String sessionId) {
    final session = _sessions[sessionId];
    final player = session?.player;
    if (_disposed || session == null || session.retired || player == null) {
      return null;
    }
    if (session.videoController == null) {
      final generation = session.generation;
      session.videoController = VideoController(
        player,
        configuration: _videoControllerConfiguration,
      );
      unawaited(
        _change(sessionId, (current) async {
          if (generation != current.generation ||
              !identical(current.player, player)) {
            return;
          }
          final platform = player.platform;
          if (platform == null) return;
          final position = current.position;
          // Changing from null output to the render context may emit an unload/EOF.
          // Treat it as source preparation, preserving the user's playback intent.
          current.opening = true;
          try {
            await platform.waitForVideoControllerInitializationIfAttached;
            if (!_isCurrent(current) ||
                generation != current.generation ||
                !identical(current.player, player)) {
              return;
            }
            if (platform is NativePlayer) {
              // Switching output before its render context exists can disable
              // video while audio keeps the file loaded. Reset the saved auto
              // selection before selecting again; another auto alone is ignored.
              await platform.setProperty('vid', 'no');
              await platform.setProperty('vid', 'auto');
            }
            await _loadVideoIfIdle(current, position: position);
            if (!_isCurrent(current) ||
                generation != current.generation ||
                !identical(current.player, player)) {
              return;
            }
            if (!current.wantsPlay &&
                position > Duration.zero &&
                current.pendingStart == null &&
                player.state.position != position) {
              await player.seek(current.absolutePosition(position));
              current.position = position;
            }
            final controller = current.videoController;
            final video = player.state.videoParams;
            final width = video.dw;
            final height = video.dh;
            if (controller != null &&
                (controller.rect.value?.width ?? 0) <= 0 &&
                width != null &&
                width > 0 &&
                height != null &&
                height > 0) {
              // media_kit_video does not replay dimensions decoded before the
              // controller subscribed. Seed that first size; later events resize it.
              final rotated = video.rotate == 90 || video.rotate == 270;
              await controller.setSize(
                width: rotated ? height : width,
                height: rotated ? width : height,
              );
            }
          } finally {
            current.opening = false;
          }
        }, markPlaybackError: false),
      );
    }
    return session.videoController;
  }

  Future<void> _loadVideoIfIdle(
    _WindowsPlaybackSession session, {
    Duration? position,
  }) async {
    if (!_isCurrent(session)) return;
    final player = session.player;
    if (player == null) return;
    final generation = session.generation;
    final native = player.platform;
    if (session.videoController != null &&
        native is NativePlayer &&
        await native.getProperty('playlist-pos') == '-1') {
      if (!_isCurrent(session) || generation != session.generation) {
        return;
      }
      // Installing the render context can unload null output. Reuse the normal
      // open/seek sequence so the saved position is applied after source loading.
      session.position = position ?? session.position;
      await _open(session);
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
    _updateUsage(session);
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
        snapshot.stopAfterCurrentTrack,
        session.queueRevision,
        session.seekRevision,
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

  bool _shouldRetainPausedPlayer(_WindowsPlaybackSession session) {
    if (session.error != null || session.queue.isEmpty) return false;
    // Once mounted video surfaces have all unmounted, do not retain the paused
    // decoder indefinitely; let the normal idle release policy free libmpv.
    if (session.hadVideoSurfaceAttached && session.mountedVideoSurfaces <= 0) {
      return false;
    }
    final video = session.player?.state.videoParams;
    // Demuxed tracks identify video before its decoder produces dimensions.
    final hasVideoTrack =
        session.player?.state.tracks.video.any(
          (track) =>
              track.id != 'auto' && track.id != 'no' && track.albumart != true,
        ) ??
        false;
    // Pause may arrive before tracks, dimensions or the first surface exist.
    // Keep a known video source loaded so it can still produce its paused frame.
    return isVideoMediaFile(
          session.queue[session.index]['path'] as String? ??
              Uri.parse(session.queue[session.index]['uri'] as String).path,
        ) ||
        hasVideoTrack ||
        ((video?.w ?? 0) > 0 && (video?.h ?? 0) > 0);
  }

  void _scheduleIdleRelease(_WindowsPlaybackSession session) {
    session.cancelIdleRelease();
    if (_disposed ||
        session.retired ||
        session.wantsPlay ||
        session.player == null ||
        _idleReleaseDelay <= Duration.zero) {
      return;
    }
    final generation = session.generation;
    final idleGeneration = session.idleReleaseGeneration;
    session.idleReleaseTimer = Timer(_idleReleaseDelay, () {
      if (_disposed || !_isCurrent(session)) return;
      unawaited(
        _change(session.id, (current) async {
          if (current.generation != generation ||
              current.idleReleaseGeneration != idleGeneration ||
              current.wantsPlay) {
            return;
          }
          await _releaseIfIdle(current);
        }, markPlaybackError: false),
      );
    });
  }

  Future<void> _releaseIfIdle(_WindowsPlaybackSession session) async {
    if (session.wantsPlay) {
      return;
    }
    if (_shouldRetainPausedPlayer(session)) {
      if (session.temporarySpeed != null) {
        session.temporarySpeed = null;
        await session.player?.setRate(session.speed);
      }
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
    } on _WindowsBridgeFailure catch (error) {
      return NativeFailure<T>(error.message, code: error.code);
    } catch (error) {
      return NativeFailure<T>(
        error.toString(),
        code: NativeErrorCode.playerError,
      );
    }
  }

  Future<NativeResult<NativePlaybackSnapshot>> _change(
    String id,
    Future<void> Function(_WindowsPlaybackSession) action, {
    bool markPlaybackError = true,
  }) {
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
          if (markPlaybackError &&
              _isCurrent(session) &&
              error is! ArgumentError &&
              error is! _WindowsBridgeFailure) {
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
    bool reuseExistingQueue = false,
  }) {
    try {
      if (audioEffects != null) {
        _finite(audioEffects.state.frontBack, -1, 1);
      }
      if (sessionId.trim().isEmpty || uri.toString().isEmpty) {
        throw ArgumentError('sessionId and uri are required');
      }
      if (_disposed) throw ArgumentError('Playback bridge was disposed');
      if (reuseExistingQueue) {
        if (!_sessions.containsKey(sessionId)) {
          return Future.value(
            const NativeFailure(
              'Session does not have an existing queue to reuse',
              code: nativePlaybackQueueResyncRequiredCode,
            ),
          );
        }
        return _change(
          sessionId,
          (session) async {
            final player = session.player;
            final index = queueStartIndex;
            if (deferPlayerCreation ||
                player == null ||
                session.queue.isEmpty ||
                index == null ||
                index < 0 ||
                index >= session.queue.length ||
                session.error != null ||
                session.completed ||
                session.nativeQueueLimited ||
                session.retainedCurrentIndex != null ||
                session.nativeQueueIndices.length != session.queue.length ||
                session.shuffle != shuffle ||
                (!shuffle && !session.nativeOrderMatchesLogical)) {
              throw const _WindowsBridgeFailure(
                nativePlaybackQueueResyncRequiredCode,
                'Existing session queue cannot be reused',
              );
            }
            final targetItem = session.queue[index];
            if (targetItem['uri'] != uri.toString() ||
                (path != null && targetItem['path'] != path)) {
              throw const _WindowsBridgeFailure(
                nativePlaybackQueueResyncRequiredCode,
                'Existing session queue does not match requested track',
              );
            }
            final clampedPosition = startPosition < Duration.zero
                ? Duration.zero
                : startPosition;
            final sameIndex = index == session.index;
            final sameTrack =
                _WindowsPlaybackSession._queueKey(session.queue[session.index]) ==
                _WindowsPlaybackSession._queueKey(targetItem);
            if (!(sameIndex && sameTrack) && clampedPosition != Duration.zero) {
              throw const _WindowsBridgeFailure(
                nativePlaybackQueueResyncRequiredCode,
                'Reusing existing queue requires zero start position on track switch',
              );
            }
            final generation = ++session.generation;
            session.wantsPlay = autoPlay;
            session.cancelRetry();
            session.cancelIdleRelease();
            _focus(sessionId);
            session.index = index;
            session.volume = _finite(volume, 0, 3);
            session.speed = _finite(speed, 0.25, 3);
            session.effects =
                audioEffects ??
                NativeAudioEffects(
                  state: AudioEffectsState.flat,
                  channelSwapEnabled: false,
                );
            session.repeatOne = repeatOne;
            session.stopAfterCurrentTrack = false;
            session.repeatAll = repeatAll;
            session.shuffle = shuffle;
            session.position = clampedPosition;
            session.error = null;
            session.completed = false;
            session.retryAttempt = 0;
            session.retryStartedAt = null;
            session.retainedCurrentIndex = null;
            session.externalQueueRevision = 0;
            session.isTemporary = isTemporary;
            if (!sameTrack) session.duration = null;
            if (sameIndex && sameTrack && clampedPosition > Duration.zero) {
              await _seekExistingTrack(session, player, generation);
            } else {
              await _jump(session, player);
            }
            if (!session.wantsPlay && !_shouldRetainPausedPlayer(session)) {
              _scheduleIdleRelease(session);
            }
          },
          markPlaybackError: false,
        );
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
                'candidateUris': candidateUris
                    ?.map((u) => u.toString())
                    .toList(),
              },
            ];
      _validateQueue(items);
      final session = _sessions.putIfAbsent(
        sessionId,
        () => _WindowsPlaybackSession(sessionId, _readNativePlaylist),
      );
      final generation = ++session.generation;
      session.wantsPlay = autoPlay;
      session.cancelRetry();
      session.cancelIdleRelease();
      _focus(sessionId);
      return _change(sessionId, (session) async {
        if (generation != session.generation) {
          throw ArgumentError('Playback preparation was superseded');
        }
        final index = (queueStartIndex ?? 0).clamp(0, items.length - 1);
        final previousQueue = session.queue;
        final sameIndex = previousQueue.isNotEmpty && index == session.index;
        final sameTrack =
            previousQueue.isNotEmpty &&
            _WindowsPlaybackSession._queueKey(previousQueue[session.index]) ==
                _WindowsPlaybackSession._queueKey(items[index]);
        final sameQueueInput =
            queue != null &&
            queue.isNotEmpty &&
            identical(items, session.lastQueueInput) &&
            previousQueue.length == items.length;
        final sameQueueStructure =
            sameQueueInput || _sameNativeQueue(previousQueue, items);
        final hadError = session.error != null;
        final wasCompleted = session.completed;
        final wasNativeQueueLimited = session.nativeQueueLimited;
        final hadRetainedCurrent = session.retainedCurrentIndex != null;
        final wasShuffle = session.shuffle;
        if (!sameQueueInput) {
          session.queue = List<Map<String, Object?>>.of(items);
          session.lastQueueInput =
              queue != null && queue.isNotEmpty ? items : null;
        }
        session.index = index;
        session.volume = _finite(volume, 0, 3);
        session.speed = _finite(speed, 0.25, 3);
        session.effects =
            audioEffects ??
            NativeAudioEffects(
              state: AudioEffectsState.flat,
              channelSwapEnabled: false,
            );
        session.repeatOne = repeatOne;
        session.stopAfterCurrentTrack = false;
        session.repeatAll = repeatAll;
        session.shuffle = shuffle;
        session.position = startPosition < Duration.zero
            ? Duration.zero
            : startPosition;
        session.error = null;
        session.completed = false;
        session.retryAttempt = 0;
        session.retryStartedAt = null;
        session.retainedCurrentIndex = null;
        session.externalQueueRevision = 0;
        session.isTemporary = isTemporary;
        final player = session.player;
        final canJump =
            !deferPlayerCreation &&
            player != null &&
            !hadError &&
            !wasCompleted &&
            !wasNativeQueueLimited &&
            !hadRetainedCurrent &&
            sameQueueStructure &&
            session.position == Duration.zero &&
            session.nativeQueueIndices.length == session.queue.length &&
            session.shuffle == wasShuffle &&
            (session.shuffle || session.nativeOrderMatchesLogical);
        if (canJump) {
          if (!sameTrack) session.duration = null;
          await _jump(session, player);
          if (!session.wantsPlay && !_shouldRetainPausedPlayer(session)) {
            _scheduleIdleRelease(session);
          }
        } else if (!deferPlayerCreation &&
            !session.wantsPlay &&
            player != null &&
            !hadError &&
            !wasCompleted &&
            !wasNativeQueueLimited &&
            !hadRetainedCurrent &&
            sameIndex &&
            sameTrack &&
            sameQueueStructure) {
          await _seekExistingTrack(session, player, generation);
          if (!_shouldRetainPausedPlayer(session)) {
            _scheduleIdleRelease(session);
          }
        } else if (!deferPlayerCreation &&
            (session.wantsPlay || session.videoController != null)) {
          if (!sameTrack) session.duration = null;
          await _open(session);
        } else {
          await session.releasePlayer();
          if (!sameTrack) session.duration = null;
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

  static bool _sameNativeQueue(
    List<Map<String, Object?>> previous,
    List<Map<String, Object?>> next,
  ) {
    if (previous.length != next.length || previous.isEmpty) return false;
    for (var i = 0; i < previous.length; i++) {
      final a = previous[i];
      final b = next[i];
      if (identical(a, b)) continue;
      if (a['uri'] != b['uri'] ||
          a['path'] != b['path'] ||
          a['clipStartMs'] != b['clipStartMs'] ||
          a['clipEndMs'] != b['clipEndMs'] ||
          !_sameHttpHeaders(a['httpHeaders'], b['httpHeaders'])) {
        return false;
      }
    }
    return true;
  }

  static bool _sameHttpHeaders(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is! Map || b is! Map) return a == b;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  Future<void> _seekExistingTrack(
    _WindowsPlaybackSession session,
    Player player,
    int generation,
  ) async {
    session.cancelIdleRelease();
    session.error = null;
    final target = session.clampPosition(session.position);
    final deferSeek =
        session.pendingStart != null || player.state.duration <= Duration.zero;
    session.pendingStart = deferSeek ? target : null;
    session.lastProgressPosition = null;
    session.lastProgressElapsed = null;
    if (!session.wantsPlay && player.state.playing) {
      await player.pause();
      if (!_isCurrent(session) || generation != session.generation) {
        throw ArgumentError('Playback preparation was superseded');
      }
    }
    await _applyMode(session, force: true);
    await _applyEffects(session, session.effects);
    await player.setVolume(session.volume * session.fade * 100);
    await player.setRate(session.temporarySpeed ?? session.speed);
    if (!_isCurrent(session) || generation != session.generation) {
      throw ArgumentError('Playback preparation was superseded');
    }
    session.position = target;
    session.seekRevision++;
    if (session.pendingStart != null ||
        player.state.duration <= Duration.zero) {
      session.pendingStart = target;
      if (player.state.duration > Duration.zero) {
        await session.restorePendingPosition(
          player,
          isCurrent: () => _isCurrent(session),
        );
      }
      return;
    }
    await player.seek(session.absolutePosition(target));
    if (!_isCurrent(session) || generation != session.generation) {
      throw ArgumentError('Playback preparation was superseded');
    }
    if (session.wantsPlay && !player.state.playing) {
      await player.play();
      if (!_isCurrent(session) || generation != session.generation) {
        throw ArgumentError('Playback preparation was superseded');
      }
    }
  }

  Future<void> _jump(_WindowsPlaybackSession session, Player player) async {
    session.cancelIdleRelease();
    session.opening = true;
    session.error = null;
    session.pendingStart = null;
    session.lastProgressPosition = null;
    session.lastProgressElapsed = null;
    final generation = session.generation;
    var fallbackToOpen = false;
    try {
      int physicalIndex;
      if (!session.shuffle && session.nativeOrderMatchesLogical) {
        physicalIndex = session.index;
      } else {
        final ids = await session.nativeEntryIds(player);
        if (!_isCurrent(session) || generation != session.generation) {
          throw ArgumentError('Playback preparation was superseded');
        }
        physicalIndex = ids.indexWhere(
          (entryId) => session.nativeQueueIndices[entryId] == session.index,
        );
      }
      if (physicalIndex < 0 ||
          (player.platform is! NativePlayer &&
              physicalIndex >= player.state.playlist.medias.length)) {
        fallbackToOpen = true;
      } else {
        if (!session.wantsPlay && player.state.playing) {
          await player.pause();
          if (!_isCurrent(session) || generation != session.generation) {
            throw ArgumentError('Playback preparation was superseded');
          }
        }
        await _applyMode(session, force: true);
        await _applyEffects(session, session.effects);
        await player.setVolume(session.volume * session.fade * 100);
        await player.setRate(session.temporarySpeed ?? session.speed);
        if (!_isCurrent(session) || generation != session.generation) {
          throw ArgumentError('Playback preparation was superseded');
        }
        await player.jump(physicalIndex);
        if (!_isCurrent(session) || generation != session.generation) {
          throw ArgumentError('Playback preparation was superseded');
        }
        if (session.wantsPlay && !player.state.playing) {
          await player.play();
          if (!_isCurrent(session) || generation != session.generation) {
            throw ArgumentError('Playback preparation was superseded');
          }
        }
      }
    } finally {
      session.opening = false;
    }
    if (fallbackToOpen) {
      if (session.wantsPlay || session.videoController != null) {
        await _open(session);
      } else {
        await session.releasePlayer();
      }
    }
  }

  Future<void> _open(_WindowsPlaybackSession session) async {
    session.cancelIdleRelease();
    final player = session.player ??= _createPlayer();
    if (session.subscriptions.isEmpty) _subscribe(session, player);
    session.opening = true;
    session.error = null;
    session.lastProgressPosition = null;
    session.lastProgressElapsed = null;
    final generation = session.generation;
    session.pendingStart = session.position > Duration.zero
        ? session.position
        : null;
    try {
      final platform = player.platform;
      if (platform is NativePlayer) {
        await AppNetwork.instance.ensureStarted();
        final proxyUrl = AppNetwork.instance.proxyUrl;
        if (_configuredProxyUrl[platform] != proxyUrl) {
          _configuredProxyUrl[platform] = proxyUrl;
          final proxy = 'http_proxy=$proxyUrl';
          // Current libmpv uses curl for the initial request; FFmpeg opens HLS
          // child streams. Configure both backends, including HTTPS CONNECT.
          await platform.setProperty('http-proxy', proxyUrl);
          for (final option in ['stream-lavf-o', 'demuxer-lavf-o']) {
            // Reading this map as text loses escaping in values such as the
            // protocol whitelist. Update its key without rewriting other values.
            await platform.command(['change-list', option, 'append', proxy]);
          }
        }
      }
      if (platform is NativePlayer && session.videoController == null) {
        final items = session.stopAfterCurrentTrack
            ? [session.queue[session.index]]
            : session.queue;
        final hasVideo = items.any(
          (item) => isVideoMediaFile(
            item['path'] as String? ?? Uri.parse(item['uri'] as String).path,
          ),
        );
        // libmpv output needs an attached render context. Keep background video
        // loaded with null output until VideoController installs that context.
        await platform.setProperty('vo', 'null');
        await platform.setProperty('vid', hasVideo ? 'auto' : 'no');
      }
      final playlist = Playlist([
        if (session.stopAfterCurrentTrack)
          _WindowsPlaybackSession.mediaFor(session.queue[session.index])
        else
          for (final item in session.queue)
            _WindowsPlaybackSession.mediaFor(item),
      ], index: session.stopAfterCurrentTrack ? 0 : session.index);
      await player.open(playlist, play: false);
      session.nativeQueueLimited = session.stopAfterCurrentTrack;
      session.nativeOrderMatchesLogical = !session.stopAfterCurrentTrack;
      if (!_isCurrent(session) || generation != session.generation) {
        throw ArgumentError('Playback preparation was superseded');
      }
      await session.mapNativeEntries(player);
      await _applyMode(session, force: true);
      if (platform is NativePlayer) {
        await platform.setProperty('volume-max', '300');
        await platform.setProperty('audio-pitch-correction', 'yes');
      }
      await _applyEffects(session, session.effects);
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
    final platform = player.platform;
    if (platform is NativePlayer) {
      platform.onLoadHooks.add(() async {
        if (!_isCurrent(session) || !identical(session.player, player)) return;
        final index = int.tryParse(await platform.getProperty('playlist-pos'));
        if (index == null || index < 0) return;
        final id = int.tryParse(
          await platform.getProperty('playlist/$index/id'),
        );
        final queueIndex =
            (id != null ? session.nativeQueueIndices[id] : null) ??
            (session.stopAfterCurrentTrack ? session.index : index);
        if (queueIndex < 0 || queueIndex >= session.queue.length) return;
        final reference = _WindowsPlaybackSession.referenceFor(
          session.queue[queueIndex],
        );
        // media_kit rebuilds Media objects from URLs when shuffling, dropping
        // their clipping fields. Reapply or clear bounds before mpv opens each
        // entry so chapter clipping never leaks to subsequent normal tracks.
        if (!reference.isChapter) {
          await platform.setProperty('start', 'none');
          await platform.setProperty('end', 'none');
          return;
        }
        await platform.setProperty('start', '${reference.startMs / 1000}');
        await platform.setProperty(
          'end',
          reference.endMs != null ? '${reference.endMs! / 1000}' : 'none',
        );
      });
    }
    session.subscriptions.addAll([
      player.stream.audioParams.listen((_) {
        if (!_isCurrent(session) ||
            !identical(session.player, player) ||
            session.effects.state.frontBack == 0) {
          return;
        }
        // Decoder layout can change when a native playlist advances, without
        // reopening the player or reapplying the saved effects.
        unawaited(
          _change(session.id, (current) async {
            if (identical(current.player, player)) {
              await _applyEffects(current, current.effects);
            }
          }, markPlaybackError: false).then((result) {
            if (result.isFailure && identical(session.player, player)) {
              AppLogService.error(
                'Windows audio filter update failed',
                error: result.errorOrNull,
              );
            }
          }),
        );
      }),
      player.stream.playlist.listen((playlist) {
        if (!_isCurrent(session) ||
            !identical(session.player, player) ||
            session.opening ||
            session.nativeQueueLimited ||
            playlist.medias.isEmpty) {
          return;
        }
        final generation = session.generation;
        final preReadQueue = session.queue;
        final preReadQueueRevision = session.queueRevision;
        Object? preReadError;
        StackTrace? preReadStackTrace;
        final preReadFuture = session
            .currentNativeEntryId(player)
            .then<({int? id, int? index})>(
              (id) => (
                id: id,
                index: id == null ? null : session.nativeQueueIndices[id],
              ),
              onError: (Object error, StackTrace stackTrace) {
                preReadError = error;
                preReadStackTrace = stackTrace;
                return (id: null, index: null);
              },
            );
        unawaited(
          _change(session.id, (current) async {
            if (!_isCurrent(current) ||
                generation != current.generation ||
                current.opening ||
                current.nativeQueueLimited) {
              return;
            }
            if (identical(current.player, player)) {
              final int? id;
              if (identical(current.queue, preReadQueue) &&
                  current.queueRevision == preReadQueueRevision) {
                final preRead = await preReadFuture;
                if (preReadError != null) {
                  Error.throwWithStackTrace(preReadError!, preReadStackTrace!);
                }
                id = preRead.id;
              } else {
                id = await current.currentNativeEntryId(player);
              }
              if (!_isCurrent(current) ||
                  generation != current.generation ||
                  !identical(current.player, player) ||
                  current.opening ||
                  current.nativeQueueLimited) {
                return;
              }
              final index = current.nativeQueueIndices[id];
              if (index == null || index == current.index) return;
              current.index = index;
              current.position = Duration.zero;
              current.duration = current.relativeDuration(
                player.state.duration,
              );
              current.cancelRetry();
              current.retryAttempt = 0;
              current.retryStartedAt = null;
              current.error = null;
              final retainedIndex = current.retainedCurrentIndex;
              if (retainedIndex != null && index != retainedIndex) {
                current.opening = true;
                try {
                  final ids = await current.nativeEntryIds(player);
                  final physicalIndex = ids.indexWhere(
                    (entryId) =>
                        current.nativeQueueIndices[entryId] == retainedIndex,
                  );
                  if (physicalIndex >= 0) {
                    await player.remove(physicalIndex);
                    current.nativeQueueIndices.remove(ids[physicalIndex]);
                    current.nativeQueueIndices.updateAll(
                      (_, value) => value > retainedIndex ? value - 1 : value,
                    );
                  }
                  current.retainedCurrentIndex = null;
                  current.lastQueueInput = null;
                  current.queue.removeAt(retainedIndex);
                  current.invalidateRetainedUris();
                  if (current.index > retainedIndex) current.index--;
                } finally {
                  current.opening = false;
                }
              }
            } else if (current.player == null &&
                identical(current.queue, preReadQueue) &&
                current.retainedCurrentIndex != null) {
              final preIndex = (await preReadFuture).index;
              if (preIndex == null ||
                  !_isCurrent(current) ||
                  generation != current.generation ||
                  current.player != null ||
                  !identical(current.queue, preReadQueue)) {
                return;
              }
              final retainedIndex = current.retainedCurrentIndex;
              if (retainedIndex == null ||
                  preIndex == current.index ||
                  preIndex == retainedIndex) {
                return;
              }
              current.index = preIndex;
              current.position = Duration.zero;
              current.duration = null;
              current.retryAttempt = 0;
              current.retryStartedAt = null;
              current.error = null;
              current.retainedCurrentIndex = null;
              current.lastQueueInput = null;
              current.queue.removeAt(retainedIndex);
              current.invalidateRetainedUris();
              if (current.index > retainedIndex) current.index--;
            }
          }, markPlaybackError: false).then((result) {
            if (result.isFailure &&
                _isCurrent(session) &&
                generation == session.generation &&
                identical(session.player, player)) {
              _handleError(session, result.errorOrNull!);
            }
          }),
        );
      }),
      player.stream.playing.listen((_) => _emit(session)),
      player.stream.completed.listen((completed) {
        if (!_isCurrent(session) ||
            !identical(session.player, player) ||
            session.opening) {
          return;
        }
        // mpv emits eof-reached before advancing a clipped playlist entry.
        // Keep playback intent alive until the physical queue really ends.
        final continues =
            session.reference.isChapter &&
            !session.stopAfterCurrentTrack &&
            (session.repeatOne ||
                session.repeatAll ||
                player.state.playlist.index <
                    player.state.playlist.medias.length - 1);
        if (completed && continues) return;
        if (completed && session.error == null) {
          session.wantsPlay = false;
          session.completed = true;
        } else if (!completed) {
          session.completed = false;
        }
        _emit(session);
        if (completed) unawaited(_change(session.id, _releaseIfIdle));
      }),
      player.stream.buffering.listen((_) => _emit(session)),
      player.stream.duration.listen((duration) {
        if (!_isCurrent(session) || !identical(session.player, player)) return;
        // media_kit resets duration to zero when reopening a paused source.
        session.duration =
            session.relativeDuration(duration) ?? session.duration;
        if (duration > Duration.zero && session.pendingStart != null) {
          final generation = session.generation;
          unawaited(
            _change(session.id, (current) async {
              if (generation != current.generation ||
                  !identical(current.player, player) ||
                  current.pendingStart == null) {
                return;
              }
              await current.restorePendingPosition(
                player,
                isCurrent: () => _isCurrent(current),
              );
            }),
          );
        }
        _emit(session);
      }),
      player.stream.position.listen((absolutePosition) {
        if (!_isCurrent(session) ||
            !identical(session.player, player) ||
            session.opening ||
            session.pendingStart != null) {
          return;
        }
        final position = session.relativePosition(absolutePosition);
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
          final nowElapsed = _elapsed;
          final previousPosition = session.lastProgressPosition;
          final previousElapsed = session.lastProgressElapsed;
          final jumped =
              previousPosition == null ||
              position < previousPosition ||
              (position - previousPosition).abs() >=
                  const Duration(milliseconds: 250);
          final elapsedDue =
              previousElapsed == null ||
              nowElapsed - previousElapsed >= const Duration(milliseconds: 32);
          if (jumped || elapsedDue) {
            session.lastProgressPosition = position;
            session.lastProgressElapsed = nowElapsed;
            _progress.add(
              NativePlaybackProgressUpdate(
                sessionId: session.id,
                position: position,
                bufferedPosition: session.relativePosition(player.state.buffer),
                duration: session.currentDuration,
                nativeElapsedRealtimeMs: nowElapsed.inMilliseconds,
              ),
            );
          }
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
    session.retryStartedAt ??= _elapsed;
    if ((!canFallback && !remote) ||
        _elapsed - session.retryStartedAt! >= const Duration(minutes: 10)) {
      // A terminal error must stop playback intent too: Windows power requests
      // follow that intent while recoverable errors are retried.
      session.wantsPlay = false;
      session.cancelRetry();
      unawaited(_change(session.id, _releaseIfIdle));
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
              final updated = Map<String, Object?>.of(item);
              updated['uri'] = candidates[next];
              currentSession.queue[currentSession.index] = updated;
              currentSession.lastQueueInput = null;
              currentSession.invalidateRetainedUris();
            }
            await _open(currentSession);
          }),
        );
      },
    );
  }

  Future<void> _applyMode(
    _WindowsPlaybackSession session, {
    bool force = false,
  }) async {
    final player = session.player;
    if (player == null) return;
    final mode = session.stopAfterCurrentTrack
        ? PlaylistMode.none
        : session.repeatOne
        ? PlaylistMode.single
        : session.repeatAll
        ? PlaylistMode.loop
        : PlaylistMode.none;
    // A failed mode change may have applied only one mpv loop property.
    if (force || session.error != null || player.state.playlistMode != mode) {
      await player.setPlaylistMode(mode);
    }
    final shuffleEnabled =
        !session.stopAfterCurrentTrack &&
        session.shuffle &&
        session.queue.length > 1;
    if (shuffleEnabled) session.nativeOrderMatchesLogical = false;
    await player.setShuffle(shuffleEnabled);
  }

  Future<void> _applyEffects(
    _WindowsPlaybackSession session,
    NativeAudioEffects effects,
  ) async {
    final frontBack = _finite(effects.state.frontBack, -1, 1);
    final platform = session.player?.platform;
    if (platform is! NativePlayer) return;

    String? impulsePath;
    if (frontBack != 0 &&
        await platform.getProperty('audio-params/channel-count') == '2') {
      // libavfilter opens the WAV by path. The Windows runner installs
      // Flutter assets beside its executable under data/flutter_assets.
      impulsePath = p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'assets',
        'audio',
        frontBack > 0 ? 'spatial_front.wav' : 'spatial_back.wav',
      );
    }
    final filter = windowsAudioFilter(effects, spatialImpulsePath: impulsePath);
    if (_appliedAudioFilters[platform] == filter) return;
    if (impulsePath != null && !await File(impulsePath).exists()) {
      throw FileSystemException('Missing spatial audio response', impulsePath);
    }
    await platform.setProperty('af', filter);
    if (impulsePath != null) {
      // media_kit's setter does not expose libmpv's return code.
      final graph = filter.substring(filter.indexOf('%', 'lavfi=%'.length) + 1);
      if (!(await platform.getProperty('af')).endsWith(graph)) {
        throw StateError('libmpv rejected the spatial audio filter');
      }
    }
    _appliedAudioFilters[platform] = filter;
  }

  bool _isUnexpectedPauseFailure(
    _WindowsPlaybackSession session,
    NativeResult<NativePlaybackSnapshot> result,
  ) =>
      result.isFailure &&
      !(result.errorCodeOrNull == NativeErrorCode.invalidArgument &&
          !_isCurrent(session));

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
    final generation = current.generation;
    current.wantsPlay = true;
    if (transportCommandId > 0) current.commandId = transportCommandId;
    current.cancelIdleRelease();
    _focus(sessionId);
    final pausedOthers = exclusive
        ? Future.wait([
            for (final other in _sessions.values.toList())
              if (other.id != sessionId &&
                  (other.wantsPlay || other.player?.state.playing == true))
                pause(
                  other.id,
                ).then((result) => (session: other, result: result)),
          ])
        : Future.value(
            const <({
              _WindowsPlaybackSession session,
              NativeResult<NativePlaybackSnapshot> result,
            })>[],
          );
    return _change(sessionId, (session) async {
      final results = await pausedOthers;
      final failure = results
          .where(
            (entry) => _isUnexpectedPauseFailure(entry.session, entry.result),
          )
          .map((entry) => entry.result)
          .firstOrNull;
      if (failure != null) throw StateError(failure.errorOrNull!);
      if (!session.wantsPlay || generation != session.generation) return;
      if (session.completed) {
        session.position = Duration.zero;
        session.completed = false;
      }
      if (session.player == null || session.error != null) {
        session.cancelRetry();
        session.retryAttempt = 0;
        session.retryStartedAt = null;
        await _open(session);
      } else if (session.pendingStart == null) {
        await session.player!.play();
        await _loadVideoIfIdle(session);
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
      if (transportCommandId > 0) current.commandId = transportCommandId;
      current.wantsPlay = false;
      current.cancelRetry();
      current.cancelIdleRelease();
    }
    return _change(sessionId, (session) async {
      if (session.wantsPlay) return;
      await session.player?.pause();
      if (session.player != null &&
          !_shouldRetainPausedPlayer(session) &&
          (session.error != null || _idleReleaseDelay <= Duration.zero)) {
        await _releaseIfIdle(session);
      } else {
        if (session.temporarySpeed != null) {
          session.temporarySpeed = null;
          await session.player?.setRate(session.speed);
        }
        if (session.player != null && !_shouldRetainPausedPlayer(session)) {
          _scheduleIdleRelease(session);
        }
      }
      // Retained players keep their decoder on pause, so restore the full
      // native queue before clearing the track-stop intent.
      await _setStopAfterCurrentTrack(session, false);
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> stop(String sessionId) {
    final current = _sessions[sessionId];
    current?.wantsPlay = false;
    current?.cancelRetry();
    current?.cancelIdleRelease();
    return _change(sessionId, (session) async {
      if (session.wantsPlay) return;
      session.stopAfterCurrentTrack = false;
      session.pendingStart = null;
      session.completed = false;
      await session.player?.pause();
      await session.player?.seek(session.absolutePosition(Duration.zero));
      session.position = Duration.zero;
      await session.releasePlayer();
    });
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) => _change(sessionId, (session) async {
    final target = session.clampPosition(position);
    session.completed = false;
    if (session.pendingStart != null) {
      session.pendingStart = target;
    } else {
      await session.player?.seek(session.absolutePosition(target));
    }
    session.position = target;
    session.seekRevision++;
    if (session.idleReleaseTimer?.isActive == true) {
      _scheduleIdleRelease(session);
    }
  }, markPlaybackError: false);
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume,
  ) => _change(sessionId, (session) async {
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
        (queueRevision == 0 ||
            queueRevision >= current.externalQueueRevision)) {
      current.cancelRetry();
    }
    return _change(sessionId, (session) async {
      // Scope and loop changes reuse the content revision; only older content
      // is stale, matching the Android queue update contract.
      if (queueRevision > 0 && queueRevision < session.externalQueueRevision) {
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
    // An earlier queued edit can bind a retry after this command's immediate
    // cancellation. Cancel again inside the session lane before replacing it.
    session.cancelRetry();
    try {
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
    } finally {
      // Queue edits cancel callbacks that captured the old queue. Preserve
      // recovery intent, including when an edit fails, using the current scope.
      final error = session.error;
      if (error != null) _handleError(session, error);
    }
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) => _change(sessionId, (session) async {
    await _applyEffects(session, effects);
    session.effects = effects;
  }, markPlaybackError: false);
  @override
  Future<NativeResult<NativePlaybackSnapshot>> setFadeMultiplier(
    String sessionId,
    double multiplier,
  ) => _change(sessionId, (session) async {
    session.fade = _finite(multiplier, 0, 1);
    await session.player?.setVolume(session.volume * session.fade * 100);
  });

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setStopAfterCurrentTrack(
    String sessionId,
    bool enabled,
  ) => _change(
    sessionId,
    (session) => _setStopAfterCurrentTrack(session, enabled),
  );

  Future<void> _setStopAfterCurrentTrack(
    _WindowsPlaybackSession session,
    bool enabled,
  ) async {
    if (session.stopAfterCurrentTrack == enabled) return;
    session.stopAfterCurrentTrack = enabled;
    final player = session.player;
    if (player == null) return;
    try {
      if (enabled) {
        session.opening = true;
        try {
          await _applyMode(session);
          await session.keepCurrentNativeEntry(player);
        } finally {
          session.opening = false;
        }
      } else if (session.nativeQueueLimited) {
        await session.updateQueue(
          session.queue,
          queueStartIndex: session.index,
          isCurrent: () => _isCurrent(session),
          restoreNativeQueue: true,
        );
        await _applyMode(session);
      } else {
        await _applyMode(session);
      }
    } catch (_) {
      // A partially edited native playlist cannot describe the retained queue.
      // Keep the logical queue and discard only the failed decoder.
      session.stopAfterCurrentTrack = false;
      session.wantsPlay = false;
      await session.releasePlayer();
      rethrow;
    }
  }

  @override
  Future<NativeResult<void>> removeSession(String sessionId) {
    _usage.update(sessionId, null);
    final session = _sessions.remove(sessionId);
    if (session != null) {
      session.retired = true;
      session.wantsPlay = false;
      session.generation++;
      session.cancelRetry();
      session.cancelIdleRelease();
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
      for (final session in _sessions.values.toList())
        pause(session.id).then((result) => (session: session, result: result)),
    ]);
    final failure = results
        .where((entry) => _isUnexpectedPauseFailure(entry.session, entry.result))
        .map((entry) => entry.result)
        .firstOrNull;
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
      sessions: [
        for (final session in _sessions.values)
          if (!session.retired &&
              session.queue.isNotEmpty &&
              session.index >= 0 &&
              session.index < session.queue.length)
            session.snapshot(),
      ],
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
  @override
  Future<bool> handleDeviceDisconnected() async {
    return _pauseOnDisconnect && (await pauseAll()).isOk;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _listening = false;
    _usageTimer?.cancel();
    try {
      await clearAll();
      await Future.wait(_retiring.toList());
      await _usageSerial;
      if (_usageLoaded || _usageStarted) await readUsage();
    } finally {
      await _snapshots.close();
      await _progress.close();
    }
  }
}

final class _WindowsBridgeFailure implements Exception {
  const _WindowsBridgeFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
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

String windowsAudioFilter(
  NativeAudioEffects effects, {
  String? spatialImpulsePath,
}) {
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
  final spatialMix = _finite(state.frontBack, -1, 1).abs();
  final left = pan > 0 ? 1 - pan : 1.0;
  final right = pan < 0 ? 1 + pan : 1.0;
  if (spatialImpulsePath != null && spatialMix > 0) {
    // The bundled impulse responses are sampled at 48 kHz.
    filters.add('aformat=channel_layouts=stereo:sample_rates=48000');
    if (effects.channelSwapEnabled) {
      filters.add('pan=stereo|c0=c1|c1=c0');
    }
    // Four independent convolutions, ordered by source and then by ear.
    filters.add('asplit[dry][spatial]');
    final impulse = _escapeFilterFilename(spatialImpulsePath);
    const peak = 'max(1,max(abs(val(0)),abs(val(1))))';
    final graph =
        '${filters.join(',')};'
        'amovie=filename=$impulse,aformat=channel_layouts=4.0[ir];'
        '[spatial]pan=4.0|c0=c0|c1=c0|c2=c1|c3=c1[sides];'
        '[sides][ir]afir=irnorm=-1:minp=32:maxp=64,'
        'pan=stereo|c0=c0+c2|c1=c1+c3[wet];'
        '[dry][wet]amix=normalize=0:duration=first:weights=${1 - spatialMix} $spatialMix,'
        "aeval=exprs='val(0)/$peak|val(1)/$peak':channel_layout=stereo"
        '${pan == 0 ? '' : ',pan=stereo|c0=$left*c0|c1=$right*c1'}';
    // mpv's fixed-length quoting preserves the complete graph as one argument.
    return 'lavfi=%${utf8.encode(graph).length}%$graph';
  }
  if (effects.channelSwapEnabled || pan != 0) {
    filters.add('aformat=channel_layouts=stereo');
    filters.add(
      'pan=args=stereo|c0=$left*${effects.channelSwapEnabled ? 'c1' : 'c0'}|c1=$right*${effects.channelSwapEnabled ? 'c0' : 'c1'}',
    );
  }
  return filters.isEmpty ? '' : 'lavfi=[${filters.join(',')}]';
}

String _escapeFilterFilename(String path) {
  // Escape the filter's option value first, then the outer filter graph syntax.
  final option = path
      .replaceAll(r'\', '/')
      .replaceAllMapped(RegExp(r"[:']"), (match) => '\\${match[0]}');
  return option.replaceAllMapped(
    RegExp(r"[\\',;\[\]]"),
    (match) => '\\${match[0]}',
  );
}

final _mockMediaIds = Expando<int>();
var _nextMockMediaId = 1;

@visibleForTesting
int mockMediaId(Media media) => _mockMediaIds[media] ??= _nextMockMediaId++;
