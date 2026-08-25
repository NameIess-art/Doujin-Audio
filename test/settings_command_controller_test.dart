import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/settings/application/settings_command_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'custom EQ preset is published and persisted by settings owner',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final settings = SettingsRepository()..syncSlice(isInitialized: true);
      final playback = PlaybackFacade.create(
        databaseRepository: TestPersistenceRepository(),
      );
      final notifications = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      addTearDown(settings.dispose);
      addTearDown(playback.dispose);
      addTearDown(notifications.dispose);
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
            ..audioEffects = AudioEffectsState(
              eqEnabled: true,
              eqBandLevels: <int, double>{60: 2.5, 1000: -1.5},
            );
      addTearDown(session.shutdown);
      playback.registerSession(session);

      await controller.saveCustomEqPreset(
        '  Night voice  ',
        session.id,
        now: DateTime.fromMicrosecondsSinceEpoch(42),
      );

      expect(settings.customEqPresets, hasLength(1));
      expect(
        settings.customEqPresets.single,
        EqPreset(
          id: 'custom_42',
          labelKey: 'Night voice',
          bandLevels: <int, double>{60: 2.5, 1000: -1.5},
        ),
      );
      expect(settings.slice.state.customEqPresets, settings.customEqPresets);
      final saved =
          json.decode(
                (await SharedPreferences.getInstance()).getString(
                  'playback_settings_v1',
                )!,
              )
              as Map<String, dynamic>;
      expect((saved['customEqPresets'] as List<dynamic>), hasLength(1));
    },
  );

  test('multi-thread setting is unchanged when pause all fails', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsRepository()..syncSlice(isInitialized: true);
    await settings.setMultiThreadPlaybackEnabled(true);
    final playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
      nativeRepository: _FailingPauseAllRepository(),
    );
    final notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    final controller = SettingsCommandController(
      settings: settings,
      playback: playback,
      notifications: notifications,
    );
    addTearDown(settings.dispose);
    addTearDown(playback.dispose);
    addTearDown(notifications.dispose);

    final updated = await controller.setMultiThreadPlaybackEnabled(false);

    expect(updated, isFalse);
    expect(settings.multiThreadPlaybackEnabled, isTrue);
  });

  test('mixing strategy disables native audio focus requests', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsRepository()..syncSlice(isInitialized: true);
    final native = _CapturingPlaybackBehaviorRepository();
    final playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
      nativeRepository: native,
    );
    final notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    final controller = SettingsCommandController(
      settings: settings,
      playback: playback,
      notifications: notifications,
    );
    addTearDown(settings.dispose);
    addTearDown(playback.dispose);
    addTearDown(notifications.dispose);

    await controller.setAudioFocusStrategy(AudioFocusStrategy.mixWithOthers);

    expect(settings.audioFocusStrategy, AudioFocusStrategy.mixWithOthers);
    expect(native.requestAudioFocus, isFalse);
  });
}

final class _FailingPauseAllRepository extends NativePlaybackRepository {
  @override
  Future<NativeResult<void>> pauseAll() async {
    return const NativeFailure<void>('pause all failed');
  }

  @override
  Future<void> dispose() async {}
}

final class _CapturingPlaybackBehaviorRepository
    extends NativePlaybackRepository {
  bool? requestAudioFocus;

  @override
  Future<NativeResult<void>> setPlaybackBehavior({
    required bool pauseOnAudioDeviceDisconnect,
    required bool requestAudioFocus,
    required bool pauseOnTransientAudioFocusLoss,
    required bool resumeAfterTransientAudioFocusGain,
    required bool resumePlaybackOnStartupRestore,
  }) async {
    this.requestAudioFocus = requestAudioFocus;
    return const NativeSuccess<void>();
  }

  @override
  Future<void> dispose() async {}
}
