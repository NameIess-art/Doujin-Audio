import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/app_persistence_coordinator.dart';
import 'package:doujin_audio/app/application/audio_path_coordinator.dart';
import 'package:doujin_audio/app/application/audio_ui_warmup_coordinator.dart';
import 'package:doujin_audio/features/player/application/playback_command_coordinator.dart';
import 'package:doujin_audio/app/application/playback_keep_alive_coordinator.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_cache_service.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_snapshot_cache_service.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/features/player/domain/playback_queue.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('loads owners and resets them before a runtime reload', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    await AppDatabase.createSchemaForTest(database);
    final repository = TestPersistenceRepository(
      database: AppDatabase.test(database),
    );
    final library = LibraryFacade.create(databaseRepository: repository);
    final native = _FakeNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository: repository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final timer = TimerFacade.create();
    final notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    final settings = _FailOnceSettingsRepository();
    final paths = AudioPathCoordinator(library: library, playback: playback);
    late final PlaybackSubtitleService subtitles;
    subtitles = PlaybackSubtitleService(
      trackResolver: library.trackByPath,
      onTrackLoaded: notifications.handleSubtitleTrackLoaded,
    );
    final warmup = AudioUiWarmupCoordinator(
      library: library,
      playback: playback,
      notifications: notifications,
      subtitles: subtitles,
    );
    final keepAlive = PlaybackKeepAliveCoordinator(
      playback: playback,
      settings: settings,
      enterBackgroundWarmup: warmup.enterBackground,
      resumeForegroundWarmup: warmup.resumeForeground,
    );
    final commands = PlaybackCommandCoordinator(
      library: library,
      playback: playback,
      timer: timer,
      notifications: notifications,
      asmrPlaybackCacheEnabled: () => settings.asmrPlaybackCacheEnabled,
      audioPaths: paths,
      subtitles: subtitles,
      activateAudioSession: keepAlive.activateAudioSession,
      asmrPlaybackCacheService: AsmrPlaybackCacheService(),
      notifyPlaybackChanged: () {},
      syncNotificationState: notifications.syncPlaybackState,
    );
    library.configureCoverArtworkRuntime(
      isActiveCoverKey: notifications.isActiveCoverKey,
      onActiveCoverChanged: () {},
    );
    notifications.attachActions(
      playback: playback,
      resolveSession: notifications.resolveNotificationSession,
      resolveActionSession: () => notifications.notificationActionSession,
      resumeSession: (session) =>
          commands.startSession(session, shouldStartTriggerCountdown: false),
      setFocusSessionId: notifications.setFocusedSession,
      notify: () {},
      syncKeepAlive: keepAlive.sync,
      hasPlaybackToKeepAlive: () => false,
      clearUnifiedNotifications:
          notifications.clearUnifiedNotificationsOnPlatform,
      preferredSessionId: () => commands.preferredSingleSessionId,
      notifyNotificationChanged: () {},
    );
    notifications.attachSynchronization(
      playbackCommands: commands,
      subtitles: subtitles,
      trackByPath: library.trackByPath,
      coverArtworkCacheService: library.coverArtworkCacheService,
      notificationsEnabled: () => settings.notificationsEnabled,
    );
    final coordinator = AppPersistenceCoordinator(
      library: library,
      playback: playback,
      settings: settings,
      timer: timer,
      notifications: notifications,
      keepAlive: keepAlive,
      uiWarmup: warmup,
      subtitles: subtitles,
    );
    addTearDown(() async {
      coordinator.dispose();
      await warmup.shutdown();
      await playback.dispose();
      await commands.dispose();
      await library.dispose();
      await timer.dispose();
      await notifications.dispose();
      await settings.dispose();
      await database.close();
    });

    await coordinator.loadPersistedState();

    expect(settings.slice.state.isInitialized, isTrue);
    expect(library.state.isInitialized, isTrue);
    expect(playback.state.isInitialized, isTrue);
    expect(timer.state.isInitialized, isTrue);

    settings.failNextLoad = true;
    await expectLater(coordinator.reloadPersistedState(), throwsStateError);

    expect(settings.slice.state.isInitialized, isFalse);
    expect(library.state.isInitialized, isFalse);
    expect(playback.state.isInitialized, isFalse);

    await coordinator.loadPersistedState();

    expect(native.clearAllCount, 2);
    expect(settings.slice.state.isInitialized, isTrue);
    expect(library.state.isInitialized, isTrue);
    expect(playback.state.isInitialized, isTrue);
  });

  test(
    'dispose invalidates a load blocked on the final card snapshot',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      await AppDatabase.createSchemaForTest(database);
      final repository = TestPersistenceRepository(
        database: AppDatabase.test(database),
      );
      final libraryService = LibraryService()..watchedFolders.add('/library');
      final detailCache = AudioDetailCacheService(
        repository: AudioDetailRepository(databaseRepository: repository),
      );
      final buildStarted = Completer<void>();
      final buildResult = Completer<LibraryTreeSnapshot>();
      final snapshotService = LibrarySnapshotCacheService(
        libraryService: libraryService,
        detailCacheService: detailCache,
        cardSnapshotBuilder: (_) {
          buildStarted.complete();
          return buildResult.future;
        },
      );
      final library = LibraryFacade.create(
        databaseRepository: repository,
        detailCacheService: detailCache,
        service: libraryService,
        snapshotCacheService: snapshotService,
      );
      final native = _FakeNativePlaybackRepository();
      final playback = PlaybackFacade.create(
        databaseRepository: repository,
        nativeRepository: native,
      )..configurePersistence(enabled: false);
      final timer = TimerFacade.create();
      final notifications = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      final settings = SettingsRepository();
      final paths = AudioPathCoordinator(library: library, playback: playback);
      late final PlaybackSubtitleService subtitles;
      subtitles = PlaybackSubtitleService(
        trackResolver: library.trackByPath,
        onTrackLoaded: notifications.handleSubtitleTrackLoaded,
      );
      final warmup = AudioUiWarmupCoordinator(
        library: library,
        playback: playback,
        notifications: notifications,
        subtitles: subtitles,
      );
      final keepAlive = PlaybackKeepAliveCoordinator(
        playback: playback,
        settings: settings,
        enterBackgroundWarmup: warmup.enterBackground,
        resumeForegroundWarmup: warmup.resumeForeground,
      );
      final commands = PlaybackCommandCoordinator(
        library: library,
        playback: playback,
        timer: timer,
        notifications: notifications,
        asmrPlaybackCacheEnabled: () => settings.asmrPlaybackCacheEnabled,
        audioPaths: paths,
        subtitles: subtitles,
        activateAudioSession: keepAlive.activateAudioSession,
        asmrPlaybackCacheService: AsmrPlaybackCacheService(),
        notifyPlaybackChanged: () {},
        syncNotificationState: notifications.syncPlaybackState,
      );
      library.configureCoverArtworkRuntime(
        isActiveCoverKey: notifications.isActiveCoverKey,
        onActiveCoverChanged: () {},
      );
      notifications.attachActions(
        playback: playback,
        resolveSession: notifications.resolveNotificationSession,
        resolveActionSession: () => notifications.notificationActionSession,
        resumeSession: (session) =>
            commands.startSession(session, shouldStartTriggerCountdown: false),
        setFocusSessionId: notifications.setFocusedSession,
        notify: () {},
        syncKeepAlive: keepAlive.sync,
        hasPlaybackToKeepAlive: () => false,
        clearUnifiedNotifications:
            notifications.clearUnifiedNotificationsOnPlatform,
        preferredSessionId: () => commands.preferredSingleSessionId,
        notifyNotificationChanged: () {},
      );
      notifications.attachSynchronization(
        playbackCommands: commands,
        subtitles: subtitles,
        trackByPath: library.trackByPath,
        coverArtworkCacheService: library.coverArtworkCacheService,
        notificationsEnabled: () => settings.notificationsEnabled,
      );
      final coordinator = AppPersistenceCoordinator(
        library: library,
        playback: playback,
        settings: settings,
        timer: timer,
        notifications: notifications,
        keepAlive: keepAlive,
        uiWarmup: warmup,
        subtitles: subtitles,
      );
      addTearDown(() async {
        coordinator.dispose();
        await warmup.shutdown();
        await playback.dispose();
        await commands.dispose();
        await library.dispose();
        await timer.dispose();
        await notifications.dispose();
        await settings.dispose();
        await database.close();
      });

      final load = coordinator.loadPersistedState();
      await buildStarted.future.timeout(const Duration(seconds: 5));
      library.syncPresentationState(isInitialized: false);
      playback.syncPresentationState(
        focusedSessionId: notifications.focusedSessionId,
        coverGeneration: library.coverArtworkCacheService.generation,
        isInitialized: false,
      );
      timer.syncPresentationState(isInitialized: false);
      settings.syncSlice();

      coordinator.dispose();
      buildResult.complete(
        LibraryTreeSnapshot(tree: const <LibraryNode>[], leafFolderCount: 0),
      );
      await load;

      expect(library.state.isInitialized, isFalse);
      expect(playback.state.isInitialized, isFalse);
      expect(timer.state.isInitialized, isFalse);
      expect(settings.slice.state.isInitialized, isFalse);
    },
  );

  test(
    'failed progress writes retry the latest state without saving another queue',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final repository = _RecordingPlaybackPersistenceRepository();
      final playback = PlaybackFacade.create(
        databaseRepository: repository,
        nativeRepository: _FakeNativePlaybackRepository(),
      );
      addTearDown(playback.dispose);
      final first = _pausedSession('first');
      final second = _pausedSession('second')
        ..playbackQueue = PlaybackQueueDefinition(
          name: 'Second queue',
          entries: const <PlaybackQueueEntry>[],
        )
        ..audioEffects = AudioEffectsState(noiseReductionEnabled: true);
      playback
        ..registerSession(first)
        ..registerSession(second)
        ..observeSession(first);
      await playback.flushSessionStatePersistence();
      repository.definitionWrites.clear();
      repository.failNextPlaybackWrite = true;
      repository.playbackWriteStarted = Completer<void>();

      first.setOptimisticPosition(const Duration(seconds: 6));
      await Future<void>.delayed(Duration.zero);
      playback.setBackgroundMode(true);
      await repository.playbackWriteStarted!.future;
      await Future<void>.delayed(Duration.zero);
      // No new bucket is crossed, so only the failed write can retain this ID.
      first.lastKnownPosition = const Duration(seconds: 12);
      await playback.flushSessionStatePersistence(sessionId: second.id);

      expect(repository.playbackWrites.map((session) => session.id), <String>[
        first.id,
        first.id,
      ]);
      expect(repository.playbackWrites.last.positionMs, 12000);
      expect(repository.definitionWrites, isEmpty);
      expect(second.playbackQueue?.name, 'Second queue');
      expect(second.audioEffects.noiseReductionEnabled, isTrue);
    },
  );

  test('flush waits for an order write already started by the timer', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final repository = _RecordingPlaybackPersistenceRepository();
    final playback = PlaybackFacade.create(
      databaseRepository: repository,
      nativeRepository: _FakeNativePlaybackRepository(),
    );
    addTearDown(playback.dispose);
    final session = _pausedSession('ordered');
    playback.registerSession(session);
    await playback.flushSessionStatePersistence();
    repository.definitionWrites.clear();
    repository.orderWriteStarted = Completer<void>();
    repository.orderWriteGate = Completer<void>();
    addTearDown(() {
      final gate = repository.orderWriteGate!;
      if (!gate.isCompleted) gate.complete();
    });

    playback.scheduleSessionOrderPersistence(delay: Duration.zero);
    await repository.orderWriteStarted!.future;
    session.volume = 0.7;
    var flushed = false;
    final flush = playback.flushSessionStatePersistence().then(
      (_) => flushed = true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(flushed, isFalse);
    expect(repository.definitionWrites, isEmpty);
    repository.orderWriteGate!.complete();
    await flush.timeout(const Duration(seconds: 5));

    expect(repository.orderWrites, <List<String>>[
      <String>[session.id],
    ]);
    expect(repository.definitionWrites.single, (session.id, false, false));
  });

  test(
    'an order failure remains pending until a later flush retries it',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final repository = _RecordingPlaybackPersistenceRepository();
      final playback = PlaybackFacade.create(
        databaseRepository: repository,
        nativeRepository: _FakeNativePlaybackRepository(),
      );
      addTearDown(playback.dispose);
      final session = _pausedSession('retry-order');
      playback.registerSession(session);
      await playback.flushSessionStatePersistence();
      repository.definitionWrites.clear();
      repository.failNextOrderWrite = true;

      await expectLater(playback.saveSessionOrder(), throwsStateError);
      await playback.flushSessionStatePersistence(sessionId: session.id);

      expect(repository.orderWrites, <List<String>>[
        <String>[session.id],
        <String>[session.id],
      ]);
      expect(repository.definitionWrites, isEmpty);
    },
  );

  test(
    'an explicit target flush repairs cold recovery for an equal restored definition',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final repository = _RecordingPlaybackPersistenceRepository();
      final track = MusicTrack(
        path: '/tracks/restored.mp3',
        displayName: 'Restored',
        groupKey: '/tracks',
        groupTitle: 'Tracks',
        groupSubtitle: '',
        isSingle: true,
      );
      repository.restoredSessions = [
        PersistedPlaybackSession(
          id: 'restored',
          trackPath: track.path,
          loopModeIndex: SessionLoopMode.single.index,
          volume: 1,
          positionMs: 22000,
          durationMs: 0,
          customQueueTracks: [track],
          channelSwapEnabled: false,
          sortOrder: 0,
          createdAtMs: DateTime(2026).millisecondsSinceEpoch,
        ),
      ];
      final playback = PlaybackFacade.create(
        databaseRepository: repository,
        nativeRepository: _FakeNativePlaybackRepository(),
      );
      addTearDown(playback.dispose);
      final recovered = <String>[];
      final gate = Completer<void>();
      _attachPausedRecovery(playback, (session) async {
        recovered.add(session.id);
        await gate.future;
      });
      await playback.loadPersistedState();
      expect(recovered, isEmpty);
      var finished = false;
      final flush = playback
          .flushSessionStatePersistence(sessionId: 'restored')
          .then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(recovered, ['restored']);
      expect(repository.definitionWrites, isEmpty);
      expect(finished, false);
      gate.complete();
      await flush;
      expect(
        playback.sessions['restored']!.position,
        const Duration(seconds: 22),
      );
    },
  );

  for (final progressOnly in [false, true]) {
    test(
      'failed cold ${progressOnly ? 'progress' : 'definition'} recovery retries after SQLite commits',
      () async {
        SharedPreferences.setMockInitialValues(const {});
        final repository = _RecordingPlaybackPersistenceRepository();
        final playback = PlaybackFacade.create(
          databaseRepository: repository,
          nativeRepository: _FakeNativePlaybackRepository(),
        );
        addTearDown(playback.dispose);
        final first = _pausedSession('recover-first');
        final second = _pausedSession('untouched');
        final recovered = <(String, int, double)>[];
        var failRecovery = false;
        final recoveryFailed = Completer<void>();
        _attachPausedRecovery(playback, (session) async {
          recovered.add((
            session.id,
            session.position.inSeconds,
            session.volume,
          ));
          if (failRecovery) {
            failRecovery = false;
            recoveryFailed.complete();
            throw StateError('recovery file unavailable');
          }
        });
        playback
          ..registerSession(first)
          ..registerSession(second);
        if (progressOnly) playback.observeSession(first);
        await playback.flushSessionStatePersistence();
        recovered.clear();
        repository.definitionWrites.clear();
        failRecovery = true;
        if (progressOnly) {
          first.setOptimisticPosition(const Duration(seconds: 6));
          await Future<void>.delayed(Duration.zero);
          playback.setBackgroundMode(true);
          await recoveryFailed.future;
          await Future<void>.delayed(Duration.zero);
        } else {
          first.volume = 0.7;
          await expectLater(
            playback.flushSessionStatePersistence(sessionId: first.id),
            throwsStateError,
          );
        }
        first.lastKnownPosition = const Duration(seconds: 12);
        first.volume = 0.5;
        // A full flush skips B's equal definition while retrying the failed A.
        await playback.flushSessionStatePersistence();
        expect(recovered.map((value) => value.$1), [first.id, first.id]);
        expect(recovered.last, (first.id, 12, 0.5));
        expect(
          repository.definitionWrites.every((entry) => entry.$1 == first.id),
          true,
        );
      },
    );
    test(
      'failed ${progressOnly ? 'progress' : 'definition'} history writes retry without rewriting queues',
      () async {
        SharedPreferences.setMockInitialValues(const <String, Object>{});
        final repository = _RecordingPlaybackPersistenceRepository();
        final playback = PlaybackFacade.create(
          databaseRepository: repository,
          nativeRepository: _FakeNativePlaybackRepository(),
        );
        addTearDown(playback.dispose);
        final first = _pausedSession('history');
        final second = _pausedSession('unrelated');
        var track = MusicTrack(
          path: first.currentTrackPath,
          displayName: 'Original title',
          groupKey: '/tracks',
          groupTitle: 'Tracks',
          groupSubtitle: '',
          isSingle: true,
        );
        playback.attachPersistenceRuntime(
          trackByPath: (path) => path == track.path ? track : null,
          recordPlaybackProgress: () => true,
          restoreRuntime: (_, {required focusedSessionId}) async {},
          updatePlaybackHistory:
              ({
                required trackPath,
                required position,
                required now,
                required updatePlayedAt,
              }) {
                track = track.copyWith(
                  lastPlayedPosition: position,
                  lastPlayedAt: updatePlayedAt ? now : track.lastPlayedAt,
                );
                return track;
              },
          onFocusChanged: (_) {},
        );
        playback
          ..registerSession(first)
          ..registerSession(second);
        if (progressOnly) playback.observeSession(first);
        await playback.flushSessionStatePersistence();
        repository.definitionWrites.clear();
        repository.failNextTrackWrite = true;

        if (progressOnly) {
          repository.trackWriteStarted = Completer<void>();
          first.setOptimisticPosition(const Duration(seconds: 31));
          await Future<void>.delayed(Duration.zero);
          playback.setBackgroundMode(true);
          await repository.trackWriteStarted!.future;
          await Future<void>.delayed(Duration.zero);
        } else {
          first.lastKnownPosition = const Duration(seconds: 6);
          await expectLater(
            playback.flushSessionStatePersistence(sessionId: first.id),
            throwsStateError,
          );
        }
        final expectedPosition = Duration(seconds: progressOnly ? 31 : 6);
        expect(track.lastPlayedPosition, expectedPosition);
        track = track.copyWith(isFavorite: true);

        await playback.flushSessionStatePersistence(sessionId: second.id);

        expect(repository.trackWrites, hasLength(2));
        expect(repository.trackWrites.last.single.isFavorite, true);
        expect(
          repository.trackWrites.last.single.lastPlayedPosition,
          expectedPosition,
        );
        expect(
          repository.definitionWrites,
          progressOnly ? isEmpty : [(first.id, false, false)],
        );
        expect(repository.playbackWrites, hasLength(progressOnly ? 1 : 0));
      },
    );
  }
}

