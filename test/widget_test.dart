import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:nameless_audio/main.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/providers/audio_provider_riverpod.dart';
import 'package:nameless_audio/screens/main_screen.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/native_playback_repository.dart';
import 'package:nameless_audio/services/playback_command_runner.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:nameless_audio/theme/theme_provider.dart';
import 'package:provider/provider.dart' as legacy_provider;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  testWidgets('app shell renders tab navigation', (WidgetTester tester) async {
    final themeProvider = ThemeProvider();
    final languageProvider = AppLanguageProvider();
    final notificationService = PlaybackNotificationService();
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final audioProvider = AudioProvider.test(
      notificationService: notificationService,
      audioDatabaseRepository: audioDatabaseRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );

    await tester.pumpWidget(
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
        child: legacy_provider.MultiProvider(
          providers: [
            legacy_provider.ChangeNotifierProvider.value(value: themeProvider),
            legacy_provider.ChangeNotifierProvider.value(
              value: languageProvider,
            ),
            legacy_provider.ChangeNotifierProvider.value(value: audioProvider),
          ],
          child: const MusicPlayerApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MainScreen), findsOneWidget);
    expect(find.text(languageProvider.tr('nav_library')), findsWidgets);
    expect(find.text(languageProvider.tr('nav_sessions')), findsWidgets);
    expect(find.text(languageProvider.tr('nav_settings')), findsWidgets);
    expect(find.byKey(const ValueKey<String>('main_page_fade_1')), findsOne);
    expect(find.byKey(const ValueKey<String>('main_page_fade_0')), findsOne);
    expect(find.byKey(const ValueKey<String>('main_page_fade_2')), findsOne);
    expect(find.byKey(const ValueKey<String>('main_page_fade_3')), findsOne);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey<String>('main_page_fade_1')),
          )
          .opacity,
      1,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey<String>('main_page_fade_0')),
          )
          .opacity,
      0,
    );

    await tester.tap(find.text(languageProvider.tr('nav_settings')).last);
    await tester.pumpAndSettle();

    final pageFades = <AnimatedOpacity>[
      tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey<String>('main_page_fade_1')),
      ),
      tester.widget<AnimatedOpacity>(
        find.byKey(const ValueKey<String>('main_page_fade_3')),
      ),
    ];
    expect(pageFades.where((widget) => widget.opacity == 1).length, 1);
    expect(pageFades.where((widget) => widget.opacity == 0).length, 1);
    expect(pageFades.every((widget) => widget.child is Align), isTrue);
    expect(languageProvider.tr('app_version'), 'NL Audio v0.9.9');

    Stack mainPageStack() => tester
        .widgetList<Stack>(find.byType(Stack))
        .firstWhere((widget) => widget.key is ValueKey<int>);

    expect((mainPageStack().key! as ValueKey<int>).value, 0);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    tester.view.physicalSize = Size(
      tester.view.physicalSize.width,
      tester.view.physicalSize.height - 600,
    );
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetViewInsets();
    });

    await tester.pump(const Duration(milliseconds: 32));

    expect((mainPageStack().key! as ValueKey<int>).value, 0);
  });
}
