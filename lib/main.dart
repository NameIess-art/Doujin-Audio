import 'dart:async';

import 'package:audio_session/audio_session.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/localization/app_language_provider.dart';
import 'app/application/app_bootstrap_controller.dart';
import 'app/application/app_runtime_graph.dart';
import 'app/state/app_runtime_providers.dart';
import 'app/presentation/app_presentation_providers.dart';
import 'app/presentation/app_bootstrap_host.dart';
import 'app/presentation/app_error_view.dart';
import 'app/presentation/app_orientation_controller.dart';
import 'app/presentation/global_shortcuts.dart';
import 'app/presentation/main_screen.dart';
import 'app/presentation/onboarding_page.dart';
import 'features/asmr/application/asmr_library_controller.dart';
import 'features/asmr/application/asmr_download_manager.dart';
import 'features/asmr/application/asmr_playback_coordinator.dart';
import 'features/asmr/application/asmr_preferences.dart';
import 'features/asmr/domain/asmr_models.dart';
import 'infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'infrastructure/sqlite/sqlite_library_repository.dart';
import 'infrastructure/sqlite/sqlite_playback_repository.dart';
import 'features/player/application/audio_state_services.dart';
import 'features/library/application/library_facade.dart';
import 'features/library/application/library_service.dart';
import 'features/library/application/cover_image_cache_policy.dart';
import 'features/player/application/native_playback_repository.dart';
import 'features/player/application/notification_facade.dart';
import 'features/player/application/playback_facade.dart';
import 'features/player/application/playback_notification_service.dart';
import 'features/player/application/playback_session_launcher.dart';
import 'features/player/application/timer_facade.dart';
import 'core/logging/app_log_service.dart';
import 'core/ui/ui_interaction_coordinator.dart';
import 'core/widgets/app_feedback.dart';
import 'app/theme/theme_provider.dart';
import 'features/settings/application/app_preferences.dart';
import 'features/settings/application/app_cache_service.dart';
import 'features/settings/application/app_update_service.dart';
import 'features/settings/application/settings_repository.dart';
import 'features/settings/application/settings_state.dart';
import 'core/persistence/app_database.dart';
import 'core/persistence/json_document_store.dart';
import 'core/platform/app_lifecycle_platform_service.dart';
import 'features/data_support/application/data_backup_service.dart';
import 'features/video_converter/application/video_conversion_runner.dart';
import 'features/video_converter/presentation/video_conversion_dialog.dart';

StartupRestoreOutcome? _startupRestoreOutcome;

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  binding.deferFirstFrame();
  var firstFrameAllowed = false;

  void allowFirstFrame() {
    if (firstFrameAllowed) return;
    firstFrameAllowed = true;
    binding.allowFirstFrame();
  }

  await runZonedGuarded<Future<void>>(
    () async {
      AppLogService.installFlutterErrorHandler();
      AppLogService.installPlatformErrorHandler();
      ErrorWidget.builder = (details) {
        AppLogService.error(
          'release_error_widget',
          error: details.exception,
          stackTrace: details.stack,
        );
        return AppErrorView.fromFlutterError(details);
      };

      bool? shouldShowOnboarding;
      await AppPreferences.init();
      final themeProvider = ThemeProvider();

      late final AppBootstrapController appBootstrapController;
      appBootstrapController = AppBootstrapController(
        initializer: () async {
          await _initializeAudioPlayerApp();
          await themeProvider.reloadPersistedState();
          unawaited(
            AppLifecyclePlatformService().syncAppTheme(
              preset: themeProvider.appThemeColor.name,
              themeMode: themeProvider.themeMode.name,
            ),
          );
          shouldShowOnboarding = AppPreferences.shouldShowOnboardingSync();
        },
      );

      runApp(
        AppBootstrapHost(
          controller: appBootstrapController,
          themeProvider: themeProvider,
          appBuilder: () => _createAudioPlayerApp(
            shouldShowOnboarding: shouldShowOnboarding!,
            themeProvider: themeProvider,
            startupRestoreOutcome: _startupRestoreOutcome,
            onBootstrapSettled: allowFirstFrame,
          ),
          onBootstrapSettled: () {
            if (appBootstrapController.state.phase ==
                AppBootstrapPhase.failure) {
              allowFirstFrame();
            }
          },
        ),
      );
    },
    (error, stackTrace) {
      AppLogService.logZoneError(error, stackTrace);
    },
  );
}

