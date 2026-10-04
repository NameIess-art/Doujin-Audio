import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/notifications_platform_service.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'disabled notifications never load subtitles on focused progress',
    () async {
      var loads = 0;
      final subtitles = PlaybackSubtitleService(
        trackResolver: (_) => null,
        subtitleLoader: (_, _) async {
          loads++;
          return null;
        },
      );
      addTearDown(subtitles.dispose);
      var enabled = false;
      final fixture = _createNotificationFixture(
        _RecordingPlaybackNotificationService(),
        subtitles: subtitles,
        notificationsEnabled: () => enabled,
      );
      addTearDown(fixture.dispose);
      fixture.facade.registerSessionFocus(fixture.session.id);
      for (var tick = 0; tick < 120; tick++) {
        fixture.facade.refreshSessionSubtitle(
          fixture.session,
          position: Duration(milliseconds: tick * 500),
          syncNotification: false,
        );
      }
      await Future<void>.delayed(Duration.zero);
      expect(loads, 0);

      enabled = true;
      fixture.facade.refreshSessionSubtitle(
        fixture.session,
        syncNotification: false,
      );
      await subtitles.loadAutomatically(fixture.session.currentTrackPath);
      expect(loads, 1);
    },
  );

  test(
    'enabled focused notifications limit failed remote subtitle retries',
    () async {
      var loads = 0;
      var now = DateTime(2026);
      final subtitles = PlaybackSubtitleService(
        trackResolver: (path) => MusicTrack(
          path: path,
          displayName: 'Remote track',
          groupKey: 'work',
          groupTitle: 'Work',
          groupSubtitle: 'ASMR',
          isSingle: false,
          remoteMetadataKind: 'asmr.one',
          remoteMetadata: const {
            'subtitleUrl': 'https://example.com/missing.vtt',
          },
        ),
        subtitleLoader: (_, _) async {
          loads++;
          return null;
        },
        now: () => now,
      );
      addTearDown(subtitles.dispose);
      final fixture = _createNotificationFixture(
        _RecordingPlaybackNotificationService(),
        subtitles: subtitles,
      );
      addTearDown(fixture.dispose);
      for (var tick = 0; tick < 120; tick++) {
        fixture.facade.refreshSessionSubtitle(
          fixture.session,
          position: Duration(milliseconds: tick * 500),
          syncNotification: false,
        );
        await Future<void>.delayed(Duration.zero);
        now = now.add(const Duration(milliseconds: 500));
      }
      expect(loads, 2);
    },
  );

  test(
    'failed platform synchronization is retried without caching success',
    () async {
      const channel = MethodChannel('test/notification_sync_failure');
      var attempts = 0;
      var fail = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        attempts++;
        return fail
            ? <String, Object?>{
                'ok': false,
                'errorCode': 'platform_error',
                'error': 'Power request failed.',
              }
            : <String, Object?>{'ok': true, 'value': null};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final fixture = _createNotificationFixture(
        PlaybackNotificationService(
          notificationsPlatformService: NotificationsPlatformService(
            channel: channel,
            isWindowsOverride: true,
          ),
        ),
      );
      addTearDown(fixture.dispose);

      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fixture.stateService.unifiedNotificationSyncKey, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(attempts, 1);

      fail = false;
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempts, 2);
      expect(fixture.stateService.unifiedNotificationSyncKey, isNotNull);

      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempts, 2);

      fail = true;
      fixture.session.setOptimisticState(playing: false);
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempts, 3);
      expect(fixture.stateService.unifiedNotificationSyncKey, isNull);

      fail = false;
      fixture.session.setOptimisticState(playing: true);
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(attempts, 4);
      expect(fixture.stateService.unifiedNotificationSyncKey, isNotNull);
    },
  );

  test('failed empty-session clear does not suppress the next clear', () async {
    final service = _RecordingPlaybackNotificationService()..failClear = true;
    final fixture = _createNotificationFixture(service, registerSession: false);
    addTearDown(fixture.dispose);

    fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.clearCount, 1);
    expect(fixture.stateService.unifiedNotificationSyncKey, isNull);

    service.failClear = false;
    fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.clearCount, 2);
    expect(fixture.stateService.unifiedNotificationSyncKey, isNotNull);
    fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(service.clearCount, 2);
  });

  for (final pauseDuringSync in <bool>[true, false]) {
    test(
      pauseDuringSync
          ? 'failed in-flight sync preserves a newer paused payload'
          : 'failed in-flight sync does not immediately retry the same payload',
      () async {
        final service = _BlockingPlaybackNotificationService()
          ..failFirstSync = true;
        final fixture = _createNotificationFixture(service);
        addTearDown(fixture.dispose);

        fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
        await service.firstSyncStarted.future;
        if (pauseDuringSync) {
          fixture.session.setOptimisticState(playing: false);
        }
        fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
        service.releaseFirstSync.complete();
        await Future<void>.delayed(const Duration(milliseconds: 120));

        expect(service.syncCount, pauseDuringSync ? 2 : 1);
        if (pauseDuringSync) {
          expect(
            (service.payloads.last['items'] as List).single['playing'],
            isFalse,
          );
          expect(fixture.stateService.unifiedNotificationSyncKey, isNotNull);
        } else {
          expect(fixture.stateService.unifiedNotificationSyncKey, isNull);
          fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(service.syncCount, 2);
        }
      },
    );
  }

  test(
    'nonfocused settings and progress reuse notification presentation',
    () async {
      final service = _RecordingPlaybackNotificationService();
      final commands = _NoopNotificationPlaybackCommands();
      final resolvedPaths = <String>[];
      final fixture = _createNotificationFixture(
        service,
        commands: commands,
        trackByPath: (trackPath) {
          resolvedPaths.add(trackPath);
          return null;
        },
      );
      addTearDown(fixture.dispose);
      final other = _additionalSession();
      fixture.playback.registerSession(other);
      fixture.facade.setFocusedSession(fixture.session.id);
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final focusedItem = (service.payloads.single['items'] as List).firstWhere(
        (item) => item['id'] == fixture.session.id,
      );
      resolvedPaths.clear();
      commands.adjacentSessionIds.clear();

      other.volume = .35;
      other.speed = 1.4;
      other.lastKnownPosition = const Duration(seconds: 3);
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(service.syncCount, 1);
      expect(resolvedPaths, isEmpty);
      expect(commands.adjacentSessionIds, isEmpty);

      other.customQueueTracks = const [];
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.syncCount, 1);
      expect(resolvedPaths, isEmpty);
      expect(commands.adjacentSessionIds, everyElement(other.id));

      other.currentTrackPath = '/tracks/changed.mp3';
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.syncCount, 2);
      expect(resolvedPaths, <String>[other.currentTrackPath]);
      final updatedFocusedItem = (service.payloads.last['items'] as List)
          .firstWhere((item) => item['id'] == fixture.session.id);
      expect(identical(updatedFocusedItem, focusedItem), isTrue);
    },
  );

  test(
    'notification membership and focus synchronize without metadata rebuild',
    () async {
      final service = _RecordingPlaybackNotificationService();
      final resolvedPaths = <String>[];
      final fixture = _createNotificationFixture(
        service,
        trackByPath: (trackPath) {
          resolvedPaths.add(trackPath);
          return null;
        },
      );
      addTearDown(fixture.dispose);
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      resolvedPaths.clear();
      final other = _additionalSession();
      fixture.playback.registerSession(other);
      fixture.facade.setFocusedSession(fixture.session.id);
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.syncCount, 2);
      expect(resolvedPaths, <String>[other.currentTrackPath]);
      expect((service.payloads.last['items'] as List).length, 2);
      resolvedPaths.clear();

      fixture.facade.setFocusedSession(other.id);
      fixture.facade.syncPlaybackState(immediateUnifiedSync: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.syncCount, 3);
      expect(service.payloads.last['mainSessionId'], other.id);
      expect(resolvedPaths, isEmpty);
    },
  );

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
    var restoredCount = 0;
    facade.attachRuntime(onNotificationsRestored: () => restoredCount++);
    stateService
      ..notificationsDismissedWhilePaused = true
      ..unifiedNotificationSyncKey = 'stale';

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);

    expect(stateService.notificationsDismissedWhilePaused, isFalse);
    expect(stateService.unifiedNotificationSyncKey, isNull);
    expect(restoredCount, 1);

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);
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
      state: const PlayerState(true, ProcessingState.ready),
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
      state: const PlayerState(true, ProcessingState.ready),
    );
    playback.registerSession(session);
    facade.attachActions(
      playback: playback,
      resolveSession: ([sessionId]) => session,
      resolveActionSession: () => session,
      resumeSession: (_) async {},
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
}

