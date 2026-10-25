import '../../core/widgets/drag_only_scrollbar.dart';
import 'package:flutter/foundation.dart';
import '../../features/asmr/presentation/asmr_providers.dart';
import '../../features/settings/presentation/settings_providers.dart';
import '../state/listening_activity_provider.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../localization/app_language_provider.dart';
import '../application/app_bootstrap_controller.dart';
import '../application/app_runtime_graph.dart';
import '../application/app_runtime_lifecycle.dart';
import '../application/windows_runtime_binding.dart';
import '../state/app_runtime_providers.dart';
import '../presentation/app_presentation_providers.dart';
import '../presentation/app_bootstrap_host.dart';
import '../presentation/app_error_view.dart';
import '../presentation/app_orientation_controller.dart';
import '../presentation/global_shortcuts.dart';
import '../presentation/main_screen.dart';
import '../presentation/onboarding_page.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/cache/app_cache_service.dart';
import '../../core/logging/app_log_service.dart';
import '../../core/widgets/app_feedback.dart';
import '../../core/widgets/app_transitions.dart';
import '../theme/theme_provider.dart';
import '../../core/persistence/app_preferences.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/player/presentation/playlist/session_detail_route.dart';
import '../../features/data_support/application/data_backup_service.dart';

import 'routed_playback_dock_host.dart';
import 'work_detail_navigation.dart';

Widget createAudioPlayerApp({
  required bool shouldShowOnboarding,
  required ThemeProvider themeProvider,
  StartupRestoreOutcome? startupRestoreOutcome,
  VoidCallback? onBootstrapSettled,
  WindowsRuntimeBinding? windowsRuntime,
}) {
  final (
    :runtimeGraph,
    :appLanguageProvider,
    :appUpdateService,
    :asmrDownloadManager,
    :asmrMetadataService,
    :asmrLibraryController,
    :asmrPlaybackCoordinator,
    :initializePresentation,
    :initializeRuntimeData,
  ) = createProductionAppRuntime(
    windowsRuntime: windowsRuntime,
  );

  final app = ProviderScope(
    overrides: [
      listeningActivityServiceProvider.overrideWithValue(
        runtimeGraph.listeningActivity!,
      ),
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
        browsePageStates: runtimeGraph.browsePageStates,
        workTexts: runtimeGraph.workTexts,
      ),
      themeProviderInstanceProvider.overrideWith((ref) => themeProvider),
      appLanguageProviderInstanceProvider.overrideWithValue(
        appLanguageProvider,
      ),
      appUpdateServiceProvider.overrideWithValue(appUpdateService),
      asmrDownloadManagerProvider.overrideWithValue(asmrDownloadManager),
      asmrWorkFinderProvider.overrideWithValue(
        asmrMetadataService.findAsmrWorkByRjCode,
      ),
      asmrLibraryControllerProvider.overrideWithValue(asmrLibraryController),
      asmrPlaybackCoordinatorProvider.overrideWithValue(
        asmrPlaybackCoordinator,
      ),
    ],
    child: MusicPlayerApp(
      shouldShowOnboarding: shouldShowOnboarding,
      startupRestoreOutcome: startupRestoreOutcome,
      onBootstrapSettled: onBootstrapSettled,
      presentationInitializer: initializePresentation,
      runtimeInitializer: initializeRuntimeData,
    ),
  );

  return app;
}

class MusicPlayerApp extends ConsumerStatefulWidget {
  const MusicPlayerApp({
    this.shouldShowOnboarding,
    this.startupRestoreOutcome,
    this.onBootstrapSettled,
    this.presentationInitializer,
    this.runtimeInitializer,
    super.key,
  });

  final bool? shouldShowOnboarding;
  final StartupRestoreOutcome? startupRestoreOutcome;
  final VoidCallback? onBootstrapSettled;
  final Future<void> Function()? presentationInitializer;
  final Future<void> Function()? runtimeInitializer;

  @override
  ConsumerState<MusicPlayerApp> createState() => _MusicPlayerAppState();
}

