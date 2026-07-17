import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/app_persistence_coordinator.dart';
import 'package:nameless_audio/app/application/audio_path_coordinator.dart';
import 'package:nameless_audio/app/application/audio_ui_warmup_coordinator.dart';
import 'package:nameless_audio/app/application/playback_command_coordinator.dart';
import 'package:nameless_audio/app/application/playback_keep_alive_coordinator.dart';
import 'package:nameless_audio/core/errors/native_result.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/playback_subtitle_service.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('loads owners and resets them in backup restore order', () async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    await AppDatabase.createSchemaForTest(database);
    final repository = AudioDatabaseRepository(
      database: AppDatabase.test(database),
    );
    final library = LibraryFacade.create(databaseRepository: repository);
    final native = _FakeNativePlaybackRepository();
    final playback = PlaybackFacade.create(
      databaseRepository: repository,
      nativeRepository: native,
    )..configurePersistence(enabled: false);
    final timer = TimerFacade.create();
    final notifications = NotificationFacade.create(
      service: PlaybackNotificationService(),
    );
    final settings = SettingsRepository();
    final paths = AudioPathCoordinator(library: library, playback: playback);
    late final PlaybackSubtitleService subtitles;
    subtitles = PlaybackSubtitleService(
      trackResolver: library.trackByPath,
      onTrackLoaded: notifications.handleSubtitleTrackLoaded,
    );
    final warmup = AudioUiWarmupCoordinator(
      library: library,
      playback: playback,
      notifications: notifications,
      subtitles: subtitles,
    );
    final keepAlive = PlaybackKeepAliveCoordinator(
      playback: playback,
      settings: settings,
      enterBackgroundWarmup: warmup.enterBackground,
      resumeForegroundWarmup: warmup.resumeForeground,
    );
    final commands = PlaybackCommandCoordinator(
      library: library,
      playback: playback,
      timer: timer,
      notifications: notifications,
      settings: settings,
      audioPaths: paths,
      subtitles: subtitles,
      keepAlive: keepAlive,
      notifyPlaybackChanged: () {},
      syncNotificationState: notifications.syncPlaybackState,
    );
    library.attachCoverArtworkCacheService(
      () => CoverArtworkCacheService(
        libraryService: library.service,
        databaseRepository: repository,
        audioDetailCacheService: library.detailCacheService,
        isActiveCoverKey: notifications.isActiveCoverKey,
        onActiveCoverChanged: () {},
      ),
    );
    notifications.attachActions(
      playback: playback,
      resolveSession: notifications.resolveNotificationSession,
      resolveActionSession: () => notifications.notificationActionSession,
      resumeSession: (session) =>
          commands.startSession(session, shouldStartTriggerCountdown: false),
      multiThreadPlaybackEnabled: () => settings.multiThreadPlaybackEnabled,
      setFocusSessionId: (sessionId) {
        notifications.stateService.notificationFocusSessionId = sessionId;
      },
      notify: () {},
      syncKeepAlive: keepAlive.sync,
      hasPlaybackToKeepAlive: () => false,
      clearUnifiedNotifications:
          notifications.clearUnifiedNotificationsOnPlatform,
      preferredSessionId: () => commands.preferredSingleSessionId,
      notifyNotificationChanged: () {},
    );
    notifications.attachSynchronization(
      playbackCommands: commands,
      subtitles: subtitles,
      trackByPath: library.trackByPath,
      coverArtworkCacheService: library.coverArtworkCacheService,
      notificationsEnabled: () => settings.notificationsEnabled,
    );
    final coordinator = AppPersistenceCoordinator(
      library: library,
      playback: playback,
      settings: settings,
      timer: timer,
      notifications: notifications,
      playbackCommands: commands,
      keepAlive: keepAlive,
      uiWarmup: warmup,
      subtitles: subtitles,
    );
    addTearDown(() async {
      coordinator.dispose();
      await warmup.shutdown();
      await playback.dispose();
      await library.dispose();
      await timer.dispose();
      await notifications.dispose();
      await settings.dispose();
      await database.close();
    });

    await coordinator.loadPersistedState();

    expect(settings.slice.state.isInitialized, isTrue);
    expect(library.state.isInitialized, isTrue);
    expect(playback.state.isInitialized, isTrue);
    expect(timer.state.isInitialized, isTrue);

    await coordinator.reloadPersistedState();

    expect(native.clearAllCount, 1);
    expect(settings.slice.state.isInitialized, isTrue);
    expect(library.state.isInitialized, isTrue);
    expect(playback.state.isInitialized, isTrue);
  });
}

final class _FakeNativePlaybackRepository extends NativePlaybackRepository {
  int clearAllCount = 0;

  @override
  Future<NativeResult<void>> clearAll() async {
    clearAllCount++;
    return const NativeSuccess<void>();
  }

  @override
  Future<void> dispose() async {}
}
