import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    show Consumer, ProviderContainer, ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/app_runtime_graph.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/persistence/json_document_store.dart';
import 'test_persistence_repository.dart';
import 'package:doujin_audio/core/platform/power_platform_service.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/core/ui/undoable_removal_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_metadata_service.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_playback_cache_service.dart';
import 'package:doujin_audio/features/library/application/audio_detail_cache_service.dart';
import 'package:doujin_audio/features/library/application/audio_detail_document_repository.dart';
import 'package:doujin_audio/features/library/application/audio_detail_repository.dart';
import 'package:doujin_audio/features/library/application/cover_artwork_cache_service.dart';
import 'package:doujin_audio/features/library/application/dlsite_metadata_service.dart';
import 'package:doujin_audio/features/library/application/library_facade.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/library/application/library_snapshot_cache_service.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/notification_facade.dart';
import 'package:doujin_audio/features/player/application/playback_command_runner.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/application/timer_facade.dart';
import 'package:doujin_audio/features/settings/application/app_update_service.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'runtime_test_models.dart';

export 'package:doujin_audio/app/application/app_runtime_graph.dart'
    show AppRuntimeGraph;

AppRuntimeGraph createTestRuntimeGraph({
  LibraryFacade? library,
  PlaybackFacade? playback,
  TimerFacade? timer,
  NotificationFacade? notification,
  SettingsRepository? settings,
  PlaybackNotificationService? notificationService,
  TestPersistenceRepository? persistenceRepository,
  AudioDetailRepository? audioDetailRepository,
  JsonDocumentStore? jsonDocumentStore,
  AudioDetailCacheService? audioDetailCacheService,
  CoverArtworkCacheService? coverArtworkCacheService,
  DlsiteMetadataService? dlsiteMetadataService,
  AsmrMetadataService? asmrMetadataService,
  AsmrPlaybackCacheService? asmrPlaybackCacheService,
  NativePlaybackRepository? nativePlaybackRepository,
  PlaybackCommandRunner playbackCommandRunner = const PlaybackCommandRunner(),
  PowerPlatformService? powerPlatformService,
  AsmrDownloadManager? asmrDownloads,
  LibraryService? libraryService,
  LibrarySnapshotCacheService? librarySnapshotCacheService,
  PlaybackSessionService? playbackService,
  TimerService? timerService,
  NotificationCoordinatorService? notificationStateService,
  SettingsRepository? settingsRepository,
  bool skipPersistence = true,
  bool startRuntime = false,
}) {
  final database = persistenceRepository ?? TestPersistenceRepository();
  final detailCache =
      audioDetailCacheService ??
      AudioDetailCacheService(
        repository:
            audioDetailRepository ??
            AudioDetailRepository(
              databaseRepository: database,
              documentRepository: jsonDocumentStore == null
                  ? null
                  : AudioDetailDocumentRepository(store: jsonDocumentStore),
            ),
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
        databaseRepository: database,
        nativeRepository: nativePlaybackRepository,
        commandRunner: playbackCommandRunner,
        playbackCacheService:
            asmrPlaybackCacheService ?? AsmrPlaybackCacheService(),
        service: playbackService,
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
    asmrDownloads: asmrDownloads,
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
  required TestPersistenceRepository persistenceRepository,
  required NativePlaybackRepository nativePlaybackRepository,
  required PlaybackCommandRunner playbackCommandRunner,
  required LibraryService libraryService,
  required PlaybackSessionService playbackService,
  required TimerService timerService,
  required NotificationCoordinatorService notificationCoordinatorService,
  required SettingsRepository settingsRepository,
  required AppLanguageProvider languageProvider,
  PlaybackSubtitleService? subtitleService,
  UiOperationService? uiOperationService,
  UndoableRemovalService? undoableRemovalService,
  ThemeProvider? themeProvider,
  List<NavigatorObserver> navigatorObservers = const <NavigatorObserver>[],
  List<Override> overrides = const <Override>[],
  required Widget child,
}) {
  final resolvedThemeProvider = themeProvider ?? ThemeProvider();
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
        subtitles: subtitleService ?? runtimeGraph.subtitles,
        timer: runtimeGraph.timer,
        notifications: runtimeGraph.notifications,
        settings: runtimeGraph.settings,
        uiOperationService: uiOperationService,
        undoableRemovalService: undoableRemovalService,
      ),
      appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
      themeProviderInstanceProvider.overrideWith(
        (ref) => resolvedThemeProvider,
      ),
      appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
      ...overrides,
    ],
    child: MaterialApp(
      navigatorObservers: navigatorObservers,
      home: Scaffold(
        body: Consumer(
          builder: (context, ref, _) {
            ref.watch(appInteractionEffectsControllerProvider);
            return child;
          },
        ),
      ),
    ),
  );
}

