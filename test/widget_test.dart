import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/main.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/providers/audio_provider_riverpod.dart';
import 'package:nameless_audio/screens/main_screen.dart';
import 'package:nameless_audio/screens/settings_tab.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/app_preferences.dart';
import 'package:nameless_audio/services/native_playback_repository.dart';
import 'package:nameless_audio/services/playback_command_runner.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:nameless_audio/theme/theme_provider.dart';
import 'package:nameless_audio/widgets/active_session_carousel.dart';
import 'package:provider/provider.dart' as legacy_provider;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{
    AppPreferences.onboardingCompletedKey: true,
  });

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
    final session = PlaybackSession(
      id: 'orientation_session',
      currentTrackPath: '/audio/orientation.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(session.dispose);
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
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
    expect(
      find.byKey(const ValueKey<String>('main_page_fade_0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('main_page_fade_2')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('main_page_fade_3')),
      findsNothing,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey<String>('main_page_fade_1')),
          )
          .opacity,
      1,
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

    expect(find.byType(ActiveSessionCarousel), findsOneWidget);
    while (tester.takeException() != null) {}
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(2400, 1080);
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;

    expect(
      find.byKey(const ValueKey<String>('android_landscape_navigation_shift')),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byType(NavigationRail),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byType(NavigationRail),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
    );
    final settingsNavigationIcon = find.descendant(
      of: find.byType(NavigationRail),
      matching: find.byIcon(Icons.tune_rounded),
    );
    expect(settingsNavigationIcon, findsOneWidget);
    expect(tester.widget<Icon>(settingsNavigationIcon).size, isNull);
    expect(
      tester.getBottomRight(settingsNavigationIcon).dy,
      lessThan(tester.getTopLeft(find.byType(ActiveSessionCarousel)).dy),
    );
    final settingsScrollable = find
        .descendant(
          of: find.byType(SettingsTab),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byIcon(Icons.system_update_alt_rounded),
      300,
      scrollable: settingsScrollable,
    );
    expect(
      tester.getCenter(find.byIcon(Icons.system_update_alt_rounded)).dx,
      tester.getCenter(find.byIcon(Icons.update_rounded)).dx,
    );

    tester.view.physicalSize = const Size(1080, 2400);
    await tester.pumpAndSettle();

    final orientationExceptions = <Object>[];
    Object? exception;
    while ((exception = tester.takeException()) != null) {
      orientationExceptions.add(exception!);
    }
    expect(
      orientationExceptions.where(
        (error) => error.toString().contains(
          'Cannot use "ref" after the widget was disposed',
        ),
      ),
      isEmpty,
    );
  });
}
