import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/desktop_main_navigation.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/presentation/mobile_dock_capsule_content.dart';
import 'package:doujin_audio/core/media/cover_image_resolution.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/visual_settings_providers.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playback_position_ui_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final interaction = UiInteractionCoordinator.instance;
  setUp(interaction.resetForTest);
  tearDown(interaction.resetForTest);

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? 'desktop' : 'mobile'} dock keeps subtitle layout stable while its progress resizes',
      (tester) async {
        debugDefaultTargetPlatformOverride = desktop
            ? TargetPlatform.windows
            : TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        const title = '播放中的長いタイトル / Long playback title for marquee motion';
        const firstCue =
            '字幕の長い文章です。播放卡片收起时仍然保持同一行文字排版，'
            '途中反向展开也不应每帧重排。Long subtitle with emoji 🎵 and more text.';
        const nextCue = '字幕更新已恢复 / Subtitle updates resumed';
        final track = testMusicTrack(
          name: title,
          path: '/subtitle-motion/audio.mp3',
          groupKey: '/subtitle-motion',
          groupTitle: 'Subtitle motion',
        );
        fixture.library.addTracks([track], persist: false);
        final session =
            PlaybackSession(
                id: 'subtitle-motion',
                currentTrackPath: track.path,
                customQueueTracks: [track],
                loopMode: SessionLoopMode.single,
                nonSingleLoopMode: SessionLoopMode.single,
                volume: 1,
                createdAt: DateTime(2026),
                state: const PlayerState(false, ProcessingState.ready),
              )
              ..duration = const Duration(minutes: 4)
              ..setOptimisticPosition(const Duration(seconds: 30));
        addTearDown(session.shutdown);
        final subtitles = PlaybackSubtitleService(
          trackResolver: (_) => track,
          subtitleLoader: (_, _) async => SubtitleTrack(
            sourcePath: '/subtitle-motion/audio.srt',
            cues: const [
              SubtitleCue(
                start: Duration.zero,
                end: Duration(minutes: 1),
                text: firstCue,
              ),
              SubtitleCue(
                start: Duration(minutes: 1),
                end: Duration(minutes: 2),
                text: nextCue,
              ),
            ],
          ),
        );
        addTearDown(subtitles.dispose);
        await subtitles.load(track.path);
        final geometryKey = GlobalKey();
        final activeIndex = ValueNotifier(0);
        addTearDown(activeIndex.dispose);
        final iconKeys = List.generate(
          MainDestinationType.values.length,
          (_) => GlobalKey(),
        );
        final iconLinks = List.generate(
          MainDestinationType.values.length,
          (_) => LayerLink(),
        );
        var expanded = true;
        var showPlaybackCalls = 0;
        Widget shell() => fixture.build(
          MediaQuery(
            data: const MediaQueryData(size: Size(1280, 800)),
            child: Center(
              child: SizedBox(
                width: 400,
                height: 500,
                child: desktop
                    ? Align(
                        alignment: Alignment.topLeft,
                        child: DesktopMainNavigation(
                          i18n: fixture.languageProvider,
                          overlaySessions: [
                            PlaybackSessionSnapshot.fromRuntime(session),
                          ],
                          destinations: resolveMainDestinations(
                            showLocalLibrary: true,
                            showAsmrOne: true,
                          ),
                          isMenuCollapsed: !expanded,
                          activePageIndex: activeIndex,
                          menuIconKeys: iconKeys,
                          menuIconLinks: iconLinks,
                          collapseOffset: (_, _) => Offset.zero,
                          onSwitchPage: (_) {},
                          onToggleMenu: () {},
                          playbackGeometryKey: geometryKey,
                          onReportPlaybackRect:
                              ({
                                required dockCollapsed,
                                required dockAreaWidth,
                                required expandedDockWidth,
                              }) {},
                        ),
                      )
                    : MobileDockCapsuleContent(
                        overlaySessions: [
                          PlaybackSessionSnapshot.fromRuntime(session),
                        ],
                        isPlaybackExpanded: expanded,
                        i18n: fixture.languageProvider,
                        mobilePlaybackGeometryKey: geometryKey,
                        onShowPlayback: () => showPlaybackCalls++,
                        onShowDestinations: () {},
                        onReportPlaybackCoverRect: () {},
                        buildBottomBar:
                            (
                              _, {
                              required isPlaybackExpanded,
                              required appearance,
                              required expansion,
                              required availableWidth,
                              required onCurrentTap,
                            }) => const SizedBox.expand(),
                      ),
              ),
            ),
          ),
          subtitleService: subtitles,
        );
        Finder paragraph(String text) => find.byWidgetPredicate(
          (widget) => widget is RichText && widget.text.toPlainText() == text,
        );
        final progress = find.byWidgetPredicate(
          (widget) =>
              widget is ClipRRect &&
              widget.borderRadius == BorderRadius.circular(2.5),
        );
        void expectSettledTextWidth() {
          final subtitle = tester.renderObject<RenderParagraph>(
            paragraph(firstCue).first,
          );
          expect(
            subtitle.constraints.maxWidth,
            closeTo(tester.getSize(progress.first).width, 0.001),
          );
          if (desktop) {
            expect(
              tester.getSize(find.byType(DesktopMainNavigation)).width,
              closeTo(260, 0.001),
            );
          }
        }

        await tester.pumpWidget(shell());
        await tester.pumpAndSettle();
        expect(paragraph(firstCue), findsWidgets);
        expectSettledTextWidth();
        final subtitleWidth = tester
            .renderObject<RenderParagraph>(paragraph(firstCue).first)
            .constraints
            .maxWidth;
        final titleWidth = tester
            .renderObject<RenderParagraph>(paragraph(title).first)
            .constraints
            .maxWidth;
        final titlePaintWidth = tester
            .renderObject<RenderParagraph>(paragraph(title).first)
            .size
            .width;
        final progressWidths = <double>{};
        var sampledTextFrames = 0;
        Future<void> sampleFrames(int count) async {
          for (var frame = 0; frame < count; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
            if (paragraph(firstCue).evaluate().isNotEmpty) {
              sampledTextFrames++;
              for (final (text, width) in [
                (firstCue, subtitleWidth),
                (title, titleWidth),
              ]) {
                for (final element in paragraph(text).evaluate()) {
                  final render = element.renderObject! as RenderParagraph;
                  expect(
                    render.constraints.maxWidth,
                    width.isFinite ? closeTo(width, 0.001) : equals(width),
                  );
                  if (text == title) {
                    expect(render.size.width, closeTo(titlePaintWidth, 0.001));
                  }
                  if (text == firstCue) expect(render.maxLines, 1);
                }
              }
              progressWidths.add(tester.getSize(progress.first).width);
            }
            expect(tester.takeException(), isNull);
          }
        }

        expanded = false;
        await tester.pumpWidget(shell());
        await sampleFrames(4);
        expanded = true;
        await tester.pumpWidget(shell());
        await sampleFrames(16);
        await tester.pumpAndSettle();
        expanded = false;
        await tester.pumpWidget(shell());
        await sampleFrames(24);
        await tester.pumpAndSettle();
        expect(paragraph(firstCue), findsNothing);
        if (!desktop) {
          await tester.tap(
            find.byKey(
              const ValueKey<String>('active_session_card_subtitle-motion'),
            ),
          );
          expect(showPlaybackCalls, 1);
        }
        expanded = true;
        await tester.pumpWidget(shell());
        await sampleFrames(24);
        await tester.pumpAndSettle();
        expect(sampledTextFrames, greaterThan(8));
        expect(progressWidths.length, greaterThan(3));
        expect(paragraph(firstCue), findsWidgets);
        expectSettledTextWidth();
        await tester.pump(interaction.idleDelay);
        session.setOptimisticPosition(const Duration(seconds: 90));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(paragraph(firstCue), findsNothing);
        expect(paragraph(nextCue), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('dock progress resizing avoids frame rebuilds on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final session =
          PlaybackSession(
              id: 'resize-progress',
              currentTrackPath: '/resize-progress.mp3',
              loopMode: SessionLoopMode.single,
              nonSingleLoopMode: SessionLoopMode.single,
              volume: 1,
              createdAt: DateTime(2026),
              state: const PlayerState(false, ProcessingState.ready),
            )
            ..duration = const Duration(minutes: 4)
            ..setOptimisticPosition(const Duration(minutes: 1));
      addTearDown(session.shutdown);
      final geometryKey = GlobalKey();
      var expanded = true;
      Widget shell() => fixture.build(
        Center(
          child: SizedBox(
            width: 400,
            height: kActiveSessionCarouselDockHeight,
            child: MobileDockCapsuleContent(
              overlaySessions: [PlaybackSessionSnapshot.fromRuntime(session)],
              isPlaybackExpanded: expanded,
              i18n: fixture.languageProvider,
              mobilePlaybackGeometryKey: geometryKey,
              onShowPlayback: () {},
              onShowDestinations: () {},
              onReportPlaybackCoverRect: () {},
              buildBottomBar:
                  (
                    _, {
                    required isPlaybackExpanded,
                    required appearance,
                    required expansion,
                    required availableWidth,
                    required onCurrentTap,
                  }) => const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pumpWidget(shell());
      await tester.pumpAndSettle();
      final progress = find.byWidgetPredicate(
        (widget) =>
            widget is ClipRRect &&
            widget.borderRadius == BorderRadius.circular(2.5),
      );
      DecoratedBox progressBackground() => tester.widget<DecoratedBox>(
        find
            .descendant(of: progress, matching: find.byType(DecoratedBox))
            .first,
      );
      var progressRebuilds = 0;
      Future<void> sampleFrames() async {
        var previous = progressBackground();
        for (var frame = 0; frame < 7; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final next = progressBackground();
          if (!identical(next, previous)) progressRebuilds++;
          previous = next;
        }
      }

      expanded = false;
      await tester.pumpWidget(shell());
      // Stay above the compact-cover threshold, then reverse mid-motion.
      await sampleFrames();
      expanded = true;
      await tester.pumpWidget(shell());
      await sampleFrames();
      await tester.pumpAndSettle();
      expect(progressRebuilds, 0);
      await tester.pump(interaction.idleDelay);
      await tester.pumpAndSettle();
      for (final (position, fraction) in [
        (Duration.zero, 0.0),
        (const Duration(minutes: 2), 0.5),
        (const Duration(minutes: 4), 1.0),
        (const Duration(minutes: 5), 1.0),
      ]) {
        session.setOptimisticPosition(position);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final fill = find.descendant(
          of: find.descendant(
            of: progress,
            matching: find.byType(FractionallySizedBox),
          ),
          matching: find.byType(DecoratedBox),
        );
        expect(
          tester.getSize(fill).width,
          closeTo(tester.getSize(progress).width * fraction, 0.01),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'carousel rebuilds indicators only at mapped page changes on $platform',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final sessions = [
          for (final id in ['one', 'two', 'three'])
            PlaybackSession(
              id: id,
              currentTrackPath: '/$id.mp3',
              loopMode: SessionLoopMode.single,
              nonSingleLoopMode: SessionLoopMode.single,
              volume: 1,
              createdAt: DateTime(2026),
              state: const PlayerState(false, ProcessingState.idle),
            ),
        ];
        for (final session in sessions) {
          addTearDown(session.shutdown);
        }
        Widget carousel(List<PlaybackSession> shown) => fixture.build(
          Center(
            child: SizedBox(
              width: 320,
              child: ActiveSessionCarousel(
                sessions: shown
                    .map(PlaybackSessionSnapshot.fromRuntime)
                    .toList(),
                viewportFraction: 1,
                presentation: ActiveSessionCarouselPresentation.embedded,
                onOpenSession: (_) {},
              ),
            ),
          ),
        );
        await tester.pumpWidget(carousel(sessions));
        await tester.pumpAndSettle();
        final indicator = find.byKey(
          const ValueKey('active_session_indicator'),
        );
        AnimatedContainer firstDot() => tester.widget<AnimatedContainer>(
          find
              .descendant(
                of: indicator,
                matching: find.byType(AnimatedContainer),
              )
              .first,
        );
        var previous = firstDot();
        var indicatorRebuilds = 0;
        Future<void> move(TestGesture gesture) async {
          await gesture.moveBy(const Offset(-20, 0));
          await tester.pump(const Duration(milliseconds: 40));
          final next = firstDot();
          if (!identical(next, previous)) indicatorRebuilds++;
          previous = next;
        }

        final gesture = await tester.startGesture(
          tester.getCenter(find.byType(PageView)),
        );
        final initialPage = tester
            .widget<PageView>(find.byType(PageView))
            .controller!
            .page!;
        for (var step = 0; step < 4; step++) {
          await move(gesture);
        }
        final fractionalPage = tester
            .widget<PageView>(find.byType(PageView))
            .controller!
            .page!;
        expect(fractionalPage, greaterThan(initialPage));
        expect(fractionalPage.round(), initialPage.round());
        expect(indicatorRebuilds, 0);
        for (var step = 0; step < 6; step++) {
          await move(gesture);
        }
        expect(indicatorRebuilds, 1);
        expect(tester.widget<Semantics>(indicator).properties.label, '2 / 3');
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          carousel([sessions[1], sessions[0], sessions[2]]),
        );
        await tester.pumpAndSettle();
        expect(tester.widget<Semantics>(indicator).properties.label, '1 / 3');
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final desktop in [false, true]) {
    testWidgets(
      '${desktop ? 'desktop' : 'mobile'} dock protects motion and releases on reversal, hide, reduced motion and disposal',
      (tester) async {
        debugDefaultTargetPlatformOverride = desktop
            ? TargetPlatform.windows
            : TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final session = PlaybackSession(
          id: 'motion',
          currentTrackPath: '/motion.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.idle),
        );
        addTearDown(session.shutdown);
        final geometryKey = GlobalKey();
        final index = ValueNotifier<int>(0);
        addTearDown(index.dispose);
        final iconKeys = List.generate(MainDestinationType.values.length, (_) => GlobalKey());
        final iconLinks = List.generate(MainDestinationType.values.length, (_) => LayerLink());
        var expanded = false;
        var visible = true;
        var reduced = false;
        var hasPlayback = desktop;
        var geometryReports = 0;
        Widget shell() {
          final sessions = hasPlayback
              ? [PlaybackSessionSnapshot.fromRuntime(session)]
              : <PlaybackSessionSnapshot>[];
          final dock = desktop
              ? DesktopMainNavigation(
                  i18n: fixture.languageProvider,
                  overlaySessions: sessions,
                  destinations: resolveMainDestinations(
                    showLocalLibrary: true,
                    showAsmrOne: true,
                  ),
                  isMenuCollapsed: !expanded,
                  activePageIndex: index,
                  menuIconKeys: iconKeys,
                  menuIconLinks: iconLinks,
                  collapseOffset: (_, _) => Offset.zero,
                  onSwitchPage: (_) {},
                  onToggleMenu: () {},
                  playbackGeometryKey: geometryKey,
                  onReportPlaybackRect:
                      ({
                        required dockCollapsed,
                        required dockAreaWidth,
                        required expandedDockWidth,
                      }) {
                        geometryReports++;
                      },
                )
              : MobileDockCapsuleContent(
                  overlaySessions: sessions,
                  isPlaybackExpanded: expanded,
                  i18n: fixture.languageProvider,
                  mobilePlaybackGeometryKey: geometryKey,
                  onShowPlayback: () {},
                  onShowDestinations: () {},
                  onReportPlaybackCoverRect: () => geometryReports++,
                  buildBottomBar:
                      (
                        _, {
                        required isPlaybackExpanded,
                        required appearance,
                        required expansion,
                        required availableWidth,
                        required onCurrentTap,
                      }) => const SizedBox.expand(),
                );
          return fixture.build(
            MediaQuery(
              data: MediaQueryData(
                size: const Size(1280, 800),
                disableAnimations: reduced,
              ),
              child: TickerMode(
                enabled: visible,
                child: Center(
                  child: SizedBox(width: 400, height: 500, child: dock),
                ),
              ),
            ),
          );
        }

        void expectVisualProtection(bool protected) {
          if (!desktop) {
            expect(interaction.isVisualUpdateDeferred, protected);
          }
        }

        await tester.pumpWidget(shell());
        await tester.pumpAndSettle();
        expectVisualProtection(false);
        if (!desktop) {
          hasPlayback = true;
          await tester.pumpWidget(shell());
          expect(interaction.isInteracting, isTrue);
          expectVisualProtection(true);
          await tester.pump(const Duration(milliseconds: 40));
          expectVisualProtection(true);
          await tester.pumpAndSettle();
          await tester.pump(interaction.idleDelay);
          expectVisualProtection(false);
        }
        final progress = PlaybackPositionUiGate(
          session: PlaybackSessionSnapshot.fromRuntime(session),
          minUpdateInterval: Duration.zero,
        );
        addTearDown(progress.dispose);
        var progressNotifications = 0;
        progress.addListener(() => progressNotifications++);
        expanded = true;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isTrue);
        expectVisualProtection(true);
        var dataCommits = 0;
        interaction.scheduleCommit(
          key: 'dock_motion_data',
          commit: () => dataCommits++,
        );
        for (var value = 1; value <= 20; value++) {
          session.setOptimisticPosition(Duration(seconds: value));
        }
        expect(session.position, const Duration(seconds: 20));
        await tester.pump(const Duration(milliseconds: 80));
        expect(dataCommits, 0);
        expect(progressNotifications, 0);
        expanded = false;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isTrue);
        expectVisualProtection(true);
        for (var value = 21; value <= 40; value++) {
          session.setOptimisticPosition(Duration(seconds: value));
        }
        expect(session.position, const Duration(seconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
        expect(progressNotifications, 0);
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        expect(interaction.isInteracting, isFalse);
        expectVisualProtection(false);
        expect(dataCommits, 1);
        expect(progressNotifications, 1);
        expect(progress.value.position, const Duration(seconds: 40));
        expect(geometryReports, greaterThan(0));

        expanded = true;
        await tester.pumpWidget(shell());
        await tester.pump(const Duration(milliseconds: 40));
        visible = false;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isFalse);
        expectVisualProtection(false);
        visible = true;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isTrue);
        expectVisualProtection(true);
        reduced = true;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isFalse);
        expectVisualProtection(false);
        expanded = false;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isFalse);
        expectVisualProtection(false);

        reduced = false;
        if (!desktop) {
          hasPlayback = false;
          await tester.pumpWidget(shell());
          expect(interaction.isInteracting, isTrue);
          expectVisualProtection(true);
          await tester.pumpAndSettle();
          await tester.pump(interaction.idleDelay);
          expect(interaction.isInteracting, isFalse);
          expectVisualProtection(false);
          hasPlayback = true;
          await tester.pumpWidget(shell());
          expect(interaction.isInteracting, isTrue);
          expectVisualProtection(true);
        } else {
          expanded = true;
          await tester.pumpWidget(shell());
          expect(interaction.isInteracting, isTrue);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(interaction.isInteracting, isFalse);
        expectVisualProtection(false);
        debugDefaultTargetPlatformOverride = null;
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final preparationDelayMs in [96, 640]) {
    testWidgets(
      'mobile dock prepares its first card before starting entrance ($preparationDelayMs ms)',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final session = PlaybackSession(
          id: 'first-entrance',
          currentTrackPath: '/first-entrance.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.idle),
        );
        addTearDown(session.shutdown);
        final geometryKey = GlobalKey();
        var hasPlayback = false;
        var navigationLayouts = 0;
        Widget shell() => fixture.build(
          Center(
            child: SizedBox(
              width: 400,
              height: kActiveSessionCarouselDockHeight,
              child: MobileDockCapsuleContent(
                overlaySessions: hasPlayback
                    ? [PlaybackSessionSnapshot.fromRuntime(session)]
                    : const [],
                isPlaybackExpanded: false,
                i18n: fixture.languageProvider,
                mobilePlaybackGeometryKey: geometryKey,
                onShowPlayback: () {},
                onShowDestinations: () {},
                onReportPlaybackCoverRect: () {},
                buildBottomBar:
                    (
                      _, {
                      required isPlaybackExpanded,
                      required appearance,
                      required expansion,
                      required availableWidth,
                      required onCurrentTap,
                    }) => LayoutBuilder(
                      builder: (context, constraints) {
                        navigationLayouts++;
                        return const SizedBox.expand();
                      },
                    ),
              ),
            ),
          ),
        );
        final playback = find.byKey(
          const ValueKey<String>('mobile_dock_playback'),
        );

        await tester.pumpWidget(shell());
        await tester.pumpAndSettle();
        hasPlayback = true;
        await tester.pumpWidget(shell());
        final initialRect = tester.getRect(playback);
        final dockRect = tester.getRect(find.byType(MobileDockCapsuleContent));
        expect(initialRect.left, closeTo(dockRect.right, 0.001));

        // The card's first layout and paint may miss several display frames.
        // Its initial offscreen preparation must not spend entrance duration.
        await tester.pump(Duration(milliseconds: preparationDelayMs));
        expect(tester.getRect(playback), initialRect);
        final preparedNavigationLayouts = navigationLayouts;
        for (var frame = 0; frame < 5; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(navigationLayouts, preparedNavigationLayouts);
        }
        final movingRect = tester.getRect(playback);
        expect(movingRect.left, lessThan(initialRect.left));
        expect(
          movingRect.left,
          greaterThan(initialRect.left - kActiveSessionCarouselDockHeight),
        );
        await tester.pump(const Duration(milliseconds: 280));
        expect(tester.getRect(playback).right, closeTo(dockRect.right, 0.001));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(interaction.isVisualUpdateDeferred, isFalse);
        debugDefaultTargetPlatformOverride = null;
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (platform, presentation) in [
    (TargetPlatform.android, ActiveSessionCarouselPresentation.embedded),
    (TargetPlatform.windows, ActiveSessionCarouselPresentation.embedded),
    (TargetPlatform.android, ActiveSessionCarouselPresentation.circularCover),
    (TargetPlatform.windows, ActiveSessionCarouselPresentation.circularCover),
  ]) {
    testWidgets(
      'round dock focuses new playback without horizontal paging ($platform, $presentation)',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final sessions = [
          for (final id in ['first', 'second'])
            PlaybackSession(
              id: id,
              currentTrackPath: '/$id.mp3',
              loopMode: SessionLoopMode.single,
              nonSingleLoopMode: SessionLoopMode.single,
              volume: 1,
              createdAt: DateTime(2026),
              state: const PlayerState(true, ProcessingState.ready),
            ),
        ];
        for (final session in sessions) {
          addTearDown(session.shutdown);
        }
        var dockWidth = kActiveSessionCarouselDockHeight;
        Widget dock(
          List<PlaybackSession> shown, {
          CoverImageResolution resolution = CoverImageResolution.balanced,
        }) => fixture.build(
          Center(
            child: SizedBox(
              width: dockWidth,
              height: kActiveSessionCarouselDockHeight,
              child: ActiveSessionCarousel(
                presentation: presentation,
                viewportFraction: 1,
                sessions: shown
                    .map(PlaybackSessionSnapshot.fromRuntime)
                    .toList(),
                onOpenSession: (_) {},
              ),
            ),
          ),
          overrides: [
            coverImageResolutionProvider.overrideWithValue(resolution),
          ],
        );

        for (final resolution in [
          CoverImageResolution.balanced,
          CoverImageResolution.original,
        ]) {
          await tester.pumpWidget(
            dock([sessions.first], resolution: resolution),
          );
          await tester.pumpAndSettle();
          final coverFinder = find.byType(AsyncLocalCoverImage);
          expect(coverFinder, findsOneWidget);
          final cover = tester.widget<AsyncLocalCoverImage>(coverFinder);
          final dimension =
              presentation == ActiveSessionCarouselPresentation.circularCover
              ? 56.0
              : 48.0;
          expect(
            cover.cacheWidth,
            coverThumbnailCacheWidth(
              logicalWidth: dimension,
              devicePixelRatio: MediaQuery.devicePixelRatioOf(
                tester.element(coverFinder),
              ),
              resolution: resolution,
            ),
          );
        }
        await tester.pumpWidget(dock([sessions.first]));
        await tester.pumpAndSettle();
        final controller = ProviderScope.containerOf(
          tester.element(find.byType(ActiveSessionCarousel)),
        ).read(playlistUiControllerProvider);
        controller.requestCarouselSnap('second');
        await tester.pumpWidget(dock(sessions));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(PageView), findsNothing);
        final card = find.byKey(
          const ValueKey<String>('active_session_card_second'),
        );
        expect(card, findsOneWidget);
        expect(
          tester.getCenter(card),
          tester.getCenter(find.byType(ActiveSessionCarousel)),
        );
        await tester.pumpAndSettle();

        // Playback activation can also arrive after the session list is rebuilt.
        controller.requestCarouselSnap('first');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final first = find.byKey(
          const ValueKey<String>('active_session_card_first'),
        );
        expect(first, findsOneWidget);
        expect(
          tester.getCenter(first),
          tester.getCenter(find.byType(ActiveSessionCarousel)),
        );

        if (presentation == ActiveSessionCarouselPresentation.embedded) {
          // Expanding restores the same selection and enables animated paging.
          dockWidth = 320;
          await tester.pumpWidget(dock(sessions));
          await tester.pump();
          expect(find.byType(PageView), findsOneWidget);
          expect(
            tester
                .widgetList<AsyncLocalCoverImage>(
                  find.byType(AsyncLocalCoverImage),
                )
                .every((cover) => cover.deferLoadDuringInteraction),
            isTrue,
          );
          expect(
            tester.getCenter(first),
            tester.getCenter(find.byType(ActiveSessionCarousel)),
          );
          final gesture = await tester.startGesture(
            tester.getCenter(find.byType(PageView)),
          );
          await gesture.moveBy(const Offset(-90, 0));
          await tester.pump(const Duration(milliseconds: 40));
          expect(interaction.isInteracting, isTrue);
          final displayedValues = <int>[];
          for (final value in [1, 2]) {
            interaction.scheduleCommit(
              key: 'carousel_gesture_data',
              commit: () => displayedValues.add(value),
            );
          }
          await tester.pump(const Duration(milliseconds: 40));
          expect(displayedValues, isEmpty);
          await gesture.up();
          await tester.pumpAndSettle();
          await tester.pump(
            tester
                .widget<ScrollActivityGate>(find.byType(ScrollActivityGate))
                .idleDelay,
          );
          await tester.pump(interaction.idleDelay);
          expect(displayedValues, [2]);
          expect(interaction.isInteracting, isFalse);

          controller.requestCarouselSnap('first');
          await tester.pumpAndSettle();
          await tester.pump(interaction.idleDelay);
          controller.requestCarouselSnap('second');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          final page = tester
              .widget<PageView>(find.byType(PageView))
              .controller!
              .page!;
          expect((page - page.roundToDouble()).abs(), greaterThan(0.0001));
          expect(interaction.isInteracting, isTrue);

          // Collapsing during paging removes the moving viewport immediately.
          dockWidth = kActiveSessionCarouselDockHeight;
          await tester.pumpWidget(dock(sessions));
          await tester.pump();
          expect(find.byType(PageView), findsNothing);
          expect(interaction.isInteracting, isFalse);
          expect(card, findsOneWidget);
          expect(
            tester.getCenter(card),
            tester.getCenter(find.byType(ActiveSessionCarousel)),
          );

          dockWidth = 320;
          await tester.pumpWidget(dock(sessions));
          await tester.pump();
          expect(
            tester.widget<PageView>(find.byType(PageView)).controller!.page,
            page.roundToDouble(),
          );
          controller.requestCarouselSnap('first');
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(interaction.isInteracting, isTrue);
          displayedValues.clear();
          for (final value in [3, 4]) {
            interaction.scheduleCommit(
              key: 'carousel_programmatic_data',
              commit: () => displayedValues.add(value),
            );
          }
          await tester.pump();
          expect(displayedValues, isEmpty);
          await tester.pumpAndSettle();
          await tester.pump(
            tester
                .widget<ScrollActivityGate>(find.byType(ScrollActivityGate))
                .idleDelay,
          );
          await tester.pump(interaction.idleDelay);
          expect(displayedValues, [4]);
          expect(interaction.isInteracting, isFalse);
          dockWidth = kActiveSessionCarouselDockHeight;
          await tester.pumpWidget(dock(sessions));
        }

        // Removing the focused round card selects its neighbor in place.
        await tester.pumpWidget(dock([sessions.last]));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(card, findsOneWidget);
        expect(
          tester.getCenter(card),
          tester.getCenter(find.byType(ActiveSessionCarousel)),
        );
        debugDefaultTargetPlatformOverride = null;
        expect(tester.takeException(), isNull);
      },
    );
  }
}
