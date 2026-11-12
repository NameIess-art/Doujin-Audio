import 'dart:async';

import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/app/presentation/work_detail_navigation.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/library/presentation/library_search_page.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_tab.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  for (final action in [
    'close',
    'close timeout',
    'background',
    'back',
    'pop',
    'pop timeout',
    'drag',
    'local work',
    'online work',
    'local search',
    'online search',
  ]) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'phone detail $action restores portrait with bounded waiting, '
        'reduced=$reducedMotion',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 820);
          tester.view.display.devicePixelRatio = 1;
          tester.view.display.size = const Size(390, 820);
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              FakeAccessibilityFeatures(disableAnimations: reducedMotion);
          addTearDown(tester.view.reset);
          addTearDown(tester.view.display.reset);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
          UiInteractionCoordinator.instance.resetForTest();
          addTearDown(UiInteractionCoordinator.instance.resetForTest);
          final fixture = AppRuntimeWidgetTestFixture();
          addTearDown(fixture.dispose);
          final opensWork = action.endsWith(' work');
          final opensSearch = action.endsWith(' search');
          final receivesPortraitMetrics = !action.endsWith(' timeout');
          var track = testMusicTrack(
            name: 'Orientation',
            path: '/music/orientation.mp3',
            groupKey: '/music',
            groupTitle: 'Music',
          );
          if (action == 'online work' || opensSearch) {
            track = track.copyWith(
              remoteMetadataKind: 'asmr.one',
              remoteMetadata: const {
                'id': 42,
                'title': 'Orientation',
                'circle': {'name': 'Circle'},
              },
            );
          }
          fixture.library.addTracks([track], persist: false);
          final session = fixture.playback.createTrackSession(track);
          fixture.playbackService.syncSlice(
            activeSessions: [session],
            playingSessionCount: 0,
            focusedSessionId: session.id,
            coverGeneration: 0,
            isInitialized: true,
          );
          final calls = <List<DeviceOrientation>>[];
          final orientation = AppOrientationController(
            setPreferredOrientations: (value) async => calls.add(value),
            setSystemUiMode: (_) async {},
          );
          await orientation.updateDisplay(390);
          await orientation.setPlaybackDetailVisible(true);
          final homePaintSizes = <Size>[];
          final homeRepaint = ValueNotifier(0);
          addTearDown(homeRepaint.dispose);
          final root = GlobalKey<NavigatorState>();
          final navigation = WorkDetailNavigation(rootNavigatorKey: root);
          addTearDown(navigation.dispose);
          final home = Scaffold(
            body: CustomPaint(
              key: const ValueKey('orientation_home'),
              painter: _RecordHomePaint(homePaintSizes, homeRepaint),
              child: const SizedBox.expand(),
            ),
          );
          await tester.pumpWidget(
            fixture.build(
              opensWork
                  ? WorkDetailNavigationScope(
                      navigation: navigation,
                      child: MaterialApp(
                        navigatorKey: root,
                        home: WorkDetailPane(
                          isLandscape: false,
                          sidebarWidth: 0,
                          child: home,
                        ),
                      ),
                    )
                  : home,
              overrides: [
                appOrientationControllerProvider.overrideWithValue(orientation),
              ],
            ),
          );
          final navigator = Navigator.of(
            tester.element(find.byKey(const ValueKey('orientation_home'))),
          );
          final route = _GuardedSessionDetailRoute(sessionId: session.id);
          unawaited(navigator.push(route));
          await tester.pumpAndSettle();
          tester.view.physicalSize = const Size(820, 390);
          await tester.pumpAndSettle();
          homePaintSizes.clear();
          homeRepaint.value++;
          calls.clear();
          switch (action) {
            case 'local search':
            case 'online search':
              await tester.longPress(find.text('Circle'));
              await tester.pumpAndSettle();
              await tester.tap(
                find.widgetWithIcon(
                  ListTile,
                  action == 'online search'
                      ? Icons.travel_explore_rounded
                      : Icons.search_rounded,
                ),
              );
            case 'local work':
            case 'online work':
              await tester.tap(
                find.byTooltip(fixture.languageProvider.tr('audio_detail')),
              );
            case 'close':
            case 'close timeout':
            case 'background':
              await tester.tap(
                find.byKey(const ValueKey('session_detail_close_button')),
              );
            case 'back':
              await tester.binding.handlePopRoute();
              await tester.binding.handlePopRoute();
            case 'pop':
            case 'pop timeout':
              navigator.pop();
              navigator.pop(); // Repeated back must not pop the home route.
            case 'drag':
              await tester.dragFrom(
                const Offset(620, 80),
                const Offset(0, 250),
              );
          }
          // The platform call is already complete; resize has not arrived yet.
          if (opensSearch) {
            // Finish the menu's reverse transition before the portrait timeout.
            await tester.pump();
            await tester.pump(kAppFadeDuration);
          } else {
            await tester.pumpAndSettle();
          }
          expect(find.byType(SessionDetailPage), findsOneWidget);
          expect(route.isCurrent, isTrue);
          expect(route.opaque, isTrue);
          expect(homePaintSizes, isEmpty);
          if (action == 'drag') {
            expect(calls, isEmpty);
            expect(route.preparingForExit, isFalse);
          } else {
            expect(calls, [AppOrientationPolicy.portrait.allowedOrientations]);
            expect(route.preparingForExit, isTrue);
            if (opensWork || opensSearch) {
              expect(route.popAttempts, 0);
              expect(navigation.isOpen, isFalse);
            }
            if (action == 'background') {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await tester.pump();
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.resumed,
              );
              await tester.pump();
            }
            if (receivesPortraitMetrics) {
              tester.view.physicalSize = const Size(390, 820);
            } else {
              await tester.pump(const Duration(seconds: 1));
            }
            if (opensWork) {
              if (!reducedMotion) {
                await tester.pump();
                await tester.pump();
                await tester.pump();
                // The prepared route starts its clock on the first ready tick.
                await tester.pump(const Duration(milliseconds: 100));
                await tester.pump(const Duration(milliseconds: 100));
                final work = find.byType(WorkDetailPage);
                expect(work, findsOneWidget);
                final workRoute = ModalRoute.of(tester.element(work))!;
                expect(workRoute.navigator, same(navigator));
                expect(workRoute.animation!.value, inExclusiveRange(0, 1));
                final slidingBody = find.descendant(
                  of: work,
                  matching: find.byWidgetPredicate(
                    (widget) =>
                        widget is SlideTransition &&
                        widget.position.value.dx > 0 &&
                        widget.position.value.dx < 1,
                  ),
                );
                expect(slidingBody, findsWidgets);
                expect(route.animation!.value, 1);
                expect(find.byType(SessionDetailPage), findsOneWidget);
                expect(homePaintSizes, isEmpty);
              }
              await pumpAndSettleWithAsync(tester);
              expect(
                find.byType(SessionDetailPage, skipOffstage: false),
                findsNothing,
              );
              expect(navigator.canPop(), isTrue);
              expect(navigation.isOpen, isFalse);
              final work = tester.widget<WorkDetailPage>(
                find.byType(WorkDetailPage),
              );
              expect(work.asmrWork != null, action == 'online work');
              navigator.pop();
              await tester.pumpAndSettle();
              await tester.pump(UiInteractionCoordinator.instance.idleDelay);
            } else if (opensSearch) {
              // Search can keep its loading spinner active in an offline test.
              // Finish route entry without waiting for network completion.
              for (var frame = 0; frame < 8; frame++) {
                await tester.pump(const Duration(milliseconds: 100));
              }
              expect(
                action == 'online search'
                    ? find.byType(AsmrSearchPage)
                    : find.byType(LibrarySearchPage),
                findsOneWidget,
              );
              expect(navigator.canPop(), isTrue);
              navigator.pop();
              await tester.pumpAndSettle();
              await tester.pump(UiInteractionCoordinator.instance.idleDelay);
            } else {
              await tester.pumpAndSettle();
            }
            expect(find.byType(SessionDetailPage), findsNothing);
            expect(navigator.canPop(), isFalse);
            expect(calls, [AppOrientationPolicy.portrait.allowedOrientations]);
            expect(homePaintSizes, isNotEmpty);
            expect(
              homePaintSizes.every(
                (size) => (size.height > size.width) == receivesPortraitMetrics,
              ),
              isTrue,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
}

class _GuardedSessionDetailRoute extends SessionDetailRoute {
  _GuardedSessionDetailRoute({required super.sessionId});

  int popAttempts = 0;

  @override
  bool didPop(void result) {
    // Bound the regression failure: popUntil would otherwise loop forever
    // while the phone is waiting for a portrait metrics event.
    if (++popAttempts > 2 && requiresPortraitRestore && preparingForExit) {
      throw StateError('Repeated pop before portrait restoration');
    }
    return super.didPop(result);
  }
}

class _RecordHomePaint extends CustomPainter {
  _RecordHomePaint(this.sizes, Listenable repaint) : super(repaint: repaint);

  final List<Size> sizes;

  @override
  void paint(Canvas canvas, Size size) {
    sizes.add(size);
    canvas.drawColor(Colors.white, BlendMode.src);
  }

  @override
  bool shouldRepaint(_RecordHomePaint oldDelegate) => false;
}