void _attachPausedRecovery(
  PlaybackFacade playback,
  Future<void> Function(PlaybackSession) synchronize,
) {
  playback.attachPersistenceRuntime(
    trackByPath: (_) => null,
    recordPlaybackProgress: () => true,
    restoreRuntime: (_, {required focusedSessionId}) async {},
    updatePlaybackHistory:
        ({
          required trackPath,
          required position,
          required now,
          required updatePlayedAt,
        }) => null,
    onFocusChanged: (_) {},
    synchronizePausedRecovery: synchronize,
  );
}

PlaybackSession _pausedSession(String id) => PlaybackSession(
  id: id,
  currentTrackPath: '/tracks/$id.mp3',
  loopMode: SessionLoopMode.single,
  nonSingleLoopMode: SessionLoopMode.folderSequential,
  volume: 1,
  createdAt: DateTime(2026),
  state: const PlayerState(false, ProcessingState.idle),
);

final class _RecordingPlaybackPersistenceRepository
    extends TestPersistenceRepository {
  List<PersistedPlaybackSession> restoredSessions = [];
  final definitionWrites = <(String, bool, bool)>[];
  final playbackWrites = <PersistedPlaybackSession>[];
  final orderWrites = <List<String>>[];
  final trackWrites = <List<MusicTrack>>[];
  Completer<void>? playbackWriteStarted;
  Completer<void>? orderWriteStarted;
  Completer<void>? orderWriteGate;
  Completer<void>? trackWriteStarted;
  bool failNextPlaybackWrite = false;
  bool failNextOrderWrite = false;
  bool failNextTrackWrite = false;

  @override
  Future<List<PersistedPlaybackSession>> loadAllSessions() async =>
      restoredSessions;

  @override
  Future<void> upsertSession(
    PersistedPlaybackSession session, {
    bool includeQueue = true,
    bool includeEffects = true,
  }) async {
    definitionWrites.add((session.id, includeQueue, includeEffects));
  }

  @override
  Future<void> upsertSessionPlaybackState(
    PersistedPlaybackSession session,
  ) async {
    playbackWrites.add(session);
    final started = playbackWriteStarted;
    if (started != null && !started.isCompleted) started.complete();
    if (failNextPlaybackWrite) {
      failNextPlaybackWrite = false;
      throw StateError('playback state unavailable');
    }
  }

  @override
  Future<void> updateSessionOrder(List<String> sessionIds) async {
    orderWrites.add(List<String>.of(sessionIds));
    final started = orderWriteStarted;
    if (started != null && !started.isCompleted) started.complete();
    if (failNextOrderWrite) {
      failNextOrderWrite = false;
      throw StateError('session order unavailable');
    }
    await orderWriteGate?.future;
  }

  @override
  Future<void> upsertTracks(List<MusicTrack> tracks) async {
    trackWrites.add(List<MusicTrack>.of(tracks));
    final started = trackWriteStarted;
    if (started != null && !started.isCompleted) started.complete();
    if (failNextTrackWrite) {
      failNextTrackWrite = false;
      throw StateError('track history unavailable');
    }
  }
}

final class _FailOnceSettingsRepository extends SettingsRepository {
  bool failNextLoad = false;

  @override
  Future<void> loadPersistedState() async {
    if (failNextLoad) {
      failNextLoad = false;
      throw StateError('settings unavailable');
    }
    await super.loadPersistedState();
  }
}

final class _FakeNativePlaybackRepository extends NativePlaybackRepository {
  int clearAllCount = 0;

  @override
  Future<NativeResult<void>> clearAll() async {
    clearAllCount++;
    return const NativeSuccess<void>();
  }

  @override
  Future<void> dispose() async {}
}