final class AppRuntimeWidgetTestFixture {
  AppRuntimeWidgetTestFixture({
    CoverArtworkCacheService? coverArtworkCacheService,
    DlsiteMetadataService? dlsiteMetadataService,
    AsmrMetadataService? asmrMetadataService,
    NativePlaybackRepository? providedNativePlaybackRepository,
    SettingsRepository? providedSettingsRepository,
    LibraryTreeSnapshotBuilder? libraryTreeSnapshotBuilder,
    void Function(SettingsRepository settingsRepository)?
    configureSettingsRepository,
  }) : notificationService = PlaybackNotificationService(),
       persistenceRepository = TestPersistenceRepository(),
       nativePlaybackRepository =
           providedNativePlaybackRepository ?? NativePlaybackRepository(),
       libraryService = LibraryService(),
       playbackService = PlaybackSessionService(),
       timerService = TimerService(),
       notificationCoordinatorService = NotificationCoordinatorService(),
       settingsRepository = providedSettingsRepository ?? SettingsRepository(),
       uiOperationService = UiOperationService(),
       undoableRemovalService = UndoableRemovalService(),
       languageProvider = AppLanguageProvider() {
    configureSettingsRepository?.call(settingsRepository);
    final detailCache = AudioDetailCacheService(
      repository: AudioDetailRepository(
        databaseRepository: persistenceRepository,
        documentRepository: AudioDetailDocumentRepository(
          store: TestJsonDocumentStore(),
        ),
      ),
    );
    final snapshotCache = libraryTreeSnapshotBuilder == null
        ? null
        : LibrarySnapshotCacheService(
            libraryService: libraryService,
            detailCacheService: detailCache,
            treeSnapshotBuilder: libraryTreeSnapshotBuilder,
          );
    library = LibraryFacade.create(
      databaseRepository: persistenceRepository,
      detailCacheService: detailCache,
      service: libraryService,
      snapshotCacheService: snapshotCache,
      coverArtworkCacheService: coverArtworkCacheService,
      metadataService: dlsiteMetadataService,
      asmrMetadataService: asmrMetadataService,
    );
    playback = PlaybackFacade.create(
      databaseRepository: persistenceRepository,
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
  final TestPersistenceRepository persistenceRepository;
  final NativePlaybackRepository nativePlaybackRepository;
  static const PlaybackCommandRunner playbackCommandRunner =
      PlaybackCommandRunner();
  final LibraryService libraryService;
  final PlaybackSessionService playbackService;
  final TimerService timerService;
  final NotificationCoordinatorService notificationCoordinatorService;
  final SettingsRepository settingsRepository;
  final UiOperationService uiOperationService;
  final UndoableRemovalService undoableRemovalService;
  final AppLanguageProvider languageProvider;
  late final LibraryFacade library;
  late final PlaybackFacade playback;
  late final TimerFacade timer;
  late final NotificationFacade notifications;
  late final AppRuntimeGraph runtimeGraph;

  SettingsRepository get settings => settingsRepository;

  Widget build(
    Widget child, {
    PlaybackSubtitleService? subtitleService,
    ThemeProvider? themeProvider,
    List<NavigatorObserver> navigatorObservers = const <NavigatorObserver>[],
    List<Override> overrides = const <Override>[],
  }) => buildAppRuntimeTestApp(
    runtimeGraph: runtimeGraph,
    persistenceRepository: persistenceRepository,
    nativePlaybackRepository: nativePlaybackRepository,
    playbackCommandRunner: playbackCommandRunner,
    libraryService: libraryService,
    playbackService: playbackService,
    timerService: timerService,
    notificationCoordinatorService: notificationCoordinatorService,
    settingsRepository: settingsRepository,
    uiOperationService: uiOperationService,
    undoableRemovalService: undoableRemovalService,
    languageProvider: languageProvider,
    subtitleService: subtitleService,
    themeProvider: themeProvider,
    navigatorObservers: navigatorObservers,
    overrides: overrides,
    child: child,
  );

  void dispose() {
    languageProvider.dispose();
    unawaited(undoableRemovalService.dispose());
    unawaited(runtimeGraph.runtime.dispose());
  }

  void disposeAfterWarmups() => dispose();
}

final class TestJsonDocumentStore implements JsonDocumentStore {
  final Map<String, Uint8List> _documents = <String, Uint8List>{};
  final Map<String, int> _generations = <String, int>{};

  @override
  Future<JsonDocumentReadResult> read(JsonDocumentLocation location) async {
    final bytes = _documents[location.lockKey];
    if (bytes == null) return const JsonDocumentReadResult.missing();
    return JsonDocumentReadResult.found(
      JsonDocumentSnapshot(
        bytes: Uint8List.fromList(bytes),
        revision: _revision(location.lockKey),
      ),
    );
  }

  @override
  Future<JsonDocumentWriteResult> write({
    required JsonDocumentLocation location,
    required Uint8List bytes,
    required JsonDocumentWriteMode mode,
    String? expectedRevision,
  }) async {
    final key = location.lockKey;
    final existing = _documents[key];
    if (mode == JsonDocumentWriteMode.createIfAbsent && existing != null) {
      return JsonDocumentWriteResult(
        status: JsonDocumentWriteStatus.preserved,
        revision: _revision(key),
      );
    }
    if (mode == JsonDocumentWriteMode.replaceIfRevision &&
        (existing == null || expectedRevision != _revision(key))) {
      return const JsonDocumentWriteResult(
        status: JsonDocumentWriteStatus.conflict,
        error: 'revision_mismatch',
      );
    }
    _documents[key] = Uint8List.fromList(bytes);
    _generations[key] = (_generations[key] ?? 0) + 1;
    return JsonDocumentWriteResult(
      status: existing == null
          ? JsonDocumentWriteStatus.created
          : JsonDocumentWriteStatus.replaced,
      revision: _revision(key),
      bytesWritten: bytes.length,
    );
  }

  @override
  Future<JsonDocumentDeleteResult> delete({
    required JsonDocumentLocation location,
    required String expectedRevision,
  }) async {
    final key = location.lockKey;
    if (!_documents.containsKey(key)) {
      return const JsonDocumentDeleteResult(
        status: JsonDocumentDeleteStatus.missing,
      );
    }
    if (expectedRevision != _revision(key)) {
      return const JsonDocumentDeleteResult(
        status: JsonDocumentDeleteStatus.conflict,
        error: 'revision_mismatch',
      );
    }
    _documents.remove(key);
    _generations.remove(key);
    return const JsonDocumentDeleteResult(
      status: JsonDocumentDeleteStatus.deleted,
    );
  }

  String _revision(String key) => 'memory:${_generations[key] ?? 0}';
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
    required ProviderContainer providerContainer,
  }) : _providerContainer = providerContainer;

