import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:provider/provider.dart';

import 'i18n/app_language_provider.dart';
import 'providers/audio_provider.dart';
import 'providers/audio_provider_riverpod.dart';
import 'screens/main_screen.dart';
import 'services/asmr_library_controller.dart';
import 'services/asmr_download_manager.dart';
import 'services/audio_database_repository.dart';
import 'services/audio_state_services.dart';
import 'services/playback_notification_handler.dart';
import 'services/native_playback_repository.dart';
import 'services/playback_command_runner.dart';
import 'services/playback_notification_service.dart';
import 'theme/theme_provider.dart';
import 'services/app_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
    AudioService.init(
      builder: PlaybackNotificationHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.nameless.audio.channel.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
      ),
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

  final results = await initFutures;
  final audioHandler = results[3] as PlaybackNotificationHandler;

  final notificationService = PlaybackNotificationService(audioHandler);
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
  unawaited(asmrLibraryController.initialize());
  unawaited(asmrDownloadManager.initialize());

  final audioProvider = AudioProvider(
    notificationService: notificationService,
    audioDatabaseRepository: audioDatabaseRepository,
    nativePlaybackRepository: nativePlaybackRepository,
    libraryService: libraryService,
    playbackService: playbackService,
    timerService: timerService,
    notificationStateService: notificationCoordinatorService,
    settingsRepository: settingsRepository,
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
}

class AppOrientationPolicy {
  const AppOrientationPolicy._(this.allowedOrientations);

  static const portrait = AppOrientationPolicy._([
    DeviceOrientation.portraitUp,
  ]);

  // Swap this policy when landscape playback detail UI is added.
  static const current = portrait;

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
          color: themeProvider.isDarkMode
              ? const Color(0xFF121017)
              : const Color(0xFFF7F4EE),
          locale: languageProvider.locale,
          supportedLocales: AppLanguageProvider.supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: themeProvider.currentTheme,
          home: const MainScreen(),
        );
      },
    );
  }
}
