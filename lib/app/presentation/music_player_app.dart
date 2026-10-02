import '../../core/widgets/drag_only_scrollbar.dart';
import 'package:flutter/foundation.dart';
import '../../features/asmr/presentation/asmr_providers.dart';
import '../../features/settings/presentation/settings_providers.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../localization/app_language_provider.dart';
import '../application/app_bootstrap_controller.dart';
import '../application/app_runtime_graph.dart';
import '../state/app_runtime_providers.dart';
import '../presentation/app_presentation_providers.dart';
import '../presentation/app_bootstrap_host.dart';
import '../presentation/app_error_view.dart';
import '../presentation/app_orientation_controller.dart';
import '../presentation/global_shortcuts.dart';
import '../presentation/main_screen.dart';
import '../presentation/onboarding_page.dart';
import '../../core/ui/ui_interaction_coordinator.dart';
import '../../core/widgets/app_feedback.dart';
import '../theme/theme_provider.dart';
import '../../core/persistence/app_preferences.dart';
import '../../features/settings/application/settings_state.dart';
import '../../features/data_support/application/data_backup_service.dart';
import '../../features/video_converter/application/video_conversion_runner.dart';
import '../../features/video_converter/presentation/video_conversion_dialog.dart';

import 'routed_playback_dock_host.dart';

Widget createAudioPlayerApp({
  required bool shouldShowOnboarding,
  required ThemeProvider themeProvider,
  StartupRestoreOutcome? startupRestoreOutcome,
  VoidCallback? onBootstrapSettled,
}) {
  final (
    :runtimeGraph,
    :appLanguageProvider,
    :appUpdateService,
    :asmrDownloadManager,
    :asmrMetadataService,
    :asmrLibraryController,
    :asmrPlaybackCoordinator,
    :asmrApiService,
    :initializeRuntimeData,
  ) = createProductionAppRuntime();

  final app = ProviderScope(
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
  double _stablePortraitTopPadding = 0;
  StreamSubscription<VideoConversionResult>? _conversionSubscription;

  @override
  void initState() {
    super.initState();
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
    return RoutedPlaybackDockHost(
      navigatorKey: _navigatorKey,
      builder: (context, routeObserver, playbackDockGeometry, wrapNavigator) =>
          MaterialApp(
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
            scrollBehavior: const AppScrollBehavior().copyWith(
              scrollbars: true,
              physics: AppScrollBehavior.defaultScrollPhysics,
            ),
            builder: (context, child) {
              final mediaQuery = MediaQuery.of(context);
              final rawTop = mediaQuery.padding.top;
              final isLandscape =
                  defaultTargetPlatform == TargetPlatform.windows ||
                  mediaQuery.orientation == Orientation.landscape;

              if (!isLandscape && rawTop > _stablePortraitTopPadding) {
                _stablePortraitTopPadding = rawTop;
              }

              final effectiveTop = !isLandscape && _stablePortraitTopPadding > 0
                  ? math.max(rawTop, _stablePortraitTopPadding)
                  : rawTop;
              final effectivePadding = effectiveTop != rawTop
                  ? mediaQuery.padding.copyWith(top: effectiveTop)
                  : mediaQuery.padding;
              final effectiveViewPadding =
                  !isLandscape && _stablePortraitTopPadding > 0
                  ? mediaQuery.viewPadding.copyWith(
                      top: math.max(
                        mediaQuery.viewPadding.top,
                        _stablePortraitTopPadding,
                      ),
                    )
                  : mediaQuery.viewPadding;

              final effectiveMediaQuery = mediaQuery.copyWith(
                padding: effectivePadding,
                viewPadding: effectiveViewPadding,
                disableAnimations:
                    reduceAnimations || mediaQuery.disableAnimations,
              );

              final navigatorChild =
                  defaultTargetPlatform == TargetPlatform.windows
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
              final content = MediaQuery(
                data: effectiveMediaQuery,
                child: wrapNavigator(context, navigatorChild),
              );
              if (defaultTargetPlatform == TargetPlatform.windows) {
                return TooltipVisibility(visible: false, child: content);
              }
              return content;
            },
            home: OnboardingRuntimeGate(
              showOnboarding: _shouldShowOnboarding,
              runtimeController: _runtimeBootstrapController,
              child: AppBootstrapGate(
                controller: _runtimeBootstrapController,
                disposeController: false,
                readyBuilder: (_) =>
                    defaultTargetPlatform == TargetPlatform.windows
                    ? MainScreen(playbackDockGeometry: playbackDockGeometry)
                    : GlobalShortcuts(
                        child: MainScreen(
                          playbackDockGeometry: playbackDockGeometry,
                        ),
                      ),
                loadingBuilder: (_) => const AppBootstrapLoadingView(),
                failureBuilder: (_, state) => AppErrorView(
                  error:
                      state.error ??
                      StateError('Unknown runtime startup failure'),
                  stackTrace: state.stackTrace,
                  onRetry: () => unawaited(_runtimeBootstrapController.retry()),
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
