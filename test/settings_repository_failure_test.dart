import 'dart:async';
import 'dart:convert';

import 'package:doujin_audio/core/network/network_route_settings.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';
import 'package:doujin_audio/core/ui/app_interaction_feedback_settings.dart';
import 'package:doujin_audio/features/player/domain/audio_effects.dart';
import 'package:doujin_audio/features/settings/application/permission_status_service.dart';
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

  for (final (storedMode, expected) in [
    ('my', StartupPage.my),
    ('settings', StartupPage.settings),
    (null, StartupPage.my),
  ]) {
    test('legacy startup mode $storedMode resolves to $expected', () async {
      await AppPreferences.writeJson('playback_settings_v1', {
        'mySettingsPageMode': ?storedMode,
        'startupPage': 'my',
      });
      await settings.loadPersistedState(enforceCacheLimit: false);
      expect(settings.slice.state.startupPage, expected);
      expect(settings.slice.state.showMyPage, isTrue);

      await settings.setAllowVideoPlayback(false);
      expect(preferences.writes.last['startupPage'], expected.name);
      expect(preferences.writes.last, isNot(contains('mySettingsPageMode')));

      final restarted = SettingsRepository();
      addTearDown(restarted.dispose);
      await restarted.loadPersistedState(enforceCacheLimit: false);
      expect(restarted.slice.state.startupPage, expected);
    });
  }

  test(
    'My page visibility and startup fallback persist across restart',
    () async {
      await settings.setStartupPage(StartupPage.my);
      await settings.setShowMyPage(false);
      await settings.setStartupPage(StartupPage.my);
      expect(settings.slice.state.showMyPage, isFalse);
      expect(settings.slice.state.startupPage, StartupPage.playlist);
      expect(preferences.writes.last['showMyPage'], isFalse);
      expect(preferences.writes.last['startupPage'], 'playlist');

      final restarted = SettingsRepository();
      addTearDown(restarted.dispose);
      await restarted.loadPersistedState(enforceCacheLimit: false);
      expect(restarted.slice.state.showMyPage, isFalse);
      expect(restarted.slice.state.startupPage, StartupPage.playlist);
      await restarted.resetPersistedState();
      expect(restarted.slice.state.showMyPage, isTrue);
    },
  );

  test(
    'failed My page visibility change keeps the original startup page',
    () async {
      await settings.setStartupPage(StartupPage.my);
      preferences.beforeSave = () async => false;
      await expectLater(settings.setShowMyPage(false), throwsStateError);
      expect(settings.showMyPage, isTrue);
      expect(settings.startupPage, StartupPage.my);
    },
  );

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

  test(
    'loadPersistedPresentationStateSync hydrates slice synchronously without reading secure storage',
    () async {
      await AppPreferences.writeJson('playback_settings_v1', {
        'startupPage': 'settings',
        'showLocalLibrary': false,
        'showAsmrOne': true,
        'showMyPage': false,
        'reduceAnimations': true,
        'workNameDisplay': 'folderName',
        'networkRouteSettings': {
          'proxyMode': 'http',
          'proxyHost': '127.0.0.1',
          'proxyPort': 8080,
          'proxyAuthenticationEnabled': true,
          'proxyUsername': 'alice',
          'proxyPasswordConfigured': true,
        },
      });
      await AppPreferences.init();
      var proxyPasswordReads = 0;
      var routeNotifications = 0;
      final repo = SettingsRepository(
        readProxyPassword: () async {
          proxyPasswordReads++;
          return 'secret';
        },
        onNetworkRouteChanged: (_, _) async {
          routeNotifications++;
        },
      );
      addTearDown(repo.dispose);

      expect(repo.loadPersistedPresentationStateSync(), isTrue);
      expect(repo.slice.state.isInitialized, isTrue);
      expect(repo.slice.state.startupPage, StartupPage.settings);
      expect(repo.slice.state.showLocalLibrary, isFalse);
      expect(repo.slice.state.showMyPage, isFalse);
      expect(repo.slice.state.reduceAnimations, isTrue);
      expect(repo.slice.state.workNameDisplay, WorkNameDisplay.folderName);
      expect(proxyPasswordReads, 0);
      expect(routeNotifications, 0);

      await repo.loadPersistedState(enforceCacheLimit: false);
      expect(proxyPasswordReads, 1);
      expect(routeNotifications, 1);
    },
  );

  test(
    'disabling proxy authentication deletes stored proxy password and rolls back on failure',
    () async {
      String? secret;
      final applied = <(NetworkRouteSettings, String?)>[];
      final repo = SettingsRepository(
        readProxyPassword: () async => secret,
        writeProxyPassword: (value) async => secret = value,
        onNetworkRouteChanged: (route, password) async =>
            applied.add((route, password)),
      );
      addTearDown(repo.dispose);
      const authRoute = NetworkRouteSettings(
        proxyMode: AppProxyMode.http,
        proxyHost: '127.0.0.1',
        proxyPort: 8080,
        proxyAuthenticationEnabled: true,
        proxyUsername: 'alice',
      );
      await repo.setNetworkRouteSettings(authRoute, password: 'top-secret');
      expect(secret, 'top-secret');
      expect(repo.networkRouteSettings.proxyPasswordConfigured, isTrue);

      // Failed persistence while disabling auth must restore the secret.
      preferences.beforeSave = () async => false;
      await expectLater(
        repo.setNetworkRouteSettings(
          authRoute.copyWith(proxyAuthenticationEnabled: false),
        ),
        throwsStateError,
      );
      expect(secret, 'top-secret');
      expect(repo.networkRouteSettings.proxyAuthenticationEnabled, isTrue);
      expect(repo.networkRouteSettings.proxyPasswordConfigured, isTrue);

      // Succeeding persistence clears the secret and marks password unconfigured.
      preferences.beforeSave = null;
      await repo.setNetworkRouteSettings(
        authRoute.copyWith(proxyAuthenticationEnabled: false),
      );
      expect(secret, isNull);
      expect(repo.networkRouteSettings.proxyAuthenticationEnabled, isFalse);
      expect(repo.networkRouteSettings.proxyPasswordConfigured, isFalse);
      expect(applied.last.$2, isNull);
    },
  );

  test(
    'loadPersistedPresentationStateSync refuses to race with an active write queue',
    () async {
      await AppPreferences.init();
      final gate = Completer<bool>();
      preferences.beforeSave = () => gate.future;
      final write = settings.setAllowVideoPlayback(false);
      await Future<void>.delayed(Duration.zero);

      expect(settings.loadPersistedPresentationStateSync(), isFalse);
      expect(settings.allowVideoPlayback, isFalse);

      gate.complete(true);
      await write;
      expect(settings.slice.state.allowVideoPlayback, isFalse);
      expect(settings.loadPersistedPresentationStateSync(), isTrue);
      expect(settings.slice.state.allowVideoPlayback, isFalse);
    },
  );

  test(
    'PermissionStatusService guards Android-only power actions and disposes cleanly',
    () async {
      final power = _TrackingPowerPlatformService();
      final service = PermissionStatusService(
        isAndroidOverride: false,
        powerService: power,
      );

      expect(await service.loadBackgroundRunDiagnostics(), isNull);
      expect(await service.openBatteryOptimizationSettings(), isFalse);
      expect(power.diagnosticsCalls, 0);
      expect(power.batterySettingsCalls, 0);
      await service.dispose();
    },
  );
}

final class _TrackingPowerPlatformService extends PowerPlatformService {
  _TrackingPowerPlatformService() : super(isAndroidOverride: true);

  int diagnosticsCalls = 0;
  int batterySettingsCalls = 0;

  @override
  Future<BackgroundRunDiagnostics?> getBackgroundRunDiagnostics() async {
    diagnosticsCalls++;
    return null;
  }

  @override
  Future<bool> openBatteryOptimizationSettings() async {
    batterySettingsCalls++;
    return true;
  }
}
