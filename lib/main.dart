import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/application/app_bootstrap_controller.dart';
import 'app/application/app_startup.dart';
import 'app/presentation/app_bootstrap_host.dart';
import 'app/presentation/app_error_view.dart';
import 'app/presentation/app_orientation_controller.dart';
import 'app/presentation/music_player_app.dart';
import 'app/theme/theme_provider.dart';
import 'core/logging/app_log_service.dart';
import 'core/persistence/app_preferences.dart';
import 'core/platform/app_lifecycle_platform_service.dart';
import 'features/data_support/application/data_backup_service.dart';
import 'features/library/application/cover_image_cache_policy.dart';
import 'features/settings/application/settings_state.dart'
    show CoverImageResolution;

export 'app/presentation/music_player_app.dart' show MusicPlayerApp;

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  await initializePlatformRuntime();
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
      StartupRestoreOutcome? startupRestoreOutcome;
      await AppPreferences.init();
      final themeProvider = ThemeProvider();

      late final AppBootstrapController appBootstrapController;
      appBootstrapController = AppBootstrapController(
        initializer: () async {
          startupRestoreOutcome = await _initializeAudioPlayerApp();
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
          appBuilder: () => createAudioPlayerApp(
            shouldShowOnboarding: shouldShowOnboarding!,
            themeProvider: themeProvider,
            startupRestoreOutcome: startupRestoreOutcome,
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

Future<StartupRestoreOutcome?> _initializeAudioPlayerApp() async {
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

  return initializeAudioPlayerStartup(uiInitialization: initFutures);
}
