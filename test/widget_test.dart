import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderScope;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/main.dart';
import 'support/runtime_test_models.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/features/asmr/application/asmr_download_manager.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/application/asmr_preferences.dart';
import 'package:doujin_audio/infrastructure/sqlite/sqlite_asmr_repository.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_download_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/library/presentation/library_cover_ui_controller.dart';
import 'package:doujin_audio/features/library/presentation/library_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist_tab.dart';
import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/settings/application/app_preferences.dart';
import 'package:doujin_audio/features/settings/application/app_update_service.dart';
import 'support/test_persistence_repository.dart';
import 'package:doujin_audio/core/persistence/app_database.dart';
import 'package:doujin_audio/features/library/application/library_service.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/player/application/native_playback_repository.dart';
import 'package:doujin_audio/features/player/application/playback_notification_service.dart';
import 'package:doujin_audio/features/player/domain/playback_persistence_repository.dart';
import 'package:doujin_audio/core/platform/platform_channels.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/ui_operation_service.dart';
import 'package:doujin_audio/core/ui/warmup_scheduler.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/glass_refresh_indicator.dart';
import 'package:doujin_audio/core/widgets/library_like_cards.dart';
import 'package:doujin_audio/core/widgets/marquee_text.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/app_edge_fade_mask.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/app/theme/app_styles.dart';
import 'package:doujin_audio/app/theme/theme_provider.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
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
    UiInteractionCoordinator.instance.resetForTest();
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

  tearDown(UiInteractionCoordinator.instance.resetForTest);

  testWidgets('app shell renders portrait tab navigation', (tester) async {
    final platformCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final harness = await _pumpAppShell(tester);

    expect(find.byType(MainScreen), findsOneWidget);
    expect(find.text(harness.language.tr('nav_library')), findsWidgets);
    expect(find.text(harness.language.tr('nav_sessions')), findsWidgets);
    expect(find.text(harness.language.tr('nav_settings')), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppFadeThroughIndexedStack &&
            widget.key == const ValueKey<String>('main_page_stack'),
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
    final settingsDestination = find.byKey(
      const ValueKey<String>('main_destination_nav_settings'),
    );
    expect(
      tester
          .widgetList<Theme>(
            find.ancestor(
              of: settingsDestination,
              matching: find.byType(Theme),
            ),
          )
          .any((theme) => theme.data.splashFactory == NoSplash.splashFactory),
      isTrue,
    );
    platformCalls.clear();
    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    expect(find.byKey(const ValueKey<String>('main_page_fade_3')), findsOne);
    final settingsCanvas = tester.widget<ColoredBox>(
      find.byKey(const ValueKey<String>('main_page_canvas_3')),
    );
    expect(settingsCanvas.color, isNot(Colors.transparent));
    expect(
      find.byKey(const ValueKey<String>('main_page_fade_1')),
      findsNothing,
    );
    expect(
      platformCalls.where((call) => call.method == 'HapticFeedback.vibrate'),
      isEmpty,
    );

    final mainPageStack = find.byKey(const ValueKey<String>('main_page_stack'));
    await tester.drag(mainPageStack, const Offset(600, 0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<AppFadeThroughIndexedStack>(mainPageStack).index, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app lifecycle disposes downloads only when detached', (
    tester,
  ) async {
    final downloads = _TrackingAsmrDownloadManager();
    await _pumpAppShell(tester, downloads: downloads);

    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.paused,
    );
    await tester.pump();

    expect(downloads.pauseAllCalls, 0);

    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.detached,
    );
    await tester.runAsync(
      () => downloads.paused.timeout(const Duration(seconds: 2)),
    );

    expect(downloads.pauseAllCalls, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  testWidgets(
    'capsule dock aligns playback card with the menu and exposes full width',
    (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(1080, 2400);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      await _pumpAppShell(tester);

      final destinationInkResponse = tester.widget<InkResponse>(
        find.byKey(const ValueKey<String>('main_destination_ink_nav_settings')),
      );
      expect(destinationInkResponse.highlightColor, Colors.transparent);
      expect(destinationInkResponse.splashColor, Colors.transparent);
      final bottomCapsule = tester.widget<FractionallySizedBox>(
        find.byKey(const ValueKey<String>('mobile_bottom_capsule_panel')),
      );
      expect(bottomCapsule.widthFactor, 0.96);
      final fadeMaskFinder = find.byKey(
        const ValueKey<String>('mobile_bottom_capsule_fade_mask'),
      );
      final fadeMask = tester.widget<AppEdgeFadeMask>(fadeMaskFinder);
      expect(fadeMask.direction, AppEdgeFadeDirection.towardBottom);
      final fadeMaskDecoration = tester.widget<DecoratedBox>(
        find.descendant(
          of: fadeMaskFinder,
          matching: find.byType(DecoratedBox),
        ),
      );
      final fadeGradient =
          (fadeMaskDecoration.decoration as BoxDecoration).gradient!
              as LinearGradient;
      final maskTheme = Theme.of(tester.element(fadeMaskFinder));
      expect(fadeGradient.stops, const <double>[0.0, 0.18, 0.42, 0.65, 1.0]);
      expect(fadeGradient.colors.first.a, 0);
      expect(
        fadeGradient.colors.last.a,
        maskTheme.brightness == Brightness.dark ? 0.86 : 0.82,
      );
      expect(
        tester.getSize(fadeMaskFinder).height,
        112 + MediaQuery.paddingOf(tester.element(fadeMaskFinder)).bottom,
      );
      expect(
        tester
            .widget<IgnorePointer>(
              find.descendant(
                of: fadeMaskFinder,
                matching: find.byType(IgnorePointer),
              ),
            )
            .ignoring,
        isTrue,
      );
      final playbackCarouselPageView = tester.widget<PageView>(
        find.descendant(
          of: find.byType(ActiveSessionCarousel),
          matching: find.byType(PageView),
        ),
      );
      final playbackCard = find.byKey(
        const ValueKey<String>('active_session_card_orientation_session'),
      );
      final menuPanel = find.byKey(
        const ValueKey<String>('mobile_bottom_capsule_panel'),
      );
      final expectedMenuWidth = (360.0 - AppSpacing.sm * 2).clamp(0.0, 430.0);
      final expectedCardWidth = expectedMenuWidth * 0.96;
      final expectedViewportFraction = ((expectedCardWidth + 4) / 360.0).clamp(
        0.1,
        1.0,
      );
      expect(
        playbackCarouselPageView.controller!.viewportFraction,
        closeTo(expectedViewportFraction, 0.001),
      );
      expect(
        tester.getSize(playbackCard).width,
        closeTo(expectedCardWidth, 0.1),
      );
      expect(
        tester.getSize(menuPanel).width,
        closeTo(expectedMenuWidth * 0.96, 0.1),
      );
      expect(tester.getTopLeft(find.byType(PageView)).dx, 0);
      expect(
        tester.getTopRight(find.byType(PageView)).dx,
        closeTo(
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
          0.1,
        ),
      );
    },
  );

  testWidgets(
    'capsule dock reduces bottom fade mask height when playback card is hidden',
    (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = const Size(1080, 2400);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      await _pumpAppShell(tester, includePlaybackSession: false);

      final fadeMaskFinder = find.byKey(
        const ValueKey<String>('mobile_bottom_capsule_fade_mask'),
      );
      expect(
        tester.getSize(fadeMaskFinder).height,
        54 + MediaQuery.paddingOf(tester.element(fadeMaskFinder)).bottom,
      );
    },
  );

  testWidgets('production app shell allows tooltips to become visible', (
    tester,
  ) async {
    await _pumpAppShell(tester);

    expect(find.byType(TooltipVisibility), findsNothing);
    final tooltipFinder = find.byWidgetPredicate(
      (widget) => widget is Tooltip && widget.message?.isNotEmpty == true,
    );
    expect(tooltipFinder, findsWidgets);
    final target = tooltipFinder.first;
    final message = tester.widget<Tooltip>(target).message!;
    final originalTextCount = find.text(message).evaluate().length;

    await tester.longPress(target);
    await tester.pump();

    expect(
      find.text(message).evaluate().length,
      greaterThan(originalTextCount),
    );

    await tester.pump(const Duration(seconds: 3));
    expect(find.text(message).evaluate().length, originalTextCount);
  });

  testWidgets('update download progress stays visible at the top of the app', (
    tester,
  ) async {
    final operations = UiOperationService.instance;
    operations.clear(UiOperationScope.settingsUpdate);
    addTearDown(() => operations.clear(UiOperationScope.settingsUpdate));
    final harness = await _pumpAppShell(tester);
    final pending = Completer<void>();

    final download = operations.run<void>(
      scope: UiOperationScope.settingsUpdate,
      labelKey: 'downloading_update',
      task: (progress) {
        progress.report(0.37);
        return pending.future;
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.text(harness.language.tr('downloading_update', {'percent': '37'})),
      findsOneWidget,
    );
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, 0.37);
    final positioned = tester.widget<Positioned>(
      find.ancestor(
        of: find.byType(LinearProgressIndicator),
        matching: find.byType(Positioned),
      ),
    );
    expect(
      positioned.top,
      MediaQuery.paddingOf(tester.element(find.byType(MainScreen))).top + 8,
    );

    pending.complete();
    await download;
    await tester.pump();
  });

  testWidgets('update download errors use a generic message', (tester) async {
    final operations = UiOperationService.instance;
    operations.clear(UiOperationScope.settingsUpdate);
    addTearDown(() => operations.clear(UiOperationScope.settingsUpdate));
    final harness = await _pumpAppShell(tester);
    const privateDetail = 'private path /token=secret';

    final failure = operations.run<void>(
      scope: UiOperationScope.settingsUpdate,
      labelKey: 'downloading_update',
      task: (_) async => throw StateError(privateDetail),
    );
    await expectLater(failure, throwsA(isA<StateError>()));
    await tester.pump();

    expect(
      find.text(harness.language.tr('update_download_failed_next_step')),
      findsOneWidget,
    );
    expect(find.textContaining(privateDetail), findsNothing);
  });

  testWidgets('ASMR main page moves category and search controls to search', (
    tester,
  ) async {
    final harness = await _pumpAppShell(tester, includePlaybackSession: false);

    await _swipeToAsmrPage(tester);
    await _waitForMainPage(tester, 0);
    await tester.pump(const Duration(seconds: 4));

    expect(
      find.text(harness.language.tr('asmr_category_collected')),
      findsOneWidget,
    );
    expect(
      find.text(harness.language.tr('asmr_category_recommendation')),
      findsOneWidget,
    );
    expect(
      find.text(harness.language.tr('asmr_category_favorites')),
      findsOneWidget,
    );
    expect(
      find.text(harness.language.tr('asmr_category_history')),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('asmr_search_button')),
      findsOneWidget,
    );
    expect(find.byType(LibraryLikeSkeletonCard), findsWidgets);
    expect(find.text(harness.language.tr('asmr_empty_category')), findsNothing);

    await tester.pump(const Duration(seconds: 4));
    await tester.tap(find.byKey(const ValueKey<String>('asmr_search_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 200));

    expect(
      find.byKey(const ValueKey<String>('app_search_field')),
      findsOneWidget,
    );
    expect(
      find.text(harness.language.tr('asmr_category_collected')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('asmr_search_collected')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('recent_search_list')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('app_search_close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey<String>('app_search_field')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('asmr_search_button')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first ASMR activation keeps an immobile skeleton until load completes',
    (tester) async {
      final activePageIndex = ValueNotifier<int>(0);
      final controller = _QueuedEmptyAsmrLibraryController(
        emptyCollectedOnInitialLoad: true,
        delayInitialCollectedRefresh: true,
      );
      final harness = AppRuntimeWidgetTestFixture();
      addTearDown(activePageIndex.dispose);
      addTearDown(controller.dispose);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(
          AsmrTab(activeTabIndexListenable: activePageIndex),
          overrides: [
            asmrLibraryControllerProvider.overrideWithValue(controller),
          ],
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byType(LibraryLikeSkeletonCard), findsWidgets);
      expect(
        find.text(harness.languageProvider.tr('asmr_empty_category')),
        findsNothing,
      );
      final loadingList = tester.widget<ListView>(
        find.byKey(const ValueKey<String>('loading')),
      );
      expect(loadingList.physics, isA<NeverScrollableScrollPhysics>());

      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.collectedRefreshCount, 1);
      expect(find.byType(LibraryLikeSkeletonCard), findsWidgets);

      controller.completeInitialCollectedRefresh();
      await tester.pump();
      await tester.pump();
    },
  );

  testWidgets('main page header actions use the compact trailing inset', (
    tester,
  ) async {
    final harness = await _pumpAppShell(tester);
    await _pumpMainScreenAnimations(tester);

    final mainHeaderTitles = <String>{
      'ASMR.ONE',
      harness.language.tr('music_library'),
      harness.language.tr('playback_sessions'),
    };
    final mainHeaders = tester
        .widgetList<TopPageHeader>(
          find.byType(TopPageHeader, skipOffstage: false),
        )
        .where((header) => mainHeaderTitles.contains(header.title))
        .toList();

    expect(mainHeaders, hasLength(3));
    for (final header in mainHeaders) {
      expect(header.padding, AppPageHeaderMetrics.mainTabPadding);
    }
  });

  testWidgets(
    'switching between local library and ASMR tabs updates visible page',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });
      await _pumpAppShell(tester, includePlaybackSession: false);

      expect(
        find.byKey(const ValueKey<String>('main_page_fade_1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('main_page_fade_0')),
        findsNothing,
      );

      // Switch to ASMR.ONE tab
      final asmrDestination = find.byKey(
        const ValueKey<String>('main_destination_ink_show_asmr_one'),
      );
      expect(asmrDestination, findsOneWidget);
      await tester.tap(asmrDestination);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('main_page_fade_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('main_page_fade_1')),
        findsNothing,
      );

      // Switch back to Music Library tab
      final libraryDestination = find.byKey(
        const ValueKey<String>('main_destination_ink_music_library'),
      );
      expect(libraryDestination, findsOneWidget);
      await tester.tap(libraryDestination);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('main_page_fade_1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('main_page_fade_0')),
        findsNothing,
      );
    },
  );

  testWidgets('ASMR library initializes only after its tab is visible', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _QueuedEmptyAsmrLibraryController();
    final activePageIndex = ValueNotifier<int>(1);
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    addTearDown(activePageIndex.dispose);

    await tester.pumpWidget(
      fixture.build(
        AsmrTab(
          key: const ValueKey<String>('audio_library_asmr_page'),
          activeTabIndexListenable: activePageIndex,
        ),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pump();
    expect(controller.initializeCount, 0);

    activePageIndex.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.initializeCount, 1);

    activePageIndex.value = 1;
    await tester.pump();
    activePageIndex.value = 0;
    await tester.pump();
    expect(controller.initializeCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('inactive ASMR tab detaches category subscriptions', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    final controller = _QueuedEmptyAsmrLibraryController();
    final activePageIndex = ValueNotifier<int>(0);
    addTearDown(fixture.dispose);
    addTearDown(controller.dispose);
    addTearDown(activePageIndex.dispose);

    await tester.pumpWidget(
      fixture.build(
        AsmrTab(
          key: const ValueKey<String>('audio_library_asmr_page'),
          activeTabIndexListenable: activePageIndex,
        ),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    activePageIndex.value = 1;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    final inactiveReadCount = controller.categoryViewReadCount;
    controller.emitPresentationChange();
    await tester.pump();
    await tester.pump();
    expect(controller.categoryViewReadCount, inactiveReadCount);

    activePageIndex.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.categoryViewReadCount, greaterThan(inactiveReadCount));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('local and ASMR library cards start at the same height', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileCacheChannel, (call) async {
          return <String, Object?>{'ok': true, 'value': null};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(fileCacheChannel, null),
    );
    final fixture = AppRuntimeWidgetTestFixture();
    final asmrController = _QueuedEmptyAsmrLibraryController();
    final coverScheduler = WarmupScheduler()..setPaused(true);
    final coverUi = LibraryCoverUiController(
      library: fixture.library,
      scheduler: coverScheduler,
    );
    final activePageIndex = ValueNotifier<int>(1);
    addTearDown(fixture.dispose);
    addTearDown(asmrController.dispose);
    addTearDown(activePageIndex.dispose);
    fixture.runtimeGraph.library.addTracks(
      <MusicTrack>[
        testMusicTrack(
          name: 'Local work',
          path: '/library/local-work/track.mp3',
          groupKey: '/library/local-work',
          groupTitle: 'Local work',
          isSingle: true,
        ),
      ],
      notify: false,
      persist: false,
    );
    fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);

    await tester.pumpWidget(
      fixture.build(
        Stack(
          children: [
            LibraryTab(
              key: const ValueKey<String>('audio_library_local_page'),
              activeTabIndexListenable: activePageIndex,
            ),
            AsmrTab(
              key: const ValueKey<String>('audio_library_asmr_page'),
              activeTabIndexListenable: activePageIndex,
            ),
          ],
        ),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(asmrController),
          libraryCoverUiControllerProvider.overrideWithValue(coverUi),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
    await pumpUntilFound(tester, find.text('Local work', findRichText: true));
    activePageIndex.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await pumpUntilFound(tester, find.text('Loaded work', findRichText: true));

    final localCard = find
        .descendant(
          of: find.byKey(
            const ValueKey<String>('audio_library_local_page'),
            skipOffstage: false,
          ),
          matching: find.byType(SwipeRevealCard, skipOffstage: false),
          skipOffstage: false,
        )
        .first;
    final asmrCard = find
        .descendant(
          of: find.byKey(
            const ValueKey<String>('audio_library_asmr_page'),
            skipOffstage: false,
          ),
          matching: find.byType(SwipeRevealCard, skipOffstage: false),
          skipOffstage: false,
        )
        .first;
    final asmrSwipeCard = tester.widget<SwipeRevealCard>(asmrCard);
    expect(
      tester.getTopLeft(asmrCard).dy,
      closeTo(tester.getTopLeft(localCard).dy, 0.01),
    );
    expect(asmrSwipeCard.verticalActions, isTrue);
    expect(asmrSwipeCard.onTertiaryAction, isNull);
    expect(asmrSwipeCard.secondaryActionIcon, Icons.info_outline_rounded);
    expect(asmrSwipeCard.primaryActionIcon, Icons.favorite_border_rounded);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 10));
    unawaited(coverUi.dispose());
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

      await tester.tap(
        find.byKey(const ValueKey<String>('asmr_search_button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(
        find.byKey(const ValueKey<String>('app_search_field')),
        'sleep',
      );
      await tester.pump(const Duration(milliseconds: 260));

      final recommendationLabel = harness.languageProvider.tr(
        'asmr_category_recommendation',
      );
      await tester.tap(find.text(recommendationLabel));
      await tester.pump();

      final recommendationList = find.byKey(
        const ValueKey<String>('asmr_search_recommendation'),
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
      expect(controller.recommendationRefreshCount, 1);
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

  testWidgets('ASMR search loading and manual refresh keep expected content', (
    tester,
  ) async {
    _setLogicalTestViewSize(tester, const Size(400, 320));
    final controller = _QueuedEmptyAsmrLibraryController(
      delayCollectedSearch: true,
    );
    addTearDown(controller.dispose);
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

    await tester.tap(find.byKey(const ValueKey<String>('asmr_search_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 550));

    final searchPage = find.byKey(
      const ValueKey<String>('asmr_search_collected'),
    );
    final contentList = find.descendant(
      of: searchPage,
      matching: find.byKey(const ValueKey<String>('content')),
    );
    final scrollController = tester.widget<ListView>(contentList).controller!;
    expect(scrollController.position.maxScrollExtent, greaterThan(0));
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    expect(scrollController.offset, greaterThan(0));

    await tester.enterText(
      find.byKey(const ValueKey<String>('app_search_field')),
      'sleep',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(controller.collectedSearchRefreshCount, 1);
    expect(
      find.descendant(
        of: searchPage,
        matching: find.byType(LibraryLikeSkeletonCard),
      ),
      findsWidgets,
    );

    controller.completeCollectedSearchRefresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(scrollController.offset, 0);
    final refreshIndicator = tester.widget<GlassRefreshIndicator>(
      find.descendant(
        of: searchPage,
        matching: find.byType(GlassRefreshIndicator),
      ),
    );
    final refreshFuture = refreshIndicator.onRefresh();
    await tester.pump();

    expect(controller.collectedSearchRefreshCount, 2);
    expect(
      find.descendant(
        of: searchPage,
        matching: find.text('Loaded work', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: searchPage,
        matching: find.byType(LibraryLikeSkeletonCard),
      ),
      findsNothing,
    );

    controller.completeCollectedSearchRefresh();
    await refreshFuture;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('ASMR work cards blend into the page surface', (tester) async {
    final controller = _QueuedEmptyAsmrLibraryController();
    addTearDown(controller.dispose);
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

    final workTitle = find.text('Loaded work', findRichText: true);
    expect(workTitle, findsOneWidget);
    final workCard = tester.widget<Card>(
      find.ancestor(of: workTitle, matching: find.byType(Card)).first,
    );
    expect(workCard.color, Colors.transparent);
    expect(workCard.elevation, 0);
    expect(workCard.shadowColor, Colors.transparent);
    expect(workCard.surfaceTintColor, Colors.transparent);
    expect((workCard.shape as RoundedRectangleBorder).side, BorderSide.none);
    final swipeCard = tester.widget<SwipeRevealCard>(
      find.ancestor(of: workTitle, matching: find.byType(SwipeRevealCard)),
    );
    expect(
      swipeCard.closedColor,
      Theme.of(tester.element(workTitle)).colorScheme.surface,
    );
    final collectedCategory = find.byKey(
      const ValueKey(AsmrCategoryType.collected),
    );
    final contentListFinder = find.descendant(
      of: collectedCategory,
      matching: find.byKey(const ValueKey('content')),
    );
    final contentList = tester.widget<ListView>(contentListFinder);
    final listPadding = contentList.padding!.resolve(TextDirection.ltr);
    expect(listPadding.left, LibraryLikeCardMetrics.listHorizontalPadding);
    expect(listPadding.right, LibraryLikeCardMetrics.listHorizontalPadding);
    final workCards = find.descendant(
      of: contentListFinder,
      matching: find.byType(SwipeRevealCard),
    );
    expect(workCards, findsNWidgets(2));
    expect(
      tester.getBottomLeft(workCards.at(0)).dy,
      closeTo(tester.getTopLeft(workCards.at(1)).dy, 0.01),
    );
  });

  testWidgets('ASMR track tree builds descendants only after expansion', (
    tester,
  ) async {
    final controller = _QueuedEmptyAsmrLibraryController();
    addTearDown(controller.dispose);
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

    await tester.tap(find.text('Loaded work', findRichText: true));
    await tester.pumpAndSettle();

    expect(find.text('Disc 1'), findsOneWidget);
    expect(find.text('Nested track'), findsNothing);

    await tester.tap(find.text('Disc 1'));
    await tester.pumpAndSettle();
    expect(find.text('Nested track'), findsOneWidget);

    await tester.tap(find.text('Disc 1'));
    await tester.pump();
    expect(find.text('Nested track'), findsOneWidget);
    final collapsingReveal = tester.widget<AnimatedTreeReveal>(
      find
          .ancestor(
            of: find.text('Nested track'),
            matching: find.byType(AnimatedTreeReveal),
          )
          .first,
    );
    expect(collapsingReveal.visible, isFalse);
    await tester.pump(kAppMotionStandard ~/ 2);
    expect(find.text('Nested track'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Nested track'), findsNothing);
  });

  testWidgets('large ASMR track trees only build visible rows', (
    WidgetTester tester,
  ) async {
    final tree = List<AsmrTrackFile>.generate(
      2000,
      (index) => AsmrTrackFile(
        hash: 'large-$index',
        title: 'Large ASMR track ${index.toString().padLeft(4, '0')}.mp3',
        type: 'audio',
        streamUrl: 'https://example.com/large-$index.mp3',
        downloadUrl: 'https://example.com/large-$index.mp3',
        lowQualityUrl: null,
        duration: const Duration(minutes: 1),
        size: 1024,
        children: const <AsmrTrackFile>[],
        workId: 1,
        workTitle: 'Loaded work',
        sourceId: 'RJ000001',
        relativePath: 'Large ASMR track $index.mp3',
      ),
      growable: false,
    );
    final controller = _QueuedEmptyAsmrLibraryController(trackTree: tree);
    addTearDown(controller.dispose);
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
    await tester.tap(find.text('Loaded work', findRichText: true));
    await tester.pumpAndSettle();

    final builtRows = find.textContaining(
      'Large ASMR track',
      findRichText: true,
    );
    expect(builtRows.evaluate().length, lessThan(100));
    expect(
      find.text('Large ASMR track 1999', findRichText: true),
      findsNothing,
    );

    final collectedCategory = find.byKey(
      const ValueKey(AsmrCategoryType.collected),
    );
    await tester.scrollUntilVisible(
      find.text('Large ASMR track 1999', findRichText: true),
      600,
      scrollable: find
          .descendant(of: collectedCategory, matching: find.byType(Scrollable))
          .last,
      maxScrolls: 400,
    );
    expect(
      find.text('Large ASMR track 1999', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('ASMR download summary stays above content with a long title', (
    WidgetTester tester,
  ) async {
    _setLogicalTestViewSize(tester, const Size(390, 800));
    final work = AsmrWork(
      id: 42,
      title:
          'A deliberately long ASMR work title that wraps across all three supported lines without covering the file list below',
      circleName: 'Circle',
      sourceId: 'RJ000042',
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
      voiceActors: const <String>[],
      tags: const <String>[],
    );
    final track = AsmrTrackFile(
      hash: 'track',
      title: 'Track.mp3',
      type: 'audio',
      streamUrl: 'https://example.invalid/track.mp3',
      downloadUrl: 'https://example.invalid/track.mp3',
      lowQualityUrl: null,
      duration: const Duration(minutes: 1),
      size: 1024,
      children: const <AsmrTrackFile>[],
      workId: work.id,
      workTitle: work.title,
      sourceId: work.sourceId,
      relativePath: 'Track.mp3',
    );
    final controller = _QueuedEmptyAsmrLibraryController(
      trackTree: <AsmrTrackFile>[track],
    );
    final downloads = AsmrDownloadManager(persistTasks: false);
    final harness = AppRuntimeWidgetTestFixture();
    addTearDown(controller.dispose);
    addTearDown(downloads.dispose);
    addTearDown(harness.dispose);
    await harness.languageProvider.setLanguage(AppLanguage.zh);

    await tester.pumpWidget(
      harness.build(
        AsmrDownloadPage(work: work),
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
          asmrDownloadManagerProvider.overrideWithValue(downloads),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final summary = find.byKey(const ValueKey<String>('asmr_download_summary'));
    final fileList = find.byKey(
      const ValueKey<String>('asmr_download_file_list'),
    );
    expect(summary, findsOneWidget);
    expect(fileList, findsOneWidget);
    expect(tester.getSize(summary).height, greaterThan(100));
    expect(
      tester.getRect(find.text('Track.mp3')).top -
          tester.getRect(summary).bottom,
      greaterThanOrEqualTo(8),
    );
  });

  testWidgets('ASMR pagination shows progress without a pull-up hint', (
    tester,
  ) async {
    final controller = _QueuedEmptyAsmrLibraryController(
      collectedHasMore: true,
    );
    addTearDown(controller.dispose);
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

    final collectedList = find.byKey(
      const ValueKey(AsmrCategoryType.collected),
    );
    expect(
      find.descendant(
        of: collectedList,
        matching: find.byKey(const ValueKey<String>('asmr_load_more_progress')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: collectedList,
        matching: find.byKey(
          const ValueKey<String>('asmr_load_more_retry_hint'),
        ),
      ),
      findsNothing,
    );
    expect(controller.loadMoreCount, 1);
  });

  testWidgets('ASMR pagination failure retries only after a manual pull-up', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator.instance;
    coordinator.resetForTest();
    addTearDown(coordinator.resetForTest);
    final controller = _QueuedEmptyAsmrLibraryController(
      collectedHasMore: true,
      needsRetry: true,
    );
    addTearDown(controller.dispose);
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

    final collectedList = find.byKey(
      const ValueKey(AsmrCategoryType.collected),
    );
    expect(
      find.descendant(
        of: collectedList,
        matching: find.byKey(
          const ValueKey<String>('asmr_load_more_retry_hint'),
        ),
      ),
      findsOneWidget,
    );
    expect(controller.loadMoreCount, 0);

    await tester.drag(collectedList, const Offset(0, -180));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));

    expect(controller.loadMoreCount, 1);
    coordinator.finishInteractionsForTest();
    await tester.pump();
    expect(
      find.descendant(
        of: collectedList,
        matching: find.byKey(
          const ValueKey<String>('asmr_load_more_retry_hint'),
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('app shell does not render a custom startup overlay', (
    tester,
  ) async {
    await _pumpAppShell(tester, waitForStartup: false);
    await tester.pump();

    const overlayKey = ValueKey<String>('main_bootstrap_overlay');
    expect(find.byKey(overlayKey), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('main_page_stack')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pump();
  });

  testWidgets('startup shell waits for every required local data load', (
    tester,
  ) async {
    final runtime = Completer<void>();
    final downloads = Completer<void>();
    final asmrLibrary = Completer<void>();
    var settledCalls = 0;

    await _pumpAppShell(
      tester,
      waitForStartup: false,
      runtimeInitializer: () => Future.wait<void>([
        runtime.future,
        downloads.future,
        asmrLibrary.future,
      ]),
      onBootstrapSettled: () => settledCalls++,
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('app_bootstrap_loading')),
      findsOneWidget,
    );
    expect(find.byType(MainScreen), findsNothing);
    expect(settledCalls, 0);

    runtime.complete();
    downloads.complete();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('app_bootstrap_loading')),
      findsOneWidget,
    );
    expect(find.byType(MainScreen), findsNothing);
    expect(settledCalls, 0);

    asmrLibrary.complete();
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('app_bootstrap_loading')),
      findsNothing,
    );
    expect(find.byType(MainScreen), findsOneWidget);
    expect(settledCalls, 1);
    await tester.pump(const Duration(milliseconds: 750));
    await tester.pump();
    expect(settledCalls, 1);
  });

  testWidgets('fresh install settles startup while onboarding is visible', (
    tester,
  ) async {
    final initialization = Completer<void>();
    var settledCalls = 0;

    await _pumpAppShell(
      tester,
      waitForStartup: false,
      shouldShowOnboarding: true,
      runtimeInitializer: () => initialization.future,
      onBootstrapSettled: () => settledCalls++,
    );
    await tester.pump();

    expect(settledCalls, 0);
    expect(find.byType(MainScreen), findsNothing);

    initialization.complete();
    await tester.pump();
    await tester.pump();

    expect(settledCalls, 1);
    expect(find.byType(MainScreen), findsNothing);
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

    final navigationRail = find.byType(NavigationRail);
    expect(navigationRail, findsOneWidget);
    expect(
      tester
          .widgetList<Theme>(
            find.ancestor(of: navigationRail, matching: find.byType(Theme)),
          )
          .any((theme) => theme.data.splashFactory == NoSplash.splashFactory),
      isTrue,
    );
    expect(
      find.ancestor(
        of: navigationRail,
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(of: navigationRail, matching: find.byType(FittedBox)),
      findsNothing,
    );
    final settingsNavigationIcon = find.descendant(
      of: navigationRail,
      matching: find.byIcon(Icons.settings_outlined),
    );
    expect(settingsNavigationIcon, findsOneWidget);
    expect(tester.widget<Icon>(settingsNavigationIcon).size, isNull);

    final expandedMenuButton = find.descendant(
      of: navigationRail,
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
    final libraryState = tester.state(
      find.byType(LibraryTab, skipOffstage: false),
    );
    final asmrState = tester.state(find.byType(AsmrTab, skipOffstage: false));
    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    AppFadeThroughIndexedStack mainPageStack() =>
        tester.widget<AppFadeThroughIndexedStack>(
          find.byKey(const ValueKey<String>('main_page_stack')),
        );

    expect(mainPageStack().index, 3);

    tester.view.physicalSize = const Size(2400, 1080);
    await tester.pump(const Duration(milliseconds: 32));
    await _pumpMainScreenAnimations(tester);

    expect(mainPageStack().index, 3);
    expect(
      tester.state(find.byType(LibraryTab, skipOffstage: false)),
      same(libraryState),
    );
    expect(
      tester.state(find.byType(AsmrTab, skipOffstage: false)),
      same(asmrState),
    );
    expect(find.byKey(const ValueKey<String>('main_page_fade_3')), findsOne);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.byIcon(Icons.library_music_outlined),
      ),
    );
    await _pumpMainScreenAnimations(tester);
    expect(mainPageStack().index, 1);

    tester.view.physicalSize = const Size(1080, 2400);
    await tester.pump(const Duration(milliseconds: 32));
    await _pumpMainScreenAnimations(tester);

    expect(mainPageStack().index, 1);
    expect(
      tester.state(find.byType(LibraryTab, skipOffstage: false)),
      same(libraryState),
    );
    expect(
      tester.state(find.byType(AsmrTab, skipOffstage: false)),
      same(asmrState),
    );
    expect(find.byKey(const ValueKey<String>('main_page_fade_1')), findsOne);
    debugDefaultTargetPlatformOverride = null;
    expect(tester.takeException(), isNull);
  });

  testWidgets('app shell handles keyboard and dynamic portrait sizes', (
    tester,
  ) async {
    await _pumpAppShell(tester);
    await _tapSettingsDestination(tester);
    await _pumpMainScreenAnimations(tester);

    AppFadeThroughIndexedStack mainPageStack() =>
        tester.widget<AppFadeThroughIndexedStack>(
          find.byKey(const ValueKey<String>('main_page_stack')),
        );

    expect(mainPageStack().index, 3);
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    tester.view.physicalSize = const Size(1080, 1800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetViewInsets();
    });
    await tester.pump(const Duration(milliseconds: 32));

    expect(mainPageStack().index, 3);
    expect(
      tester
          .widget<MediaQuery>(
            find.byKey(
              const ValueKey<String>('main_screen_keyboard_inset_boundary'),
            ),
          )
          .data
          .viewInsets
          .bottom,
      0,
    );
    expect(find.byType(ActiveSessionCarousel), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(1080, 2400);
    await _pumpMainScreenAnimations(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ASMR playback errors show retry subtitle and play icon', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final themeProvider = ThemeProvider();
    final languageProvider = AppLanguageProvider();
    final notificationService = PlaybackNotificationService();
    final persistenceRepository = TestPersistenceRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final runtimeGraph = createTestRuntimeGraph(
      notificationService: notificationService,
      persistenceRepository: persistenceRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );
    final track = MusicTrack(
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
    addTearDown(session.shutdown);
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
                sessions: [PlaybackSessionSnapshot.fromRuntime(session)],
                onOpenSession: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(
        find.byKey(const ValueKey('active_session_cover_asmr_error_session')),
      ),
      const Size.square(48),
    );
    final playbackCardRect = tester.getRect(
      find.byKey(const ValueKey('active_session_card_asmr_error_session')),
    );
    final playbackCoverRect = tester.getRect(
      find.byKey(const ValueKey('active_session_cover_asmr_error_session')),
    );
    expect(playbackCoverRect.left - playbackCardRect.left, 4);
    expect(playbackCoverRect.top - playbackCardRect.top, 4);
    expect(playbackCardRect.bottom - playbackCoverRect.bottom, 4);
    expect(
      tester
          .widget<AsyncLocalCoverImage>(find.byType(AsyncLocalCoverImage))
          .displayMode,
      CoverImageDisplayMode.fill,
    );
    expect(
      tester
          .widget<ClipRRect>(
            find.byKey(
              const ValueKey('active_session_card_asmr_error_session'),
            ),
          )
          .borderRadius,
      BorderRadius.circular(LibraryLikeCardMetrics.coverRadius + 4),
    );
    expect(
      tester
          .widget<Material>(
            find.descendant(
              of: find.byKey(
                const ValueKey('active_session_cover_asmr_error_session'),
              ),
              matching: find.byType(Material),
            ),
          )
          .borderRadius,
      BorderRadius.circular(LibraryLikeCardMetrics.coverRadius),
    );

    await settingsRepository.setBottomNavigationStyle(
      BottomNavigationStyle.bar,
    );
    await tester.pump();
    final barCardRect = tester.getRect(
      find.byKey(const ValueKey('active_session_card_asmr_error_session')),
    );
    final barCoverRect = tester.getRect(
      find.byKey(const ValueKey('active_session_cover_asmr_error_session')),
    );
    expect(barCoverRect.size, const Size.square(48));
    expect(barCoverRect.left - barCardRect.left, 4);
    expect(barCoverRect.top - barCardRect.top, 4);
    expect(barCardRect.bottom - barCoverRect.bottom, 4);
    await settingsRepository.setBottomNavigationStyle(
      BottomNavigationStyle.capsule,
    );
    await tester.pump();

    expect(
      find.text(languageProvider.tr('asmr_playback_network_failed_retry')),
      findsOneWidget,
    );
    expect(find.text('network failed'), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byType(SessionFeatureBadgeStack), findsNothing);

    session.playbackError = null;
    session.isLoading = true;
    session.isPlaybackStarting = true;
    session.setOptimisticState(playing: true);
    playbackService.markActiveSessionsDirty();
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 1,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(languageProvider.tr('playback_loading')), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);

    session.isLoading = false;
    session.isPlaybackStarting = false;
    session.setOptimisticState(
      playing: false,
      processingState: ProcessingState.buffering,
    );
    playbackService.markActiveSessionsDirty();
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(languageProvider.tr('playback_loading')), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsWidgets);

    session.setOptimisticState(
      playing: true,
      processingState: ProcessingState.ready,
    );
    playbackService.markActiveSessionsDirty();
    playbackService.syncSlice(
      activeSessions: [session],
      playingSessionCount: 1,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.value == '1 / 1',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
    semantics.dispose();
  });

  testWidgets('playback carousel wraps between the first and last session', (
    tester,
  ) async {
    final themeProvider = ThemeProvider();
    final languageProvider = AppLanguageProvider();
    final notificationService = PlaybackNotificationService();
    final persistenceRepository = TestPersistenceRepository();
    final nativePlaybackRepository = NativePlaybackRepository();
    final libraryService = LibraryService();
    final playbackService = PlaybackSessionService();
    final timerService = TimerService();
    final notificationCoordinatorService = NotificationCoordinatorService();
    final settingsRepository = SettingsRepository();
    final runtimeGraph = createTestRuntimeGraph(
      notificationService: notificationService,
      persistenceRepository: persistenceRepository,
      nativePlaybackRepository: nativePlaybackRepository,
      libraryService: libraryService,
      playbackService: playbackService,
      timerService: timerService,
      notificationStateService: notificationCoordinatorService,
      settingsRepository: settingsRepository,
    );
    final firstTrack = MusicTrack(
      path: '/audio/first.mp3',
      displayName: 'First track',
      groupKey: 'first',
      groupTitle: 'First',
      groupSubtitle: 'First',
      isSingle: true,
    );
    final secondTrack = MusicTrack(
      path: '/audio/second.mp3',
      displayName: 'Second track',
      groupKey: 'second',
      groupTitle: 'Second',
      groupSubtitle: 'Second',
      isSingle: true,
    );
    final firstSession = PlaybackSession(
      id: 'first_session',
      currentTrackPath: firstTrack.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    final secondSession = PlaybackSession(
      id: 'second_session',
      currentTrackPath: secondTrack.path,
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(() => unawaited(runtimeGraph.runtime.dispose()));
    addTearDown(firstSession.shutdown);
    addTearDown(secondSession.shutdown);
    runtimeGraph.library.addTracks(
      [firstTrack, secondTrack],
      notify: false,
      persist: false,
    );
    playbackService
      ..registerSession(firstSession)
      ..registerSession(secondSession)
      ..syncSlice(
        activeSessions: [firstSession, secondSession],
        playingSessionCount: 0,
        focusedSessionId: firstSession.id,
        multiThreadPlaybackEnabled: true,
        coverGeneration: 0,
        isInitialized: true,
      );

    final semantics = tester.ensureSemantics();
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
                sessions: [
                  PlaybackSessionSnapshot.fromRuntime(firstSession),
                  PlaybackSessionSnapshot.fromRuntime(secondSession),
                ],
                onOpenSession: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    Finder pageIndicator(String label) => find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label,
    );

    final indicatorFinder = pageIndicator('1 / 2');
    expect(indicatorFinder, findsOneWidget);
    final activeCardFinder = find.byKey(
      ValueKey<String>('active_session_card_${firstSession.id}'),
    );
    expect(activeCardFinder, findsOneWidget);
    final indicatorRect = tester.getRect(indicatorFinder);
    final cardRect = tester.getRect(activeCardFinder);
    expect(indicatorRect.right, lessThan(cardRect.right));
    expect(indicatorRect.left, greaterThan(cardRect.left));
    expect(indicatorRect.bottom, lessThanOrEqualTo(cardRect.bottom));
    expect(indicatorRect.top, greaterThan(cardRect.top));

    await tester.drag(find.byType(PageView), const Offset(400, 0));
    await tester.pumpAndSettle();
    expect(pageIndicator('2 / 2'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(pageIndicator('1 / 2'), findsOneWidget);
    semantics.dispose();
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

  testWidgets('mobile content inset updates with playback card visibility', (
    tester,
  ) async {
    _setLogicalTestViewSize(tester, const Size(420, 840));
    final harness = await _pumpAppShell(tester, includePlaybackSession: false);

    double currentInset() => tester
        .widget<MobileOverlayInset>(find.byType(MobileOverlayInset))
        .bottomInset;

    final withoutCard = currentInset();
    final session = PlaybackSession(
      id: 'inset-session',
      currentTrackPath: '/audio/inset.mp3',
      loopMode: SessionLoopMode.single,
      nonSingleLoopMode: SessionLoopMode.single,
      volume: 1,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(session.shutdown);
    harness.playbackService.registerSession(session);
    harness.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    for (
      var frame = 0;
      frame < 4 && find.byType(ActiveSessionCarousel).evaluate().isEmpty;
      frame++
    ) {
      await tester.pump();
    }
    expect(find.byType(ActiveSessionCarousel), findsOneWidget);
    final withCard = currentInset();
    expect(withCard, greaterThan(withoutCard + 56));

    harness.playbackService.syncSlice(
      activeSessions: const <PlaybackSession>[],
      playingSessionCount: 0,
      focusedSessionId: null,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );
    for (
      var frame = 0;
      frame < 4 && find.byType(ActiveSessionCarousel).evaluate().isNotEmpty;
      frame++
    ) {
      await tester.pump();
    }
    expect(find.byType(ActiveSessionCarousel), findsNothing);

    expect(currentInset(), closeTo(withoutCard, 0.1));
  });

  testWidgets('single audio detail uses the standard artwork layout', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
    final track = MusicTrack(
      path: '/imports/standalone.mp3',
      displayName: 'Standalone audio',
      groupKey: '__single_files__',
      groupTitle: 'Imported files',
      groupSubtitle: '',
      isSingle: true,
    );
    await _pumpAppShell(tester, playbackTrack: track);
    final expectedAccent = Theme.of(
      tester.element(find.byType(Scaffold).first),
    ).colorScheme.primary;
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
    );
    await tester.pumpAndSettle();

    final detail = find.byType(SessionDetailPage);
    expect(
      find.descendant(of: detail, matching: find.byType(AsyncLocalCoverImage)),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('segments_pinned_artwork')), findsNothing);
    final detailThemeContext = tester.element(detail);
    expect(Theme.of(detailThemeContext).colorScheme.primary, expectedAccent);

    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('ASMR session detail uses ASMR accent theme', (tester) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
    final track = MusicTrack(
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
      find
          .descendant(
            of: find.byType(SessionDetailPage),
            matching: find.byType(MarqueeText),
          )
          .first,
    );
    final artworkCover = tester.widget<AsyncLocalCoverImage>(
      find.descendant(
        of: find.byType(SessionDetailPage),
        matching: find.byType(AsyncLocalCoverImage),
      ),
    );
    final expectedAccent = AppDesignTokens.of(detailThemeContext).asmrAccent;
    expect(Theme.of(detailThemeContext).colorScheme.primary, expectedAccent);
    expect(artworkCover.duration, kCoverImageFadeDuration);
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
    final track = MusicTrack(
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
    final detailContext = tester.element(detail);
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
    expect(
      find.descendant(of: detail, matching: find.byIcon(Icons.alarm_rounded)),
      findsNothing,
    );
    final secondaryButton = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.descendant(
              of: detail,
              matching: find.byIcon(Icons.tune_rounded),
            ),
            matching: find.byType(IconButton),
          )
          .first,
    );
    final secondaryColor = secondaryButton.style!.foregroundColor!.resolve({})!;

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
        tester
            .widgetList<TickerMode>(
              find.descendant(
                of: detailFinder,
                matching: find.byType(TickerMode),
              ),
            )
            .any((tickerMode) => tickerMode.enabled),
        isTrue,
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

  testWidgets(
    'session loop and volume controls open corresponding modes and allow configuration',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = previousPlatform;
      });
      _setLogicalTestViewSize(tester, const Size(1080, 2400));
      final harness = await _pumpAppShell(tester);
      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('session_loop_button_anchor')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('loop_mode_single_row')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('loop_mode_scope_row')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('loop_mode_playback_row')),
        findsOneWidget,
      );
      final scopeRect = tester.getRect(
        find.byKey(const ValueKey('loop_mode_scope_row')),
      );
      final playbackRect = tester.getRect(
        find.byKey(const ValueKey('loop_mode_playback_row')),
      );
      expect(scopeRect.bottom, lessThan(playbackRect.top));
      expect(find.text(harness.language.tr('loop_playback')), findsOneWidget);

      final ignorePointer = tester.widget<IgnorePointer>(
        find
            .descendant(
              of: find.byType(Column),
              matching: find.byWidgetPredicate(
                (w) => w is IgnorePointer && w.ignoring == true,
              ),
            )
            .first,
      );
      expect(ignorePointer.ignoring, isTrue);

      await tester.tap(find.text(harness.language.tr('single_loop')));
      await tester.pump();
      await tester.tap(find.text(harness.language.tr('pause_after_playback')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('loop_mode_confirm')));
      await tester.pumpAndSettle();
      expect(
        harness.playbackService.sessions['orientation_session']?.loopMode,
        SessionLoopMode.folderOnce,
      );

      await tester.tap(
        find.byKey(const ValueKey('session_loop_button_anchor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(harness.language.tr('shuffle_playback')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('loop_mode_confirm')));
      await tester.pumpAndSettle();
      expect(
        harness.playbackService.sessions['orientation_session']?.loopMode,
        SessionLoopMode.folderRandomOnce,
      );

      await tester.tap(
        find.byKey(const ValueKey('session_loop_button_anchor')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(harness.language.tr('loop_playback')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('loop_mode_confirm')));
      await tester.pumpAndSettle();
      expect(
        harness.playbackService.sessions['orientation_session']?.loopMode,
        SessionLoopMode.folderOnce,
      );

      await tester.tap(
        find.byKey(const ValueKey('session_volume_button_anchor')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session_volume_exit_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session_volume_mute_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session_volume_slider')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session_volume_percent_text')),
        findsOneWidget,
      );

      final initialVol =
          harness.playbackService.sessions['orientation_session']?.volume ??
          1.0;
      expect(initialVol, greaterThan(0.0));

      await tester.tap(
        find.byKey(const ValueKey('session_volume_mute_button')),
      );
      await tester.pumpAndSettle();
      expect(
        harness.playbackService.sessions['orientation_session']?.volume,
        0.0,
      );

      await tester.tap(
        find.byKey(const ValueKey('session_volume_mute_button')),
      );
      await tester.pumpAndSettle();
      expect(
        (harness.playbackService.sessions['orientation_session']?.volume ??
                0.0) -
            initialVol,
        closeTo(0.0, 0.01),
      );

      await tester.tap(
        find.byKey(const ValueKey('session_volume_exit_button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('session_volume_exit_button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('session_volume_button_anchor')),
        findsOneWidget,
      );

      await _settleSessionDetailAsyncWork(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = previousPlatform;
    },
  );

  testWidgets('playback queue loop mode includes folder scope selection', (
    tester,
  ) async {
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
    final harness = await _pumpAppShell(tester);
    final session = harness.playbackService.sessions['orientation_session']!;
    session.playbackQueue = PlaybackQueueDefinition(
      name: 'Queue',
      entries: const <PlaybackQueueEntry>[],
    );
    harness.playbackService.markSessionStateDirty();
    harness.playbackService.syncSlice(
      activeSessions: <PlaybackSession>[session],
      playingSessionCount: 0,
      focusedSessionId: session.id,
      multiThreadPlaybackEnabled: false,
      coverGeneration: 0,
      isInitialized: true,
    );

    unawaited(
      showLoopModeBottomSheet(
        context: tester.element(find.byType(Scaffold).first),
        session: PlaybackSessionSnapshot.fromRuntime(session),
        playback: harness.playback,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('loop_mode_scope_row')), findsOneWidget);
    await tester.tap(find.text(harness.language.tr('single_loop')));
    await tester.pump();
    await tester.tap(find.text(harness.language.tr('cross_folder')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('loop_mode_confirm')));
    await tester.pumpAndSettle();
    expect(session.loopMode, SessionLoopMode.crossSequential);
    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('session volume slider keeps its released value visible', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
    final harness = await _pumpAppShell(tester, playbackVolume: 2);
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('session_volume_button_anchor')),
    );
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('session_volume_slider')),
    );
    expect(slider.max, 1.5);
    expect(slider.value, 1.25);
    expect(find.text('125%'), findsOneWidget);

    slider.onChanged!(1.5);
    await tester.pump();
    expect(find.text('150%'), findsOneWidget);
    expect(harness.playbackService.sessions['orientation_session']?.volume, 3);

    slider.onChangeEnd!(1.5);
    await tester.pump();
    expect(find.text('150%'), findsOneWidget);
    expect(harness.playbackService.sessions['orientation_session']?.volume, 3);

    await _settleSessionDetailAsyncWork(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('session volume input maps 150 percent to threefold gain', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = previousPlatform;
    });
    _setLogicalTestViewSize(tester, const Size(1080, 2400));
    final harness = await _pumpAppShell(tester);
    unawaited(
      tester
          .state<NavigatorState>(find.byType(Navigator).first)
          .push(buildSessionDetailRoute(sessionId: 'orientation_session')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('session_volume_button_anchor')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('100%'));
    await tester.pumpAndSettle();

    final input = find.byType(TextFormField);
    final confirm = find.widgetWithText(
      FilledButton,
      harness.language.tr('confirm'),
    );
    await tester.enterText(input, '151');
    tester.widget<FilledButton>(confirm).onPressed!();
    await tester.pump();
    expect(input, findsOneWidget);
    expect(harness.playbackService.sessions['orientation_session']?.volume, 1);

    await tester.enterText(input, '150');
    tester.widget<FilledButton>(confirm).onPressed!();
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(harness.playbackService.sessions['orientation_session']?.volume, 3);

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
    await _settleSessionDetailAsyncWork(tester);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    debugDefaultTargetPlatformOverride = previousPlatform;
  });
}

final class _AppShellHarness {
  const _AppShellHarness({
    required this.language,
    required this.playback,
    required this.playbackService,
  });

  final AppLanguageProvider language;
  final PlaybackFacade playback;
  final PlaybackSessionService playbackService;
}

final class _AppShellTestPersistenceRepository
    extends TestPersistenceRepository {
  @override
  Future<List<MusicTrack>> loadStartupTracks() async => const <MusicTrack>[];

  @override
  Future<List<LibraryEntry>> loadAllLibraryEntries() async =>
      const <LibraryEntry>[];

  @override
  Future<List<AudioDetail>> loadMany(
    Iterable<AudioDetailTarget> targets,
  ) async => const <AudioDetail>[];

  @override
  Future<List<PersistedPlaybackSession>> loadAllSessions() async =>
      const <PersistedPlaybackSession>[];

  @override
  Future<String?> loadAppSetting(String key) async => null;

  @override
  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) async {
    return const <TimeSegmentLabel>[];
  }
}

final class _AppShellNativePlaybackRepository extends NativePlaybackRepository {
  @override
  void startListening() {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {}
}

final class _QueuedEmptyAsmrLibraryController extends AsmrLibraryController {
  _QueuedEmptyAsmrLibraryController({
    this.collectedHasMore = false,
    this.needsRetry = false,
    this.delayCollectedSearch = false,
    this.emptyCollectedOnInitialLoad = false,
    this.delayInitialCollectedRefresh = false,
    this.trackTree,
  }) : super(
         preferencesStore: AsmrPreferencesStore(
           repository: SqliteAsmrRepository(database: AppDatabase.instance),
         ),
         persistenceRepository: SqliteAsmrRepository(
           database: AppDatabase.instance,
         ),
       );

  final Completer<void> _recommendationRefresh = Completer<void>();
  final List<Completer<void>> _collectedSearchRefreshes = <Completer<void>>[];
  final Completer<void> _initialCollectedRefresh = Completer<void>();
  final bool collectedHasMore;
  final bool delayCollectedSearch;
  final bool emptyCollectedOnInitialLoad;
  final bool delayInitialCollectedRefresh;
  final List<AsmrTrackFile>? trackTree;
  bool needsRetry;
  bool _recommendationLoading = false;
  bool _collectedLoading = false;
  bool _isLoadingMore = false;
  int _revision = 0;
  int recommendationRefreshCount = 0;
  int collectedSearchRefreshCount = 0;
  int collectedRefreshCount = 0;
  int loadMoreCount = 0;
  int initializeCount = 0;
  int categoryViewReadCount = 0;

  static final AsmrWork _collectedWork = AsmrWork(
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
    voiceActors: const <String>[],
    tags: const <String>[],
  );

  @override
  Future<List<AsmrTrackFile>> ensureTrackTree(AsmrWork work) {
    final resolvedTree = trackTree;
    if (resolvedTree != null) {
      return SynchronousFuture<List<AsmrTrackFile>>(resolvedTree);
    }
    return super.ensureTrackTree(work);
  }

  static final AsmrWork _secondCollectedWork = AsmrWork(
    id: 2,
    title: 'Second loaded work',
    circleName: 'Circle',
    sourceId: 'RJ000002',
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
    voiceActors: const <String>[],
    tags: const <String>[],
  );

  static final AsmrTrackFile _nestedTrack = AsmrTrackFile(
    hash: 'nested-track',
    title: 'Nested track',
    type: 'audio',
    streamUrl: 'https://example.com/nested-track.mp3',
    downloadUrl: 'https://example.com/nested-track.mp3',
    lowQualityUrl: null,
    duration: const Duration(minutes: 1),
    size: 1024,
    children: const <AsmrTrackFile>[],
    workId: 1,
    workTitle: 'Loaded work',
    sourceId: 'RJ000001',
    relativePath: 'Disc 1/Nested track.mp3',
  );

  static final AsmrTrackFile _trackFolder = AsmrTrackFile(
    hash: 'disc-1',
    title: 'Disc 1',
    type: 'folder',
    streamUrl: null,
    downloadUrl: null,
    lowQualityUrl: null,
    duration: const Duration(minutes: 1),
    size: 1024,
    children: <AsmrTrackFile>[_nestedTrack],
    workId: 1,
    workTitle: 'Loaded work',
    sourceId: 'RJ000001',
    relativePath: 'Disc 1',
  );

  @override
  Future<void> initialize({AsmrContentLanguage? defaultLanguage}) async {
    initializeCount++;
    scheduleMicrotask(notifyListeners);
  }

  @override
  Future<void> restoreAsmrAccountSession({bool force = false}) async {}

  @override
  AsmrLibraryGlobalViewState get globalViewState => AsmrLibraryGlobalViewState(
    initialized: true,
    visibleCategories: kDefaultVisibleAsmrCategories,
    contentLanguage: AsmrContentLanguage.zh,
    contentLanguagePreference: ContentLanguagePreference.followPage,
    revision: 0,
  );

  @override
  List<AsmrWork> worksFor(AsmrCategoryType category) =>
      category == AsmrCategoryType.collected
      ? emptyCollectedOnInitialLoad
            ? const <AsmrWork>[]
            : <AsmrWork>[_collectedWork, _secondCollectedWork]
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
    categoryViewReadCount++;
    final works = worksFor(category);
    final isLoading =
        (category == AsmrCategoryType.recommendation &&
            _recommendationLoading) ||
        (category == AsmrCategoryType.collected && _collectedLoading);
    final isPaginated =
        category == AsmrCategoryType.collected && collectedHasMore;
    return AsmrCategoryViewState(
      category: category,
      works: works,
      isLoading: isLoading,
      isLoadingMore: isPaginated && _isLoadingMore,
      isRefreshing: isLoading && works.isNotEmpty,
      isStale: isLoading && works.isNotEmpty,
      hasAttemptedLoad: true,
      hasMore: isPaginated,
      needsLoadMoreRetry: isPaginated && needsRetry,
      totalCount: isPaginated ? works.length + 1 : works.length,
      activeQuery: searchQuery,
      lastError: null,
      operationError: null,
      revision: _revision,
    );
  }

  @override
  AsmrTrackTreeViewState trackTreeViewState(int workId) {
    final tree = workId == _collectedWork.id
        ? trackTree ?? <AsmrTrackFile>[_trackFolder]
        : const <AsmrTrackFile>[];
    return AsmrTrackTreeViewState(
      workId: workId,
      tree: tree,
      visibleTree: tree,
      isLoading: false,
      isRefreshing: false,
      isStale: false,
      operationError: null,
      revision: _revision,
    );
  }

  @override
  Future<void> refreshCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    if (category == AsmrCategoryType.collected &&
        searchQuery.isEmpty &&
        delayInitialCollectedRefresh) {
      collectedRefreshCount++;
      _collectedLoading = true;
      notifyListeners();
      await _initialCollectedRefresh.future;
      _collectedLoading = false;
      _revision++;
      notifyListeners();
      return;
    }
    if (category == AsmrCategoryType.collected &&
        searchQuery.isNotEmpty &&
        delayCollectedSearch) {
      collectedSearchRefreshCount++;
      final refresh = Completer<void>();
      _collectedSearchRefreshes.add(refresh);
      await refresh.future;
      _revision++;
      notifyListeners();
      return;
    }
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

  void completeInitialCollectedRefresh() {
    if (!_initialCollectedRefresh.isCompleted) {
      _initialCollectedRefresh.complete();
    }
  }

  void completeCollectedSearchRefresh() {
    for (final refresh in _collectedSearchRefreshes) {
      if (refresh.isCompleted) continue;
      refresh.complete();
      return;
    }
  }

  void emitPresentationChange() {
    _revision++;
    notifyListeners();
  }

  @override
  Future<void> loadMoreCategory(
    AsmrCategoryType category, {
    String searchQuery = '',
  }) async {
    if (!collectedHasMore ||
        category != AsmrCategoryType.collected ||
        _isLoadingMore) {
      return;
    }
    loadMoreCount++;
    _isLoadingMore = true;
    needsRetry = false;
    _revision++;
    notifyListeners();
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
  double playbackVolume = 1,
  MusicTrack? playbackTrack,
  bool waitForStartup = true,
  AsmrDownloadManager? downloads,
  Future<void> Function()? runtimeInitializer,
  bool? shouldShowOnboarding,
  VoidCallback? onBootstrapSettled,
}) async {
  final themeProvider = ThemeProvider();
  final languageProvider = AppLanguageProvider();
  final notificationService = PlaybackNotificationService();
  final persistenceRepository = _AppShellTestPersistenceRepository();
  final nativePlaybackRepository = _AppShellNativePlaybackRepository();
  final libraryService = LibraryService();
  final playbackService = PlaybackSessionService();
  final timerService = TimerService();
  final notificationCoordinatorService = NotificationCoordinatorService();
  final settingsRepository = SettingsRepository();
  final runtimeGraph = createTestRuntimeGraph(
    notificationService: notificationService,
    persistenceRepository: persistenceRepository,
    nativePlaybackRepository: nativePlaybackRepository,
    libraryService: libraryService,
    playbackService: playbackService,
    timerService: timerService,
    notificationStateService: notificationCoordinatorService,
    settingsRepository: settingsRepository,
    asmrDownloads: downloads,
  );
  addTearDown(() => unawaited(runtimeGraph.runtime.dispose()));
  settingsRepository.syncSlice(isInitialized: true);
  libraryService.syncSlice(isInitialized: true, detailRevision: 0);
  await tester.runAsync(runtimeGraph.runtime.start);
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
      volume: playbackVolume,
      createdAt: DateTime(2026),
      state: PlayerState(false, ProcessingState.ready),
    );
    addTearDown(session.shutdown);
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
      child: MusicPlayerApp(
        shouldShowOnboarding: shouldShowOnboarding,
        runtimeInitializer: runtimeInitializer,
        onBootstrapSettled: onBootstrapSettled,
      ),
    ),
  );
  if (waitForStartup) {
    await _pumpMainScreenAnimations(tester, startup: true);
  }
  return _AppShellHarness(
    language: languageProvider,
    playback: runtimeGraph.playback,
    playbackService: playbackService,
  );
}

final class _TrackingAsmrDownloadManager extends AsmrDownloadManager {
  _TrackingAsmrDownloadManager() : super(persistTasks: false);

  final Completer<void> _paused = Completer<void>();
  int pauseAllCalls = 0;

  Future<void> get paused => _paused.future;

  @override
  Future<void> pauseAllTasks() async {
    pauseAllCalls++;
    if (!_paused.isCompleted) _paused.complete();
  }
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
  final pageStackFinder = find.byKey(const ValueKey<String>('main_page_stack'));
  final stack = tester.widget<AppFadeThroughIndexedStack>(pageStackFinder);
  final settingsIndex = stack.itemCount - 1;

  final navigationRail = find.byType(NavigationRail);
  if (navigationRail.evaluate().isNotEmpty) {
    tester
        .widget<NavigationRail>(navigationRail)
        .onDestinationSelected!
        .call(settingsIndex);
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
  await _waitForMainPage(tester, settingsIndex);
}

Future<void> _swipeToAsmrPage(WidgetTester tester) async {
  final destination = find.byKey(
    const ValueKey<String>('main_destination_ink_show_asmr_one'),
  );
  if (destination.evaluate().isNotEmpty) {
    await tester.tap(destination);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    return;
  }
  final navigationRail = find.byType(NavigationRail);
  if (navigationRail.evaluate().isNotEmpty) {
    tester
        .widget<NavigationRail>(navigationRail)
        .onDestinationSelected
        ?.call(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }
}

Future<void> _waitForMainPage(WidgetTester tester, int targetPage) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump();
}
