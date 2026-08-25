import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/audio_state_services.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';

import 'support/test_persistence_repository.dart';

void main() {
  test('notification synchronization coalesces while paused', () async {
    final service = _RecordingPlaybackNotificationService();
    final fixture = _createNotificationFixture(service);
    addTearDown(fixture.dispose);

    fixture.facade.setSynchronizationPaused(true);
    fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
    fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.syncCount, 0);

    fixture.facade.setSynchronizationPaused(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.syncCount, 1);
  });

  test('queued debounce survives synchronization pause', () async {
    final service = _RecordingPlaybackNotificationService();
    final fixture = _createNotificationFixture(service);
    addTearDown(fixture.dispose);

    fixture.facade.syncPlaybackState();
    expect(fixture.stateService.unifiedNotificationSyncTimer, isNotNull);

    fixture.facade.setSynchronizationPaused(true);
    expect(fixture.stateService.unifiedNotificationSyncTimer, isNull);
    expect(fixture.stateService.synchronizationPendingWhilePaused, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(service.syncCount, 0);

    fixture.facade.setSynchronizationPaused(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.syncCount, 1);
    expect(fixture.stateService.synchronizationPendingWhilePaused, isFalse);
  });

  test('queued in-flight synchronization waits for resume', () async {
    final service = _BlockingPlaybackNotificationService();
    final fixture = _createNotificationFixture(service);
    addTearDown(fixture.dispose);

    fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
    await service.firstSyncStarted.future;

    fixture.session.setOptimisticState(playing: false);
    fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
    fixture.facade.setSynchronizationPaused(true);
    service.releaseFirstSync.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(service.syncCount, 1);
    expect(fixture.stateService.synchronizationPendingWhilePaused, isTrue);

    fixture.facade.setSynchronizationPaused(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.syncCount, 2);
    expect(
      (service.payloads.last['items'] as List<dynamic>).single['playing'],
      isFalse,
    );
  });

  test('pause and resume without pending work does not synchronize', () async {
    final service = _RecordingPlaybackNotificationService();
    final fixture = _createNotificationFixture(service);
    addTearDown(fixture.dispose);

    fixture.facade.setSynchronizationPaused(true);
    fixture.facade.setSynchronizationPaused(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(service.syncCount, 0);
  });

  test('NotificationFacade owns foreground notification recovery', () async {
    final stateService = NotificationCoordinatorService();
    final facade = NotificationFacade.create(
      service: PlaybackNotificationService(),
      stateService: stateService,
    );
    addTearDown(facade.dispose);
    var undismissCount = 0;
    var restoredCount = 0;
    facade.attachRuntime(
      undismissNotifications: () async => undismissCount++,
      onNotificationsRestored: () => restoredCount++,
    );
    stateService
      ..notificationsDismissedWhilePaused = true
      ..unifiedNotificationSyncKey = 'stale';

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);

    expect(stateService.notificationsDismissedWhilePaused, isFalse);
    expect(stateService.unifiedNotificationSyncKey, isNull);
    expect(undismissCount, 1);
    expect(restoredCount, 1);

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);
    expect(undismissCount, 1);
    expect(restoredCount, 1);
  });

  test('NotificationFacade owns guarded pause action coordination', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    );
    final facade = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    final session = PlaybackSession(
      id: 'notification-session',
      currentTrackPath: '/tracks/notification.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(true, ProcessingState.ready),
    );
    var focusedSessionId = '';
    addTearDown(() async {
      await session.shutdown();
      await facade.dispose();
      await playback.dispose();
      await library.dispose();
    });
    playback.registerSession(session);
    facade.attachActions(
      playback: playback,
      resolveSession: ([sessionId]) =>
          sessionId == null || sessionId == session.id ? session : null,
      resolveActionSession: () => session,
      resumeSession: (_) async {},
      multiThreadPlaybackEnabled: () => false,
      setFocusSessionId: (sessionId) => focusedSessionId = sessionId ?? '',
      notify: () {},
      syncKeepAlive: () {},
      hasPlaybackToKeepAlive: () => true,
      clearUnifiedNotifications: () async {},
      preferredSessionId: () => session.id,
      notifyNotificationChanged: () {},
    );

    await facade.pausePrimarySession();

    expect(native.pausedSessionIds, <String>[session.id]);
    expect(session.state.playing, isFalse);
    expect(focusedSessionId, session.id);
  });

  test('notification pause failure keeps the session playing', () async {
    final library = _createLibraryFacade();
    final native = _RecordingNativePlaybackRepository()..failPause = true;
    final playback = PlaybackFacade.create(
      databaseRepository:
          library.databaseRepository as PlaybackPersistenceRepository,
      nativeRepository: native,
    );
    final facade = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    final session = PlaybackSession(
      id: 'notification-pause-failure',
      currentTrackPath: '/tracks/failure.mp3',
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(true, ProcessingState.ready),
    );
    playback.registerSession(session);
    facade.attachActions(
      playback: playback,
      resolveSession: ([sessionId]) => session,
      resolveActionSession: () => session,
      resumeSession: (_) async {},
      multiThreadPlaybackEnabled: () => false,
      setFocusSessionId: (_) {},
      notify: () {},
      syncKeepAlive: () {},
      hasPlaybackToKeepAlive: () => true,
      clearUnifiedNotifications: () async {},
      preferredSessionId: () => session.id,
      notifyNotificationChanged: () {},
    );
    addTearDown(() async {
      await facade.dispose();
      await playback.dispose();
      await library.dispose();
    });

    await facade.pausePrimarySession();

    expect(session.state.playing, isTrue);
    expect(native.pausedSessionIds, <String>[session.id]);
  });

  test(
    'NotificationFacade resets platform state after playback mode changes',
    () async {
      final library = _createLibraryFacade();
      final playback = PlaybackFacade.create(
        databaseRepository:
            library.databaseRepository as PlaybackPersistenceRepository,
      );
      final stateService = NotificationCoordinatorService();
      final facade = NotificationFacade.create(
        service: PlaybackNotificationService(),
        stateService: stateService,
      );
      var clearCount = 0;
      var keepAliveSyncCount = 0;
      String? focusedSessionId = 'stale';
      addTearDown(() async {
        await facade.dispose();
        await playback.dispose();
        await library.dispose();
      });
      facade.attachActions(
        playback: playback,
        resolveSession: ([sessionId]) => null,
        resolveActionSession: () => null,
        resumeSession: (_) async {},
        multiThreadPlaybackEnabled: () => false,
        setFocusSessionId: (sessionId) => focusedSessionId = sessionId,
        notify: () {},
        syncKeepAlive: () => keepAliveSyncCount++,
        hasPlaybackToKeepAlive: () => false,
        clearUnifiedNotifications: () async => clearCount++,
        preferredSessionId: () => null,
        notifyNotificationChanged: () {},
      );
      stateService.unifiedNotificationSyncKey = 'stale';

      await facade.handlePlaybackModeChanged();

      expect(stateService.unifiedNotificationSyncKey, isNull);
      expect(focusedSessionId, isNull);
      expect(clearCount, 1);
      expect(keepAliveSyncCount, 1);
    },
  );
}