class _MusicPlayerAppState extends ConsumerState<MusicPlayerApp>
    with WidgetsBindingObserver {
  late final AppBootstrapController _presentationBootstrapController;
  late final AppBootstrapController _runtimeBootstrapController;
  late final AppRuntimeLifecycle _runtime;
  late final bool _shouldShowOnboarding;
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final _workDetailNavigation = WorkDetailNavigation(
    rootNavigatorKey: _navigatorKey,
  );
  var _restoreOutcomeScheduled = false;
  var _presentationSettledNotified = false;
  var _secondaryFrameReady = false;
  bool _secondaryInitializationRequested = false;
  double _stablePortraitTopPadding = 0;
  double _stableLandscapeTopPadding = 0;
  late final AppOrientationController _orientationController;

  @override
  void initState() {
    super.initState();
    _runtime = ref.read(audioRuntimeCoordinatorProvider);
    _orientationController = ref.read(appOrientationControllerProvider);
    WidgetsBinding.instance.addObserver(this);
    UiInteractionCoordinator.instance.addListener(
      _scheduleSecondaryInitialization,
    );
    _presentationBootstrapController = AppBootstrapController(
      initializer: () async {
        final initializer = widget.presentationInitializer;
        if (initializer != null) {
          await initializer();
        } else {
          await ref.read(appLanguageProviderInstanceProvider).initialized;
          await ref
              .read(appPersistenceCoordinatorProvider)
              .initializePresentation();
        }
      },
    );
    _presentationBootstrapController.addListener(
      _handlePresentationStateChanged,
    );
    _runtimeBootstrapController = AppBootstrapController(
      initializer:
          widget.runtimeInitializer ??
          ref.read(audioRuntimeCoordinatorProvider).start,
    );
    _runtimeBootstrapController.addListener(_scheduleSecondaryInitialization);
    _shouldShowOnboarding =
        widget.shouldShowOnboarding ??
        AppPreferences.shouldShowOnboardingSync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateDisplayOrientation();
  }

  @override
  void didChangeMetrics() => _updateDisplayOrientation();

  void _updateDisplayOrientation() {
    if (defaultTargetPlatform == TargetPlatform.windows) return;
    // Window bounds can be letterboxed or split; device class uses the display.
    final display = View.of(context).display;
    unawaited(
      _orientationController.updateDisplay(
        display.size.shortestSide / display.devicePixelRatio,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UiInteractionCoordinator.instance.removeListener(
      _scheduleSecondaryInitialization,
    );
    _presentationBootstrapController.removeListener(
      _handlePresentationStateChanged,
    );
    _presentationBootstrapController.dispose();
    _runtimeBootstrapController.removeListener(_scheduleSecondaryInitialization);
    _runtimeBootstrapController.dispose();
    _workDetailNavigation.dispose();
    unawaited(
      _runtime.dispose().catchError((Object error, StackTrace stack) {
        AppLogService.error(
          'app_runtime_shutdown_failed',
          error: error,
          stackTrace: stack,
        );
      }),
    );
    super.dispose();
  }

  void _handlePresentationStateChanged() {
    if (_presentationBootstrapController.state.phase !=
        AppBootstrapPhase.ready) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handlePresentationSettled();
    });
  }

  void _handlePresentationSettled() {
    if (!_presentationSettledNotified) {
      _presentationSettledNotified = true;
      widget.onBootstrapSettled?.call();
    }
    if (_presentationBootstrapController.state.phase !=
            AppBootstrapPhase.ready ||
        _secondaryFrameReady) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _secondaryFrameReady) return;
      _secondaryFrameReady = true;
      _scheduleSecondaryInitialization();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _scheduleSecondaryInitialization() {
    if (!mounted ||
        !_secondaryFrameReady ||
        _runtimeBootstrapController.state.phase != AppBootstrapPhase.ready ||
        _secondaryInitializationRequested) {
      return;
    }
    final interaction = UiInteractionCoordinator.instance;
    // Navigation changes generations; reschedule pending startup work when its
    // interaction ends so an immediate page switch cannot discard restoration.
    interaction.scheduleAfterIdle(
      key: 'app-secondary-initialization-${identityHashCode(this)}',
      generation: interaction.generation,
      priority: 200,
      task: () async {
        if (!mounted ||
            _runtimeBootstrapController.state.phase != AppBootstrapPhase.ready ||
            _secondaryInitializationRequested) {
          return;
        }
        _secondaryInitializationRequested = true;
        await _initializeSecondaryData();
      },
    );
  }

  Future<void> _initializeSecondaryData() async {
    AppCacheService.scheduleEnforce();
    try {
      await _runtime.initializeSecondaryData();
    } catch (error, stackTrace) {
      AppLogService.warning(
        'app_secondary_initialization_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(appInteractionEffectsControllerProvider);
    ref.listen<AsyncValue<SettingsState>>(settingsStateProvider, (_, next) {
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
    final coreRuntimeReady = ref.watch(coreRuntimeReadyProvider);
    final fallbackSettings = ref.read(settingsRepositoryProvider).slice.state;
    final languageProvider = ref.read(appLanguageProviderInstanceProvider);
    _scheduleRestoreOutcomeFeedback(languageProvider);
    final languageState =
        ref.watch(appLanguageStateProvider).value ??
        AppLanguageState.from(languageProvider);
    final reduceAnimations = ref.watch(
      settingsStateProvider.select(
        (state) =>
            state.value?.reduceAnimations ?? fallbackSettings.reduceAnimations,
      ),
    );
    final disableAnimations =
        reduceAnimations ||
        (MediaQuery.maybeDisableAnimationsOf(context) ?? false);
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
    return WorkDetailNavigationScope(
      navigation: _workDetailNavigation,
      child: RoutedPlaybackDockHost(
        navigatorKey: _navigatorKey,
        onTopPageChanged: (route) => unawaited(
          _orientationController.setPlaybackDetailVisible(
            route is SessionDetailRoute,
          ),
        ),
        builder:
            (
              context,
              routeObserver,
              playbackDockGeometry,
              wrapNavigator,
            ) => MaterialApp(
              navigatorKey: _navigatorKey,
              title: languageProvider.tr('app_title'),
              debugShowCheckedModeBanner: false,
              navigatorObservers: [
                UiInteractionNavigatorObserver.instance,
                routeObserver,
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
              themeAnimationStyle: disableAnimations
                  ? AnimationStyle.noAnimation
                  : null,
              scrollBehavior: const AppScrollBehavior().copyWith(
                scrollbars: true,
                physics: AppScrollBehavior.defaultScrollPhysics,
              ),
              builder: (context, child) {
                final routedContent = wrapNavigator(
                  context,
                  child ?? const SizedBox(),
                );
                final navigatorContent = Builder(
                  builder: (context) {
                    final mediaQuery = MediaQuery.of(context);
                    final rawTop = mediaQuery.padding.top;
                    final isLandscape =
                        defaultTargetPlatform == TargetPlatform.windows ||
                        mediaQuery.orientation == Orientation.landscape;

                    if (!isLandscape && rawTop > _stablePortraitTopPadding) {
                      _stablePortraitTopPadding = rawTop;
                    }

                    final isAndroidLandscape =
                        defaultTargetPlatform == TargetPlatform.android &&
                        mediaQuery.orientation == Orientation.landscape;
                    if (isAndroidLandscape) {
                      // Playback hides the status bar; retain the same header inset
                      // for the main page and every route in the navigator.
                      _stableLandscapeTopPadding = math.max(
                        _stableLandscapeTopPadding,
                        math.max(rawTop, mediaQuery.viewPadding.top),
                      );
                    }
                    final stableTop = isAndroidLandscape
                        // The first landscape frame can arrive after immersive
                        // mode has hidden both inset values. Retain the known
                        // portrait height until Android reports a landscape inset.
                        ? (_stableLandscapeTopPadding > 0
                              ? _stableLandscapeTopPadding
                              : _stablePortraitTopPadding)
                        : !isLandscape
                        ? _stablePortraitTopPadding
                        : 0.0;
                    final effectiveTop = math.max(rawTop, stableTop);
                    final effectivePadding = effectiveTop != rawTop
                        ? mediaQuery.padding.copyWith(top: effectiveTop)
                        : mediaQuery.padding;
                    final effectiveViewPadding = stableTop > 0
                        ? mediaQuery.viewPadding.copyWith(
                            top: math.max(
                              mediaQuery.viewPadding.top,
                              stableTop,
                            ),
                          )
                        : mediaQuery.viewPadding;

                    final effectiveMediaQuery = mediaQuery.copyWith(
                      padding: effectivePadding,
                      viewPadding: effectiveViewPadding,
                      disableAnimations:
                          disableAnimations || mediaQuery.disableAnimations,
                    );

                    return MediaQuery(
                      data: effectiveMediaQuery,
                      child: routedContent,
                    );
                  },
                );
                final content = ListenableBuilder(
                  listenable: _runtimeBootstrapController,
                  child: navigatorContent,
                  builder: (context, child) => GlobalShortcuts(
                    enabled:
                        coreRuntimeReady &&
                        _runtimeBootstrapController.state.phase ==
                            AppBootstrapPhase.ready,
                    navigatorKey: _navigatorKey,
                    navigationAllowed:
                        UiInteractionCoordinator.instance.navigationAllowed,
                    child: defaultTargetPlatform == TargetPlatform.windows
                        ? child!
                        : AppNavigationInputLock(
                            navigationAllowed: UiInteractionCoordinator
                                .instance
                                .navigationAllowed,
                            child: child!,
                          ),
                  ),
                );
                if (defaultTargetPlatform == TargetPlatform.windows) {
                  return TooltipVisibility(visible: false, child: content);
                }
                return content;
              },
              home: AppBootstrapGate(
                controller: _presentationBootstrapController,
                disposeController: false,
                onBootstrapSettled: _handlePresentationSettled,
                readyBuilder: (_) => OnboardingRuntimeGate(
                  showOnboarding: _shouldShowOnboarding,
                  runtimeController: _runtimeBootstrapController,
                  child: AppBootstrapGate(
                    controller: _runtimeBootstrapController,
                    disposeController: false,
                    showReadyWhileInitializing: true,
                    initializeAfterFirstFrame: true,
                    readyBuilder: (_) =>
                        MainScreen(playbackDockGeometry: playbackDockGeometry),
                    loadingBuilder: (_) => const AppBootstrapLoadingView(),
                    failureBuilder: (_, state) => AppErrorView(
                      error:
                          state.error ??
                          StateError('Unknown runtime startup failure'),
                      stackTrace: state.stackTrace,
                      onRetry: () =>
                          unawaited(_runtimeBootstrapController.retry()),
                    ),
                  ),
                ),
                loadingBuilder: (_) => const AppBootstrapLoadingView(),
                failureBuilder: (_, state) => AppErrorView(
                  error:
                      state.error ??
                      StateError('Unknown presentation startup failure'),
                  stackTrace: state.stackTrace,
                  onRetry: () =>
                      unawaited(_presentationBootstrapController.retry()),
                ),
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
