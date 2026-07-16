import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/app/application/app_runtime_graph.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/app/theme/theme_provider.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/core/platform/power_platform_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/core/ui/ui_operation_service.dart';
import 'package:nameless_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:nameless_audio/features/asmr/application/asmr_playback_cache_service.dart';
import 'package:nameless_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:nameless_audio/features/library/application/audio_detail_repository.dart';
import 'package:nameless_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:nameless_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:nameless_audio/features/library/application/library_facade.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/library/application/library_snapshot_cache_service.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/notification_facade.dart';
import 'package:nameless_audio/features/player/application/playback_command_runner.dart';
import 'package:nameless_audio/features/player/application/playback_facade.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/features/player/application/system_media_controls_service.dart';
import 'package:nameless_audio/features/player/application/timer_facade.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'runtime_test_models.dart';

export 'package:nameless_audio/app/application/app_runtime_graph.dart'
    show AppRuntimeGraph;

AppRuntimeGraph createTestRuntimeGraph({
  LibraryFacade? library,
  PlaybackFacade? playback,
  TimerFacade? timer,
  NotificationFacade? notification,
  SettingsRepository? settings,
  PlaybackNotificationService? notificationService,
  AudioDatabaseRepository? audioDatabaseRepository,
  AudioDetailRepository? audioDetailRepository,
  AudioDetailCacheService? audioDetailCacheService,
  CoverArtworkCacheService? coverArtworkCacheService,
  DlsiteMetadataService? dlsiteMetadataService,
  AsmrMetadataService? asmrMetadataService,
  AsmrPlaybackCacheService asmrPlaybackCacheService =
      const AsmrPlaybackCacheService(),
  NativePlaybackRepository? nativePlaybackRepository,
  PlaybackCommandRunner playbackCommandRunner = const PlaybackCommandRunner(),
  PowerPlatformService? powerPlatformService,
  LibraryService? libraryService,
  LibrarySnapshotCacheService? librarySnapshotCacheService,
  PlaybackSessionService? playbackService,
  TimerService? timerService,
  NotificationCoordinatorService? notificationStateService,
  SettingsRepository? settingsRepository,
  SystemMediaControlsService? systemMediaControlsService,
  bool skipPersistence = true,
  bool startRuntime = false,
}) {
  final database = audioDatabaseRepository ?? AudioDatabaseRepository();
  final detailCache =
      audioDetailCacheService ??
      AudioDetailCacheService(
        repository:
            audioDetailRepository ??
            AudioDetailRepository(databaseRepository: database),
      );
  final resolvedLibraryService = libraryService ?? LibraryService();
  final resolvedLibrary =
      library ??
      LibraryFacade.create(
        databaseRepository: database,
        detailCacheService: detailCache,
        metadataService: dlsiteMetadataService,
        asmrMetadataService: asmrMetadataService,
        service: resolvedLibraryService,
        snapshotCacheService: librarySnapshotCacheService,
        coverArtworkCacheService: coverArtworkCacheService,
      );
  final resolvedPlayback =
      playback ??
      PlaybackFacade.create(
        databaseRepository: resolvedLibrary.databaseRepository,
        nativeRepository: nativePlaybackRepository,
        commandRunner: playbackCommandRunner,
        playbackCacheService: asmrPlaybackCacheService,
        service: playbackService,
        systemMediaControlsService: systemMediaControlsService,
      );
  final graph = createAppRuntimeGraph(
    library: resolvedLibrary,
    playback: resolvedPlayback,
    timer:
        timer ??
        TimerFacade.create(
          service: timerService,
          powerPlatformService: powerPlatformService,
        ),
    notifications:
        notification ??
        NotificationFacade.create(
          service: notificationService ?? PlaybackNotificationService(),
          stateService: notificationStateService,
        ),
    settings: settings ?? settingsRepository ?? SettingsRepository(),
    persistenceEnabled: !skipPersistence,
  );
  if (startRuntime) unawaited(graph.runtime.start());
  return graph;
}

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
  LibraryFacade library, {
  Duration timeout = const Duration(seconds: 10),
  bool waitForCategorySnapshot = false,
}) async {
  final ticks = timeout.inMilliseconds ~/ 50;
  for (var i = 0; i < ticks; i++) {
    if (library.libraryTree.isNotEmpty &&
        (!waitForCategorySnapshot || library.categorySnapshot != null)) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Timed out waiting for library tree');
}

Widget buildAppRuntimeTestApp({
  required AppRuntimeGraph runtimeGraph,
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
      ...createAppRuntimeOverrides(
        persistence: runtimeGraph.persistence,
        runtime: runtimeGraph.runtime,
        warmup: runtimeGraph.warmup,
        playbackCommands: runtimeGraph.playbackCommands,
        keepAlive: runtimeGraph.keepAlive,
        library: runtimeGraph.library,
        playback: runtimeGraph.playback,
        subtitles: runtimeGraph.subtitles,
        timer: runtimeGraph.timer,
        notifications: runtimeGraph.notifications,
        settings: runtimeGraph.settings,
        uiOperationService: uiOperationService,
      ),
      appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
      themeProviderInstanceProvider.overrideWithValue(themeProvider),
      appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

final class AppRuntimeWidgetTestFixture {
  AppRuntimeWidgetTestFixture({
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
    library = LibraryFacade.create(
      databaseRepository: audioDatabaseRepository,
      service: libraryService,
      coverArtworkCacheService: coverArtworkCacheService,
      metadataService: dlsiteMetadataService,
      asmrMetadataService: asmrMetadataService,
    );
    playback = PlaybackFacade.create(
      databaseRepository: audioDatabaseRepository,
      nativeRepository: nativePlaybackRepository,
      service: playbackService,
    );
    timer = TimerFacade.create(service: timerService);
    notifications = NotificationFacade.create(
      service: notificationService,
      stateService: notificationCoordinatorService,
    );
    runtimeGraph = createAppRuntimeGraph(
      library: library,
      playback: playback,
      timer: timer,
      notifications: notifications,
      settings: settingsRepository,
      persistenceEnabled: false,
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
  late final LibraryFacade library;
  late final PlaybackFacade playback;
  late final TimerFacade timer;
  late final NotificationFacade notifications;
  late final AppRuntimeGraph runtimeGraph;

  SettingsRepository get settings => settingsRepository;

  Widget build(Widget child) => buildAppRuntimeTestApp(
    runtimeGraph: runtimeGraph,
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

  void dispose() {
    unawaited(runtimeGraph.runtime.dispose());
  }

  void disposeAfterWarmups() => dispose();
}

final class AppRuntimeTestFixture {
  AppRuntimeTestFixture._({
    required this.database,
    required this.notificationService,
    required this.library,
    required this.playback,
    required this.timer,
    required this.notifications,
    required this.settings,
    required this.runtimeGraph,
  });

  final Database database;
  final PlaybackNotificationService notificationService;
  final LibraryFacade library;
  final PlaybackFacade playback;
  final TimerFacade timer;
  final NotificationFacade notifications;
  final SettingsRepository settings;
  final AppRuntimeGraph runtimeGraph;
  bool _disposed = false;

  static void initialize() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  static Future<AppRuntimeTestFixture> create() async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    await AppDatabase.createSchemaForTest(database);
    final notificationService = PlaybackNotificationService();
    final repository = AudioDatabaseRepository(
      database: AppDatabase.test(database),
    );
    final library = LibraryFacade.create(databaseRepository: repository);
    final playback = PlaybackFacade.create(databaseRepository: repository);
    final timer = TimerFacade.create();
    final notifications = NotificationFacade.create(
      service: notificationService,
    );
    final settings = SettingsRepository();
    final runtimeGraph = createAppRuntimeGraph(
      library: library,
      playback: playback,
      timer: timer,
      notifications: notifications,
      settings: settings,
      persistenceEnabled: false,
    );
    return AppRuntimeTestFixture._(
      database: database,
      notificationService: notificationService,
      library: library,
      playback: playback,
      timer: timer,
      notifications: notifications,
      settings: settings,
      runtimeGraph: runtimeGraph,
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

  Future<void> dispose({AppRuntimeGraph? currentGraph}) async {
    if (_disposed) return;
    _disposed = true;
    await (currentGraph ?? runtimeGraph).runtime.dispose();
    await Future<void>.delayed(Duration.zero);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fileCacheChannel, null);
    messenger.setMockMethodCallHandler(nativePlaybackChannel, null);
    messenger.setMockMethodCallHandler(notificationsChannel, null);
    await database.close();
  }
}
