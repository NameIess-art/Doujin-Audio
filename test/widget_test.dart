import 'package:flutter_test/flutter_test.dart';
import 'package:music_player/main.dart';
import 'package:music_player/i18n/app_language_provider.dart';
import 'package:music_player/providers/audio_provider.dart';
import 'package:music_player/screens/main_screen.dart';
import 'package:music_player/services/playback_notification_handler.dart';
import 'package:music_player/services/playback_notification_service.dart';
import 'package:music_player/theme/theme_provider.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('app shell renders tab navigation', (WidgetTester tester) async {
    final themeProvider = ThemeProvider();
    final languageProvider = AppLanguageProvider();
    final notificationHandler = PlaybackNotificationHandler();
    final notificationService = PlaybackNotificationService(notificationHandler);
    final audioProvider = AudioProvider(notificationService: notificationService);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: themeProvider),
          ChangeNotifierProvider.value(value: languageProvider),
          ChangeNotifierProvider.value(value: audioProvider),
        ],
        child: const MusicPlayerApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MainScreen), findsOneWidget);
    expect(find.text(languageProvider.tr('nav_library')), findsWidgets);
    expect(find.text(languageProvider.tr('nav_sessions')), findsWidgets);
    expect(find.text(languageProvider.tr('nav_settings')), findsWidgets);
  });
}
