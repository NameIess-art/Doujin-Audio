import 'dart:async';
import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/features/library/application/cover_image_cache_policy.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/core/errors/native_result.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/settings/application/settings_command_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      );
      final session =
          PlaybackSession(
              id: 'session-1',
              currentTrackPath: '/audio/01.mp3',
              loopMode: SessionLoopMode.folderSequential,
              nonSingleLoopMode: SessionLoopMode.folderSequential,
              volume: 1,
              createdAt: DateTime(2026),
              state: const PlayerState(false, ProcessingState.ready),
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

  test(
    'deleting a custom EQ preset resets every referencing session',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preset = EqPreset(
        id: 'custom_shared',
        labelKey: 'Shared preset',
        bandLevels: const <int, double>{60: 2.5},
      );
      final settings = SettingsRepository()
        ..customEqPresets = <EqPreset>[preset]
        ..syncSlice(isInitialized: true);
      final playback = PlaybackFacade.create(
        databaseRepository: TestPersistenceRepository(),
        nativeRepository: _AudioEffectsRepository(),
      )..configurePersistence(enabled: false);
      final notifications = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      final controller = SettingsCommandController(
        settings: settings,
        playback: playback,
      );
      addTearDown(settings.dispose);
      addTearDown(playback.dispose);
      addTearDown(notifications.dispose);

      final sessions = <PlaybackSession>[
        _sessionUsingPreset('session-1', preset),
        _sessionUsingPreset('session-2', preset),
      ];
      for (final session in sessions) {
        addTearDown(session.shutdown);
        playback.registerSession(session);
      }

      await controller.deleteCustomEqPreset(preset.id);

      expect(settings.customEqPresets, isEmpty);
      for (final session in sessions) {
        expect(session.audioEffects.eqPresetId, builtInEqPresets.first.id);
      }
    },
  );

  test(
    'custom EQ preset is preserved when a referencing session cannot reset',
    () async {
      SharedPreferences.setMockInitialValues(const <String, Object>{});
      final preset = EqPreset(
        id: 'custom_in_use',
        labelKey: 'In-use preset',
        bandLevels: const <int, double>{60: 2.5},
      );
      final settings = SettingsRepository()
        ..customEqPresets = <EqPreset>[preset]
        ..syncSlice(isInitialized: true);
      final playback = PlaybackFacade.create(
        databaseRepository: TestPersistenceRepository(),
        nativeRepository: _AudioEffectsRepository(fail: true),
      )..configurePersistence(enabled: false);
      final notifications = NotificationFacade.create(
        service: PlaybackNotificationService(),
      );
      final controller = SettingsCommandController(
        settings: settings,
        playback: playback,
      );
      final session = _sessionUsingPreset('session-1', preset);
      playback.registerSession(session);
      addTearDown(session.shutdown);
      addTearDown(settings.dispose);
      addTearDown(playback.dispose);
      addTearDown(notifications.dispose);

      await controller.deleteCustomEqPreset(preset.id);

      expect(settings.customEqPresets, <EqPreset>[preset]);
      expect(session.audioEffects.eqPresetId, preset.id);
    },
  );

  test('failed EQ persistence never sends a native reset', () async {
    SharedPreferences.setMockInitialValues({});
    final preset = EqPreset(
      id: 'custom',
      labelKey: 'Custom',
      bandLevels: {60: 1},
    );
    final settings = _FailingSettingsRepository()
      ..customEqPresets = [preset]
      ..syncSlice(isInitialized: true);
    final native = _AudioEffectsRepository();
    final playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final session = _sessionUsingPreset('session', preset);
    playback.registerSession(session);
    addTearDown(settings.dispose);
    addTearDown(playback.dispose);
    addTearDown(session.shutdown);
    final controller = SettingsCommandController(
      settings: settings,
      playback: playback,
    );
    final calls = native.calls;
    await expectLater(
      controller.deleteCustomEqPreset(preset.id),
      throwsStateError,
    );
    expect(native.calls, calls);
    expect(settings.customEqPresets, [preset]);
    expect(session.audioEffects.eqPresetId, preset.id);
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
    );
    addTearDown(settings.dispose);
    addTearDown(playback.dispose);
    addTearDown(notifications.dispose);

    await controller.setAudioFocusStrategy(AudioFocusStrategy.mixWithOthers);

    expect(settings.audioFocusStrategy, AudioFocusStrategy.mixWithOthers);
    expect(native.requestAudioFocus, isFalse);
  });

  test(
    'queued focus change back to the original value is saved and applied',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsRepository()..syncSlice(isInitialized: true);
      final native = _CapturingPlaybackBehaviorRepository();
      final playback = PlaybackFacade.create(
        databaseRepository: TestPersistenceRepository(),
        nativeRepository: native,
      );
      addTearDown(settings.dispose);
      addTearDown(playback.dispose);
      final controller = SettingsCommandController(
        settings: settings,
        playback: playback,
      );

      final first = controller.setAudioFocusStrategy(
        AudioFocusStrategy.mixWithOthers,
      );
      final second = controller.setAudioFocusStrategy(
        AudioFocusStrategy.standard,
      );
      await Future.wait([first, second]);

      expect(native.focusHistory, [false, true]);
      expect(settings.audioFocusStrategy, AudioFocusStrategy.standard);
      final saved =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  'playback_settings_v1',
                )!,
              )
              as Map;
      expect(saved['audioFocusStrategy'], AudioFocusStrategy.standard.name);
    },
  );

  test(
    'native feedback completes before the next setting can be saved',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = _SequencedSettingsRepository(failSave: 2)
        ..syncSlice(isInitialized: true);
      final native = _CapturingPlaybackBehaviorRepository()
        ..firstCallGate = Completer<void>();
      final playback = PlaybackFacade.create(
        databaseRepository: TestPersistenceRepository(),
        nativeRepository: native,
      );
      addTearDown(settings.dispose);
      addTearDown(playback.dispose);
      final controller = SettingsCommandController(
        settings: settings,
        playback: playback,
      );
      final first = controller.setAudioFocusStrategy(
        AudioFocusStrategy.mixWithOthers,
      );
      await native.firstCallStarted.future;
      final second = controller.setAudioFocusStrategy(
        AudioFocusStrategy.standard,
      );
      final failed = expectLater(second, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(settings.saves, 1);
      expect(native.focusHistory, [false]);
      native.firstCallGate!.complete();
      await first;
      await failed;
      expect(native.focusHistory, [false]);
      expect(
        settings.slice.state.audioFocusStrategy,
        AudioFocusStrategy.mixWithOthers,
      );
    },
  );

  test('failed cover save leaves image cache policy unchanged', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = _FailingSettingsRepository()
      ..syncSlice(isInitialized: true);
    final playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
    );
    addTearDown(settings.dispose);
    addTearDown(playback.dispose);
    final cache = PaintingBinding.instance.imageCache;
    final previousSize = cache.maximumSize;
    final previousBytes = cache.maximumSizeBytes;
    addTearDown(() {
      cache.maximumSize = previousSize;
      cache.maximumSizeBytes = previousBytes;
    });
    applyCoverImageCachePolicy(CoverImageResolution.balanced);
    final size = cache.maximumSize;
    final bytes = cache.maximumSizeBytes;
    final controller = SettingsCommandController(
      settings: settings,
      playback: playback,
    );
    await expectLater(
      controller.setCoverImageResolution(CoverImageResolution.original),
      throwsStateError,
    );
    expect(settings.coverImageResolution, CoverImageResolution.balanced);
    expect(cache.maximumSize, size);
    expect(cache.maximumSizeBytes, bytes);
  });

  test('post-save feedback failure preserves the committed setting', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsRepository()..syncSlice(isInitialized: true);
    addTearDown(settings.dispose);
    await expectLater(
      settings.setCoverImageResolution(
        CoverImageResolution.original,
        afterSave: () async => throw StateError('runtime_feedback_failed'),
      ),
      throwsStateError,
    );
    expect(
      settings.slice.state.coverImageResolution,
      CoverImageResolution.original,
    );
    final saved =
        jsonDecode(
              (await SharedPreferences.getInstance()).getString(
                'playback_settings_v1',
              )!,
            )
            as Map;
    expect(saved['coverImageResolution'], CoverImageResolution.original.name);
  });

  test('application cache clearing is coordinated by the controller', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final settings = SettingsRepository()..syncSlice(isInitialized: true);
    final playback = PlaybackFacade.create(
      databaseRepository: TestPersistenceRepository(),
    );
    final notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    var clears = 0;
    final controller = SettingsCommandController(
      settings: settings,
      playback: playback,
      clearApplicationCacheFiles: () async {
        clears++;
        return 17;
      },
    );
    addTearDown(settings.dispose);
    addTearDown(playback.dispose);
    addTearDown(notifications.dispose);

    expect(await controller.clearApplicationCache(), 17);
    expect(clears, 1);
  });
}

