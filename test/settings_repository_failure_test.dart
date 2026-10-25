import 'dart:async';
import 'dart:convert';

import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/ui/app_interaction_feedback_settings.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();

  Future<bool> Function()? beforeSave;
  final writes = <Map<String, dynamic>>[];

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(jsonDecode(value as String) as Map<String, dynamic>);
    if (beforeSave != null && !await beforeSave!()) return false;
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Preferences preferences;
  late SettingsRepository settings;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    preferences = _Preferences();
    SharedPreferencesStorePlatform.instance = preferences;
    settings = SettingsRepository()..syncSlice(isInitialized: true);
    AppInteractionFeedbackSettings.hapticFeedbackEnabled = true;
  });
  tearDown(() async {
    await settings.dispose();
    SharedPreferences.setMockInitialValues({});
    AppInteractionFeedbackSettings.hapticFeedbackEnabled = true;
  });

  test('flush waits for submitted writes but not later changes', () async {
    final firstGate = Completer<bool>();
    final laterGate = Completer<bool>();
    preferences.beforeSave = () =>
        preferences.writes.length == 1 ? firstGate.future : laterGate.future;
    final first = settings.setAllowVideoPlayback(false);
    final flushing = settings.flushPendingWrites();
    final later = settings.setShowLocalLibrary(false);
    firstGate.complete(true);
    await flushing;
    expect(settings.slice.state.allowVideoPlayback, isFalse);
    expect(settings.slice.state.showLocalLibrary, isTrue);
    laterGate.complete(true);
    await Future.wait([first, later]);
  });

  test(
    'flush reports a queued failure even when the next write succeeds',
    () async {
      final gate = Completer<bool>();
      preferences.beforeSave = () =>
          preferences.writes.length == 1 ? gate.future : Future.value(true);
      final failed = settings.setAllowVideoPlayback(false);
      final failure = expectLater(failed, throwsStateError);
      final succeeding = settings.setShowLocalLibrary(false);
      final flushing = expectLater(
        settings.flushPendingWrites(),
        throwsStateError,
      );
      gate.complete(false);
      await Future.wait([failure, succeeding, flushing]);
      expect(settings.allowVideoPlayback, isTrue);
      expect(settings.showLocalLibrary, isFalse);
      await settings.flushPendingWrites();
    },
  );

  test('merged page mode is persisted and restored on restart', () async {
    expect(
      settings.slice.state.mySettingsPageMode,
      MySettingsPageMode.settings,
    );
    expect(settings.startupPage, StartupPage.library);
    await settings.setMySettingsPageMode(MySettingsPageMode.my);
    expect(settings.slice.state.mySettingsPageMode, MySettingsPageMode.my);
    expect(preferences.writes.single['mySettingsPageMode'], 'my');

    final restarted = SettingsRepository();
    addTearDown(restarted.dispose);
    await restarted.loadPersistedState(enforceCacheLimit: false);
    expect(restarted.slice.state.mySettingsPageMode, MySettingsPageMode.my);
    expect(restarted.slice.state.isInitialized, isTrue);
    await restarted.setMySettingsPageMode(MySettingsPageMode.my);
    expect(preferences.writes, hasLength(1));
  });

  for (final stored in <Object?>[null, 'unknown', 2]) {
    test(
      'legacy or unknown merged page mode $stored defaults to settings',
      () async {
        await AppPreferences.writeJson('playback_settings_v1', {
          'mySettingsPageMode': ?stored,
          'startupPage': 'my',
        });
        settings.mySettingsPageMode = MySettingsPageMode.my;
        await settings.loadPersistedState(enforceCacheLimit: false);
        expect(settings.mySettingsPageMode, MySettingsPageMode.settings);
        expect(
          settings.slice.state.mySettingsPageMode,
          MySettingsPageMode.settings,
        );
        expect(settings.startupPage, StartupPage.my);
      },
    );
  }

  test(
    'merged page mode follows preference backup restore and reset',
    () async {
      await settings.setMySettingsPageMode(MySettingsPageMode.my);
      final backup = await AppPreferences.snapshot();
      await settings.setMySettingsPageMode(MySettingsPageMode.settings);
      await AppPreferences.replaceSnapshot(backup);
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(settings.slice.state.mySettingsPageMode, MySettingsPageMode.my);

      await settings.resetPersistedState();
      expect(settings.mySettingsPageMode, MySettingsPageMode.settings);
      expect(
        settings.slice.state.mySettingsPageMode,
        MySettingsPageMode.settings,
      );
      await AppPreferences.replaceSnapshot({});
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(
        settings.slice.state.mySettingsPageMode,
        MySettingsPageMode.settings,
      );
    },
  );

  test(
    'failed merged page mode save retains the last committed mode',
    () async {
      await settings.setMySettingsPageMode(MySettingsPageMode.my);
      final original = settings.slice.state;
      preferences.beforeSave = () async => false;
      await expectLater(
        settings.setMySettingsPageMode(MySettingsPageMode.settings),
        throwsStateError,
      );
      expect(settings.mySettingsPageMode, MySettingsPageMode.my);
      expect(settings.slice.state, original);
      preferences.beforeSave = null;
      await settings.setAllowVideoPlayback(false);
      expect(preferences.writes.last['mySettingsPageMode'], 'my');
    },
  );

  test('merged page mode changes publish only after serial saves', () async {
    final blocked = Completer<bool>();
    preferences.beforeSave = () => preferences.writes.length == 1
        ? blocked.future
        : Future<bool>.value(true);
    final first = settings.setMySettingsPageMode(MySettingsPageMode.my);
    final second = settings.setMySettingsPageMode(MySettingsPageMode.settings);
    final last = settings.setMySettingsPageMode(MySettingsPageMode.my);
    await Future<void>.delayed(Duration.zero);
    expect(preferences.writes, hasLength(1));
    expect(
      settings.slice.state.mySettingsPageMode,
      MySettingsPageMode.settings,
    );
    blocked.complete(true);
    await Future.wait([first, second, last]);
    expect(preferences.writes.map((write) => write['mySettingsPageMode']), [
      'my',
      'settings',
      'my',
    ]);
    expect(settings.slice.state.mySettingsPageMode, MySettingsPageMode.my);
  });

  test('listening chart style is persisted and restored on restart', () async {
    expect(settings.slice.state.listeningChartStyle, ListeningChartStyle.bar);
    await settings.setListeningChartStyle(ListeningChartStyle.heatmap);
    expect(
      settings.slice.state.listeningChartStyle,
      ListeningChartStyle.heatmap,
    );
    expect(preferences.writes.single['listeningChartStyle'], 'heatmap');

    final restarted = SettingsRepository();
    addTearDown(restarted.dispose);
    await restarted.loadPersistedState(enforceCacheLimit: false);
    expect(
      restarted.slice.state.listeningChartStyle,
      ListeningChartStyle.heatmap,
    );
    expect(restarted.slice.state.isInitialized, isTrue);
    await restarted.setListeningChartStyle(ListeningChartStyle.heatmap);
    expect(preferences.writes, hasLength(1));
  });

  for (final stored in <Object?>[null, 'unknown', 2]) {
    test('legacy or unknown chart style $stored defaults to bars', () async {
      await AppPreferences.writeJson('playback_settings_v1', {
        'listeningChartStyle': ?stored,
        'workNameDisplay': 'folderName',
      });
      settings.listeningChartStyle = ListeningChartStyle.heatmap;
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(settings.listeningChartStyle, ListeningChartStyle.bar);
      expect(settings.slice.state.listeningChartStyle, ListeningChartStyle.bar);
      expect(settings.workNameDisplay, WorkNameDisplay.folderName);
    });
  }

  test('chart style follows preference backup restore and reset', () async {
    await settings.setListeningChartStyle(ListeningChartStyle.heatmap);
    final backup = await AppPreferences.snapshot();
    await settings.setListeningChartStyle(ListeningChartStyle.bar);
    await AppPreferences.replaceSnapshot(backup);
    await settings.loadPersistedState(enforceCacheLimit: false);
    expect(
      settings.slice.state.listeningChartStyle,
      ListeningChartStyle.heatmap,
    );

    await settings.resetPersistedState();
    expect(settings.listeningChartStyle, ListeningChartStyle.bar);
    expect(settings.slice.state.listeningChartStyle, ListeningChartStyle.bar);
    await AppPreferences.replaceSnapshot({});
    await settings.loadPersistedState(enforceCacheLimit: false);
    expect(settings.slice.state.listeningChartStyle, ListeningChartStyle.bar);
  });

  test(
    'failed chart style save rolls back and later updates preserve it',
    () async {
      await settings.setListeningChartStyle(ListeningChartStyle.heatmap);
      final original = settings.slice.state;
      preferences.beforeSave = () async => false;
      await expectLater(
        settings.setListeningChartStyle(ListeningChartStyle.bar),
        throwsStateError,
      );
      expect(settings.listeningChartStyle, ListeningChartStyle.heatmap);
      expect(settings.slice.state, original);

      preferences.beforeSave = null;
      await settings.setAllowVideoPlayback(false);
      expect(preferences.writes.last['listeningChartStyle'], 'heatmap');
      final persisted = await AppPreferences.readJson(
        'playback_settings_v1',
        (value) => value as Map<String, dynamic>,
      );
      expect(persisted?['listeningChartStyle'], 'heatmap');
    },
  );

  for (final throwing in [false, true]) {
    test(
      'platform ${throwing ? 'exception' : 'false'} rejects a setting and restores published state',
      () async {
        preferences.beforeSave = () async {
          if (throwing) throw PlatformException(code: 'disk_write_failed');
          return false;
        };
        final original = settings.slice.state;
        await expectLater(
          settings.setAllowVideoPlayback(false),
          throwsStateError,
        );
        expect(settings.allowVideoPlayback, isTrue);
        expect(settings.slice.state, original);
        expect(await preferences.getAll(), isEmpty);
        preferences.beforeSave = null;
        await settings.setAllowVideoPlayback(false);
        expect(settings.slice.state.allowVideoPlayback, isFalse);
        expect(
          (await preferences.getAll()).keys,
          contains('flutter.playback_settings_v1'),
        );
      },
    );
  }

  test(
    'queued updates use the last committed state after a failed write',
    () async {
      final blocked = Completer<bool>();
      preferences.beforeSave = () => preferences.writes.length == 1
          ? blocked.future
          : Future<bool>.value(true);
      final failed = settings.setAllowVideoPlayback(false);
      final failure = expectLater(failed, throwsStateError);
      final next = settings.setRecordPlaybackProgress(false);
      await Future<void>.delayed(Duration.zero);
      expect(preferences.writes, hasLength(1));
      expect(settings.slice.state.allowVideoPlayback, isTrue);
      blocked.complete(false);
      await failure;
      await next;
      expect(settings.allowVideoPlayback, isTrue);
      expect(settings.recordPlaybackProgress, isFalse);
      expect(preferences.writes.last['allowVideoPlayback'], isTrue);
      expect(preferences.writes.last['recordPlaybackProgress'], isFalse);
      expect(settings.slice.state.isInitialized, isTrue);
    },
  );

  test('concurrent pin operations accumulate within the write queue', () async {
    final blocked = Completer<bool>();
    preferences.beforeSave = () => preferences.writes.length == 1
        ? blocked.future
        : Future<bool>.value(true);
    final first = settings.pinPlaylistSessions(['first']);
    final second = settings.pinPlaylistSessions(['second']);
    await Future<void>.delayed(Duration.zero);
    expect(preferences.writes, hasLength(1));
    blocked.complete(true);
    await Future.wait([first, second]);
    expect(settings.pinnedPlaylistSessionIds, ['first', 'second']);
    expect(preferences.writes.last['pinnedPlaylistSessionIds'], [
      'first',
      'second',
    ]);
  });

  test(
    'failed composite library visibility and sort updates rollback every field',
    () async {
      preferences.beforeSave = () async => false;
      final original = settings.slice.state;
      await expectLater(settings.setShowLocalLibrary(false), throwsStateError);
      expect(settings.showLocalLibrary, isTrue);
      expect(settings.startupPage, StartupPage.library);
      await expectLater(
        settings.setLibrarySortOptions(
          criterion: LibrarySortCriterion.duration,
          ascending: false,
          groupByLibrary: true,
        ),
        throwsStateError,
      );
      expect(settings.slice.state, original);
    },
  );

  test('failed haptic setting restores the shared feedback flag', () async {
    preferences.beforeSave = () async => false;
    await expectLater(
      settings.setHapticFeedbackEnabled(false),
      throwsStateError,
    );
    expect(settings.hapticFeedbackEnabled, isTrue);
    expect(settings.slice.state.hapticFeedbackEnabled, isTrue);
    expect(AppInteractionFeedbackSettings.hapticFeedbackEnabled, isTrue);
  });

  test(
    'EQ write failure precedes session reset and leaves the preset available',
    () async {
      final preset = EqPreset(
        id: 'custom',
        labelKey: 'Custom',
        bandLevels: {60: 1},
      );
      settings.customEqPresets = [preset];
      settings.syncSlice(isInitialized: true);
      preferences.beforeSave = () async => false;
      var resetCalls = 0;
      await expectLater(
        settings.deleteCustomEqPreset(
          preset.id,
          resetSessions: () async {
            resetCalls++;
            return true;
          },
        ),
        throwsStateError,
      );
      expect(resetCalls, 0);
      expect(settings.customEqPresets, [preset]);
      expect(settings.slice.state.customEqPresets, [preset]);
    },
  );
}
