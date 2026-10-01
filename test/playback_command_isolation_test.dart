import 'dart:async';

import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_cache_service.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_command_coordinator.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/playback_track_resolver.dart'
    as ports;
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_library_catalog.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Native native;
  late _Catalog catalog;
  late PlaybackFacade playback;
  late PlaybackCommandCoordinator commands;
  late TimerFacade timer;
  late NotificationFacade notifications;
  late PlaybackSubtitleService subtitles;

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
    native = _Native();
    catalog = _Catalog();
    playback = PlaybackFacade.create(
      databaseRepository: _Persistence(),
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    timer = TimerFacade.create();
    notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    subtitles = PlaybackSubtitleService(
      trackResolver: catalog.trackByPath,
      subtitleLoader: (_, _) async => null,
    );
    commands = PlaybackCommandCoordinator(
      library: catalog,
      playback: playback,
      timer: timer,
      notifications: notifications,
      asmrPlaybackCacheEnabled: () => false,
      audioPaths: _Paths(),
      subtitles: subtitles,
      activateAudioSession: () async => true,
      asmrPlaybackCacheService: AsmrPlaybackCacheService(),
      notifyPlaybackChanged: () {},
      syncNotificationState: ({bool immediateUnifiedSync = false}) {},
    );
    playback.attachCommandPort(commands);
    playback.attachPlaybackQueueSynchronizer(commands.syncPlaybackQueueSession);
  });

  tearDown(() async {
    await commands.dispose();
    await playback.dispose();
    await timer.dispose();
    await notifications.dispose();
    subtitles.dispose();
  });

  PlaybackSession register(
    String id, {
    bool playing = false,
    bool queue = false,
  }) {
    final session = PlaybackSession(
      id: id,
      currentTrackPath: catalog.tracks.first.path,
      loopMode: SessionLoopMode.crossSequential,
      nonSingleLoopMode: SessionLoopMode.crossSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(playing, ProcessingState.ready),
      customQueueTracks: catalog.tracks,
      playbackQueue: queue
          ? PlaybackQueueDefinition(
              name: id,
              entries: [
                PlaybackQueueEntry(
                  id: 'entry',
                  kind: PlaybackQueueEntryKind.work,
                  title: id,
                  tracks: catalog.tracks,
                ),
              ],
            )
          : null,
    );
    playback.registerSession(session);
    return session;
  }

  test(
    'blocked session preparation does not delay another session play and pause',
    () async {
      final first = register('a');
      final second = register('b');
      final release = Completer<void>();
      native.blocked['a'] = release.future;
      var firstFinished = false;
      final firstPreparation = commands
          .prepareSession(first, nextPath: first.currentTrackPath)
          .then((result) {
            firstFinished = true;
            return result;
          });
      await native.startedFor('a').future;

      expect(
        await commands.prepareSession(
          second,
          nextPath: second.currentTrackPath,
        ),
        true,
      );
      expect(await commands.pauseSession(second), true);
      expect(native.played, ['b']);
      expect(native.paused, ['b']);
      expect(firstFinished, false);
      release.complete();
      expect(await firstPreparation, true);
      expect(native.played, ['b', 'a']);
    },
  );

  test(
    'queue descriptor cache survives progress and repositions duplicate tracks without re-reading covers',
    () async {
      final session = register('a', queue: true);
      final firstRequest = commands.nativePlaybackQueueFor(
        session,
        currentPath: session.currentTrackPath,
      );
      final concurrentRequest = commands.nativePlaybackQueueFor(
        session,
        currentPath: session.currentTrackPath,
      );
      final first = await firstRequest;
      expect(await concurrentRequest, same(first));
      final coverReads = catalog.coverReads;
      session.setOptimisticPosition(const Duration(seconds: 30));
      session.volume = 0.5;
      session.currentQueueIndex = 1;

      expect(
        await commands.nativePlaybackQueueFor(
          session,
          currentPath: session.currentTrackPath,
        ),
        same(first),
      );
      expect(
        commands.nativePlaybackQueueStartIndexFor(
          session,
          currentPath: session.currentTrackPath,
        ),
        1,
      );
      expect(catalog.coverReads, coverReads);
      expect(catalog.groupReads, 0);
    },
  );

  test(
    'paused track selection performs no native preparation or cover work',
    () async {
      final session = register('a');
      session.setOptimisticPosition(const Duration(seconds: 22));
      expect(
        await commands.prepareSession(
          session,
          nextPath: catalog.tracks.last.path,
          targetQueueIndex: 1,
          autoPlay: false,
        ),
        true,
      );
      expect(native.prepared, isEmpty);
      expect(native.played, isEmpty);
      expect(native.paused, isEmpty);
      expect(catalog.coverReads, 0);
      expect(session.loadedPath, isNull);
      expect(session.currentQueueIndex, 1);
      expect(session.position, Duration.zero);
      expect(session.playbackRequested, false);
    },
  );

  test(
    'an idle preparation snapshot still starts the requested playback',
    () async {
      native.coldPreparation = true;
      final session = register('a');
      session.setOptimisticPosition(const Duration(seconds: 22));
      final overlays = <List<String>>[];
      final subscription = playback.catalogStates.listen((state) {
        overlays.add(state.nowPlayingSessions.map((s) => s.id).toList());
      });
      addTearDown(subscription.cancel);
      final prepareRelease = Completer<void>();
      final playRelease = Completer<void>();
      native.blocked['a'] = prepareRelease.future;
      native.blockedPlay['a'] = playRelease.future;
      final preparation = commands.prepareSession(
        session,
        nextPath: session.currentTrackPath,
      );
      await native.startedFor('a').future;
      prepareRelease.complete();
      await native.playStartedFor('a').future;
      try {
        expect(session.state.processingState, ProcessingState.idle);
        expect(session.isLoading, false);
        expect(session.isPlaybackLoading, false);
        expect(session.playbackRequested, true);
        expect(playback.catalogState.nowPlayingSessions.map((s) => s.id), [
          'a',
        ]);
        expect(overlays.skipWhile((ids) => ids.isEmpty), everyElement(['a']));
      } finally {
        playRelease.complete();
        expect(await preparation, true);
      }
      expect(native.prepared, ['a']);
      expect(native.played, ['a']);
      expect(native.startPositions, [const Duration(seconds: 22)]);
      expect(session.playbackRequested, true);
    },
  );

  test(
    'a cold paused session keeps its seek point without starting native work',
    () async {
      final session = register('a');
      session.setOptimisticPosition(const Duration(seconds: 22));
      expect(await commands.pauseSession(session), true);
      expect(
        await commands.prepareSession(
          session,
          nextPath: session.currentTrackPath,
          autoPlay: false,
        ),
        true,
      );
      expect(native.prepared, isEmpty);
      expect(native.paused, isEmpty);
      expect(session.position, const Duration(seconds: 22));
      expect(session.loadedPath, isNull);
      expect(playback.hasPlaybackToKeepAlive, false);
    },
  );

  test(
    'restore keeps every paused definition without resolving native queues',
    () async {
      final first = register('a');
      final second = register('b');
      final release = Completer<void>();
      native.blocked['a'] = release.future;
      final restoration = commands.restorePersistedRuntime([
        first,
        second,
      ], focusedSessionId: first.id);
      await restoration;
      expect(native.prepared, isEmpty);
      expect(catalog.coverReads, 0);
      expect(native.played, isEmpty);
      release.complete();
      expect(first.effectivePlaying, false);
      expect(second.effectivePlaying, false);
    },
  );

  test(
    'editing a prepared queue uses updateQueue without changing repeat mode through transport',
    () async {
      final session = register('a', playing: true, queue: true);
      session.loadedPath = session.currentTrackPath;
      await commands.syncPlaybackQueueSession(session);
      expect(native.queueUpdates, ['a']);
      expect(native.lastQueueRevision, session.queueVersion);
      expect(native.played, isEmpty);
      expect(native.paused, isEmpty);
    },
  );

  test('reconnect ignores stale idle native definitions', () async {
    final session = register('a');
    session.currentTrackPath = catalog.tracks.last.path;
    session.volume = 0.35;
    session.setOptimisticPosition(const Duration(seconds: 22));
    native.runtimeSnapshots = [
      NativePlaybackSnapshot(
        sessionId: session.id,
        path: catalog.tracks.first.path,
        playing: false,
        playWhenReady: false,
        processingState: 'idle',
        position: const Duration(seconds: 9),
        bufferedPosition: Duration.zero,
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
      ),
    ];

    await commands.reconcileNativeRuntime();

    expect(session.currentTrackPath, catalog.tracks.last.path);
    expect(session.position, const Duration(seconds: 22));
    expect(session.volume, 0.35);
    expect(session.loadedPath, isNull);
    expect(native.prepared, isEmpty);
    expect(catalog.coverReads, 0);
  });

  test('cold queue replacement resets the previous track progress', () async {
    final session = register('a', queue: true);
    session.setOptimisticPosition(const Duration(seconds: 22));
    session.setOptimisticDuration(const Duration(minutes: 5));
    session.playbackQueue = session.playbackQueue!.copyWith(
      entries: [
        PlaybackQueueEntry(
          id: 'replacement',
          kind: PlaybackQueueEntryKind.track,
          title: 'Replacement',
          tracks: [catalog.tracks.last],
        ),
      ],
    );
    session.currentQueueIndex = -1;

    await commands.syncPlaybackQueueSession(session);

    expect(session.currentTrackPath, catalog.tracks.last.path);
    expect(session.position, Duration.zero);
    expect(session.duration, catalog.tracks.last.duration);
    expect(native.prepared, isEmpty);
    expect(native.queueUpdates, isEmpty);
  });

  test('repeat and shuffle changes reuse the same queue descriptors', () async {
    final session = register('a', queue: true)
      ..loadedPath = catalog.tracks.first.path;
    final descriptors = await commands.nativePlaybackQueueFor(
      session,
      currentPath: session.currentTrackPath,
    );
    final coverReads = catalog.coverReads;
    for (final mode in [
      SessionLoopMode.crossRandom,
      SessionLoopMode.crossOnce,
      SessionLoopMode.crossRandomOnce,
      SessionLoopMode.crossSequential,
    ]) {
      session.loopMode = mode;
      await commands.synchronizeLoopMode(session, mode);
      expect(session.nativePlaybackQueueCache, same(descriptors));
      expect(catalog.coverReads, coverReads);
    }
    expect(native.queueUpdates, isEmpty);
    expect(native.repeatUpdates, 4);
  });

  test('a late failed play cannot restart a paused session', () async {
    final session = register('a')..loadedPath = catalog.tracks.first.path;
    final release = Completer<void>();
    native.blockedPlay['a'] = release.future;
    final start = commands.startSession(
      session,
      shouldStartTriggerCountdown: false,
    );
    await native.playStartedFor('a').future;
    expect(await commands.pauseSession(session), true);

    release.completeError(StateError('The old source failed.'));

    expect(await start, false);
    expect(native.prepared, isEmpty);
    expect(native.played, ['a']);
    expect(session.playbackRequested, false);
    expect(session.isLoading, false);
  });

  for (final clear in [false, true]) {
    test(
      'global ${clear ? 'clear' : 'pause'} cancels preparation before its native command finishes',
      () async {
        final session = register('a');
        final prepareRelease = Completer<void>();
        final commandRelease = Completer<void>();
        native.blocked['a'] = prepareRelease.future;
        if (clear) {
          native.blockedClearAll = commandRelease.future;
        } else {
          native.blockedPauseAll = commandRelease.future;
        }
        final preparation = commands.prepareSession(
          session,
          nextPath: session.currentTrackPath,
        );
        await native.startedFor('a').future;
        final generation = session.loadGeneration;
        final cancellation = clear
            ? playback.clearAllSessions()
            : playback.pauseAllSessions();
        expect(session.loadGeneration, greaterThan(generation));
        expect(session.isLoading, false);

        prepareRelease.complete();
        expect(await preparation, false);
        expect(native.played, isEmpty);

        commandRelease.complete();
        expect(await cancellation, true);
        if (clear) {
          expect(playback.hasSession(session.id), false);
        } else {
          expect(session.playbackRequested, false);
        }
      },
    );
  }

  test('a newer play intent survives an older global pause result', () async {
    final session = register('a')..loadedPath = catalog.tracks.first.path;
    final release = Completer<void>();
    native.blockedPauseAll = release.future;
    final pause = playback.pauseAllSessions();
    expect(
      await commands.startSession(session, shouldStartTriggerCountdown: false),
      true,
    );

    release.complete();
    expect(await pause, true);
    expect(session.playbackRequested, true);
  });

  test(
    'global clear keeps sessions registered after it was requested',
    () async {
      final first = register('a');
      final release = Completer<void>();
      native.blockedClearAll = release.future;
      final clear = playback.clearAllSessions();
      final second = register('b');

      release.complete();
      expect(await clear, true);
      expect(playback.hasSession(first.id), false);
      expect(playback.sessionById(second.id), same(second));
    },
  );

  test(
    'adding to an empty queue keeps a removed current item until advance',
    () async {
      final session = register('a', playing: true, queue: true)
        ..loadedPath = catalog.tracks.first.path;
      final originalPath = session.currentTrackPath;
      await playback.removePlaybackQueueEntry(session.id, 'entry');
      expect(session.playbackQueue!.expandedTracks, isEmpty);
      expect(session.hasDetachedQueueTrack, true);

      await commands.pauseSession(session);
      session.setOptimisticPosition(const Duration(seconds: 22));
      expect(session.loadedPath, isNull);
      native.queueUpdates.clear();

      await playback.addTrackToPlaybackQueue(session.id, catalog.tracks[2]);

      expect(session.currentTrackPath, originalPath);
      expect(session.currentQueueIndex, 0);
      expect(session.hasDetachedQueueTrack, true);
      expect(session.customQueueTracks!.map((track) => track.path), [
        originalPath,
        catalog.tracks[2].path,
      ]);
      expect(native.prepared, isEmpty);
      expect(native.played, isEmpty);
      expect(native.queueUpdates, isEmpty);
      expect(session.position, const Duration(seconds: 22));
      expect(
        commands.resolveAdvance(session, forward: true)?.path,
        catalog.tracks[2].path,
      );
    },
  );
  test(
    'cold recovery stores the current duplicate occurrence without playback',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = register('a', queue: true)
        ..currentQueueIndex = 1
        ..volume = 0.4;
      session.setOptimisticPosition(const Duration(seconds: 22));
      await commands.synchronizePausedRecovery(session);
      expect(native.deferredPrepared, ['a']);
      expect(native.lastPreparedQueueIndex, 1);
      expect(native.lastPreparedVolume, 0.4);
      expect(native.startPositions, [const Duration(seconds: 22)]);
      expect(native.played, isEmpty);
      expect(session.loadedPath, isNull);
      final coverReads = catalog.coverReads;
      session.volume = 0.6;
      await commands.synchronizePausedRecovery(session);
      expect(native.lastPreparedVolume, 0.6);
      expect(catalog.coverReads, coverReads);
    },
  );

  test(
    'empty cold queues remove recovery without registering a stale track',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = register('a', queue: true)
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'empty',
          entries: const [],
        );
      await commands.synchronizePausedRecovery(session);
      expect(native.removed, ['a']);
      expect(native.prepared, isEmpty);
      expect(catalog.coverReads, 0);
    },
  );

  test(
    'completed cold recovery restarts from zero without changing its saved progress',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = register('completed', queue: true);
      session.setOptimisticPosition(const Duration(minutes: 2));
      session.setOptimisticDuration(const Duration(minutes: 2));
      session.setOptimisticState(
        playing: false,
        processingState: ProcessingState.completed,
      );
      await commands.synchronizePausedRecovery(session);
      expect(native.deferredPrepared, ['completed']);
      expect(native.startPositions, [Duration.zero]);
      expect(native.played, isEmpty);
      expect(session.lastKnownPosition, const Duration(minutes: 2));
      expect(session.duration, const Duration(minutes: 2));
      expect(session.state.processingState, ProcessingState.completed);
      expect(session.loadedPath, isNull);
    },
  );

  test(
    'Windows and playing sessions do not publish cold recovery definitions',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = register('a', queue: true);
      await commands.synchronizePausedRecovery(session);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      session.setOptimisticState(playing: true);
      await commands.synchronizePausedRecovery(session);
      expect(native.prepared, isEmpty);
      expect(catalog.coverReads, 0);
    },
  );
}

