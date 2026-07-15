import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/native_playback_bridge.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';

void main() {
  test('NotificationFacade owns foreground notification recovery', () async {
    final facade = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    addTearDown(facade.dispose);
    var undismissCount = 0;
    var restoredCount = 0;
    facade.attachRuntime(
      undismissNotifications: () async => undismissCount++,
      onNotificationsRestored: () => restoredCount++,
    );
    facade.stateService
      ..notificationsDismissedWhilePaused = true
      ..unifiedNotificationSyncKey = 'stale';

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);

    expect(facade.stateService.notificationsDismissedWhilePaused, isFalse);
    expect(facade.stateService.unifiedNotificationSyncKey, isNull);
    expect(undismissCount, 1);
    expect(restoredCount, 1);

    facade.resyncAfterForegroundResume();
    await Future<void>.delayed(Duration.zero);
    expect(undismissCount, 1);
    expect(restoredCount, 1);
  });

  test('NotificationFacade owns guarded pause action coordination', () async {
    final library = LibraryFacade.create();
    final native = _RecordingNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository: library.databaseRepository,
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
      session.dispose();
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
      syncNotificationState: () {},
      hasPlaybackToKeepAlive: () => true,
      clearUnifiedNotifications: () async {},
      stopPlaybackKeepAlive: () async {},
      preferredSessionId: () => session.id,
      notifyNotificationChanged: () {},
    );

    await facade.pausePrimarySession();

    expect(native.pausedSessionIds, <String>[session.id]);
    expect(session.state.playing, isFalse);
    expect(focusedSessionId, session.id);
  });
}

final class _RecordingNativePlaybackRepository
    extends NativePlaybackRepository {
  final List<String> pausedSessionIds = <String>[];

  @override
  Future<NativeResult<NativePlaybackSnapshot>> pause(
    String sessionId, {
    int transportCommandId = 0,
  }) async {
    pausedSessionIds.add(sessionId);
    return const NativeSuccess<NativePlaybackSnapshot>();
  }

  @override
  Future<void> dispose() async {}
}
