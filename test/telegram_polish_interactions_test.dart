import 'dart:async';

import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/core/media/subtitle_parser.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_feedback.dart';
import 'package:doujin_audio/core/widgets/app_search_page.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/sliding_selection_indicator.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_action_pane.dart';
import 'package:doujin_audio/core/widgets/swipe_reveal_card.dart';
import 'package:doujin_audio/features/library/presentation/work_image_viewer_page.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/application/playback_subtitle_service.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/playlist/playlist_progress_widgets.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_page.dart';
import 'package:doujin_audio/features/player/presentation/playlist/timeline_subtitle_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();
  final coordinator = UiInteractionCoordinator.instance;
  setUp(coordinator.resetForTest);
  tearDown(coordinator.resetForTest);

  group('Telegram-inspired interaction polish', () {
    testWidgets(
      'WorkImageViewerPage animates double-tap zoom, toggles chrome, and handles vertical drag-to-dismiss',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        const images = [
          WorkImageItem(
            name: '01.jpg',
            path: 'path/to/01.jpg',
            relativePath: '01.jpg',
          ),
        ];

        await tester.pumpWidget(
          fixture.build(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      buildAppPageRoute<void>(
                        context: context,
                        child: const WorkImageViewerPage(images: images),
                      ),
                    );
                  },
                  child: const Text('Open viewer'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open viewer'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        final viewport = find.byKey(
          const ValueKey<String>('work_image_viewport'),
        );
        expect(viewport, findsOneWidget);

        // Single tap toggles chrome fade.
        final viewerFinder = find.byType(InteractiveViewer);
        bool isHeaderHidden() => tester
            .widgetList<Opacity>(
              find.ancestor(
                of: find.byKey(const ValueKey<String>('work_image_header')),
                matching: find.byType(Opacity),
              ),
            )
            .any((widget) => widget.opacity == 0.0);
        expect(isHeaderHidden(), isFalse);
        await tester.tap(viewport);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(milliseconds: 220));
        expect(isHeaderHidden(), isTrue);
        await tester.tap(viewport);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(milliseconds: 220));
        expect(isHeaderHidden(), isFalse);

        // Double-tap animates zoom continuously rather than snapping in 1 frame.
        await tester.tap(viewport);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(viewport);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        final controller =
            tester.widget<InteractiveViewer>(viewerFinder).transformationController!;
        final midScale = controller.value.getMaxScaleOnAxis();
        expect(midScale, greaterThan(1.0));
        expect(midScale, lessThan(2.5));
        await tester.pump(const Duration(milliseconds: 260));
        expect(controller.value.getMaxScaleOnAxis(), closeTo(2.5, 0.01));

        // Double-tap again animates back to 1.0.
        await tester.tap(viewport);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(viewport);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

        // Small unzoomed vertical drag springs back cleanly.
        await tester.drag(viewport, const Offset(0, 50));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(WorkImageViewerPage), findsOneWidget);

        // Large vertical drag dismisses the viewer route.
        await tester.drag(viewport, const Offset(0, 180));
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(WorkImageViewerPage), findsNothing);
        expect(find.text('Open viewer'), findsOneWidget);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets(
      'SessionDetailScaffold portrait drag springs back under threshold and dismisses past threshold',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 820);
        addTearDown(tester.view.reset);

        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final track = testMusicTrack(
          name: 'Drag Track',
          path: '/music/drag.mp3',
          groupKey: '/music',
          groupTitle: 'Music',
        );
        fixture.library.addTracks([track], persist: false);
        final session = fixture.playback.createTrackSession(track);
        final subtitles = PlaybackSubtitleService(
          trackResolver: (_) => track,
          subtitleLoader: (_, _) async => SubtitleTrack(
            sourcePath: '/music/drag.srt',
            cues: [
              for (var index = 0; index < 8; index++)
                SubtitleCue(
                  start: Duration(seconds: index * 5),
                  end: Duration(seconds: (index + 1) * 5),
                  text: 'Subtitle line $index',
                ),
            ],
          ),
        );
        session.setOptimisticPosition(const Duration(seconds: 17));
        expect(await subtitles.load(track.path), isNotNull);
        fixture.playbackService.syncSlice(
          activeSessions: [session],
          playingSessionCount: 0,
          focusedSessionId: session.id,
          coverGeneration: 0,
          isInitialized: true,
        );
        final orientation = AppOrientationController(
          setPreferredOrientations: (_) async {},
          setSystemUiMode: (_) async {},
        );
        await orientation.updateDisplay(390);

        await tester.pumpWidget(
          fixture.build(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      buildSessionDetailRoute(sessionId: session.id),
                    );
                  },
                  child: const Text('Open detail'),
                ),
              ),
            ),
            subtitleService: subtitles,
            overrides: [
              appOrientationControllerProvider.overrideWithValue(orientation),
            ],
          ),
        );
        await tester.tap(find.text('Open detail'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('session_detail_close_button')),
          findsOneWidget,
        );

        final timeline = find.byType(TimelineSubtitleView);
        final timelineState = tester.state(timeline);
        final scrollable = find.descendant(
          of: timeline,
          matching: find.byType(Scrollable),
        );
        final scrollPosition = tester
            .state<ScrollableState>(scrollable)
            .position;
        final offset = scrollPosition.pixels;
        expect(offset, greaterThan(0));
        final originalTop = tester.getTopLeft(timeline).dy;

        void expectStableSubtitle() {
          expect(tester.state(timeline), same(timelineState));
          expect(
            tester.state<ScrollableState>(scrollable).position,
            same(scrollPosition),
          );
          expect(scrollPosition.pixels, offset);
        }

        // Small pull near top springs back without closing.
        final pull = await tester.startGesture(const Offset(195, 160));
        await pull.moveBy(const Offset(0, 24));
        await pull.moveBy(const Offset(0, 26));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(timeline).dy, greaterThan(originalTop));
        expectStableSubtitle();
        await pull.up();
        await tester.pumpAndSettle();
        expectStableSubtitle();
        expect(tester.getTopLeft(timeline).dy, originalTop);
        expect(
          find.byKey(const ValueKey('session_detail_close_button')),
          findsOneWidget,
        );

        // Large pull down closes the portrait detail route.
        final dismiss = await tester.startGesture(const Offset(195, 160));
        await dismiss.moveBy(const Offset(0, 24));
        await dismiss.moveBy(const Offset(0, 156));
        await tester.pump(const Duration(milliseconds: 16));
        expectStableSubtitle();
        await dismiss.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 32));
        expectStableSubtitle();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('session_detail_close_button')),
          findsNothing,
        );
        expect(find.text('Open detail'), findsOneWidget);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets('showAppSnackBar supports upward swipe-to-dismiss', (
      tester,
    ) async {
      AppFeedbackDismissReason? reason;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  showAppSnackBar(
                    context,
                    'Swipe up toast',
                    onDismissed: (r) => reason = r,
                  );
                },
                child: const Text('Show toast'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show toast'));
      await tester.pumpAndSettle();
      expect(find.text('Swipe up toast'), findsOneWidget);

      await tester.drag(find.text('Swipe up toast'), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(find.text('Swipe up toast'), findsNothing);
      expect(reason, AppFeedbackDismissReason.swipe);
    });

    testWidgets(
      'AppPreparedPageRoute supports left-edge swipe back on Android',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      buildAppPageRoute<void>(
                        context: context,
                        child: const Scaffold(
                          body: Center(child: Text('Second page')),
                        ),
                      ),
                    );
                  },
                  child: const Text('Push page'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Push page'));
        await tester.pumpAndSettle();
        expect(find.text('Second page'), findsOneWidget);

        // Short edge drag cancels back without popping.
        final cancelGesture = await tester.startGesture(const Offset(10, 200));
        await cancelGesture.moveBy(const Offset(60, 0));
        await cancelGesture.up();
        await tester.pumpAndSettle();
        expect(find.text('Second page'), findsOneWidget);

        // Full edge drag pops back to home page.
        await tester.dragFrom(const Offset(10, 200), const Offset(360, 0));
        await tester.pumpAndSettle();
        expect(find.text('Second page'), findsNothing);
        expect(find.text('Push page'), findsOneWidget);
      },
      variant: const TargetPlatformVariant({TargetPlatform.android}),
    );

    testWidgets('SwipeRevealCard fast closing fling closes an open card', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 280,
                height: 96,
                child: SwipeRevealCard(
                  shape: const RoundedRectangleBorder(),
                  actionLabel: 'Remove',
                  removeTooltip: 'Remove',
                  onRemove: () {},
                  child: const SizedBox.expand(child: Text('Fling card')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.text('Fling card'), const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove'), findsOneWidget);

      await tester.fling(
        find.byType(SwipeRevealCard),
        const Offset(120, 0),
        1200,
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove'), findsNothing);
    });

    test(
      'UiInteractionCoordinator.beginNavigation with lockInput false defers background work without blocking input',
      () {
        coordinator.beginNavigation('tab-switch', lockInput: false);
        expect(coordinator.navigationAllowed.value, isFalse);
        expect(coordinator.navigationInputAllowed.value, isTrue);

        coordinator.endNavigation('tab-switch');
        expect(coordinator.navigationAllowed.value, isTrue);
        expect(coordinator.navigationInputAllowed.value, isTrue);
      },
    );

    testWidgets(
      'SlidingSelectionIndicator tracks overridePosition immediately and springs to target index when cleared',
      (tester) async {
        double? reportedPosition;

        Widget buildSubject({required int index, double? overridePosition}) {
          return MaterialApp(
            home: Scaffold(
              body: SlidingSelectionIndicator(
                index: index,
                layoutKey: 'capsule',
                overridePosition: overridePosition,
                builder: (_, position, child) {
                  reportedPosition = position;
                  return child!;
                },
                child: const SizedBox(width: 240, height: 48),
              ),
            ),
          );
        }

        await tester.pumpWidget(buildSubject(index: 0));
        expect(reportedPosition, closeTo(0.0, 0.001));

        await tester.pumpWidget(buildSubject(index: 0, overridePosition: 1.4));
        await tester.pump();
        expect(reportedPosition, closeTo(1.4, 0.001));

        await tester.pumpWidget(buildSubject(index: 2));
        await tester.pump();
        expect(reportedPosition, closeTo(1.4, 0.001));

        await tester.pump(const Duration(milliseconds: 70));
        expect(reportedPosition, inExclusiveRange(1.4, 2.0));

        await tester.pumpAndSettle();
        expect(reportedPosition, closeTo(2.0, 0.001));
      },
    );

    testWidgets(
      'SwipeRevealCard begins translating after small horizontal threshold',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  height: 72,
                  child: SwipeRevealCard(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    actionLabel: 'Remove',
                    removeTooltip: 'Remove',
                    onRemove: () {},
                    child: const ColoredBox(
                      color: Colors.blueGrey,
                      child: Center(child: Text('Short drag card')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final initialRight = tester.getRect(find.text('Short drag card')).right;
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Short drag card')),
        );
        await gesture.moveBy(const Offset(-20, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));

        expect(
          tester.getRect(find.text('Short drag card')).right,
          lessThan(initialRight),
        );

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'SessionProgressBar applies 0.5x and 0.25x fine-scrub sensitivity when dragging vertically off track',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        final session = PlaybackSession(
          id: 'fine-scrub-session',
          currentTrackPath: '/library/track.mp3',
          loopMode: SessionLoopMode.single,
          nonSingleLoopMode: SessionLoopMode.single,
          volume: 1,
          createdAt: DateTime(2026),
          state: const PlayerState(false, ProcessingState.ready),
        )..setOptimisticDuration(const Duration(seconds: 100));
        addTearDown(session.shutdown);
        session.applyNativeProgress(
          NativePlaybackProgressUpdate(
            sessionId: session.id,
            position: const Duration(seconds: 50),
            duration: const Duration(seconds: 100),
            bufferedPosition: const Duration(seconds: 80),
            nativeElapsedRealtimeMs: 50000,
          ),
        );

        final seeked = <Duration>[];
        await tester.pumpWidget(
          fixture.build(
            Center(
              child: SizedBox(
                width: 400,
                child: SessionProgressBar(
                  session: PlaybackSessionSnapshot.fromRuntime(session),
                  playback: fixture.runtimeGraph.playback,
                  onManualSeek: seeked.add,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Future<double> measureDragDelta(double verticalOffset) async {
          final sliderRect = tester.getRect(find.byType(Slider));
          final gesture = await tester.startGesture(sliderRect.center);
          await gesture.moveBy(const Offset(20, 0));
          await tester.pump();
          final baselineMs = tester.widget<Slider>(find.byType(Slider)).value;

          if (verticalOffset != 0) {
            await gesture.moveBy(Offset(0, verticalOffset));
            await tester.pump();
          }
          await gesture.moveBy(const Offset(80, 0));
          await tester.pump();
          await gesture.up();
          await tester.pumpAndSettle();
          return seeked.last.inMilliseconds - baselineMs;
        }

        final normalDelta = await measureDragDelta(0);
        final halfDelta = await measureDragDelta(60);
        final quarterDelta = await measureDragDelta(110);

        expect(normalDelta, greaterThan(5000));
        expect(halfDelta, closeTo(normalDelta * 0.5, normalDelta * 0.08));
        expect(quarterDelta, closeTo(normalDelta * 0.25, normalDelta * 0.08));
      },
    );

    testWidgets(
      'SwipeRevealCard tracks drag at 55ms and SwipeRevealActionPane pops with spring-back past threshold',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  height: 76,
                  child: SwipeRevealCard(
                    shape: const RoundedRectangleBorder(),
                    actionLabel: 'Remove',
                    removeTooltip: 'Remove',
                    onRemove: () {},
                    child: const SizedBox.expand(
                      child: Center(child: Text('Track swipe')),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Track swipe')),
        );
        await gesture.moveBy(const Offset(-28, 0));
        await tester.pump();

        final dragTween = tester.widget<TweenAnimationBuilder<double>>(
          find.byType(TweenAnimationBuilder<double>),
        );
        expect(dragTween.duration, Duration.zero);
        expect(dragTween.curve, Curves.linear);

        await gesture.moveBy(const Offset(-52, 0));
        await tester.pump(const Duration(milliseconds: 60));

        final paneScale = tester.widget<AnimatedScale>(
          find.descendant(
            of: find.byType(SwipeRevealActionPane),
            matching: find.byType(AnimatedScale),
          ),
        );
        expect(paneScale.duration, Duration.zero);
        expect(paneScale.curve, kAppSpringBackCurve);

        await gesture.up();
        await tester.pump();

        final releasedPaneScale = tester.widget<AnimatedScale>(
          find.descendant(
            of: find.byType(SwipeRevealActionPane),
            matching: find.byType(AnimatedScale),
          ),
        );
        expect(releasedPaneScale.duration, kAppMotionStandard);

        final releaseTween = tester.widget<TweenAnimationBuilder<double>>(
          find.byType(TweenAnimationBuilder<double>),
        );
        expect(releaseTween.duration, kAppMotionStandard);
        expect(releaseTween.curve, kAppSpringCurve);

        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'AppPlaybackIconTransition applies rotational morph without RotationTransition and returns to zero rotation at rest',
      (tester) async {
        var playing = false;
        late StateSetter setPlaying;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setPlaying = setState;
                    return AppPlaybackIconTransition(
                      child: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        key: ValueKey<bool>(playing),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Iterable<Transform> rotatedTransforms() => tester
            .widgetList<Transform>(
              find.descendant(
                of: find.byType(AppPlaybackIconTransition),
                matching: find.byType(Transform),
              ),
            )
            .where((t) => t.transform.entry(0, 1).abs() > 0.001);

        expect(
          find.descendant(
            of: find.byType(AppPlaybackIconTransition),
            matching: find.byType(RotationTransition),
          ),
          findsNothing,
        );
        expect(rotatedTransforms(), isEmpty);

        setPlaying(() => playing = true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 45));

        expect(
          find.descendant(
            of: find.byType(AppPlaybackIconTransition),
            matching: find.byType(RotationTransition),
          ),
          findsNothing,
        );
        expect(rotatedTransforms(), isNotEmpty);

        await tester.pumpAndSettle();
        expect(rotatedTransforms(), isEmpty);
      },
    );

    testWidgets(
      'AppPlaybackIconTransition crossfades without scale or rotation on Windows',
      (tester) async {
        var playing = false;
        late StateSetter setPlaying;

        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setPlaying = setState;
                    return AppPlaybackIconTransition(
                      child: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        key: ValueKey<bool>(playing),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        setPlaying(() => playing = true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));

        expect(
          find.descendant(
            of: find.byType(AppPlaybackIconTransition),
            matching: find.byType(ScaleTransition),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AppPlaybackIconTransition),
            matching: find.byType(Transform),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(AppPlaybackIconTransition),
            matching: find.byType(FadeTransition),
          ),
          findsNWidgets(2),
        );

        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      },
    );

    testWidgets(
      'buildAppSearchPageRoute configures non-sliding fade route with appSearchRouteName',
      (tester) async {
        late PageRoute<void> searchRoute;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () {
                    searchRoute = buildAppSearchPageRoute(
                      context: context,
                      child: const Scaffold(
                        body: AppPageContentTransition(
                          child: SizedBox.expand(
                            key: ValueKey<String>('search_polish_body'),
                          ),
                        ),
                      ),
                    );
                    unawaited(Navigator.of(context).push(searchRoute));
                  },
                  child: const Text('Open search'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open search'));
        await tester.pump();
        await tester.pump();

        expect(searchRoute.settings.name, appSearchRouteName);
        expect(searchRoute.transitionDuration, kAppMotionStandard);
        expect(searchRoute.reverseTransitionDuration, kAppMotionFast);
        final searchBody = find.byKey(const ValueKey<String>('search_polish_body'));
        expect(
          find.ancestor(of: searchBody, matching: find.byType(SlideTransition)),
          findsNothing,
        );
        expect(
          find.ancestor(of: searchBody, matching: find.byType(FadeTransition)),
          findsOneWidget,
        );

        await tester.pumpAndSettle();
      },
    );
  });
}