_NotificationFixture _createNotificationFixture(
  PlaybackNotificationService service, {
  bool registerSession = true,
  NotificationPlaybackCommands? commands,
  NotificationTrackResolver? trackByPath,
  PlaybackSubtitleService? subtitles,
  bool Function()? notificationsEnabled,
}) {
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
    state: const PlayerState(true, ProcessingState.ready),
  );
  if (registerSession) playback.registerSession(session);
  facade.attachActions(
    playback: playback,
    resolveSession: ([sessionId]) => session,
    resolveActionSession: () => session,
    resumeSession: (_) async {},
    setFocusSessionId: (_) {},
    notify: () {},
    syncKeepAlive: () {},
    hasPlaybackToKeepAlive: () => true,
    clearUnifiedNotifications: () async {},
    preferredSessionId: () => session.id,
    notifyNotificationChanged: () {},
  );
  facade.attachSynchronization(
    playbackCommands: commands ?? _NoopNotificationPlaybackCommands(),
    subtitles: subtitles ?? PlaybackSubtitleService(trackResolver: (_) => null),
    trackByPath: trackByPath ?? (_) => null,
    coverArtworkCacheService: library.coverArtworkCacheService,
    notificationsEnabled: notificationsEnabled ?? () => true,
  );
  return _NotificationFixture(library, playback, facade, stateService, session);
}

