import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/application/playback_keep_alive_coordinator.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/core/platform/power_platform_service.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';

void main() {
  test(
    'sync mirrors retained playback into platform keep-alive state',
    () async {
      final power = _RecordingPowerPlatformService();
      final playback = PlaybackFacade.create(
        databaseRepository: AudioDatabaseRepository(),
      );
      final timer = TimerFacade.create(powerPlatformService: power);
      final notifications = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      final settings = SettingsRepository();
      final coordinator = PlaybackKeepAliveCoordinator(
        playback: playback,
        timer: timer,
        notifications: notifications,
        settings: settings,
        enterBackgroundWarmup: () {},
        resumeForegroundWarmup: () {},
      );
      addTearDown(playback.dispose);
      addTearDown(timer.dispose);
      addTearDown(notifications.dispose);
      addTearDown(settings.dispose);

      final session = PlaybackSession(
        id: 'session-a',
        currentTrackPath: 'track.mp3',
        loopMode: SessionLoopMode.folderSequential,
        nonSingleLoopMode: SessionLoopMode.folderSequential,
        volume: 1,
        createdAt: DateTime(2026),
        state: PlayerState(false, ProcessingState.ready),
      )..loadedPath = 'track.mp3';
      playback.registerSession(session);

      coordinator.sync();
      await Future<void>.delayed(Duration.zero);

      expect(settings.keepCpuAwake, isTrue);
      expect(timer.keepAliveHasPlayback, isTrue);
      expect(power.calls.single.enabled, isTrue);
      expect(power.calls.single.hasActivePlayback, isTrue);

      playback.service.sessions.clear();
      coordinator.sync();
      await Future<void>.delayed(Duration.zero);

      expect(settings.keepCpuAwake, isFalse);
      expect(timer.keepAliveHasPlayback, isFalse);
      expect(power.calls.last.enabled, isFalse);
    },
  );
}

final class _RecordingPowerPlatformService extends PowerPlatformService {
  _RecordingPowerPlatformService() : super(isAndroidOverride: false);

  final List<_KeepAliveCall> calls = <_KeepAliveCall>[];

  @override
  Future<void> setKeepCpuAwake({
    required bool enabled,
    required bool hasActivePlayback,
    required bool hasActiveTimer,
    required bool usesUnifiedPlaybackNotifications,
    required bool keepForegroundServiceAlive,
  }) async {
    calls.add(
      _KeepAliveCall(enabled: enabled, hasActivePlayback: hasActivePlayback),
    );
  }
}

final class _KeepAliveCall {
  const _KeepAliveCall({
    required this.enabled,
    required this.hasActivePlayback,
  });

  final bool enabled;
  final bool hasActivePlayback;
}