_NotificationFixture _createNotificationFixture(
  PlaybackNotificationService service,
) {
  final library = _createLibraryFacade();
  final playback = PlaybackFacade.create(
    databaseRepository:
        library.databaseRepository as PlaybackPersistenceRepository,
  );
  final stateService = NotificationCoordinatorService();
  final facade = NotificationFacade.create(
    service: service,
    stateService: stateService,
  );
  library.configureCoverArtworkRuntime(
    isActiveCoverKey: (_) => false,
    onActiveCoverChanged: () {},
  );
  final session = PlaybackSession(
    id: 'paused-notification-session',
    currentTrackPath: '/tracks/paused.mp3',
    loopMode: SessionLoopMode.folderSequential,
    nonSingleLoopMode: SessionLoopMode.folderSequential,
    volume: 1,
    createdAt: DateTime(2026),
    state: PlayerState(true, ProcessingState.ready),
  );
  playback.registerSession(session);
  facade.attachActions(
    playback: playback,
    resolveSession: ([sessionId]) => session,
    resolveActionSession: () => session,
    resumeSession: (_) async {},
    multiThreadPlaybackEnabled: () => false,
    setFocusSessionId: (_) {},
    notify: () {},
    syncKeepAlive: () {},
    hasPlaybackToKeepAlive: () => true,
    clearUnifiedNotifications: () async {},
    preferredSessionId: () => session.id,
    notifyNotificationChanged: () {},
  );
  facade.attachSynchronization(
    playbackCommands: _NoopNotificationPlaybackCommands(),
    subtitles: PlaybackSubtitleService(trackResolver: (_) => null),
    trackByPath: (_) => null,
    coverArtworkCacheService: library.coverArtworkCacheService,
    notificationsEnabled: () => true,
  );
  return _NotificationFixture(library, playback, facade, stateService, session);
}

final class _NotificationFixture {
  const _NotificationFixture(
    this.library,
    this.playback,
    this.facade,
    this.stateService,
    this.session,
  );

  final LibraryFacade library;
  final PlaybackFacade playback;
  final NotificationFacade facade;
  final NotificationCoordinatorService stateService;
  final PlaybackSession session;

  Future<void> dispose() async {
    await session.shutdown();
    await facade.dispose();
    await playback.dispose();
    await library.dispose();
  }
}

final class _RecordingPlaybackNotificationService
    extends PlaybackNotificationService {
  int syncCount = 0;

  @override
  Future<void> syncUnifiedNotifications(Map<String, dynamic> payload) async {
    syncCount++;
  }
}

final class _BlockingPlaybackNotificationService
    extends PlaybackNotificationService {
  final Completer<void> firstSyncStarted = Completer<void>();
  final Completer<void> releaseFirstSync = Completer<void>();
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];
  int syncCount = 0;

  @override
  Future<void> syncUnifiedNotifications(Map<String, dynamic> payload) async {
    payloads.add(payload);
    syncCount++;
    if (syncCount != 1) return;
    firstSyncStarted.complete();
    await releaseFirstSync.future;
  }
}

final class _NoopNotificationPlaybackCommands
    implements NotificationPlaybackCommands {
  @override
  bool hasAdjacent(PlaybackSession session, {required bool forward}) => false;

  @override
  Future<bool> prepareAndPlay(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
    bool forceStartAtZero = false,
    bool showLoading = true,
    int? targetQueueIndex,
  }) async => false;

  @override
  Future<bool> startSession(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  }) async => false;
}

final class _RecordingNativePlaybackRepository
    extends NativePlaybackRepository {
  final List<String> pausedSessionIds = <String>[];
  bool failPause = false;

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) async {
    pausedSessionIds.add(sessionId);
    if (failPause) {
      return const NativeFailure<NativePlaybackSnapshot>('pause failed');
    }
    return const NativeSuccess<NativePlaybackSnapshot>();
  }

  @override
  Future<void> dispose() async {}
}

LibraryFacade _createLibraryFacade() {
  return LibraryFacade.create(databaseRepository: TestPersistenceRepository());
}