Future<void> _initializeAudioPlayerApp() async {
  await AppLogService.initialize();
  applyCoverImageCachePolicy(CoverImageResolution.balanced);

  // Start essential services in parallel to minimize blocking before runApp
  final initFutures = Future.wait([
    SystemChrome.setPreferredOrientations(
      AppOrientationPolicy.current.allowedOrientations,
    ),
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    AudioSession.instance.then(
      (session) => session.configure(const AudioSessionConfiguration.music()),
    ),
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  await AppLogService.measureAsync(
    'app_bootstrap_pre_run_app',
    () => initFutures,
  );

  final restoreOutcome = await DataBackupService().applyAtStartup();
  _startupRestoreOutcome = restoreOutcome;
  if (restoreOutcome?.succeeded == true) {
    final nativePlayback = NativePlaybackRepository();
    try {
      await nativePlayback.clearAll();
    } finally {
      await nativePlayback.dispose();
    }
    await AppCacheService.clearAllCaches();
    AppLogService.info('backup_restore_applied');
  } else if (restoreOutcome != null) {
    AppLogService.warning(
      'backup_restore_failed code=${restoreOutcome.errorCode}',
    );
  }
}

Widget _createAudioPlayerApp({
  required bool shouldShowOnboarding,
  required ThemeProvider themeProvider,
  StartupRestoreOutcome? startupRestoreOutcome,
  VoidCallback? onBootstrapSettled,
}) {
  final notificationService = PlaybackNotificationService();
  final database = AppDatabase.instance;
  final libraryRepository = SqliteLibraryRepository(database: database);
  final playbackRepository = SqlitePlaybackRepository(database: database);
  final asmrRepository = SqliteAsmrRepository(database: database);
  final nativePlaybackRepository = NativePlaybackRepository();
  final libraryService = LibraryService();
  final playbackService = PlaybackSessionService();
  final timerService = TimerService();
  final notificationCoordinatorService = NotificationCoordinatorService();
  final settingsRepository = SettingsRepository();
  final jsonDocumentStore = DefaultJsonDocumentStore();
  final asmrDownloadManager = AsmrDownloadManager(
    jsonDocumentStore: jsonDocumentStore,
  );
  final appLanguageProvider = AppLanguageProvider();
  final appUpdateService = AppUpdateService();
  final libraryFacade = LibraryFacade.create(
    databaseRepository: libraryRepository,
    jsonDocumentStore: jsonDocumentStore,
    service: libraryService,
  );
  final playbackFacade = PlaybackFacade.create(
    databaseRepository: playbackRepository,
    nativeRepository: nativePlaybackRepository,
    service: playbackService,
  );
  final timerFacade = TimerFacade.create(service: timerService);
  final notificationFacade = NotificationFacade.create(
    service: notificationService,
    stateService: notificationCoordinatorService,
  );
  final runtimeGraph = createAppRuntimeGraph(
    library: libraryFacade,
    playback: playbackFacade,
    timer: timerFacade,
    notifications: notificationFacade,
    settings: settingsRepository,
    asmrDownloads: asmrDownloadManager,
  );
  final asmrLibraryController = AsmrLibraryController(
    persistenceRepository: asmrRepository,
    preferencesStore: AsmrPreferencesStore(repository: asmrRepository),
  );
  final asmrPlaybackCoordinator = AsmrPlaybackCoordinator(
    source: asmrLibraryController,
    launcher: PlaybackFacadeSessionLauncher(playbackFacade),
  );

  Future<void> initializeRuntimeData() async {
    await appLanguageProvider.initialized;
    await Future.wait<void>([
      runtimeGraph.runtime.start(),
      asmrDownloadManager.initialize(),
      asmrLibraryController.initialize(
        defaultLanguage: AsmrContentLanguage.fromAppLanguage(
          appLanguageProvider.language,
        ),
      ),
    ]);
  }

  final app = ProviderScope(
    overrides: [
      ...createAppRuntimeOverrides(
        persistence: runtimeGraph.persistence,
        runtime: runtimeGraph.runtime,
        warmup: runtimeGraph.warmup,
        playbackCommands: runtimeGraph.playbackCommands,
        keepAlive: runtimeGraph.keepAlive,
        library: libraryFacade,
        playback: playbackFacade,
        subtitles: runtimeGraph.subtitles,
        timer: timerFacade,
        notifications: notificationFacade,
        settings: settingsRepository,
      ),
      themeProviderInstanceProvider.overrideWith((ref) => themeProvider),
      appLanguageProviderInstanceProvider.overrideWithValue(
        appLanguageProvider,
      ),
      appUpdateServiceProvider.overrideWithValue(appUpdateService),
      asmrDownloadManagerProvider.overrideWithValue(asmrDownloadManager),
      asmrLibraryControllerProvider.overrideWithValue(asmrLibraryController),
      asmrPlaybackCoordinatorProvider.overrideWithValue(
        asmrPlaybackCoordinator,
      ),
    ],
    child: MusicPlayerApp(
      shouldShowOnboarding: shouldShowOnboarding,
      startupRestoreOutcome: startupRestoreOutcome,
      onBootstrapSettled: onBootstrapSettled,
      runtimeInitializer: initializeRuntimeData,
    ),
  );

  return app;
}

class _StretchOverscrollBehavior extends MaterialScrollBehavior {
  const _StretchOverscrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (details.direction == AxisDirection.left ||
        details.direction == AxisDirection.right) {
      return child;
    }
    return StretchingOverscrollIndicator(
      axisDirection: details.direction,
      child: child,
    );
  }
}

class MusicPlayerApp extends ConsumerStatefulWidget {
  const MusicPlayerApp({
    this.shouldShowOnboarding,
    this.startupRestoreOutcome,
    this.onBootstrapSettled,
    this.runtimeInitializer,
    super.key,
  });

  final bool? shouldShowOnboarding;
  final StartupRestoreOutcome? startupRestoreOutcome;
  final VoidCallback? onBootstrapSettled;
  final Future<void> Function()? runtimeInitializer;

  @override
  ConsumerState<MusicPlayerApp> createState() => _MusicPlayerAppState();
}

class _MusicPlayerAppState extends ConsumerState<MusicPlayerApp> {
  late final AppBootstrapController _runtimeBootstrapController;
  late final bool _shouldShowOnboarding;
  final _navigatorKey = GlobalKey<NavigatorState>();
  var _restoreOutcomeScheduled = false;
  var _runtimeBootstrapSettledNotified = false;
  StreamSubscription<VideoConversionResult>? _conversionSubscription;

  @override
  void initState() {
    super.initState();
    _runtimeBootstrapController = AppBootstrapController(
      initializer:
          widget.runtimeInitializer ??
          ref.read(audioRuntimeCoordinatorProvider).start,
    );
    _runtimeBootstrapController.addListener(_handleRuntimeBootstrapState);
    _shouldShowOnboarding =
        widget.shouldShowOnboarding ??
        AppPreferences.shouldShowOnboardingSync();
    _conversionSubscription = ref
        .read(videoConversionCoordinatorProvider)
        .completionStream
        .listen(_handleConversionCompletion);
  }

  @override
  void dispose() {
    _conversionSubscription?.cancel();
    _runtimeBootstrapController.removeListener(_handleRuntimeBootstrapState);
    _runtimeBootstrapController.dispose();
    super.dispose();
  }

  void _handleConversionCompletion(VideoConversionResult result) {
    if (result.status == VideoConversionStatus.canceled) return;
    final context = _navigatorKey.currentContext;
    if (context == null || !mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final coordinator = ref.read(videoConversionCoordinatorProvider);
    unawaited(
      showVideoConversionResultDialog(
        context,
        result: result,
        i18n: i18n,
        videoPath: coordinator.selectedVideoPath,
      ),
    );
  }

  void _handleRuntimeBootstrapState() {
    if (_runtimeBootstrapSettledNotified ||
        _runtimeBootstrapController.state.phase ==
            AppBootstrapPhase.initializing) {
      return;
    }
    _runtimeBootstrapSettledNotified = true;
    widget.onBootstrapSettled?.call();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appInteractionEffectsControllerProvider);
    ref.listen<AsyncValue<SettingsState>>(settingsStateProvider, (_, next) {
      final portraitLockEnabled = next.asData?.value.portraitLockEnabled;
      if (portraitLockEnabled != null) {
        unawaited(
          ref
              .read(appOrientationControllerProvider)
              .setPortraitLockEnabled(portraitLockEnabled),
        );
      }
      final hapticFeedbackEnabled = next.asData?.value.hapticFeedbackEnabled;
      if (hapticFeedbackEnabled != null) {
        AppInteractionFeedback.hapticFeedbackEnabled = hapticFeedbackEnabled;
      }
    });
    ref.listen<(ThemeAccentPreset, ThemeMode)>(
      themeProviderInstanceProvider.select(
        (theme) => (theme.appThemeColor, theme.themeMode),
      ),
      (previous, next) {
        if (previous != next) {
          unawaited(
            ref.read(appLifecyclePlatformServiceProvider).syncAppTheme(
              preset: next.$1.name,
              themeMode: next.$2.name,
            ),
          );
        }
      },
    );
    final themeProvider = ref.watch(themeProviderInstanceProvider);
    final languageProvider = ref.read(appLanguageProviderInstanceProvider);
    _scheduleRestoreOutcomeFeedback(languageProvider);
    final languageState =
        ref.watch(appLanguageStateProvider).value ??
        AppLanguageState.from(languageProvider);
    final reduceAnimations = ref.watch(
      settingsStateProvider.select(
        (state) => state.value?.reduceAnimations ?? false,
      ),
    );
    final platformBrightness =
        MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light;
    final windowSurface = switch (themeProvider.themeMode) {
      ThemeMode.dark => themeProvider.darkTheme.colorScheme.surface,
      ThemeMode.light => themeProvider.lightTheme.colorScheme.surface,
      ThemeMode.system =>
        platformBrightness == Brightness.dark
            ? themeProvider.darkTheme.colorScheme.surface
            : themeProvider.lightTheme.colorScheme.surface,
    };
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: languageProvider.tr('app_title'),
      debugShowCheckedModeBanner: false,
      navigatorObservers: [UiInteractionNavigatorObserver.instance],
      color: windowSurface,
      locale: languageState.locale,
      supportedLocales: AppLanguageProvider.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: themeProvider.lightTheme,
      darkTheme: themeProvider.darkTheme,
      themeMode: themeProvider.themeMode,
      scrollBehavior: const _StretchOverscrollBehavior().copyWith(
        scrollbars: false,
        physics: const ClampingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            disableAnimations: reduceAnimations || mediaQuery.disableAnimations,
          ),
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: child ?? const SizedBox(),
          ),
        );
      },
      home: OnboardingRuntimeGate(
        showOnboarding: _shouldShowOnboarding,
        runtimeController: _runtimeBootstrapController,
        child: AppBootstrapGate(
          controller: _runtimeBootstrapController,
          disposeController: false,
          readyBuilder: (_) => const GlobalShortcuts(child: MainScreen()),
          loadingBuilder: (_) => const AppBootstrapLoadingView(),
          failureBuilder: (_, state) => AppErrorView(
            error: state.error ?? StateError('Unknown runtime startup failure'),
            stackTrace: state.stackTrace,
            onRetry: () => unawaited(_runtimeBootstrapController.retry()),
          ),
        ),
      ),
    );
  }

  void _scheduleRestoreOutcomeFeedback(AppLanguageProvider languageProvider) {
    final outcome = widget.startupRestoreOutcome;
    if (_restoreOutcomeScheduled || outcome == null) return;
    _restoreOutcomeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigatorContext = _navigatorKey.currentContext;
      if (navigatorContext == null) return;
      showAppSnackBar(
        navigatorContext,
        languageProvider.tr(
          outcome.succeeded
              ? 'backup_restore_succeeded'
              : 'backup_restore_failed_rolled_back',
        ),
        tone: outcome.succeeded
            ? AppFeedbackTone.success
            : AppFeedbackTone.destructive,
      );
    });
  }
}