PlaybackSession _additionalSession() => PlaybackSession(
  id: 'other-notification-session',
  currentTrackPath: '/tracks/other.mp3',
  loopMode: SessionLoopMode.folderSequential,
  nonSingleLoopMode: SessionLoopMode.folderSequential,
  volume: 1,
  createdAt: DateTime(2026, 2),
  state: const PlayerState(true, ProcessingState.ready),
);

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
  int clearCount = 0;
  bool failClear = false;
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];

  @override
  Future<NativeResult<void>> clearUnifiedNotifications() async {
    clearCount++;
    return failClear
        ? const NativeFailure<void>('Power release failed.')
        : const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<void>> syncUnifiedNotifications(
    Map<String, dynamic> payload,
  ) async {
    syncCount++;
    payloads.add(payload);
    return const NativeSuccess<void>();
  }
}

final class _BlockingPlaybackNotificationService
    extends PlaybackNotificationService {
  final Completer<void> firstSyncStarted = Completer<void>();
  final Completer<void> releaseFirstSync = Completer<void>();
  final List<Map<String, dynamic>> payloads = <Map<String, dynamic>>[];
  int syncCount = 0;
  bool failFirstSync = false;

  @override
  Future<NativeResult<void>> syncUnifiedNotifications(
    Map<String, dynamic> payload,
  ) async {
    payloads.add(payload);
    syncCount++;
    if (syncCount == 1) {
      firstSyncStarted.complete();
      await releaseFirstSync.future;
      if (failFirstSync) {
        return const NativeFailure<void>('Power request failed.');
      }
    }
    return const NativeSuccess<void>();
  }
}

final class _NoopNotificationPlaybackCommands
    implements NotificationPlaybackCommands {
  final List<String> adjacentSessionIds = <String>[];
  @override
  bool hasAdjacent(PlaybackSession session, {required bool forward}) {
    adjacentSessionIds.add(session.id);
    return false;
  }

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