  final Database database;
  final PlaybackNotificationService notificationService;
  final LibraryFacade library;
  final PlaybackFacade playback;
  final TimerFacade timer;
  final NotificationFacade notifications;
  final SettingsRepository settings;
  final AppRuntimeGraph runtimeGraph;
  ProviderContainer? _providerContainer;
  bool _disposed = false;

  static void initialize() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.localesTestValue = const <Locale>[Locale('zh')];
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
    final repository = TestPersistenceRepository(
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
    final providerContainer = ProviderContainer(
      overrides: createAppRuntimeOverrides(
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
      ),
    );
    providerContainer.read(appInteractionEffectsControllerProvider);
    return AppRuntimeTestFixture._(
      database: database,
      notificationService: notificationService,
      library: library,
      playback: playback,
      timer: timer,
      notifications: notifications,
      settings: settings,
      runtimeGraph: runtimeGraph,
      providerContainer: providerContainer,
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
    _providerContainer?.dispose();
    _providerContainer = null;
    await (currentGraph ?? runtimeGraph).runtime.dispose();
    await Future<void>.delayed(Duration.zero);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(fileCacheChannel, null);
    messenger.setMockMethodCallHandler(nativePlaybackChannel, null);
    messenger.setMockMethodCallHandler(notificationsChannel, null);
    await database.close();
    UiInteractionCoordinator.instance.resetForTest();
  }

  void bindRuntimeGraph(AppRuntimeGraph graph) {
    _providerContainer?.dispose();
    _providerContainer = ProviderContainer(
      overrides: createAppRuntimeOverrides(
        persistence: graph.persistence,
        runtime: graph.runtime,
        warmup: graph.warmup,
        playbackCommands: graph.playbackCommands,
        keepAlive: graph.keepAlive,
        library: graph.library,
        playback: graph.playback,
        subtitles: graph.subtitles,
        timer: graph.timer,
        notifications: graph.notifications,
        settings: graph.settings,
      ),
    )..read(appInteractionEffectsControllerProvider);
  }
}
