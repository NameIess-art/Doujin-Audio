import 'dart:async';

import 'package:doujin_audio/app/presentation/app_orientation_controller.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_page.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  for (final action in [
    'close',
    'background',
    'back',
    'pop',
    'drag',
    'cancel',
  ]) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'phone detail $action waits for a portrait frame, reduced=$reducedMotion',
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
          final track = testMusicTrack(
            name: 'Orientation',
            path: '/music/orientation.mp3',
            groupKey: '/music',
            groupTitle: 'Music',
          );
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
          );
          await orientation.updateDisplay(390);
          await orientation.setPlaybackDetailVisible(true);
          final homePaintSizes = <Size>[];
          final homeRepaint = ValueNotifier(0);
          addTearDown(homeRepaint.dispose);
          await tester.pumpWidget(
            fixture.build(
              Scaffold(
                body: CustomPaint(
                  key: const ValueKey('orientation_home'),
                  painter: _RecordHomePaint(homePaintSizes, homeRepaint),
                  child: const SizedBox.expand(),
                ),
              ),
              overrides: [
                appOrientationControllerProvider.overrideWithValue(orientation),
              ],
            ),
          );
          final navigator = Navigator.of(
            tester.element(find.byKey(const ValueKey('orientation_home'))),
          );
          final route = SessionDetailRoute(sessionId: session.id);
          unawaited(navigator.push(route));
          await tester.pumpAndSettle();
          tester.view.physicalSize = const Size(820, 390);
          await tester.pumpAndSettle();
          homePaintSizes.clear();
          homeRepaint.value++;
          calls.clear();
          final scaffold = tester.widget<SessionDetailScaffold>(
            find.byType(SessionDetailScaffold),
          );
          switch (action) {
            case 'close':
            case 'background':
              await tester.tap(
                find.byKey(const ValueKey('session_detail_close_button')),
              );
            case 'back':
              unawaited(navigator.maybePop());
            case 'pop':
              navigator.pop();
              navigator.pop(); // Repeated back must not pop the home route.
            case 'drag':
            case 'cancel':
              scaffold.onVerticalDragUpdate!(180);
              await tester.pump();
              expect(route.opaque, isTrue);
              expect(homePaintSizes, isEmpty);
              if (action == 'cancel') {
                scaffold.onVerticalDragCancel!();
              } else {
                scaffold.onVerticalDragEnd!(
                  DragEndDetails(
                    primaryVelocity: 600,
                    velocity: const Velocity(pixelsPerSecond: Offset(0, 600)),
                  ),
                );
              }
          }
          // The platform call is already complete; resize has not arrived yet.
          await tester.pumpAndSettle();
          expect(find.byType(SessionDetailPage), findsOneWidget);
          expect(route.isCurrent, isTrue);
          expect(route.opaque, isTrue);
          expect(homePaintSizes, isEmpty);
          if (action == 'cancel') {
            expect(calls, isEmpty);
            expect(route.preparingForExit, isFalse);
          } else {
            expect(calls, [AppOrientationPolicy.portrait.allowedOrientations]);
            expect(route.preparingForExit, isTrue);
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
            tester.view.physicalSize = const Size(390, 820);
            await tester.pumpAndSettle();
            expect(find.byType(SessionDetailPage), findsNothing);
            expect(navigator.canPop(), isFalse);
            expect(homePaintSizes, isNotEmpty);
            expect(
              homePaintSizes.every((size) => size.height > size.width),
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
