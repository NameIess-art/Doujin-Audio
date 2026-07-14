import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/main.dart';
import 'package:nameless_audio/app/state/audio_provider.dart';
import 'package:nameless_audio/app/state/audio_provider_riverpod.dart';
import 'package:nameless_audio/app/presentation/main_screen.dart';
import 'package:nameless_audio/features/player/presentation/playlist_tab.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/features/player/application/audio_state_services.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/playback_command_runner.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:nameless_audio/app/theme/app_design_tokens.dart';
import 'package:nameless_audio/app/theme/theme_provider.dart';
import 'package:nameless_audio/features/player/presentation/active_session_carousel.dart';
import 'package:provider/provider.dart' as legacy_provider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{
      AppPreferences.onboardingCompletedKey: true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(SubtitleOverlayChannel.name),
          (call) async {
            return switch (call.method) {
              SubtitleOverlayMethod.canDrawOverlays => false,
              SubtitleOverlayMethod.openOverlaySettings => false,
              _ => null,
            };
          },
        );
  });

  testWidgets('app shell renders portrait tab navigation', (tester) async {
    final harness = await _pumpAppShell(tester);

    expect(find.byType(MainScreen), findsOneWidget);
    expect(find.text(harness.language.tr('nav_library')), findsWidgets);
    expect(find.text(harness.language.tr('nav_sessions')), findsWidgets);
    expect(find.text(harness.language.tr('nav_settings')), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is PageView &&
            widget.key == const ValueKey<String>('main_page_view'),
      ),
      findsOneWidget,
    );
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

    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    expect(find.byKey(const ValueKey<String>('main_page_fade_3')), findsOne);
    expect(
      find.byKey(const ValueKey<String>('main_page_fade_1')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows settings hides haptic feedback option', (tester) async {
    if (!Platform.isWindows) {
      return;
    }

    final harness = await _pumpAppShell(tester);
    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    expect(
      find.text(harness.language.tr('haptic_feedback_enabled')),
      findsNothing,
    );
  });

  testWidgets('app shell supports Android landscape navigation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(2400, 1080);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
    });
    await _pumpAppShell(tester, includePlaybackSession: false);

    expect(find.byType(NavigationRail), findsOneWidget);
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
      matching: find.byIcon(Icons.tune_outlined),
    );
    expect(settingsNavigationIcon, findsOneWidget);
    expect(tester.widget<Icon>(settingsNavigationIcon).size, isNull);

    final expandedMenuButton = find.descendant(
      of: find.byType(NavigationRail),
      matching: find.byIcon(Icons.menu_open_rounded),
    );
    expect(expandedMenuButton, findsOneWidget);
    expect(tester.getSize(expandedMenuButton), isNot(Size.zero));
    expect(find.byType(ActiveSessionCarousel), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('app shell keeps the active page after orientation changes', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await _pumpAppShell(tester, includePlaybackSession: false);
    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    PageController mainPageController() => tester
        .widget<PageView>(find.byKey(const ValueKey<String>('main_page_view')))
        .controller!;

    expect(mainPageController().page, 3);

    // Reproduce the controller reset observed while Android reattaches the
    // responsive PageView during a configuration change.
    mainPageController().jumpToPage(1);
    await tester.pump();
    expect(mainPageController().page, 1);

    tester.view.physicalSize = const Size(2400, 1080);
    await tester.pump(const Duration(milliseconds: 32));
    await _pumpMainScreenAnimations(tester);

    expect(mainPageController().page, 3);
    expect(find.byKey(const ValueKey<String>('main_page_fade_3')), findsOne);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.podcasts_outlined),
      ),
    );
    await _pumpMainScreenAnimations(tester);
    expect(mainPageController().page, 0);

    mainPageController().jumpToPage(1);
    await tester.pump();
    expect(mainPageController().page, 1);

    tester.view.physicalSize = const Size(1080, 2400);
    await tester.pump(const Duration(milliseconds: 32));
    await _pumpMainScreenAnimations(tester);

    expect(mainPageController().page, 0);
    expect(find.byKey(const ValueKey<String>('main_page_fade_0')), findsOne);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows keeps desktop rail without side menu scrolling', (
    tester,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(550, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await _pumpAppShell(tester, includePlaybackSession: false);

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byType(NavigationRail),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Windows shows a blurred scroll-to-top button away from top', (
    tester,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

    _setLogicalTestViewSize(tester, const Size(1100, 750));
    await _pumpAppShell(tester, includePlaybackSession: false);
    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    final buttonFinder = find.byKey(
      const ValueKey('main_scroll_to_top_button'),
    );
    expect(buttonFinder, findsOneWidget);
    expect(_scrollToTopOpacity(tester), 0);

    await tester.drag(find.byType(ListView).last, const Offset(0, -520));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));

    expect(_scrollToTopOpacity(tester), 1);
    expect(
      find.ancestor(
        of: buttonFinder,
        matching: find.byKey(const ValueKey('main_scroll_to_top_blur')),
      ),
      findsOneWidget,
    );

    await tester.tap(buttonFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(_scrollToTopOpacity(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app shell handles keyboard and dynamic portrait sizes', (
    tester,
  ) async {
    if (Platform.isWindows) {
      return;
    }

    await _pumpAppShell(tester);
    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    PageView mainPageView() => tester
        .widgetList<PageView>(find.byType(PageView))
        .firstWhere(
          (widget) => widget.key == const ValueKey<String>('main_page_view'),
        );

    expect(mainPageView().controller!.page, 3);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    tester.view.physicalSize = const Size(1080, 1800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetViewInsets();
    });
    await tester.pump(const Duration(milliseconds: 32));

    expect(mainPageView().controller!.page, 3);
    expect(find.byType(ActiveSessionCarousel), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1080, 2400);
    await _pumpMainScreenAnimations(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ASMR playback errors show retry subtitle and play icon', (
    tester,
  ) async {
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
    const track = MusicTrack(
      path: 'https://asmr.one/media/work/track.mp3',
      displayName: 'ASMR remote track',
      groupKey: 'RJ123456',
      groupTitle: 'ASMR work',
      groupSubtitle: 'ASMR work',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
    );
    final session = PlaybackSession(
      id: 'asmr_error_session',
      currentTrackPath: track.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.idle),
    )..playbackError = 'network failed';
    addTearDown(audioProvider.dispose);
    addTearDown(session.dispose);
    audioProvider.addTracks([track], notify: false, persist: false);
    playbackService.registerSession(session);
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
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: ActiveSessionCarousel(
                  sessions: [session],
                  provider: audioProvider,
                  onOpenSession: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text(languageProvider.tr('asmr_playback_network_failed_retry')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('bottom dock blur remains active during UI interaction', (
    tester,
  ) async {
    if (Platform.isWindows) {
      return;
    }

    tester.view.physicalSize = const Size(1080, 2400);
    addTearDown(tester.view.resetPhysicalSize);
    await _pumpAppShell(tester);
    final interactionSource = Object();
    addTearDown(
      () => UiInteractionCoordinator.instance.cancelInteraction(
        interactionSource,
      ),
    );

    expect(
      find.byKey(const ValueKey('floating_glass_panel_blur')),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey('active_session_blur_orientation_session')),
      findsOne,
    );

    UiInteractionCoordinator.instance.beginInteraction(interactionSource);
    await tester.pump();

    expect(
      find.byKey(const ValueKey('floating_glass_panel_blur')),
      findsWidgets,
    );
    expect(
      find.byKey(const ValueKey('active_session_blur_orientation_session')),
      findsOne,
    );
  });

  testWidgets('ASMR session detail uses ASMR accent theme', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(
      tester,
      Platform.isWindows ? const Size(1100, 750) : const Size(1080, 2400),
    );
    const track = MusicTrack(
      path: 'https://asmr.one/media/work/detail-track.mp3',
      displayName: 'ASMR detail track',
      groupKey: 'asmr-work-123456',
      groupTitle: 'ASMR detail work',
      groupSubtitle: 'RJ123456',
      isSingle: false,
      remoteMetadataKind: 'asmr.one',
    );
    await _pumpAppShell(tester, playbackTrack: track);
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
    );
    await tester.pumpAndSettle();

    final detailThemeContext = tester.element(
      find.byKey(const ValueKey('session_detail_background_blur')),
    );
    final expectedAccent =
        Theme.of(detailThemeContext).brightness == Brightness.dark
        ? AppDesignTokens.dark.asmrAccent
        : AppDesignTokens.light.asmrAccent;
    expect(Theme.of(detailThemeContext).colorScheme.primary, expectedAccent);
    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('Windows session detail exposes a window drag region', (
    tester,
  ) async {
    if (!Platform.isWindows) {
      return;
    }

    _setLogicalTestViewSize(tester, const Size(1100, 750));
    await _pumpAppShell(tester);
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
    );
    await tester.pumpAndSettle();

    final dragRegion = tester.widget<GestureDetector>(
      find.byKey(const ValueKey('session_detail_window_drag_region')),
    );
    expect(dragRegion.onPanStart, isNotNull);
    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'session detail keeps route revealed through a rapid drag reversal',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = previousPlatform;
      });
      expect(defaultTargetPlatform, TargetPlatform.android);
      _setLogicalTestViewSize(
        tester,
        Platform.isWindows ? const Size(1100, 750) : const Size(1080, 2400),
      );
      await _pumpAppShell(tester);
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final detailFinder = find.byType(SessionDetailPage);
      expect(detailFinder, findsOne);
      final detailContext = tester.element(detailFinder);
      final detailRoute = ModalRoute.of(detailContext)!;
      expect(detailRoute.opaque, isTrue);
      expect(
        find.byKey(const ValueKey('session_detail_background_blur')),
        findsOne,
      );

      final dismissGestureFinder = find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector && widget.onVerticalDragUpdate != null,
      );
      expect(dismissGestureFinder, findsOne);
      final dismissGesture = tester.widget<GestureDetector>(
        dismissGestureFinder,
      );
      dismissGesture.onVerticalDragStart!(DragStartDetails());
      dismissGesture.onVerticalDragUpdate!(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: const Offset(0, 48),
          primaryDelta: 48,
        ),
      );
      dismissGesture.onVerticalDragUpdate!(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: const Offset(0, 48),
          primaryDelta: 48,
        ),
      );
      await tester.pump();

      expect(detailRoute.opaque, isFalse);
      expect(
        find.byKey(const ValueKey('session_detail_background_blur')),
        findsOne,
      );

      dismissGesture.onVerticalDragUpdate!(
        DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: const Offset(0, -48),
          primaryDelta: -48,
        ),
      );
      await tester.pump();

      expect(detailRoute.opaque, isFalse);
      expect(
        find.byKey(const ValueKey('session_detail_background_blur')),
        findsOne,
      );

      dismissGesture.onVerticalDragEnd!(DragEndDetails(primaryVelocity: 0));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = previousPlatform;

      expect(detailFinder, findsOne);
      expect(detailRoute.opaque, isTrue);
      expect(tester.takeException(), isNull);
      await _settleSessionDetailAsyncWork(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('session detail loop and volume capsules share geometry', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(
      tester,
      Platform.isWindows ? const Size(1100, 750) : const Size(1080, 2400),
    );
    await _pumpAppShell(tester);
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('session_loop_button_anchor')));
    await tester.pump(const Duration(milliseconds: 400));
    final loopCapsule = find.byKey(const ValueKey('session_loop_capsule'));
    expect(loopCapsule, findsOne);
    final loopSize = tester.getSize(loopCapsule);
    final loopBottom = tester.getBottomLeft(loopCapsule).dy;

    await tester.tapAt(const Offset(2, 2));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey('session_volume_button_anchor')),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final volumeCapsule = find.byKey(const ValueKey('session_volume_capsule'));
    expect(volumeCapsule, findsOne);

    expect(tester.getSize(volumeCapsule), loopSize);
    expect(tester.getBottomLeft(volumeCapsule).dy, closeTo(loopBottom, 2.5));
    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('session detail dismisses after dragging past one third', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(
      tester,
      Platform.isWindows ? const Size(1100, 750) : const Size(1080, 2400),
    );
    await _pumpAppShell(tester);
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
    );
    await tester.pumpAndSettle();

    final detailFinder = find.byType(SessionDetailPage);
    expect(detailFinder, findsOne);
    final dismissGesture = tester.widget<GestureDetector>(
      find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector && widget.onVerticalDragUpdate != null,
      ),
    );
    final logicalHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final dismissDelta = logicalHeight / 3 + 1;
    dismissGesture.onVerticalDragStart!(DragStartDetails());
    dismissGesture.onVerticalDragUpdate!(
      DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: Offset(0, dismissDelta),
        primaryDelta: dismissDelta,
      ),
    );
    dismissGesture.onVerticalDragEnd!(DragEndDetails(primaryVelocity: 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    expect(detailFinder, findsNothing);
    expect(tester.takeException(), isNull);
    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
  });
}

