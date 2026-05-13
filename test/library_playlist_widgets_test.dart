import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:nameless_audio/i18n/app_language_provider.dart';
import 'package:nameless_audio/providers/audio_provider.dart';
import 'package:nameless_audio/providers/audio_provider_riverpod.dart';
import 'package:nameless_audio/screens/library_tab.dart';
import 'package:nameless_audio/services/audio_database_repository.dart';
import 'package:nameless_audio/services/audio_state_services.dart';
import 'package:nameless_audio/services/native_playback_repository.dart';
import 'package:nameless_audio/services/playback_command_runner.dart';
import 'package:nameless_audio/services/playback_notification_handler.dart';
import 'package:nameless_audio/services/playback_notification_service.dart';
import 'package:provider/provider.dart' as legacy_provider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

MusicTrack _track({
  required String name,
  required String path,
  required String groupKey,
  required String groupTitle,
}) {
  return MusicTrack(
    path: path,
    displayName: name,
    groupKey: groupKey,
    groupTitle: groupTitle,
    groupSubtitle: groupKey,
    isSingle: false,
  );
}

Widget _buildTestApp({
  required AudioProvider audioProvider,
  required AudioDatabaseRepository audioDatabaseRepository,
  required NativePlaybackRepository nativePlaybackRepository,
  required PlaybackCommandRunner playbackCommandRunner,
  required LibraryService libraryService,
  required PlaybackSessionService playbackService,
  required TimerService timerService,
  required NotificationCoordinatorService notificationCoordinatorService,
  required SettingsRepository settingsRepository,
  required AppLanguageProvider languageProvider,
  required Widget child,
}) {
  return ProviderScope(
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
        legacy_provider.ChangeNotifierProvider.value(value: languageProvider),
        legacy_provider.ChangeNotifierProvider.value(value: audioProvider),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(const <String, Object>{});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('library tab search filters results and shows empty state copy', (
    WidgetTester tester,
  ) async {
    final handler = PlaybackNotificationHandler();
    final notificationService = PlaybackNotificationService(handler);
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
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

    addTearDown(audioProvider.dispose);

    audioProvider.addTracks(
      [
        _track(
          name: 'Soft Rain',
          path: '/library/rain/soft_rain.mp3',
          groupKey: '/library/rain',
          groupTitle: 'Rain Pack',
        ),
        _track(
          name: 'Ocean Waves',
          path: '/library/rain/ocean_waves.mp3',
          groupKey: '/library/rain',
          groupTitle: 'Rain Pack',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true);

    await tester.pumpWidget(
      _buildTestApp(
        audioProvider: audioProvider,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const LibraryTab(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ocean');
    await tester.pump(const Duration(milliseconds: 260));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Ocean Waves', findRichText: true), findsOneWidget);
    expect(find.text('Soft Rain', findRichText: true), findsNothing);
  });

  testWidgets(
    'library tab shows localized empty state when search has no matches',
    (WidgetTester tester) async {
      final handler = PlaybackNotificationHandler();
      final notificationService = PlaybackNotificationService(handler);
      final audioDatabaseRepository = AudioDatabaseRepository();
      final nativePlaybackRepository = NativePlaybackRepository();
      const playbackCommandRunner = PlaybackCommandRunner();
      final libraryService = LibraryService();
      final playbackService = PlaybackSessionService();
      final timerService = TimerService();
      final notificationCoordinatorService = NotificationCoordinatorService();
      final settingsRepository = SettingsRepository();
      final languageProvider = AppLanguageProvider();
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

      addTearDown(audioProvider.dispose);

      audioProvider.addTracks(
        [
          _track(
            name: 'Soft Rain',
            path: '/library/rain/soft_rain.mp3',
            groupKey: '/library/rain',
            groupTitle: 'Rain Pack',
          ),
        ],
        notify: false,
        persist: false,
      );
      libraryService.syncSlice(isInitialized: true);

      await tester.pumpWidget(
        _buildTestApp(
          audioProvider: audioProvider,
          audioDatabaseRepository: audioDatabaseRepository,
          nativePlaybackRepository: nativePlaybackRepository,
          playbackCommandRunner: playbackCommandRunner,
          libraryService: libraryService,
          playbackService: playbackService,
          timerService: timerService,
          notificationCoordinatorService: notificationCoordinatorService,
          settingsRepository: settingsRepository,
          languageProvider: languageProvider,
          child: const LibraryTab(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'forest');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(languageProvider.tr('no_search_results')),
        findsOneWidget,
      );
    },
  );

  testWidgets('library edit keeps restored content folder visible', (
    WidgetTester tester,
  ) async {
    final handler = PlaybackNotificationHandler();
    final notificationService = PlaybackNotificationService(handler);
    final audioDatabaseRepository = AudioDatabaseRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    const playbackCommandRunner = PlaybackCommandRunner();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final languageProvider = AppLanguageProvider();
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

    addTearDown(audioProvider.dispose);

    const libraryRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR';
    const childFolder = '$libraryRoot/document/primary%3AASMR%2FWorkA';
    const nestedFolder = '$libraryRoot::WorkA/Disc1';
    const trackPath =
        'content://com.android.externalstorage.documents/tree/primary%3AASMR/document/primary%3AASMR%2FWorkA%2FDisc1%2F01.mp3';

    audioProvider.addWatchedLibrary(libraryRoot, notify: false);
    audioProvider.addWatchedFolder(childFolder, notify: false);
    audioProvider.addTracks(
      [
        _track(
          name: '01',
          path: trackPath,
          groupKey: nestedFolder,
          groupTitle: 'Disc1',
        ),
      ],
      notify: false,
      persist: false,
    );
    libraryService.syncSlice(isInitialized: true);

    await tester.pumpWidget(
      _buildTestApp(
        audioProvider: audioProvider,
        audioDatabaseRepository: audioDatabaseRepository,
        nativePlaybackRepository: nativePlaybackRepository,
        playbackCommandRunner: playbackCommandRunner,
        libraryService: libraryService,
        playbackService: playbackService,
        timerService: timerService,
        notificationCoordinatorService: notificationCoordinatorService,
        settingsRepository: settingsRepository,
        languageProvider: languageProvider,
        child: const LibraryEditPage(libraryPath: libraryRoot),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(
      find.text('1 \u9996\u97f3\u9891', findRichText: true),
      findsOneWidget,
    );

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('exclude')).first,
    );
    await tester.pump();

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(find.text(languageProvider.tr('restore')), findsOneWidget);

    await tester.tap(find.text('WorkA', findRichText: true).first);
    await tester.pumpAndSettle();

    expect(find.text('Disc1', findRichText: true), findsOneWidget);

    await tester.tap(
      find.widgetWithText(TextButton, languageProvider.tr('restore')).first,
    );
    await tester.pump();

    expect(find.text('WorkA', findRichText: true), findsOneWidget);
    expect(find.text('1 \u9996\u97f3\u9891', findRichText: true), findsWidgets);

    expect(find.text('Disc1', findRichText: true), findsOneWidget);
    expect(find.text(languageProvider.tr('exclude')), findsWidgets);
  });
}
