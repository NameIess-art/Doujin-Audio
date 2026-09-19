import 'core/widgets/drag_only_scrollbar.dart';
import 'core/widgets/mobile_overlay_inset.dart';
import 'package:flutter/foundation.dart';
import 'features/asmr/presentation/asmr_providers.dart';
import 'features/settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/localization/app_language_provider.dart';
import 'app/application/app_bootstrap_controller.dart';
import 'app/application/app_runtime_graph.dart';
import 'app/application/windows_runtime_binding.dart';
import 'app/state/app_runtime_providers.dart';
import 'app/presentation/app_presentation_providers.dart';
import 'app/presentation/app_bootstrap_host.dart';
import 'app/presentation/app_error_view.dart';
import 'app/presentation/app_orientation_controller.dart';
import 'app/presentation/global_shortcuts.dart';
import 'app/presentation/main_screen.dart';
import 'app/presentation/onboarding_page.dart';
import 'features/asmr/application/asmr_library_controller.dart';
import 'features/asmr/application/asmr_api_service.dart';
import 'features/asmr/application/asmr_auth_service.dart';
import 'features/asmr/application/asmr_remote_catalog_service.dart';
import 'features/asmr/application/asmr_account_sync_service.dart';
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
import 'features/player/presentation/active_session_carousel.dart';
import 'features/player/presentation/playlist_tab.dart';
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
  if (Platform.isWindows) {
    MediaKit.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await getApplicationSupportDirectory();
    await databaseFactory.setDatabasesPath(
      path.join(directory.path, 'databases'),
    );
  }
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
    if (!Platform.isWindows)
      SystemChrome.setPreferredOrientations(
        AppOrientationPolicy.current.allowedOrientations,
      ),
    if (!Platform.isWindows)
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge),
    if (!Platform.isWindows)
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
  final asmrApiService = AsmrApiService();
  final asmrPreferences = AsmrPreferencesStore(repository: asmrRepository);
  final asmrLibraryController = AsmrLibraryController(
    preferencesStore: asmrPreferences,
    remoteCatalogService: AsmrRemoteCatalogService(
      apiService: asmrApiService,
      persistenceRepository: asmrRepository,
    ),
    accountSyncService: AsmrAccountSyncService(
      authService: AsmrAuthService(apiService: asmrApiService),
      apiService: asmrApiService,
      preferencesStore: asmrPreferences,
    ),
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
    if (Platform.isWindows) {
      await attachWindowsRuntime(
        runtime: runtimeGraph.runtime,
        playback: playbackFacade,
        notifications: notificationFacade,
        timer: timerFacade,
      );
    }
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
      asmrLibraryControllerProvider.overrideWith((ref) {
        ref.onDispose(() {
          asmrLibraryController.dispose();
          asmrApiService.close();
        });
        return asmrLibraryController;
      }),
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

class _RootPageRouteObserver extends NavigatorObserver {
  _RootPageRouteObserver(this.revision);

  final ValueNotifier<int> revision;
  final List<PageRoute<dynamic>> _routes = <PageRoute<dynamic>>[];
  bool _syncScheduled = false;
  bool _disposed = false;

  PageRoute<dynamic>? get topRoute => _routes.lastOrNull;
  bool get hasSecondaryRoute => _routes.length > 1;

  void _sync() {
    if (_syncScheduled || _disposed) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!_disposed) revision.value++;
    });
  }

  void dispose() {
    _disposed = true;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route case final PageRoute<dynamic> pageRoute) {
      _routes.add(pageRoute);
      _sync();
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) {
      _routes.remove(route);
      _sync();
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PageRoute<dynamic>) {
      _routes.remove(route);
      _sync();
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is PageRoute<dynamic>) {
      final index = _routes.indexOf(oldRoute);
      if (index >= 0) {
        if (newRoute is PageRoute<dynamic>) {
          _routes[index] = newRoute;
        } else {
          _routes.removeAt(index);
        }
      }
    } else if (newRoute is PageRoute<dynamic>) {
      _routes.add(newRoute);
    }
    _sync();
  }
}

class _RoutedPlaybackDock extends ConsumerStatefulWidget {
  const _RoutedPlaybackDock({
    required this.active,
    required this.navigatorKey,
    required this.currentRoute,
  });

  final bool active;
  final GlobalKey<NavigatorState> navigatorKey;
  final Route<dynamic>? currentRoute;

  @override
  ConsumerState<_RoutedPlaybackDock> createState() =>
      _RoutedPlaybackDockState();
}

