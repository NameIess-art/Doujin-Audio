import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nameless_audio/app/localization/app_language_provider.dart';
import 'package:nameless_audio/main.dart';
import 'support/runtime_test_models.dart';
import 'package:nameless_audio/app/state/app_runtime_providers.dart';
import 'package:nameless_audio/app/presentation/main_screen.dart';
import 'package:nameless_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:nameless_audio/features/asmr/application/asmr_preferences.dart';
import 'package:nameless_audio/features/asmr/domain/asmr_models.dart';
import 'package:nameless_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:nameless_audio/features/player/presentation/playlist_tab.dart';
import 'package:nameless_audio/features/settings/application/app_preferences.dart';
import 'package:nameless_audio/features/settings/application/app_update_service.dart';
import 'package:nameless_audio/core/persistence/audio_database_repository.dart';
import 'package:nameless_audio/core/persistence/app_database.dart';
import 'package:nameless_audio/features/library/application/library_service.dart';
import 'package:nameless_audio/features/settings/application/settings_repository.dart';
import 'package:nameless_audio/features/player/application/native_playback_repository.dart';
import 'package:nameless_audio/features/player/application/playback_notification_service.dart';
import 'package:nameless_audio/core/platform/platform_channels.dart';
import 'package:nameless_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:nameless_audio/core/widgets/async_cover_image.dart';
import 'package:nameless_audio/core/widgets/library_like_cards.dart';
import 'package:nameless_audio/core/widgets/marquee_text.dart';
import 'package:nameless_audio/app/theme/app_design_tokens.dart';
import 'package:nameless_audio/app/theme/theme_provider.dart';
import 'package:nameless_audio/features/player/presentation/active_session_carousel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/app_runtime_test_fixture.dart';

