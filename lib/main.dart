import 'dart:async';

import 'package:audio_session/audio_session.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:provider/provider.dart';

import 'app/localization/app_language_provider.dart';
import 'core/platform/app_platform.dart';
import 'core/platform/app_window_bootstrap.dart';
import 'app/state/audio_provider.dart';
import 'app/state/audio_provider_riverpod.dart';
import 'app/presentation/main_screen.dart';
import 'app/presentation/onboarding_page.dart';
import 'features/asmr/application/asmr_library_controller.dart';
import 'features/asmr/application/asmr_download_manager.dart';
import 'features/asmr/application/asmr_playback_coordinator.dart';
import 'features/asmr/application/asmr_preferences.dart';
import 'features/asmr/domain/asmr_models.dart';
import 'core/persistence/audio_database_repository.dart';
import 'features/player/application/audio_state_services.dart';
import 'features/library/application/library_facade.dart';
import 'features/library/application/cover_image_cache_policy.dart';
import 'features/player/application/native_playback_repository.dart';
import 'features/player/application/notification_facade.dart';
import 'features/player/application/playback_facade.dart';
import 'features/player/application/playback_notification_service.dart';
import 'features/player/application/playback_session_launcher.dart';
import 'features/player/application/timer_facade.dart';
import 'core/logging/app_log_service.dart';
import 'core/ui/ui_interaction_coordinator.dart';
import 'app/theme/theme_provider.dart';
import 'features/settings/application/app_preferences.dart';
import 'core/persistence/app_database.dart';
import 'core/widgets/global_shortcuts.dart';
import 'core/widgets/app_error_view.dart';

Future<void> main() async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLogService.initialize();
    AppLogService.installFlutterErrorHandler();
    AppLogService.installPlatformErrorHandler();
    if (kReleaseMode) {
      ErrorWidget.builder = (details) {
        AppLogService.error(
          'release_error_widget',
          error: details.exception,
          stackTrace: details.stack,
        );
        return AppErrorView(details: details);
      };
    }
    await _runAudioPlayerApp();
  }, AppLogService.logZoneError);
}

Future<void> _runAudioPlayerApp() async {
  AppDatabase.initializeForPlatform();
  await AppWindowBootstrap.initializeMainWindow();

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
    AppPreferences.init(),
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

  final notificationService = PlaybackNotificationService();
  final audioDatabaseRepository = AudioDatabaseRepository();
  final nativePlaybackRepository = NativePlaybackRepository();
  final libraryService = LibraryService();
  final playbackService = PlaybackSessionService();
  final timerService = TimerService();
  final notificationCoordinatorService = NotificationCoordinatorService();
  final settingsRepository = SettingsRepository();
  final asmrDownloadManager = AsmrDownloadManager();
  final appLanguageProvider = AppLanguageProvider();
  final libraryFacade = LibraryFacade.create(
    databaseRepository: audioDatabaseRepository,
    service: libraryService,
  );
  final playbackFacade = PlaybackFacade.create(
    databaseRepository: audioDatabaseRepository,
    nativeRepository: nativePlaybackRepository,
    service: playbackService,
  );
  final timerFacade = TimerFacade.create(service: timerService);
  final notificationFacade = NotificationFacade.create(
    service: notificationService,
    stateService: notificationCoordinatorService,
  );
  final audioProvider = AudioProvider(
    library: libraryFacade,
    playback: playbackFacade,
    timer: timerFacade,
    notification: notificationFacade,
    settings: settingsRepository,
    pageLanguageResolver: () => appLanguageProvider.language,
    deferRuntimeStart: true,
  );
  final asmrLibraryController = AsmrLibraryController(
    audioDatabaseRepository: audioDatabaseRepository,
    preferencesStore: AsmrPreferencesStore(database: AppDatabase.instance),
  );
  final asmrPlaybackCoordinator = AsmrPlaybackCoordinator(
    source: asmrLibraryController,
    launcher: PlaybackFacadeSessionLauncher(playbackFacade),
  );

  runApp(
    ProviderScope(
      overrides: createAudioProviderOverrides(audioProvider: audioProvider),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider.value(value: appLanguageProvider),
          ChangeNotifierProvider.value(value: audioProvider),
          ChangeNotifierProvider.value(value: asmrLibraryController),
          ChangeNotifierProvider.value(value: asmrDownloadManager),
          Provider.value(value: asmrPlaybackCoordinator),
        ],
        child: const MusicPlayerApp(),
      ),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    audioProvider.startRuntime();
    unawaited(
      asmrLibraryController.initialize(
        defaultLanguage: AsmrContentLanguage.fromAppLanguageName(
          appLanguageProvider.language.name,
        ),
      ),
    );
    unawaited(asmrDownloadManager.initialize());
  });
}

class AppOrientationPolicy {
  const AppOrientationPolicy._(this.allowedOrientations);

  static const portrait = AppOrientationPolicy._([
    DeviceOrientation.portraitUp,
  ]);

  // Swap this policy when landscape playback detail UI is added.
  static const current = AppOrientationPolicy._([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  final List<DeviceOrientation> allowedOrientations;
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

class MusicPlayerApp extends StatelessWidget {
  const MusicPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer2<ThemeProvider, AppLanguageProvider>(
      builder: (context, themeProvider, languageProvider, child) {
        return MaterialApp(
          title: languageProvider.tr('app_title'),
          debugShowCheckedModeBanner: false,
          navigatorObservers: [UiInteractionNavigatorObserver.instance],
          color: const Color(0xFFC94D63),
          locale: languageProvider.locale,
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
            scrollbars: AppPlatform.showsDesktopScrollbars,
            physics: const ClampingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
          ),
          builder: (context, child) {
            return TooltipVisibility(
              visible: false,
              child: child ?? const SizedBox(),
            );
          },
          home: const OnboardingGate(
            child: GlobalShortcuts(child: MainScreen()),
          ),
        );
      },
    );
  }
}
