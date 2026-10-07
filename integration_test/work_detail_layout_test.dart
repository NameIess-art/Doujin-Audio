import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as mobile_sqlite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/platform/windows_desktop_service.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/library/presentation/dlsite_metadata_review_page.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_page.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';

import '../test/support/app_runtime_test_fixture.dart';
import '../test/support/runtime_test_models.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(UiInteractionCoordinator.instance.idleDelay);
  await tester.pumpAndSettle();
}

Future<void> _waitForOrientation(
  WidgetTester tester,
  Orientation orientation,
) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    final context = tester.element(find.byType(MainScreen));
    if (MediaQuery.orientationOf(context) == orientation) {
      await _settle(tester);
      return;
    }
  }
  fail('The device did not change to $orientation');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real viewport changes preserve the work detail editor', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final database = Platform.isAndroid
        ? await mobile_sqlite.openDatabase(mobile_sqlite.inMemoryDatabasePath)
        : await (() async {
            sqfliteFfiInit();
            return databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
          })();
    await AppDatabase.createSchemaForTest(database);
    AppDatabase.setInstanceForTest(AppDatabase.test(database));

    // Native business calls must not touch the user's existing app state.
    final messenger = binding.defaultBinaryMessenger;
    const businessChannels = [
      AppLifecycleChannel.name,
      NativePlaybackChannel.name,
      NativePlaybackChannel.eventName,
      NotificationsChannel.name,
      PowerChannel.name,
      FileCacheChannel.name,
      FileCacheChannel.scanEvents,
      SubtitleOverlayChannel.name,
    ];
    for (final name in businessChannels) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    final fixture = AppRuntimeWidgetTestFixture(
      configureSettingsRepository: (settings) => settings.showAsmrOne = false,
    );
    fixture.settings.syncSlice(isInitialized: true);
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
    fixture.playbackService.syncSlice(
      activeSessions: const [],
      playingSessionCount: 0,
      focusedSessionId: null,
      coverGeneration: 0,
      isInitialized: true,
    );
    final root = GlobalKey<NavigatorState>();
    final navigation = WorkDetailNavigation(rootNavigatorKey: root);
    try {
      if (Platform.isAndroid) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
        ]);
      }
      await tester.pumpWidget(
        fixture.build(
          WorkDetailNavigationScope(
            navigation: navigation,
            child: MaterialApp(navigatorKey: root, home: const MainScreen()),
          ),
          overrides: [
            settingsStateProvider.overrideWithValue(
              AsyncData(fixture.settings.slice.state),
            ),
            mainOverlayUiProvider.overrideWithValue(
              const MainOverlayUiState(
                overlaySessions: [],
                playingSessionCount: 0,
                hasPlayingAudioSession: false,
                activeSessionCount: 0,
                isInitialized: true,
                startupReady: true,
              ),
            ),
          ],
        ),
      );
      await _waitForOrientation(tester, Orientation.landscape);
      const target = AudioDetailTarget(
        targetType: AudioDetailTargetType.singleAudioFile,
        targetPath: '/layout-test/track.mp3',
      );
      final detail = AudioDetail.empty(target).copyWith(
        workTitle: 'Layout test work',
        duration: const Duration(minutes: 1),
      );
      unawaited(
        navigation.open(
          target,
          (_) => MaterialPageRoute<void>(
            settings: const RouteSettings(name: workDetailRouteName),
            builder: (_) =>
                WorkDetailPage.forLocal(target: target, initialDetail: detail),
          ),
        ),
      );
      await _settle(tester);
      final main = find.byKey(const ValueKey('main_content_region'));
      final pane = find.byKey(const ValueKey('work_detail_pane'));
      expect(
        tester.getSize(main).width,
        closeTo(tester.getSize(pane).width, 1),
      );
      await tester.tap(find.byKey(const ValueKey('work_detail_edit')));
      await _settle(tester);
      final editor = find.byType(DlsiteMetadataReviewPage);
      final initialState = tester.state(editor);
      final title = find.descendant(
        of: find.byKey(const ValueKey('metadata_edit_audio_detail_work_title')),
        matching: find.byType(TextField),
      );
      await tester.enterText(title, 'Unsaved viewport input');
      FocusManager.instance.primaryFocus?.unfocus();
      await _settle(tester);
      final initialWidth = tester.getSize(pane).width;
      if (Platform.isAndroid) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
        await _waitForOrientation(tester, Orientation.portrait);
        expect(
          tester.getSize(pane).width,
          MediaQuery.sizeOf(tester.element(find.byType(MainScreen))).width,
        );
      } else {
        await WindowsDesktopService.instance.setFullscreen(true);
        await _settle(tester);
        expect(tester.getSize(pane).width, isNot(closeTo(initialWidth, 1)));
      }
      expect(tester.state(editor), same(initialState));
      expect(
        tester.widget<TextField>(title).controller!.text,
        'Unsaved viewport input',
      );
      if (Platform.isAndroid) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
        ]);
        await _waitForOrientation(tester, Orientation.landscape);
      } else {
        await WindowsDesktopService.instance.setFullscreen(false);
        await _settle(tester);
      }
      expect(tester.state(editor), same(initialState));
      expect(
        tester.getSize(main).width,
        closeTo(tester.getSize(pane).width, 1),
      );
      navigation.navigatorKey.currentState!.pop();
      await _settle(tester);
      expect(find.byType(WorkDetailPage), findsOneWidget);
      navigation.navigatorKey.currentState!.pop();
      await _settle(tester);
      expect(navigation.isOpen, isFalse);
      if (Platform.isWindows) {
        final track = MusicTrack(
          path: target.targetPath,
          displayName: 'Session layout test',
          groupKey: '',
          groupTitle: '',
          groupSubtitle: '',
          isSingle: true,
          duration: const Duration(minutes: 1),
        );
        fixture.library.addTracks([track], notify: false, persist: false);
        final session = fixture.playback.createTrackSession(track);
        unawaited(
          root.currentState!.push(
            buildSessionDetailRoute(sessionId: session.id),
          ),
        );
        await _settle(tester);
        expect(find.byType(SessionDetailPage), findsOneWidget);
        await WindowsDesktopService.instance.setFullscreen(true);
        await _settle(tester);
        expect(find.byType(SessionDetailPage), findsOneWidget);
        await WindowsDesktopService.instance.setFullscreen(false);
        await _settle(tester);
        root.currentState!.pop();
        await _settle(tester);
        expect(find.byType(SessionDetailPage), findsNothing);
        expect(fixture.playback.sessionById(session.id), same(session));
      }
      expect(tester.takeException(), isNull);
    } finally {
      if (Platform.isAndroid) {
        await SystemChrome.setPreferredOrientations([]);
      } else {
        await WindowsDesktopService.instance.setFullscreen(false);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await fixture.runtimeGraph.runtime.dispose();
      fixture.dispose();
      navigation.dispose();
      for (final name in businessChannels) {
        messenger.setMockMethodCallHandler(MethodChannel(name), null);
      }
      AppDatabase.setInstanceForTest(null);
      await database.close();
    }
  });
}