List<Override> _testRuntimeOverrides(AppRuntimeGraph graph) {
  return createAppRuntimeOverrides(
    persistence: graph.persistence,
    runtime: graph.runtime,
    warmup: graph.warmup,
    playbackCommands: graph.playbackCommands,
    keepAlive: graph.keepAlive,
    library: graph.library,
    playback: graph.playback,
    subtitles: graph.subtitles,
    timer: graph.timer,
    notifications: graph.notifications,
    settings: graph.settings,
  );
}

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

  testWidgets('ASMR initial shell keeps category and search controls visible', (
    tester,
  ) async {
    final harness = await _pumpAppShell(tester, includePlaybackSession: false);

    await _tapAsmrDestination(tester);
    await _pumpMainScreenAnimations(tester);

    expect(
      find.text(harness.language.tr('asmr_category_collected')),
      findsOneWidget,
    );
    expect(find.text(harness.language.tr('loading_dot')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(LibraryLikeSkeletonCard), findsWidgets);
    expect(find.text(harness.language.tr('asmr_empty_category')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ASMR queued empty category shows skeleton until empty is confirmed',
    (tester) async {
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.resetForTest();
      final controller = _QueuedEmptyAsmrLibraryController();
      addTearDown(controller.dispose);
      addTearDown(coordinator.resetForTest);
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(
          const AsmrTab(),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();

      final recommendationLabel = harness.languageProvider.tr(
        'asmr_category_recommendation',
      );
      await tester.tap(find.text(recommendationLabel));
      await tester.pump();

      final recommendationList = find.byKey(
        const ValueKey(AsmrCategoryType.recommendation),
      );
      expect(recommendationList, findsOneWidget);
      final recommendationSkeletons = find.descendant(
        of: recommendationList,
        matching: find.byType(LibraryLikeSkeletonCard),
      );
      final recommendationEmptyState = find.descendant(
        of: recommendationList,
        matching: find.text(harness.languageProvider.tr('asmr_empty_category')),
      );
      expect(controller.recommendationRefreshCount, 0);
      expect(recommendationSkeletons, findsWidgets);
      expect(recommendationEmptyState, findsNothing);

      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(controller.recommendationRefreshCount, 1);
      expect(recommendationSkeletons, findsWidgets);
      expect(recommendationEmptyState, findsNothing);

      controller.completeRecommendationRefresh();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));

      expect(recommendationEmptyState, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('startup overlay stays for 1.5 seconds while pages initialize', (
    tester,
  ) async {
    await _pumpAppShell(tester, waitForStartup: false);
    await tester.pump();

    const overlayKey = ValueKey<String>('main_bootstrap_overlay');
    expect(find.byKey(overlayKey), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('main_page_view')),
      findsOneWidget,
    );
    expect(kBootstrapOverlayDuration, const Duration(milliseconds: 1500));

    const entranceDuration = Duration(milliseconds: 750);
    await tester.pump(entranceDuration);
    await tester.pump();
    await tester.pump(
      kBootstrapOverlayDuration -
          entranceDuration -
          const Duration(milliseconds: 1),
    );
    expect(find.byKey(overlayKey), findsOneWidget);

    for (
      var frame = 0;
      frame < 60 && find.byKey(overlayKey).evaluate().isNotEmpty;
      frame++
    ) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(overlayKey), findsNothing);
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

  testWidgets('app shell handles keyboard and dynamic portrait sizes', (
    tester,
  ) async {
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
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final runtimeGraph = createTestRuntimeGraph(
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
    addTearDown(() => unawaited(runtimeGraph.runtime.dispose()));
    addTearDown(session.dispose);
    runtimeGraph.library.addTracks([track], notify: false, persist: false);
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
        overrides: [
          ..._testRuntimeOverrides(runtimeGraph),
          themeProviderInstanceProvider.overrideWithValue(themeProvider),
          appLanguageProviderInstanceProvider.overrideWithValue(
            languageProvider,
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: ActiveSessionCarousel(
                sessions: [session],
                onOpenSession: (_) {},
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
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
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
    final backgroundCover = tester.widget<AsyncCoverImage>(
      find.descendant(
        of: find.byKey(const ValueKey('session_detail_background_blur')),
        matching: find.byType(AsyncCoverImage),
      ),
    );
    final artworkCover = tester.widget<AsyncLocalCoverImage>(
      find.descendant(
        of: find.byType(SessionDetailPage),
        matching: find.byType(AsyncLocalCoverImage),
      ),
    );
    final expectedAccent =
        Theme.of(detailThemeContext).brightness == Brightness.dark
        ? AppDesignTokens.dark.asmrAccent
        : AppDesignTokens.light.asmrAccent;
    expect(Theme.of(detailThemeContext).colorScheme.primary, expectedAccent);
    expect(backgroundCover.duration, kCoverImageFadeDuration);
    expect(backgroundCover.deferCommitDuringInteraction, isTrue);
    expect(artworkCover.duration, kCoverImageFadeDuration);
    expect(artworkCover.deferCommitDuringInteraction, isTrue);
    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('light session detail uses layered foreground colors', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
    const track = MusicTrack(
      path: 'https://asmr.one/media/work/color-hierarchy.mp3',
      displayName: 'Color hierarchy track',
      groupKey: 'asmr-color-hierarchy',
      groupTitle: 'Color hierarchy work',
      groupSubtitle: 'RJ000001',
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

    final detail = find.byType(SessionDetailPage);
    final detailContext = tester.element(
      find.byKey(const ValueKey('session_detail_background_blur')),
    );
    final scheme = Theme.of(detailContext).colorScheme;
    expect(scheme.brightness, Brightness.light);

    final detailMarquees = tester.widgetList<MarqueeText>(
      find.descendant(of: detail, matching: find.byType(MarqueeText)),
    );
    final titleColor = detailMarquees
        .singleWhere((widget) => widget.text == 'Color hierarchy track')
        .style!
        .color!;
    final supportingColor = detailMarquees
        .firstWhere((widget) => widget.text != 'Color hierarchy track')
        .style!
        .color!;
    final closeColor = tester
        .widget<Icon>(
          find.descendant(
            of: detail,
            matching: find.byIcon(Icons.keyboard_arrow_down_rounded),
          ),
        )
        .color!;
    final forwardColor = tester
        .widget<Icon>(
          find.descendant(
            of: detail,
            matching: find.byIcon(Icons.forward_5_rounded),
          ),
        )
        .color!;
    final timeColor = tester
        .widgetList<Text>(
          find.descendant(of: detail, matching: find.byType(Text)),
        )
        .firstWhere((widget) => widget.style?.fontFeatures?.isNotEmpty ?? false)
        .style!
        .color!;
    final timerButton = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.descendant(
              of: detail,
              matching: find.byIcon(Icons.alarm_rounded),
            ),
            matching: find.byType(IconButton),
          )
          .first,
    );
    final secondaryColor = timerButton.style!.foregroundColor!.resolve({})!;

    expect(titleColor, isNot(Colors.black));
    expect(titleColor, isNot(scheme.onSurface));
    expect(titleColor.a, 1.0);
    expect(supportingColor, isNot(titleColor));
    expect(supportingColor.a, 1.0);
    expect(forwardColor, supportingColor);
    expect(closeColor, isNot(supportingColor));
    expect(closeColor.a, lessThan(1.0));
    expect(timeColor, closeColor);
    expect(secondaryColor, closeColor);

    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
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
      _setLogicalTestViewSize(tester, const Size(1080, 2400));
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
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
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
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
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
    await tester.pumpAndSettle();
    await _settleSessionDetailAsyncWork(tester);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
  });
}

final class _AppShellHarness {
  const _AppShellHarness({required this.language});

  final AppLanguageProvider language;
}

final class _AppShellAudioDatabaseRepository extends AudioDatabaseRepository {
  @override
  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) async {
    return const <TimeSegmentLabel>[];
  }
}

final class _QueuedEmptyAsmrLibraryController extends AsmrLibraryController {
  _QueuedEmptyAsmrLibraryController()
    : super(
        preferencesStore: AsmrPreferencesStore(database: AppDatabase.instance),
      );

  final Completer<void> _recommendationRefresh = Completer<void>();
  bool _recommendationLoading = false;
  int _revision = 0;
  int recommendationRefreshCount = 0;

  static const AsmrWork _collectedWork = AsmrWork(
    id: 1,
    title: 'Loaded work',
    circleName: 'Circle',
    sourceId: 'RJ000001',
    sourceType: 'DLSITE',
    sourceUrl: '',
    coverUrl: '',
    thumbnailUrl: '',
    mainCoverUrl: '',
    releaseDate: null,
    createDate: null,
    duration: Duration.zero,
    dlCount: 0,
    reviewCount: 0,
    rating: 0,
    voiceActors: <String>[],
    tags: <String>[],
  );

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {
    scheduleMicrotask(notifyListeners);
  }

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

  @override
  AsmrLibraryGlobalViewState get globalViewState =>
      const AsmrLibraryGlobalViewState(
        initialized: true,
        lastError: null,
        visibleCategories: kDefaultVisibleAsmrCategories,
        contentLanguage: AsmrContentLanguage.zh,
        contentLanguagePreference: ContentLanguagePreference.followPage,
        revision: 0,
      );

  @override
  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      category == AsmrCategoryType.collected
      ? const <AsmrWork>[_collectedWork]
      : const <AsmrWork>[];

  @override
  int totalCountFor(AsmrCategoryType category) => worksFor(category).length;

  @override
  String activeQueryFor(AsmrCategoryType category) => '';

  @override
  AsmrCategoryViewState categoryViewState(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) {
    final works = worksFor(category);
    final isLoading =
        category == AsmrCategoryType.recommendation && _recommendationLoading;
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: isLoading,
      isLoadingMore: false,
      isRefreshing: isLoading && works.isNotEmpty,
      isStale: isLoading && works.isNotEmpty,
      hasAttemptedLoad: true,
      hasMore: false,
      totalCount: works.length,
      activeQuery: searchQuery,
      lastError: null,
      operationError: null,
      revision: _revision,
    );
  }

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    if (category != AsmrCategoryType.recommendation) return;
    recommendationRefreshCount++;
    _recommendationLoading = true;
    notifyListeners();
    await _recommendationRefresh.future;
    _recommendationLoading = false;
    _revision++;
    notifyListeners();
  }

  void completeRecommendationRefresh() {
    if (!_recommendationRefresh.isCompleted) {
      _recommendationRefresh.complete();
    }
  }
}

void _setLogicalTestViewSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
}

Future<_AppShellHarness> _pumpAppShell(
  WidgetTester tester, {
  bool includePlaybackSession = true,
  MusicTrack? playbackTrack,
  bool waitForStartup = true,
}) async {
  final themeProvider = ThemeProvider();
  final languageProvider = AppLanguageProvider();
  final notificationService = PlaybackNotificationService();
  final audioDatabaseRepository = _AppShellAudioDatabaseRepository();
  final nativePlaybackRepository = NativePlaybackRepository();
  final libraryService = LibraryService();
  final playbackService = PlaybackSessionService();
  final timerService = TimerService();
  final notificationCoordinatorService = NotificationCoordinatorService();
  final settingsRepository = SettingsRepository();
  final runtimeGraph = createTestRuntimeGraph(
    notificationService: notificationService,
    audioDatabaseRepository: audioDatabaseRepository,
    nativePlaybackRepository: nativePlaybackRepository,
    libraryService: libraryService,
    playbackService: playbackService,
    timerService: timerService,
    notificationStateService: notificationCoordinatorService,
    settingsRepository: settingsRepository,
  );
  addTearDown(() => unawaited(runtimeGraph.runtime.dispose()));
  settingsRepository.syncSlice(isInitialized: true);
  libraryService.syncSlice(isInitialized: true, detailRevision: 0);
  if (includePlaybackSession) {
    if (playbackTrack != null) {
      runtimeGraph.library.addTracks(
        [playbackTrack],
        notify: false,
        persist: false,
      );
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
      overrides: [
        ..._testRuntimeOverrides(runtimeGraph),
        themeProviderInstanceProvider.overrideWithValue(themeProvider),
        appLanguageProviderInstanceProvider.overrideWithValue(languageProvider),
        appUpdateServiceProvider.overrideWithValue(AppUpdateService()),
      ],
      child: const MusicPlayerApp(),
    ),
  );
  if (waitForStartup) {
    await _pumpMainScreenAnimations(tester, startup: true);
    await _waitForAppBootstrap(tester);
  }
  return _AppShellHarness(language: languageProvider);
}

Future<void> _waitForAppBootstrap(WidgetTester tester) async {
  final overlay = find.byKey(const ValueKey<String>('main_bootstrap_overlay'));
  for (
    var attempt = 0;
    attempt < 20 && overlay.evaluate().isNotEmpty;
    attempt++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
  expect(overlay, findsNothing, reason: 'App bootstrap did not complete.');
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
  final navigationRail = find.byType(NavigationRail);
  if (navigationRail.evaluate().isNotEmpty) {
    tester
        .widget<NavigationRail>(navigationRail)
        .onDestinationSelected!
        .call(3);
  } else {
    final destination = find.byKey(
      const ValueKey<String>('main_destination_nav_settings'),
    );
    tester
        .widget<InkResponse>(
          find.descendant(of: destination, matching: find.byType(InkResponse)),
        )
        .onTap!
        .call();
  }
  await _waitForMainPage(tester, 3);
}

Future<void> _tapAsmrDestination(WidgetTester tester) async {
  final navigationRail = find.byType(NavigationRail);
  if (navigationRail.evaluate().isNotEmpty) {
    tester
        .widget<NavigationRail>(navigationRail)
        .onDestinationSelected!
        .call(0);
  } else {
    final destination = find.byKey(
      const ValueKey<String>('main_destination_ASMR.ONE'),
    );
    tester
        .widget<InkResponse>(
          find.descendant(of: destination, matching: find.byType(InkResponse)),
        )
        .onTap!
        .call();
  }
  await _waitForMainPage(tester, 0);
}

Future<void> _waitForMainPage(WidgetTester tester, int targetPage) async {
  final pageViewFinder = find.byKey(const ValueKey<String>('main_page_view'));
  for (var frame = 0; frame < 30; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    final controller = tester.widget<PageView>(pageViewFinder).controller!;
    if (controller.hasClients &&
        ((controller.page ?? controller.initialPage) - targetPage).abs() <
            0.001) {
      return;
    }
  }
  final controller = tester.widget<PageView>(pageViewFinder).controller!;
  fail(
    'Main PageController did not reach page $targetPage; '
    'current page: ${controller.page}.',
  );
}