final class _AppShellHarness {
  const _AppShellHarness({required this.language});

  final AppLanguageProvider language;
}

void _setLogicalTestViewSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

double _scrollToTopOpacity(WidgetTester tester) {
  final opacity = tester.widget<AnimatedOpacity>(
    find.byKey(const ValueKey('main_scroll_to_top_opacity')),
  );
  return opacity.opacity;
}

Future<_AppShellHarness> _pumpAppShell(
  WidgetTester tester, {
  bool includePlaybackSession = true,
  MusicTrack? playbackTrack,
}) async {
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
  settingsRepository.syncSlice(isInitialized: true);
  libraryService.syncSlice(isInitialized: true, detailRevision: 0);
  if (includePlaybackSession) {
    if (playbackTrack != null) {
      audioProvider.addTracks([playbackTrack], notify: false, persist: false);
    }
    final session = PlaybackSession(
      id: 'orientation_session',
      currentTrackPath: playbackTrack?.path ?? '/audio/orientation.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(session.dispose);
    playbackService.registerSession(session);
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
  }

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
          legacy_provider.ChangeNotifierProvider.value(value: languageProvider),
          legacy_provider.ChangeNotifierProvider.value(value: audioProvider),
        ],
        child: const MusicPlayerApp(),
      ),
    ),
  );
  await _pumpMainScreenAnimations(tester, startup: true);
  return _AppShellHarness(language: languageProvider);
}

Future<void> _pumpMainScreenAnimations(
  WidgetTester tester, {
  bool startup = false,
}) async {
  await tester.pump();
  if (startup) {
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
  } else {
    await tester.pump(const Duration(milliseconds: 180));
  }
  await tester.pump();
}

Future<void> _settleSessionDetailAsyncWork(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump(const Duration(milliseconds: 120));
}

Future<void> _tapSettingsDestination(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.tune_outlined).last);
}
