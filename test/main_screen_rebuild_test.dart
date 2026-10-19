import 'dart:convert';
import 'dart:io';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/desktop_main_navigation.dart';
import 'package:doujin_audio/app/presentation/main_screen.dart';
import 'package:doujin_audio/app/presentation/mobile_dock_capsule_content.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/cover_image_retention.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'package:doujin_audio/features/settings/presentation/settings_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

void main() {
  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          notificationsChannel,
          (_) async => {'ok': true, 'value': null},
        );
  });
  tearDown(() {
    UiInteractionCoordinator.instance.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationsChannel, null);
  });

  for (final (platform, playing, expanded, category) in [
    for (final platform in [TargetPlatform.android, TargetPlatform.windows])
      for (final playing in [false, true])
        for (final expanded
            in platform == TargetPlatform.android ? [false, true] : [false])
          for (final category in ['section_common', 'about'])
            (platform, playing, expanded, category),
  ]) {
    final presentation = switch ((platform, expanded)) {
      (TargetPlatform.windows, _) => 'desktop',
      (_, true) => 'expanded',
      _ => 'collapsed',
    };
    testWidgets('${platform.name} $category pop retains the $presentation '
        '${playing ? 'playing' : 'paused'} dock without rebuilding its tab subtree', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = platform == TargetPlatform.windows
          ? const Size(1280, 800)
          : const Size(390, 820);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('settings-pop-cover-'),
      ))!;
      final coverFile = File('${directory.path}/cover.png');
      await tester.runAsync(
        () => coverFile.writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
          ),
        ),
      );
      addTearDown(() async {
        releaseRetainedCoverImages();
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        await tester.runAsync(() => directory.delete(recursive: true));
      });
      final fixture = AppRuntimeWidgetTestFixture(
        configureSettingsRepository: (settings) {
          settings.showAsmrOne = false;
          settings.showLocalLibrary = false;
        },
      );
      addTearDown(fixture.dispose);
      final navigation = WorkDetailNavigation(
        rootNavigatorKey: GlobalKey<NavigatorState>(),
      );
      addTearDown(navigation.dispose);
      final track = testMusicTrack(
        name: 'Settings cover',
        path: '/audio/settings_pop.mp3',
        groupKey: '/audio',
        groupTitle: 'Settings',
        isSingle: true,
      ).copyWith(manualCoverPath: coverFile.path);
      final resolvedCover = await tester.runAsync(
        () => fixture.library.playbackCoverPathFutureForTrack(track),
      );
      expect(resolvedCover, coverFile.path);
      final session = PlaybackSession(
        id: 'settings_pop',
        currentTrackPath: '/audio/settings_pop.mp3',
        loopMode: SessionLoopMode.single,
        nonSingleLoopMode: SessionLoopMode.single,
        volume: 1,
        createdAt: DateTime(2026),
        customQueueTracks: [track],
        state: PlayerState(playing, ProcessingState.ready),
      );
      addTearDown(session.shutdown);
      fixture.playbackService.registerSession(session);
      fixture.settings.syncSlice(isInitialized: true);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      final snapshot = PlaybackSessionSnapshot.fromRuntime(session);
      await tester.pumpWidget(
        fixture.build(
          WorkDetailNavigationScope(
            navigation: navigation,
            child: const MainScreen(),
          ),
          overrides: [
            settingsStateProvider.overrideWithValue(
              AsyncData(fixture.settings.slice.state),
            ),
            mainOverlayUiProvider.overrideWithValue(
              MainOverlayUiState(
                overlaySessions: [snapshot],
                playingSessionCount: playing ? 1 : 0,
                hasPlayingAudioSession: playing,
                activeSessionCount: 1,
                isInitialized: true,
                startupReady: true,
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(
        find.byKey(const ValueKey('main_destination_nav_settings')),
      );
      await tester.pumpAndSettle();
      final dock = find.byType(
        platform == TargetPlatform.windows
            ? DesktopMainNavigation
            : MobileDockCapsuleContent,
        skipOffstage: false,
      );
      final carousel = find.descendant(
        of: dock,
        matching: find.byType(ActiveSessionCarousel, skipOffstage: false),
      );
      if (expanded) {
        await tester.tap(carousel);
        await tester.pumpAndSettle();
      }
      final carouselState = tester.state(carousel);
      final cover = find.descendant(
        of: dock,
        matching: find.byKey(
          const ValueKey('active_session_cover_settings_pop'),
          skipOffstage: false,
        ),
      );
      final initialCoverSize = tester.getSize(cover.first);
      final fileImage = find.descendant(
        of: cover.first,
        matching: find.byWidgetPredicate(
          (widget) => widget is Image && switch (widget.image) {
            FileImage() || ResizeImage(imageProvider: FileImage()) => true,
            _ => false,
          },
        ),
      );
      final coverImage = find.descendant(
        of: fileImage,
        matching: find.byType(RawImage),
      );
      for (
        var attempt = 0;
        attempt < 50 &&
            (coverImage.evaluate().isEmpty ||
                tester.widget<RawImage>(coverImage.first).image == null);
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.widget<RawImage>(coverImage.first).image, isNotNull);
      final decodedCover = tester
          .widget<RawImage>(coverImage.first)
          .image!
          .clone();
      addTearDown(decodedCover.dispose);
      final pages = find.descendant(
        of: dock,
        matching: find.byType(PageView, skipOffstage: false),
      );
      final initialPageSize = expanded ? tester.getSize(pages) : null;
      final contentNavigator = tester.element(
        find.byWidgetPredicate(
          (widget) =>
              widget is MainContentNavigator && widget.navigatorKey == null,
        ),
      );
      var contentNavigatorBuilds = 0;
      final beforeNavigation = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        beforeNavigation?.call(element, builtOnce);
        if (identical(element, contentNavigator)) contentNavigatorBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = beforeNavigation);
      await tester.tap(find.text(fixture.languageProvider.tr(category)));
      await tester.pumpAndSettle();
      expect(tester.state(carousel), same(carouselState));

      final header = find.byType(TopPageHeader);
      final route = ModalRoute.of(tester.element(header))! as PageRoute<void>;
      final page = find.byElementPredicate(
        (element) => identical(element, route.subtreeContext),
      );
      final origin = tester.getTopLeft(page).dx;
      expect(route.reverseTransitionDuration, kAppMotionSlow);

      await tester.tap(
        category == 'about'
            ? find.byType(BackButton).hitTestable()
            : find.byIcon(Icons.arrow_back_rounded).hitTestable(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final retainedElements = <Element>{
        tester.element(find.byType(MainScreen)),
        tester.element(find.byType(SettingsTab, skipOffstage: false)),
        tester.element(dock),
        tester.element(carousel),
        tester.element(find.byType(AppFadeThroughIndexedStack)),
      };
      final rebuiltElements = <Element>{};
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (retainedElements.contains(element)) rebuiltElements.add(element);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      var previousLeft = tester.getTopLeft(page).dx;
      var previousProgress = route.animation!.value;
      for (var frame = 0; frame < 12; frame++) {
        session.setOptimisticPosition(Duration(milliseconds: frame * 100));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.state(carousel), same(carouselState));
        expect(tester.getSize(cover.first), initialCoverSize);
        expect(route.animation!.status, AnimationStatus.reverse);
        expect(route.animation!.value, inExclusiveRange(0, previousProgress));
        final left = tester.getTopLeft(page).dx;
        expect(left, greaterThan(previousLeft));
        expect(left, greaterThan(origin));
        previousLeft = left;
        previousProgress = route.animation!.value;
        if (expanded) expect(tester.getSize(pages), initialPageSize);
      }
      debugOnRebuildDirtyWidget = previous;
      expect(
        rebuiltElements.map((element) => element.widget.runtimeType),
        isEmpty,
        reason:
            'Route animation frames must retain the settings and dock '
            'subtrees while playback progress changes.',
      );
      await tester.pump(const Duration(milliseconds: 91));
      expect(route.animation!.status, AnimationStatus.reverse);
      await tester.pump(const Duration(milliseconds: 2));
      await tester.pumpAndSettle();
      expect(tester.state(carousel), same(carouselState));
      expect(find.byType(SettingsTab), findsOneWidget);
      expect(
        tester
            .widget<RawImage>(coverImage.first)
            .image!
            .isCloneOf(decodedCover),
        isTrue,
      );
      if (platform == TargetPlatform.android) {
        expect(
          contentNavigatorBuilds,
          0,
          reason:
              'Portrait settings push and pop must retain the content navigator '
              'through route notifications and the final animation frame.',
        );
      }
      debugOnRebuildDirtyWidget = beforeNavigation;
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(UiInteractionCoordinator.instance.idleDelay);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets(
    'sidebar animation reuses main navigation while content keeps resizing',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = AppRuntimeWidgetTestFixture(
        configureSettingsRepository: (settings) {
          settings.showAsmrOne = false;
          settings.showLocalLibrary = false;
        },
      );
      addTearDown(fixture.dispose);
      fixture.settings.syncSlice(isInitialized: true);
      fixture.libraryService.syncSlice(isInitialized: true, detailRevision: 0);
      fixture.playbackService.syncSlice(
        activeSessions: [],
        playingSessionCount: 0,
        focusedSessionId: null,
        coverGeneration: 0,
        isInitialized: true,
      );
      await tester.pumpWidget(
        fixture.build(
          const MainScreen(),
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
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final navigation = tester.element(find.byType(DesktopMainNavigation));
      final content = find.byKey(const ValueKey('main_content_region'));
      expect(tester.getSize(content).width, 1020);
      await tester.tap(find.byIcon(Icons.menu_open_rounded));
      await tester.pump();

      var navigationBuilds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (identical(element, navigation)) navigationBuilds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final movingContentWidth = tester.getSize(content).width;
      expect(movingContentWidth, 1200);
      expect(navigationBuilds, 0);
      debugOnRebuildDirtyWidget = previous;
      await tester.pumpAndSettle();
      expect(tester.getSize(content).width, 1200);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