final class _CapturingPlaybackBehaviorRepository
    extends NativePlaybackRepository {
  bool? requestAudioFocus;
  final List<bool> focusHistory = [];
  final firstCallStarted = Completer<void>();
  Completer<void>? firstCallGate;

  @override
  Future<NativeResult<void>> setPlaybackBehavior({
    required bool pauseOnAudioDeviceDisconnect,
    required bool requestAudioFocus,
    required bool pauseOnTransientAudioFocusLoss,
    required bool resumeAfterTransientAudioFocusGain,
  }) async {
    this.requestAudioFocus = requestAudioFocus;
    focusHistory.add(requestAudioFocus);
    if (focusHistory.length == 1) {
      firstCallStarted.complete();
      await firstCallGate?.future;
    }
    return const NativeSuccess<void>();
  }

  @override
  Future<void> dispose() async {}
}

PlaybackSession _sessionUsingPreset(String id, EqPreset preset) {
  final path = '/audio/$id.mp3';
  return PlaybackSession(
      id: id,
      currentTrackPath: path,
      loopMode: SessionLoopMode.folderSequential,
      nonSingleLoopMode: SessionLoopMode.folderSequential,
      volume: 1,
      createdAt: DateTime(2026),
      state: const PlayerState(false, ProcessingState.ready),
    )
    ..loadedPath = path
    ..audioEffects = AudioEffectsState(
      eqEnabled: true,
      eqPresetId: preset.id,
      eqBandLevels: preset.bandLevels,
    );
}

final class _AudioEffectsRepository extends NativePlaybackRepository {
  _AudioEffectsRepository({this.fail = false});

  final bool fail;
  int calls = 0;

  @override
  Future<NativeResult<NativePlaybackSnapshot>> setAudioEffects(
    String sessionId,
    NativeAudioEffects effects,
  ) async {
    calls++;
    if (fail) {
      return const NativeFailure<NativePlaybackSnapshot>('effects failed');
    }
    return const NativeSuccess<NativePlaybackSnapshot>();
  }

  @override
  Future<void> dispose() async {}
}

class _FailingSettingsRepository extends SettingsRepository {
  @override
  Future<void> persist() async => throw StateError('settings_write_failed');
}

class _SequencedSettingsRepository extends SettingsRepository {
  _SequencedSettingsRepository({required this.failSave});
  final int failSave;
  int saves = 0;

  @override
  Future<void> persist() async {
    if (++saves == failSave) throw StateError('settings_write_failed');
    await super.persist();
  }
}