class _Persistence extends Fake implements PlaybackPersistenceRepository {}

class _Paths extends Fake implements ports.PlaybackTrackResolver {}

class _Catalog implements PlaybackLibraryCatalog {
  final tracks = List.generate(
    30,
    (index) => MusicTrack(
      path: 'https://example.com/track-${index ~/ 2}.mp3',
      displayName: 'Track $index',
      groupKey: 'work',
      groupTitle: 'Work',
      groupSubtitle: '',
      isSingle: false,
    ),
  );
  int coverReads = 0;
  int groupReads = 0;
  @override
  int get structureRevision => 0;
  @override
  int get contentRevision => 0;
  @override
  int get coverGeneration => 0;
  @override
  MusicTrack? trackByPath(String path) {
    for (final track in tracks) {
      if (track.path == path) return track;
    }
    return null;
  }

  @override
  List<MusicTrack> tracksInGroup(String groupKey, {int? limit}) {
    groupReads++;
    return tracks;
  }

  @override
  void updateTrackSnapshot(MusicTrack track) {}
  @override
  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) {
    coverReads++;
    return null;
  }

  @override
  Future<String?> playbackCoverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) async => null;
}

class _Native extends NativePlaybackRepository {
  List<NativePlaybackSnapshot> runtimeSnapshots = [];
  final blocked = <String, Future<void>>{};
  final blockedPlay = <String, Future<void>>{};
  final _started = <String, Completer<void>>{};
  final _playStarted = <String, Completer<void>>{};
  bool coldPreparation = false;
  final startPositions = <Duration>[];
  final prepared = <String>[];
  final deferredPrepared = <String>[];
  final removed = <String>[];
  int? lastPreparedQueueIndex;
  double? lastPreparedVolume;
  final played = <String>[];
  final paused = <String>[];
  final queueUpdates = <String>[];
  final _paths = <String, String>{};
  int lastQueueRevision = 0;
  int repeatUpdates = 0;
  Future<void>? blockedPauseAll;
  Future<void>? blockedClearAll;
  Completer<void> startedFor(String id) =>
      _started.putIfAbsent(id, Completer<void>.new);
  Completer<void> playStartedFor(String id) =>
      _playStarted.putIfAbsent(id, Completer<void>.new);
  @override
  Future<void> dispose() async {}
  @override
  Future<NativeResult<void>> removeSession(String sessionId) async {
    removed.add(sessionId);
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<NativePlaybackBundleSnapshot>> snapshot() async =>
      NativeSuccess(NativePlaybackBundleSnapshot(sessions: runtimeSnapshots));
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
  }) async {
    prepared.add(sessionId);
    if (deferPlayerCreation) deferredPrepared.add(sessionId);
    lastPreparedQueueIndex = queueStartIndex;
    lastPreparedVolume = volume;
    _paths[sessionId] = path ?? uri.toString();
    startPositions.add(startPosition);
    final started = startedFor(sessionId);
    if (!started.isCompleted) started.complete();
    await blocked[sessionId];
    if (deferPlayerCreation) return const NativeSuccess();
    return NativeSuccess(
      _snapshot(sessionId, processingState: coldPreparation ? 'idle' : 'ready'),
    );
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> play(
    String sessionId, {
    int transportCommandId = 0,
    bool exclusive = false,
  }) async {
    played.add(sessionId);
    final started = playStartedFor(sessionId);
    if (!started.isCompleted) started.complete();
    await blockedPlay[sessionId];
    return NativeSuccess(
      _snapshot(sessionId, playing: true, commandId: transportCommandId),
    );
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) async {
    paused.add(sessionId);
    return NativeSuccess(_snapshot(sessionId, commandId: transportCommandId));
  }

  @override
  Future<NativeResult<void>> pauseAll() async {
    await blockedPauseAll;
    return const NativeSuccess();
  }

  @override
  Future<NativeResult<void>> clearAll() async {
    await blockedClearAll;
    return const NativeSuccess();
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
  }) async {
    queueUpdates.add(sessionId);
    lastQueueRevision = queueRevision;
    return NativeSuccess(_snapshot(sessionId, playing: true));
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
    repeatUpdates++;
    return NativeSuccess(_snapshot(sessionId));
  }

  NativePlaybackSnapshot _snapshot(
    String id, {
    bool playing = false,
    int? commandId,
    String processingState = 'ready',
  }) => NativePlaybackSnapshot(
    sessionId: id,
    path: _paths[id],
    playing: playing,
    playWhenReady: playing,
    processingState: processingState,
    position: Duration.zero,
    bufferedPosition: Duration.zero,
    volume: 1,
    boostGain: 1,
    channelSwapEnabled: false,
    transportCommandId: commandId,
  );
}