class _RoutedPlaybackDockState extends ConsumerState<_RoutedPlaybackDock> {
  static const _duration = Duration(milliseconds: 280);
  Timer? _hideTimer;
  late bool _visible = widget.active;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _scheduleExpansion();
  }

  @override
  void didUpdateWidget(covariant _RoutedPlaybackDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    _hideTimer?.cancel();
    if (widget.active) {
      _visible = true;
      _expanded = false;
      _scheduleExpansion();
      return;
    }
    _expanded = false;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _duration;
    _hideTimer = Timer(duration, () {
      if (mounted && !widget.active) setState(() => _visible = false);
    });
  }

  void _scheduleExpansion() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) setState(() => _expanded = true);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(
      mainOverlayUiProvider.select((state) => state.overlaySessions),
    );
    final size = MediaQuery.sizeOf(context);
    final supported =
        defaultTargetPlatform != TargetPlatform.windows &&
        MediaQuery.orientationOf(context) == Orientation.portrait &&
        size.width < 980;
    if (!_visible || !supported || sessions.isEmpty) {
      return const SizedBox.shrink();
    }
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _duration;
    final i18n = ref.read(appLanguageProviderInstanceProvider);

    return IgnorePointer(
      ignoring: !widget.active,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 6),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: FractionallySizedBox(
                widthFactor: 0.96,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: AnimatedContainer(
                        key: const ValueKey<String>(
                          'routed_playback_dock_width',
                        ),
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        width: _expanded
                            ? constraints.maxWidth
                            : kActiveSessionCarouselDockHeight,
                        height: kActiveSessionCarouselDockHeight,
                        child: AppDockGlassPanel(
                          key: const ValueKey<String>('routed_playback_dock'),
                          shadowOpacity: 0.12,
                          showTopHighlight: false,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              kActiveSessionCarouselDockHeight / 2,
                            ),
                            child: ActiveSessionCarousel(
                              sessions: sessions,
                              i18n: i18n,
                              viewportFraction: 1,
                              presentation:
                                  ActiveSessionCarouselPresentation.embedded,
                              onOpenSession: (sessionId) {
                                if (widget.currentRoute is SessionDetailRoute) {
                                  return;
                                }
                                widget.navigatorKey.currentState?.push(
                                  buildSessionDetailRoute(sessionId: sessionId),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
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
  final ValueNotifier<int> _routeRevision = ValueNotifier(0);
  late final _RootPageRouteObserver _routeObserver;
  var _restoreOutcomeScheduled = false;
  var _runtimeBootstrapSettledNotified = false;
  StreamSubscription<VideoConversionResult>? _conversionSubscription;

  @override
  void initState() {
    super.initState();
    _routeObserver = _RootPageRouteObserver(_routeRevision);
    // Register root-owned disposal even when onboarding hides the ASMR page.
    ref.read(asmrLibraryControllerProvider);
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
    _routeObserver.dispose();
    _routeRevision.dispose();
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
            ref
                .read(appLifecyclePlatformServiceProvider)
                .syncAppTheme(preset: next.$1.name, themeMode: next.$2.name),
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
    final hasOverlaySessions = ref.watch(
      mainOverlayUiProvider.select((state) => state.overlaySessions.isNotEmpty),
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
      navigatorObservers: [
        UiInteractionNavigatorObserver.instance,
        _routeObserver,
      ],
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
      scrollBehavior: const AppScrollBehavior().copyWith(
        scrollbars: true,
        physics: const ClampingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final navigatorChild = defaultTargetPlatform == TargetPlatform.windows
            ? ListenableBuilder(
                listenable: _runtimeBootstrapController,
                child: child ?? const SizedBox(),
                builder: (context, child) => GlobalShortcuts(
                  enabled:
                      _runtimeBootstrapController.state.phase ==
                      AppBootstrapPhase.ready,
                  navigatorKey: _navigatorKey,
                  child: child!,
                ),
              )
            : child ?? const SizedBox();
        return MediaQuery(
          data: mediaQuery.copyWith(
            disableAnimations: reduceAnimations || mediaQuery.disableAnimations,
          ),
          child: ValueListenableBuilder<int>(
            valueListenable: _routeRevision,
            child: navigatorChild,
            builder: (context, revision, navigatorChild) {
              final hasSecondaryRoute = _routeObserver.hasSecondaryRoute;
              final supportsRoutedDock =
                  defaultTargetPlatform != TargetPlatform.windows &&
                  mediaQuery.orientation == Orientation.portrait &&
                  mediaQuery.size.width < 980;
              final routeDockActive =
                  hasSecondaryRoute && supportsRoutedDock && hasOverlaySessions;
              final routeDockInset = routeDockActive
                  ? kActiveSessionCarouselDockHeight +
                        12 +
                        mediaQuery.padding.bottom
                  : 0.0;
              return MobileOverlayInset(
                bottomInset: routeDockInset,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(
                      color: Theme.of(context).colorScheme.surface,
                      child: navigatorChild!,
                    ),
                    _RoutedPlaybackDock(
                      active: routeDockActive,
                      navigatorKey: _navigatorKey,
                      currentRoute: _routeObserver.topRoute,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
      home: OnboardingRuntimeGate(
        showOnboarding: _shouldShowOnboarding,
        runtimeController: _runtimeBootstrapController,
        child: AppBootstrapGate(
          controller: _runtimeBootstrapController,
          disposeController: false,
          readyBuilder: (_) => defaultTargetPlatform == TargetPlatform.windows
              ? const MainScreen()
              : const GlobalShortcuts(child: MainScreen()),
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
