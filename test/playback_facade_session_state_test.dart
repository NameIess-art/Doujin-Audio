import 'package:nameless_audio/features/player/domain/playback_persistence_repository.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/core/media/path_matcher.dart';
import 'package:nameless_audio/core/media/music_track.dart';
import 'support/test_persistence_repository.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/features/player/application/playback_queue_resolver.dart';
import 'package:nameless_audio/features/player/domain/audio_effects.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/features/player/domain/playback_queue.dart';

void main() {
  test('PlaybackFacade owns session registration and reorder commands', () {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    final first = _session('first');
    final second = _session('second');
    addTearDown(() async {
      first.dispose();
      second.dispose();
      await playback.dispose();
      await library.dispose();
    });
    final registered = <String>[];
    var reorderCount = 0;
    playback.attachSessionRuntime(
      onSessionRegistered: (session) => registered.add(session.id),
      onSessionsReordered: () => reorderCount++,
      onSessionStateChanged: () {},
    );

    playback
      ..registerSession(first)
      ..registerSession(second);

    expect(registered, <String>['first', 'second']);
    expect(playback.activeSessions.map((session) => session.id), <String>[
      'second',
      'first',
    ]);

    playback.reorderSessions(0, 2);
    expect(playback.activeSessions.map((session) => session.id), <String>[
      'first',
      'second',
    ]);
    expect(reorderCount, 1);

    playback.reorderSessions(-1, 0);
    expect(reorderCount, 1);
  });

  test('PlaybackFacade owns pause and session removal lifecycle', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    addTearDown(() async {
      await playback.dispose();
      await library.dispose();
    });
    final first = _session('first')
      ..setOptimisticState(playing: true)
      ..isLoading = true
      ..isPlaybackStarting = true;
    final second = _session('second')..setOptimisticState(playing: true);
    final removed = <String>[];
    var stateChanges = 0;
    var runtimeChanges = 0;
    var settingsChanges = 0;
    final positionChanges = <Duration>[];
    playback.attachSessionRuntime(
      onSessionRegistered: (_) {},
      onSessionsRemoved: (sessions) {
        removed.addAll(sessions.map((session) => session.id));
      },
      onSessionsReordered: () {},
      onSessionStateChanged: () => stateChanges++,
      onRuntimeStateChanged: () => runtimeChanges++,
      onSessionPositionChanged: (session, position) {
        positionChanges.add(position);
      },
      onSessionSettingsChanged: () => settingsChanges++,
    );
    playback
      ..registerSession(first)
      ..registerSession(second);

    await playback.pauseAllSessions();

    expect(first.state.playing, isFalse);
    expect(first.isLoading, isFalse);
    expect(first.isPlaybackStarting, isFalse);
    expect(second.state.playing, isFalse);
    expect(native.pauseAllCount, 1);
    expect(stateChanges, 1);
    expect(runtimeChanges, 1);

    await playback.seekSession(first.id, const Duration(seconds: 17));

    expect(first.position, const Duration(seconds: 17));
    expect(first.lastPersistedPositionBucket, 3);
    expect(native.seekPositions, <Duration>[const Duration(seconds: 17)]);
    expect(positionChanges, <Duration>[const Duration(seconds: 17)]);

    await playback.setSessionVolume(first.id, 1.75, persist: false);
    await playback.setSessionVolume(first.id, 1.75);
    await playback.setSessionSpeed(first.id, 1.6, persist: false);

    expect(first.volume, 1.75);
    expect(native.volumeUpdates, <(double, bool)>[(1.75, false), (1.75, true)]);
    expect(first.speed, 1.5);
    expect(native.speedUpdates, <double>[1.5]);
    expect(settingsChanges, 1);

    native.failSpeed = true;
    await playback.setSessionSpeed(first.id, 2, persist: false);

    expect(first.speed, 1.5);
    expect(settingsChanges, 3);

    await playback.removeSession(first.id);

    expect(playback.sessionById(first.id), isNull);
    expect(native.removedSessionIds, <String>[first.id]);
    expect(removed, <String>[first.id]);
    expect(stateChanges, 3);
    expect(runtimeChanges, 2);

    await playback.clearAllSessions();

    expect(playback.sessions, isEmpty);
    expect(native.clearAllCount, 1);
    expect(removed, <String>[first.id, second.id]);
    expect(stateChanges, 4);
    expect(runtimeChanges, 3);
  });

  test('native pause failure keeps Flutter playback state unchanged', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository()..failPauseAll = true;
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final session = _session('pause-failure')
      ..setOptimisticState(playing: true)
      ..isLoading = true
      ..isPlaybackStarting = true;
    playback.registerSession(session);
    addTearDown(() async {
      await playback.dispose();
      await library.dispose();
    });

    final paused = await playback.pauseAllSessions();

    expect(paused, isFalse);
    expect(session.state.playing, isTrue);
    expect(session.isLoading, isTrue);
    expect(session.isPlaybackStarting, isTrue);
  });

  test('native volume failure restores the previous session volume', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository()..failVolume = true;
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final session = _session('volume-failure');
    addTearDown(() async {
      await playback.dispose();
      await library.dispose();
    });
    playback.registerSession(session);

    final changed = await playback.setSessionVolume(session.id, 1.8);

    expect(changed, isFalse);
    expect(session.volume, 1.0);
    expect(native.volumeUpdates, <(double, bool)>[(1.8, true)]);
  });

  test('batch removal commits only native successes', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository()
      ..failedRemovalSessionIds.add('second');
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final first = _session('first');
    final second = _session('second');
    playback
      ..registerSession(first)
      ..registerSession(second);
    addTearDown(() async {
      await playback.dispose();
      await library.dispose();
    });

    final removed = await playback.removeSessions(<String>[
      first.id,
      second.id,
    ]);

    expect(removed, isFalse);
    expect(playback.sessionById(first.id), isNull);
    expect(first.isDisposed, isTrue);
    expect(playback.sessionById(second.id), same(second));
    expect(second.isDisposed, isFalse);
  });

  test('native clear failure keeps every local session', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository()..failClearAll = true;
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final session = _session('clear-failure');
    playback.registerSession(session);
    addTearDown(() async {
      await playback.dispose();
      await library.dispose();
    });

    final cleared = await playback.clearAllSessions();

    expect(cleared, isFalse);
    expect(playback.sessionById(session.id), same(session));
    expect(session.isDisposed, isFalse);
  });

  test('session removal wins over an in-flight speed command', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final session = _session('racing');
    var settingsChanges = 0;
    playback.attachSessionRuntime(
      onSessionRegistered: (_) {},
      onSessionsRemoved: (_) {},
      onSessionsReordered: () {},
      onSessionStateChanged: () {},
      onSessionSettingsChanged: () => settingsChanges++,
    );
    playback.registerSession(session);
    final gate = Completer<NativeResult<NativePlaybackSnapshot>>();
    native.speedGate = gate;

    final speedChange = playback.setSessionSpeed(session.id, 1.5);
    await Future<void>.delayed(Duration.zero);
    await playback.removeSession(session.id);
    gate.complete(const NativeSuccess<NativePlaybackSnapshot>());
    await speedChange;

    expect(session.isDisposed, isTrue);
    expect(playback.sessionById(session.id), isNull);
    expect(settingsChanges, 1);

    await playback.dispose();
    await library.dispose();
  });

  test(
    'loading playback intent can be paused from the spinner control',
    () async {
      final library = _createLibraryFacade();
      final playback = PlaybackFacade.create(
        databaseRepository:
            library.databaseRepository as PlaybackPersistenceRepository,
      )..configurePersistence(enabled: false);
      final session = _session('loading_toggle')
        ..setOptimisticState(
          playing: true,
          processingState: ProcessingState.loading,
        )
        ..isLoading = true;
      var pauseCount = 0;
      var prepareCount = 0;
      addTearDown(() async {
        session.dispose();
        await playback.dispose();
        await library.dispose();
      });
      playback
        ..attachSessionRuntime(
          onSessionRegistered: (_) {},
          onSessionsReordered: () {},
          onSessionStateChanged: () {},
        )
        ..attachPlaybackCommands(
          prepareSession:
              (
                session, {
                required nextPath,
                autoPlay = true,
                forceStartAtZero = false,
                showLoading = true,
                targetQueueIndex,
              }) async {
                prepareCount++;
                return true;
              },
          pauseSession: (_) async => pauseCount++,
          startSession: (_, {required shouldStartTriggerCountdown}) async =>
              true,
          resolveAdvance: (_, {required forward}) => null,
          hasAdjacent: (_, {required forward}) => false,
        )
        ..registerSession(session);

      await playback.toggleSessionPlayPause(session.id);

      expect(pauseCount, 1);
      expect(prepareCount, 0);
    },
  );

  test('PlaybackFacade owns transport command decisions', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final session = _session('transport')
      ..customQueueTracks = <MusicTrack>[
        MusicTrack(
          path: '/tracks/first.mp3',
          displayName: 'First',
          groupKey: '/tracks',
          groupTitle: 'Tracks',
          groupSubtitle: '',
          isSingle: false,
        ),
        MusicTrack(
          path: '/tracks/second.mp3',
          displayName: 'Second',
          groupKey: '/tracks',
          groupTitle: 'Tracks',
          groupSubtitle: '',
          isSingle: false,
        ),
      ];
    final preparations = <(String, bool, bool, int?)>[];
    var pauseCount = 0;
    var startCount = 0;
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..attachPlaybackCommands(
        prepareSession:
            (
              session, {
              required nextPath,
              autoPlay = true,
              forceStartAtZero = false,
              showLoading = true,
              targetQueueIndex,
            }) async {
              preparations.add((
                nextPath,
                forceStartAtZero,
                showLoading,
                targetQueueIndex,
              ));
              return true;
            },
        pauseSession: (session) async => pauseCount++,
        startSession: (session, {required shouldStartTriggerCountdown}) async {
          startCount++;
          return true;
        },
        resolveAdvance: (session, {required forward}) => PlaybackAdvanceResult(
          path: forward ? '/tracks/second.mp3' : '/tracks/first.mp3',
          queueIndex: forward ? 1 : 0,
        ),
        hasAdjacent: (session, {required forward}) => true,
      )
      ..registerSession(session);

    await playback.toggleSessionPlayPause(session.id);
    session.state = PlayerState(true, ProcessingState.ready);
    await playback.toggleSessionPlayPause(session.id);
    session.state = PlayerState(false, ProcessingState.ready);
    await playback.toggleSessionPlayPause(session.id);
    await playback.switchSessionTrack(session.id, '/tracks/direct.mp3');
    await playback.switchSessionQueueTrack(session.id, 1);
    await playback.seekSessionToNext(session.id);
    session.setOptimisticPosition(const Duration(seconds: 5));
    await playback.seekSessionToPrev(session.id);

    expect(pauseCount, 1);
    expect(startCount, 1);
    expect(preparations, <(String, bool, bool, int?)>[
      ('/tracks/transport.mp3', false, true, null),
      ('/tracks/direct.mp3', true, false, null),
      ('/tracks/second.mp3', true, false, 1),
      ('/tracks/second.mp3', true, false, 1),
    ]);
    expect(native.seekPositions, <Duration>[Duration.zero]);
    expect(playback.hasSessionAdjacentTrack(session.id, forward: true), isTrue);
  });

  test('track changes preserve the session playback intent', () async {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    )..configurePersistence(enabled: false);
    final session = _session('adjacent_playback_intent')
      ..state = PlayerState(false, ProcessingState.ready)
      ..customQueueTracks = <MusicTrack>[
        MusicTrack(
          path: '/tracks/first.mp3',
          displayName: 'First',
          groupKey: '/tracks',
          groupTitle: 'Tracks',
          groupSubtitle: '',
          isSingle: false,
        ),
        MusicTrack(
          path: '/tracks/second.mp3',
          displayName: 'Second',
          groupKey: '/tracks',
          groupTitle: 'Tracks',
          groupSubtitle: '',
          isSingle: false,
        ),
      ];
    final autoPlayValues = <bool>[];
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..attachPlaybackCommands(
        prepareSession:
            (
              session, {
              required nextPath,
              autoPlay = true,
              forceStartAtZero = false,
              showLoading = true,
              targetQueueIndex,
            }) async {
              autoPlayValues.add(autoPlay);
              return true;
            },
        pauseSession: (_) async {},
        startSession: (_, {required shouldStartTriggerCountdown}) async => true,
        resolveAdvance: (_, {required forward}) => PlaybackAdvanceResult(
          path: forward ? '/tracks/next.mp3' : '/tracks/previous.mp3',
        ),
        hasAdjacent: (_, {required forward}) => true,
      )
      ..registerSession(session);

    await playback.switchSessionTrack(session.id, '/tracks/direct.mp3');
    await playback.switchSessionQueueTrack(session.id, 1);
    await playback.seekSessionToNext(session.id);
    await playback.seekSessionToPrev(session.id);

    session.state = PlayerState(true, ProcessingState.ready);
    await playback.switchSessionTrack(session.id, '/tracks/direct.mp3');
    await playback.switchSessionQueueTrack(session.id, 1);
    await playback.seekSessionToNext(session.id);
    await playback.seekSessionToPrev(session.id);

    expect(autoPlayValues, <bool>[
      false,
      false,
      false,
      false,
      true,
      true,
      true,
      true,
    ]);
  });

  test('previous and next suppress transient playback loading', () async {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    )..configurePersistence(enabled: false);
    final session = _session('adjacent_loading');
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..attachPlaybackCommands(
        prepareSession:
            (
              session, {
              required nextPath,
              autoPlay = true,
              forceStartAtZero = false,
              showLoading = true,
              targetQueueIndex,
            }) async {
              session.isPlaybackStarting = true;
              session.setOptimisticState(
                processingState: ProcessingState.buffering,
              );
              return true;
            },
        pauseSession: (_) async {},
        startSession: (_, {required shouldStartTriggerCountdown}) async => true,
        resolveAdvance: (_, {required forward}) => PlaybackAdvanceResult(
          path: forward ? '/tracks/next.mp3' : '/tracks/previous.mp3',
        ),
        hasAdjacent: (_, {required forward}) => true,
      )
      ..registerSession(session);

    await playback.seekSessionToNext(session.id);

    expect(session.isPlaybackLoading, isFalse);

    session.isPlaybackStarting = false;
    session.setOptimisticState(processingState: ProcessingState.ready);
    await playback.seekSessionToPrev(session.id);

    expect(session.isPlaybackLoading, isFalse);
  });

  test(
    'sequential play pauses instead of auto-advancing on completion',
    () async {
      final library = _createLibraryFacade();
      final playback = PlaybackFacade.create(
        databaseRepository:
            library.databaseRepository as PlaybackPersistenceRepository,
      )..configurePersistence(enabled: false);
      final session = _session('sequential_once')
        ..loopMode = SessionLoopMode.folderOnce;
      var completedCount = 0;
      addTearDown(() async {
        session.dispose();
        await playback.dispose();
        await library.dispose();
      });
      playback
        ..attachSessionRuntime(
          onSessionRegistered: (_) {},
          onSessionsReordered: () {},
          onSessionStateChanged: () {},
          onSessionCompleted: (_) => completedCount++,
        )
        ..attachPlaybackCommands(
          prepareSession:
              (
                session, {
                required nextPath,
                autoPlay = true,
                forceStartAtZero = false,
                showLoading = true,
                targetQueueIndex,
              }) async => true,
          pauseSession: (_) async {},
          startSession: (_, {required shouldStartTriggerCountdown}) async =>
              true,
          resolveAdvance: (_, {required forward}) =>
              const PlaybackAdvanceResult(path: '/tracks/next.mp3'),
          hasAdjacent: (_, {required forward}) => true,
        )
        ..registerSession(session);

      session.setOptimisticState(
        playing: false,
        processingState: ProcessingState.completed,
      );
      await Future<void>.delayed(Duration.zero);

      expect(completedCount, 0);
      expect(session.isLoading, isFalse);
      expect(session.isAdvancingAfterCompletion, isFalse);
    },
  );

  test('completion callback failures are contained and surfaced', () async {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    )..configurePersistence(enabled: false);
    final session = _session('completion_failure');
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..attachSessionRuntime(
        onSessionRegistered: (_) {},
        onSessionsReordered: () {},
        onSessionStateChanged: () {},
        onSessionCompleted: (_) async {
          throw StateError('next track failed');
        },
      )
      ..attachPlaybackCommands(
        prepareSession:
            (
              session, {
              required nextPath,
              autoPlay = true,
              forceStartAtZero = false,
              showLoading = true,
              targetQueueIndex,
            }) async => true,
        pauseSession: (_) async {},
        startSession: (_, {required shouldStartTriggerCountdown}) async => true,
        resolveAdvance: (_, {required forward}) =>
            const PlaybackAdvanceResult(path: '/tracks/next.mp3'),
        hasAdjacent: (_, {required forward}) => true,
      )
      ..registerSession(session);

    session.setOptimisticState(
      playing: false,
      processingState: ProcessingState.completed,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(session.isLoading, isFalse);
    expect(session.isAdvancingAfterCompletion, isFalse);
    expect(session.playbackError, contains('next track failed'));
  });

  test('PlaybackFacade owns loop mode state and synchronization', () async {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    )..configurePersistence(enabled: false);
    final session = _session('loop');
    final synchronizedModes = <SessionLoopMode>[];
    var settingsChanges = 0;
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..attachSessionRuntime(
        onSessionRegistered: (_) {},
        onSessionsReordered: () {},
        onSessionStateChanged: () {},
        onSessionSettingsChanged: () => settingsChanges++,
      )
      ..attachLoopModeSynchronizer((session, mode) async {
        synchronizedModes.add(mode);
      })
      ..registerSession(session);

    await playback.setSessionLoopMode(
      session.id,
      SessionLoopMode.crossSequential,
    );
    await playback.toggleSessionShuffle(session.id);
    await playback.toggleSessionCrossFolder(session.id);
    await playback.toggleSessionShuffle(session.id);
    await playback.toggleSessionSingleLoop(session.id);
    await playback.toggleSessionShuffle(session.id);
    await playback.toggleSessionSingleLoop(session.id);
    await Future<void>.delayed(Duration.zero);

    expect(session.loopMode, SessionLoopMode.folderRandom);
    expect(session.nonSingleLoopMode, SessionLoopMode.folderRandom);
    expect(settingsChanges, 6);
    expect(synchronizedModes, <SessionLoopMode>[
      SessionLoopMode.crossSequential,
      SessionLoopMode.crossOnce,
      SessionLoopMode.folderOnce,
      SessionLoopMode.folderRandom,
      SessionLoopMode.single,
      SessionLoopMode.folderRandom,
    ]);
  });

  test('PlaybackFacade owns audio effect updates and rollback', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final session = _session('effects')..loadedPath = '/tracks/effects.mp3';
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..attachSessionRuntime(
        onSessionRegistered: (_) {},
        onSessionsReordered: () {},
        onSessionStateChanged: () {},
      )
      ..registerSession(session);

    await playback.setSessionSkipSilence(session.id, true);
    expect(session.audioEffects.skipSilenceEnabled, isTrue);
    expect(native.audioEffectsCalls, 1);

    native.failAudioEffects = true;
    await playback.setSessionPanning(session.id, 0.5);

    expect(session.audioEffects.panning, 0.0);
    expect(native.audioEffectsCalls, 2);
  });

  test('PlaybackFacade owns track and playback queue session creation', () {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    addTearDown(() async {
      for (final session in playback.sessions.values) {
        session.dispose();
      }
      await playback.dispose();
      await library.dispose();
    });
    final registered = <String>[];
    playback.attachSessionRuntime(
      onSessionRegistered: (session) => registered.add(session.id),
      onSessionsReordered: () {},
      onSessionStateChanged: () {},
    );
    final track = MusicTrack(
      path: '/tracks/created.mp3',
      displayName: 'Created',
      groupKey: '/tracks',
      groupTitle: 'Tracks',
      groupSubtitle: '',
      isSingle: true,
    );

    final trackSession = playback.createTrackSession(
      track,
      loopMode: SessionLoopMode.single,
      volume: 4,
      customQueueTracks: <MusicTrack>[track],
    );
    final queueSession = playback.createPlaybackQueue('Queue 1');

    expect(trackSession.currentTrackPath, track.path);
    expect(trackSession.loopMode, SessionLoopMode.single);
    expect(trackSession.nonSingleLoopMode, SessionLoopMode.folderSequential);
    expect(trackSession.volume, PlaybackFacade.maxSessionVolume);
    expect(trackSession.state.processingState, ProcessingState.idle);
    expect(trackSession.customQueueTracks, <MusicTrack>[track]);
    expect(queueSession.currentTrackPath, isEmpty);
    expect(queueSession.playbackQueue?.name, 'Queue 1');
    expect(queueSession.customQueueTracks, isEmpty);
    expect(registered, <String>[trackSession.id, queueSession.id]);
    expect(trackSession.id, isNot(queueSession.id));
  });

  test('PlaybackFacade can disable session persistence scheduling', () async {
    final database = _RecordingTestPersistenceRepository();
    final library = LibraryFacade.create(databaseRepository: database);
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    addTearDown(() async {
      await playback.dispose();
      await library.dispose();
    });
    playback.configurePersistence(enabled: false);
    final queue = playback.createPlaybackQueue('No persistence');
    addTearDown(queue.dispose);

    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(database.sessionSaves, 0);
    expect(database.orderSaves, 0);
    expect(playback.hasScheduledSessionStatePersistence, isFalse);
    expect(playback.hasScheduledSessionOrderPersistence, isFalse);
  });

  test('PlaybackFacade normalizes native snapshots after a path retarget', () {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    final session = _session('retargeted')
      ..currentTrackPath = '/new/work/track.mp3';
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..registerSession(session)
      ..rememberRetargetedPath('/old/work', '/new/work');

    final application = playback.applyNativeSnapshot(
      NativePlaybackSnapshot(
        sessionId: 'retargeted',
        path: '/old/work/track.mp3',
        playing: true,
        playWhenReady: true,
        processingState: 'ready',
        position: const Duration(seconds: 2),
        bufferedPosition: const Duration(seconds: 4),
        volume: 1,
        boostGain: 1,
        channelSwapEnabled: false,
        transportCommandId: 9,
      ),
      hasLibraryTrack: (_) => false,
    );

    expect(application.applied, isTrue);
    expect(
      PathMatcher.equalsNormalized(
        application.snapshot.path!,
        '/new/work/track.mp3',
      ),
      isTrue,
    );
    expect(
      PathMatcher.equalsNormalized(
        session.currentTrackPath,
        '/new/work/track.mp3',
      ),
      isTrue,
    );
    expect(session.state.playing, isTrue);
    expect(playback.nextTransportCommandId(), 10);
  });

  test(
    'PlaybackFacade owns debounced session persistence scheduling',
    () async {
      final database = _RecordingTestPersistenceRepository();
      final library = LibraryFacade.create(databaseRepository: database);
      final playback = PlaybackFacade.create(
        databaseRepository:
            library.databaseRepository as PlaybackPersistenceRepository,
      );
      addTearDown(() async {
        await playback.dispose();
        await library.dispose();
      });
      playback
        ..scheduleSessionStatePersistence(
          delay: const Duration(milliseconds: 5),
        )
        ..scheduleSessionStatePersistence(
          delay: const Duration(milliseconds: 5),
        )
        ..scheduleSessionOrderPersistence(
          delay: const Duration(milliseconds: 5),
        );

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(database.sessionSaves, 1);
      expect(database.orderSaves, 1);

      playback.scheduleSessionStatePersistence(
        delay: const Duration(minutes: 1),
      );
      await playback.flushSessionStatePersistence();
      expect(database.sessionSaves, 2);
    },
  );

  test(
    'position buckets upsert playback state without rewriting all sessions',
    () async {
      final database = _RecordingTestPersistenceRepository();
      final library = LibraryFacade.create(databaseRepository: database);
      final playback = PlaybackFacade.create(
        databaseRepository:
            library.databaseRepository as PlaybackPersistenceRepository,
      );
      final session = _session('incremental-position');
      final track = MusicTrack(
        path: '/tracks/incremental-position.mp3',
        displayName: 'Incremental',
        groupKey: '/tracks',
        groupTitle: 'Tracks',
        groupSubtitle: '',
        isSingle: true,
      );
      addTearDown(() async {
        session.dispose();
        await playback.dispose();
        await library.dispose();
      });
      playback
        ..registerSession(session)
        ..observeSession(session)
        ..attachPersistenceRuntime(
          trackByPath: (_) => track,
          recordPlaybackProgress: () => true,
          restoreRuntime: (_, {required focusedSessionId}) async {},
          updatePlaybackHistory:
              ({
                required trackPath,
                required position,
                required now,
                required updatePlayedAt,
              }) => track.copyWith(
                lastPlayedPosition: position,
                lastPlayedAt: updatePlayedAt ? now : null,
              ),
          onFocusChanged: (_) {},
        );

      session.setOptimisticPosition(const Duration(seconds: 6));
      await Future<void>.delayed(const Duration(milliseconds: 900));

      expect(database.sessionStateUpserts, 1);
      expect(database.sessionSaves, 0);
      expect(database.lastPlaybackState?.id, session.id);
      expect(database.lastPlaybackState?.positionMs, 6000);
      expect(database.trackUpserts, 1);
      expect(
        database.lastTrack?.lastPlayedPosition,
        const Duration(seconds: 6),
      );
    },
  );

  test('a full session save supersedes a pending position upsert', () async {
    final database = _RecordingTestPersistenceRepository();
    final library = LibraryFacade.create(databaseRepository: database);
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    final session = _session('full-supersedes-position');
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback
      ..registerSession(session)
      ..observeSession(session);

    session.setOptimisticPosition(const Duration(seconds: 6));
    playback.scheduleSessionStatePersistence(
      delay: const Duration(milliseconds: 5),
    );
    await Future<void>.delayed(const Duration(milliseconds: 850));

    expect(database.sessionSaves, 1);
    expect(database.sessionStateUpserts, 0);
  });

  test('PlaybackFacade owns queue metadata and track snapshots', () async {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    final original = MusicTrack(
      path: '/tracks/a.mp3',
      displayName: 'Old',
      groupKey: '/tracks',
      groupTitle: 'Tracks',
      groupSubtitle: '',
      isSingle: true,
    );
    final updated = MusicTrack(
      path: '/tracks/a.mp3',
      displayName: 'Updated',
      groupKey: '/tracks',
      groupTitle: 'Tracks',
      groupSubtitle: '',
      isSingle: true,
    );
    final queueSession = _session('queue')
      ..customQueueTracks = <MusicTrack>[original]
      ..playbackQueue = PlaybackQueueDefinition(
        name: 'Before',
        entries: <PlaybackQueueEntry>[
          PlaybackQueueEntry(
            id: 'entry',
            kind: PlaybackQueueEntryKind.track,
            title: 'Track',
            tracks: <MusicTrack>[original],
          ),
        ],
      );
    addTearDown(() async {
      queueSession.dispose();
      await playback.dispose();
      await library.dispose();
    });
    var changeCount = 0;
    var synchronizeCount = 0;
    playback.attachSessionRuntime(
      onSessionRegistered: (_) {},
      onSessionsReordered: () {},
      onSessionStateChanged: () => changeCount++,
    );
    playback.attachPlaybackQueueSynchronizer((
      session, {
      selectFirst = false,
    }) async {
      synchronizeCount++;
      session.customQueueTracks = session.playbackQueue?.expandedTracks;
    });
    playback.registerSession(queueSession);

    expect(playback.renamePlaybackQueue('queue', 'After'), isTrue);
    expect(playback.setPlaybackQueueColorValue('queue', 0xff112233), isTrue);
    expect(playback.replaceSessionTrackSnapshots(updated), isTrue);
    await playback.addTrackToPlaybackQueue('queue', updated);
    final addedEntry = queueSession.playbackQueue!.entries.last;
    await playback.removePlaybackQueueEntry('queue', addedEntry.id);

    expect(queueSession.playbackQueue?.name, 'After');
    expect(queueSession.playbackQueue?.colorValue, 0xff112233);
    expect(queueSession.customQueueTracks?.single.displayName, 'Updated');
    expect(
      queueSession.playbackQueue?.entries.single.tracks.single.displayName,
      'Updated',
    );
    expect(changeCount, 5);
    expect(synchronizeCount, 2);
    expect(addedEntry.id, startsWith('queue_entry_'));
    expect(queueSession.playbackQueue?.entries, hasLength(1));
  });

  _backgroundBucketTests();
}

