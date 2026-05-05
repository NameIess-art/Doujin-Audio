import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'i18n/app_language_provider.dart';
import 'providers/audio_provider.dart';
import 'screens/main_screen.dart';
import 'services/playback_notification_handler.dart';
import 'services/playback_notification_service.dart';
import 'theme/theme_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  final audioSession = await AudioSession.instance;
  await audioSession.configure(const AudioSessionConfiguration.music());
  final audioHandler = await AudioService.init(
    builder: PlaybackNotificationHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.music_player.channel.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
    ),
  );
  final notificationService = PlaybackNotificationService(audioHandler);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AppLanguageProvider()),
        ChangeNotifierProvider(
          create: (_) =>
              AudioProvider(notificationService: notificationService),
        ),
      ],
      child: const MusicPlayerApp(),
    ),
  );
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
