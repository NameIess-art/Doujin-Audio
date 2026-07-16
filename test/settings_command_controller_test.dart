import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_session.dart';
import 'package:nameless_audio/features/player/domain/audio_effects.dart';
import 'package:nameless_audio/features/player/domain/playback_mode.dart';
import 'package:nameless_audio/features/settings/application/settings_command_controller.dart';

void main() {
  test(
    'custom EQ preset is published and persisted by settings owner',
    () async {
      final settings = SettingsRepository()..syncSlice(isInitialized: true);
      final playback = PlaybackFacade.create(
        databaseRepository: AudioDatabaseRepository(),
      );
      final notifications = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      addTearDown(settings.dispose);
      addTearDown(playback.dispose);
      addTearDown(notifications.dispose);
      var persistCount = 0;
      settings.attachPersistence(() async => persistCount++);
      final controller = SettingsCommandController(
        settings: settings,
        playback: playback,
        notifications: notifications,
      );
      final session =
          PlaybackSession(
              id: 'session-1',
              currentTrackPath: '/audio/01.mp3',
              loopMode: SessionLoopMode.folderSequential,
              nonSingleLoopMode: SessionLoopMode.folderSequential,
              volume: 1,
              createdAt: DateTime(2026),
              state: PlayerState(false, ProcessingState.ready),
            )
            ..audioEffects = const AudioEffectsState(
              eqEnabled: true,
              eqBandLevels: <int, double>{60: 2.5, 1000: -1.5},
            );
      addTearDown(session.dispose);

      await controller.saveCustomEqPreset(
        '  Night voice  ',
        session,
        now: DateTime.fromMicrosecondsSinceEpoch(42),
      );

      expect(settings.customEqPresets, hasLength(1));
      expect(
        settings.customEqPresets.single,
        const EqPreset(
          id: 'custom_42',
          labelKey: 'Night voice',
          bandLevels: <int, double>{60: 2.5, 1000: -1.5},
        ),
      );
      expect(settings.slice.state.customEqPresets, settings.customEqPresets);
      expect(persistCount, 1);
    },
  );
}
