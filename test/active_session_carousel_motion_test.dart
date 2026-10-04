import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/desktop_main_navigation.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/presentation/mobile_dock_capsule_content.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/core/widgets/scroll_activity_gate.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playback_position_ui_gate.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
        final iconKeys = List.generate(4, (_) => GlobalKey());
        final iconLinks = List.generate(4, (_) => LayerLink());
        var expanded = false;
        var visible = true;
        var reduced = false;
        var hasPlayback = true;
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
                        required anchorProgress,
                        required stackProgress,
                        required expandedWidth,
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

        await tester.pumpWidget(shell());
        await tester.pumpAndSettle();
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
        for (var value = 21; value <= 40; value++) {
          session.setOptimisticPosition(Duration(seconds: value));
        }
        expect(session.position, const Duration(seconds: 40));
        await tester.pump(const Duration(milliseconds: 40));
        expect(progressNotifications, 0);
        await tester.pumpAndSettle();
        await tester.pump(interaction.idleDelay);
        expect(interaction.isInteracting, isFalse);
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
        visible = true;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isTrue);
        reduced = true;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isFalse);
        expanded = false;
        await tester.pumpWidget(shell());
        expect(interaction.isInteracting, isFalse);

        reduced = false;
        if (!desktop) {
          hasPlayback = false;
          await tester.pumpWidget(shell());
          expect(interaction.isInteracting, isTrue);
          await tester.pumpAndSettle();
          await tester.pump(interaction.idleDelay);
          expect(interaction.isInteracting, isFalse);
          hasPlayback = true;
          await tester.pumpWidget(shell());
          expect(interaction.isInteracting, isTrue);
        } else {
          expanded = true;
          await tester.pumpWidget(shell());
          expect(interaction.isInteracting, isTrue);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(interaction.isInteracting, isFalse);
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
        Widget dock(List<PlaybackSession> shown) => fixture.build(
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
        );

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