final class _RecordingTestPersistenceRepository
    extends TestPersistenceRepository {
  int sessionSaves = 0;
  int sessionStateUpserts = 0;
  int trackUpserts = 0;
  int orderSaves = 0;
  PersistedPlaybackSession? lastPlaybackState;
  MusicTrack? lastTrack;

  @override
  Future<void> saveAllSessions(List<PersistedPlaybackSession> sessions) async {
    sessionSaves++;
  }

  @override
  Future<void> upsertSessionPlaybackState(
    PersistedPlaybackSession session,
  ) async {
    sessionStateUpserts++;
    lastPlaybackState = session;
  }

  @override
  Future<void> upsertTracks(List<MusicTrack> tracks) async {
    trackUpserts++;
    lastTrack = tracks.single;
  }

  @override
  Future<void> updateSessionOrder(List<String> sessionIds) async {
    orderSaves++;
  }
}

LibraryFacade _createLibraryFacade() {
  return LibraryFacade.create(databaseRepository: TestPersistenceRepository());
}

void _backgroundBucketTests() {
  test('background mode coarsens the position persistence bucket', () {
    final library = _createLibraryFacade();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
    );
    final session = _session('bucket');
    addTearDown(() async {
      session.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback.registerSession(session);

    expect(
      playback.positionBucketSeconds,
      PlaybackFacade.foregroundPositionBucketSeconds,
    );

    session.lastKnownPosition = const Duration(seconds: 97);
    playback.setBackgroundMode(true);

    expect(
      playback.positionBucketSeconds,
      PlaybackFacade.backgroundPositionBucketSeconds,
    );
    // Buckets are re-based so the first background tick is not a spurious write.
    expect(
      session.lastPersistedPositionBucket,
      97 ~/ PlaybackFacade.backgroundPositionBucketSeconds,
    );

    playback.setBackgroundMode(false);

    expect(
      playback.positionBucketSeconds,
      PlaybackFacade.foregroundPositionBucketSeconds,
    );
    expect(
      session.lastPersistedPositionBucket,
      97 ~/ PlaybackFacade.foregroundPositionBucketSeconds,
    );
  });
}

PlaybackSession _session(String id) {
  return PlaybackSession(
    id: id,
    currentTrackPath: '/tracks/$id.mp3',
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.folderSequential,
    volume: 1,
    createdAt: DateTime(2026),
    state: PlayerState(false, ProcessingState.idle),
  );
}

final class _RecordingNativePlaybackRepository
    extends NativePlaybackRepository {
  int pauseAllCount = 0;
  int clearAllCount = 0;
  final List<String> removedSessionIds = <String>[];
  final List<Duration> seekPositions = <Duration>[];
  final List<(double, bool)> volumeUpdates = <(double, bool)>[];
  final List<double> speedUpdates = <double>[];
  bool failSpeed = false;
  bool failVolume = false;
  bool failPauseAll = false;
  bool failClearAll = false;
  final Set<String> failedRemovalSessionIds = <String>{};
  Completer<NativeResult<NativePlaybackSnapshot>>? speedGate;
  int audioEffectsCalls = 0;
  bool failAudioEffects = false;

  @override
  Future<NativeResult<void>> pauseAll() async {
    pauseAllCount++;
    if (failPauseAll) return const NativeFailure<void>('pause all failed');
    return const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<void>> clearAll() async {
    clearAllCount++;
    if (failClearAll) return const NativeFailure<void>('clear all failed');
    return const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<void>> removeSession(String sessionId) async {
    removedSessionIds.add(sessionId);
    if (failedRemovalSessionIds.contains(sessionId)) {
      return const NativeFailure<void>('remove failed');
    }
    return const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> seek(
    String sessionId,
    Duration position,
  ) async {
    seekPositions.add(position);
    return const NativeFailure<NativePlaybackSnapshot>('not needed');
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setVolume(
    String sessionId,
    double volume, {
    bool reloadSource = true,
  }) async {
    volumeUpdates.add((volume, reloadSource));
    if (failVolume) {
      return const NativeFailure<NativePlaybackSnapshot>('volume failed');
    }
    return const NativeSuccess<NativePlaybackSnapshot>();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setSpeed(
    String sessionId,
    double speed,
  ) async {
    speedUpdates.add(speed);
    final gate = speedGate;
    if (gate != null) return gate.future;
    if (failSpeed) {
      return const NativeFailure<NativePlaybackSnapshot>('speed failed');
    }
    return const NativeSuccess<NativePlaybackSnapshot>();
  }

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) async {
    audioEffectsCalls++;
    if (failAudioEffects) {
      return const NativeFailure<NativePlaybackSnapshot>('effects failed');
    }
    return const NativeSuccess<NativePlaybackSnapshot>();
  }

  @override
  Future<void> dispose() async {}
}
