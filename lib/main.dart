import 'dart:async';

import 'package:audio_session/audio_session.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:provider/provider.dart';

import 'i18n/app_language_provider.dart';
import 'platform/app_platform.dart';
import 'platform/app_window_bootstrap.dart';
import 'providers/audio_provider.dart';
import 'providers/audio_provider_riverpod.dart';
import 'screens/main_screen.dart';
import 'screens/onboarding_page.dart';
import 'services/asmr_library_controller.dart';
import 'services/asmr_download_manager.dart';
import 'services/audio_database_repository.dart';
import 'services/audio_state_services.dart';
import 'services/native_playback_repository.dart';
import 'services/playback_command_runner.dart';
import 'services/playback_notification_service.dart';
import 'services/app_log_service.dart';
import 'services/ui_interaction_coordinator.dart';
import 'theme/theme_provider.dart';
import 'services/app_preferences.dart';
import 'services/app_database.dart';
import 'widgets/global_shortcuts.dart';
import 'widgets/app_error_view.dart';

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

  // Optimize image cache for mobile memory stability
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      50 * 1024 * 1024; // 50MB
  PaintingBinding.instance.imageCache.maximumSize = 200; // 200 images

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

  await initFutures;

  final notificationService = PlaybackNotificationService();
  final audioDatabaseRepository = AudioDatabaseRepository();
  final nativePlaybackRepository = NativePlaybackRepository();
  const playbackCommandRunner = PlaybackCommandRunner();
  final libraryService = LibraryService();
  final playbackService = PlaybackSessionService();
  final timerService = TimerService();
  final notificationCoordinatorService = NotificationCoordinatorService();
  final settingsRepository = SettingsRepository();
  final asmrLibraryController = AsmrLibraryController(
    audioDatabaseRepository: audioDatabaseRepository,
  );
  final asmrDownloadManager = AsmrDownloadManager();
  final audioProvider = AudioProvider(
    notificationService: notificationService,
    audioDatabaseRepository: audioDatabaseRepository,
    nativePlaybackRepository: nativePlaybackRepository,
    libraryService: libraryService,
    playbackService: playbackService,
    timerService: timerService,
    notificationStateService: notificationCoordinatorService,
    settingsRepository: settingsRepository,
    deferRuntimeStart: true,
  );

  runApp(
    ProviderScope(
      overrides: createAudioProviderOverrides(
        audioProvider: audioProvider,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
      ),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => AppLanguageProvider()),
          ChangeNotifierProvider.value(value: audioProvider),
          ChangeNotifierProvider.value(value: asmrLibraryController),
          ChangeNotifierProvider.value(value: asmrDownloadManager),
        ],
        child: const MusicPlayerApp(),
      ),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    audioProvider.startRuntime();
    unawaited(asmrLibraryController.initialize());
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
          scrollBehavior: const MaterialScrollBehavior().copyWith(
            scrollbars: AppPlatform.showsDesktopScrollbars,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
          ),
          home: const OnboardingGate(
            child: GlobalShortcuts(child: MainScreen()),
          ),
        );
      },
    );
  }
}
