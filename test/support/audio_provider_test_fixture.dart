import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/app/state/audio_provider_riverpod.dart';
import 'package:nameless_audio/app/theme/theme_provider.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/playback_command_runner.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fileCacheChannel = MethodChannel(FileCacheChannel.name);
const nativePlaybackChannel = MethodChannel(NativePlaybackChannel.name);
const notificationsChannel = MethodChannel(NotificationsChannel.name);

MusicTrack testMusicTrack({
  required String name,
  required String path,
  required String groupKey,
  required String groupTitle,
  bool isSingle = false,
}) {
  return MusicTrack(
    path: path,
    displayName: name,
    groupKey: groupKey,
    groupTitle: groupTitle,
    groupSubtitle: groupKey,
    isSingle: isSingle,
  );
}

Future<void> pumpUntilNotFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ticks = timeout.inMilliseconds ~/ 50;
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for $finder to disappear');
}

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final ticks = timeout.inMilliseconds ~/ 50;
  for (var i = 0; i < ticks; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for $finder to appear');
}

Future<void> pumpUntilLibraryTreeReady(
  WidgetTester tester,
  AudioProvider audioProvider, {
  Duration timeout = const Duration(seconds: 10),
  bool waitForCategorySnapshot = false,
}) async {
  final ticks = timeout.inMilliseconds ~/ 50;
  for (var i = 0; i < ticks; i++) {
    if (audioProvider.libraryTree.isNotEmpty &&
        (!waitForCategorySnapshot ||
            audioProvider.audioLibraryCategorySnapshotSync != null)) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for library tree');
}

Widget buildAudioProviderTestApp({
  required AudioProvider audioProvider,
  required AudioDatabaseRepository audioDatabaseRepository,
  required NativePlaybackRepository nativePlaybackRepository,
  required PlaybackCommandRunner playbackCommandRunner,
  required LibraryService libraryService,
  required PlaybackSessionService playbackService,
  required TimerService timerService,
  required NotificationCoordinatorService notificationCoordinatorService,
  required SettingsRepository settingsRepository,
  required AppLanguageProvider languageProvider,
  UiOperationService? uiOperationService,
  required Widget child,
}) {
  final themeProvider = ThemeProvider();
  return ProviderScope(
    overrides: [
      ...createAudioProviderOverrides(
        audioProvider: audioProvider,
        uiOperationService: uiOperationService,
      ),
      appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
      themeProviderInstanceProvider.overrideWithValue(themeProvider),
      appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

final class AudioProviderWidgetTestFixture {
  AudioProviderWidgetTestFixture({
    CoverArtworkCacheService? coverArtworkCacheService,
    DlsiteMetadataService? dlsiteMetadataService,
    AsmrMetadataService? asmrMetadataService,
    void Function(SettingsRepository settingsRepository)?
    configureSettingsRepository,
  }) : notificationService = PlaybackNotificationService(),
       audioDatabaseRepository = AudioDatabaseRepository(),
       nativePlaybackRepository = NativePlaybackRepository(),
       libraryService = LibraryService(),
       playbackService = PlaybackSessionService(),
       timerService = TimerService(),
       notificationCoordinatorService = NotificationCoordinatorService(),
       settingsRepository = SettingsRepository(),
       uiOperationService = UiOperationService(),
       languageProvider = AppLanguageProvider() {
    configureSettingsRepository?.call(settingsRepository);
    audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
      coverArtworkCacheService: coverArtworkCacheService,
      dlsiteMetadataService: dlsiteMetadataService,
      asmrMetadataService: asmrMetadataService,
      pageLanguageResolver: () => languageProvider.language,
    );
  }

  final PlaybackNotificationService notificationService;
  final AudioDatabaseRepository audioDatabaseRepository;
  final NativePlaybackRepository nativePlaybackRepository;
  static const PlaybackCommandRunner playbackCommandRunner =
      PlaybackCommandRunner();
  final LibraryService libraryService;
  final PlaybackSessionService playbackService;
  final TimerService timerService;
  final NotificationCoordinatorService notificationCoordinatorService;
  final SettingsRepository settingsRepository;
  final UiOperationService uiOperationService;
  final AppLanguageProvider languageProvider;
  late final AudioProvider audioProvider;

  ({
    PlaybackNotificationService notificationService,
    AudioDatabaseRepository audioDatabaseRepository,
    NativePlaybackRepository nativePlaybackRepository,
    PlaybackCommandRunner playbackCommandRunner,
    LibraryService libraryService,
    PlaybackSessionService playbackService,
    TimerService timerService,
    NotificationCoordinatorService notificationCoordinatorService,
    SettingsRepository settingsRepository,
    UiOperationService uiOperationService,
    AppLanguageProvider languageProvider,
    AudioProvider audioProvider,
  })
  get dependencies => (
    notificationService: notificationService,
    audioDatabaseRepository: audioDatabaseRepository,
    nativePlaybackRepository: nativePlaybackRepository,
    playbackCommandRunner: playbackCommandRunner,
    libraryService: libraryService,
    playbackService: playbackService,
    timerService: timerService,
    notificationCoordinatorService: notificationCoordinatorService,
    settingsRepository: settingsRepository,
    uiOperationService: uiOperationService,
    languageProvider: languageProvider,
    audioProvider: audioProvider,
  );

  Widget build(Widget child) => buildAudioProviderTestApp(
    audioProvider: audioProvider,
    audioDatabaseRepository: audioDatabaseRepository,
    nativePlaybackRepository: nativePlaybackRepository,
    playbackCommandRunner: playbackCommandRunner,
    libraryService: libraryService,
    playbackService: playbackService,
    timerService: timerService,
    notificationCoordinatorService: notificationCoordinatorService,
    settingsRepository: settingsRepository,
    uiOperationService: uiOperationService,
    languageProvider: languageProvider,
    child: child,
  );

  void dispose() => audioProvider.dispose();

  Future<void> disposeAfterWarmups() async {
    await audioProvider.uiWarmupCoordinator.shutdown();
    audioProvider.dispose();
  }
}

final class AudioProviderTestFixture {
  AudioProviderTestFixture._({
    required this.database,
    required this.notificationService,
    required this.provider,
  });

  final Database database;
  final PlaybackNotificationService notificationService;
  final AudioProvider provider;
  bool _disposed = false;

  static void initialize() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  static Future<AudioProviderTestFixture> create() async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    await AppDatabase.createSchemaForTest(database);
    final notificationService = PlaybackNotificationService();
    final provider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: AudioDatabaseRepository(
        database: AppDatabase.test(database),
      ),
    );
    return AudioProviderTestFixture._(
      database: database,
      notificationService: notificationService,
      provider: provider,
    );
  }

  static Future<Database> installSharedDatabase() async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    await AppDatabase.createSchemaForTest(database);
    AppDatabase.setInstanceForTest(AppDatabase.test(database));
    return database;
  }

  static Future<void> disposeSharedDatabase(Database database) async {
    AppDatabase.setInstanceForTest(null);
    await database.close();
  }

  Future<void> dispose({required AudioProvider currentProvider}) async {
    if (_disposed) return;
    _disposed = true;
    await currentProvider.uiWarmupCoordinator.shutdown();
    currentProvider.dispose();
    await Future<void>.delayed(Duration.zero);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fileCacheChannel, null);
    messenger.setMockMethodCallHandler(nativePlaybackChannel, null);
    messenger.setMockMethodCallHandler(notificationsChannel, null);
    await database.close();
  }
}
