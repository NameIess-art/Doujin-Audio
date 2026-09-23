import 'dart:async';

import 'package:doujin_audio/app/application/app_runtime_lifecycle.dart';
import 'package:doujin_audio/app/application/windows_runtime_binding.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_persistence_repository.dart';
import 'support/test_playback_commands.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('doujin_audio/windows_desktop');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('taskbar play restores only sessions it paused', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'ready');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final native = _RecordingNativeRepository();
    final playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    final timer = TimerFacade.create();
    addTearDown(() async {
      await notifications.dispose();
      await playback.dispose();
    });

    final resumed = <String>[];
    playback.attachPlaybackCommands(
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
      startSession: (session, {required shouldStartTriggerCountdown}) async {
        resumed.add(session.id);
        session.setOptimisticState(playing: true);
        return true;
      },
      resolveAdvance: (_, {required forward}) => null,
      hasAdjacent: (_, {required forward}) => false,
    );
    for (final (id, playing) in [
      ('first', true),
      ('second', false),
      ('third', true),
    ]) {
      playback.registerSession(
        PlaybackSession(
          id: id,
          currentTrackPath: '/$id.mp3',
          loopMode: SessionLoopMode.folderSequential,
          nonSingleLoopMode: SessionLoopMode.folderSequential,
          volume: 1,
          createdAt: DateTime(2026),
          state: PlayerState(playing, ProcessingState.ready),
        ),
      );
    }
    await attachWindowsRuntime(
      runtime: _NoopRuntime(),
      playback: playback,
      notifications: notifications,
      timer: timer,
    );

    native.failPauseAll = true;
    await _sendTaskbarToggle(channel);
    expect(playback.sessionById('first')!.state.playing, isTrue);
    native.failPauseAll = false;
    await _sendTaskbarToggle(channel);
    expect(native.pauseAllCount, 2);
    expect(playback.sessions.values.every((s) => !s.state.playing), isTrue);

    await _sendTaskbarToggle(channel);
    expect(resumed, ['first', 'third']);
    expect(playback.sessionById('second')!.state.playing, isFalse);

    await _sendTaskbarToggle(channel);
    expect(native.pauseAllCount, 3);
    await playback.removeSession('third');
    await _sendTaskbarToggle(channel);
    expect(resumed, ['first', 'third', 'first']);
  });
}

Future<void> _sendTaskbarToggle(MethodChannel channel) {
  final completer = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('action', 'taskbarToggle'),
        ),
        (ByteData? data) => completer.complete(),
      );
  return completer.future;
}

final class _RecordingNativeRepository extends NativePlaybackRepository {
  int pauseAllCount = 0;
  bool failPauseAll = false;

  @override
  Future<NativeResult<void>> pauseAll() async {
    pauseAllCount++;
    if (failPauseAll) return const NativeFailure<void>('pause failed');
    return const NativeSuccess<void>();
  }

  @override
  Future<NativeResult<void>> removeSession(String sessionId) async =>
      const NativeSuccess<void>();

  @override
  Future<void> dispose() async {}
}

final class _NoopRuntime implements AppRuntimeLifecycle {
  @override
  Future<void> start() async {}
  @override
  Future<void> enterBackground() async {}
  @override
  Future<void> resumeForeground() async {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> handleMemoryPressure() async {}
}
