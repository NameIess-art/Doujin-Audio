import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/routed_playback_dock_host.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/mobile_overlay_inset.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:doujin_audio/features/player/application/playback_session_snapshot.dart';
import 'package:doujin_audio/features/player/presentation/active_session_carousel.dart';
import 'package:doujin_audio/features/player/presentation/playlist_view_models.dart';
import 'package:doujin_audio/features/player/presentation/playlist/session_detail_route.dart';
import 'support/app_runtime_test_fixture.dart';
import 'support/runtime_test_models.dart';

final _dock = find.byKey(
  const ValueKey<String>('routed_playback_dock'),
  skipOffstage: false,
);
final _content = find.descendant(
  of: _dock,
  matching: find.byType(ActiveSessionCarousel, skipOffstage: false),
);

Future<GlobalKey<NavigatorState>> _pumpHost(
  WidgetTester tester,
  TargetPlatform platform, {
  bool reducedMotion = false,
  bool dockCollapsed = true,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.devicePixelRatio = 1;
  final size = platform == TargetPlatform.windows
      ? const Size(1280, 800)
      : const Size(390, 820);
  tester.view.physicalSize = size;
  addTearDown(() {
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  final fixture = AppRuntimeWidgetTestFixture();
  addTearDown(fixture.dispose);
  final session = PlaybackSession(
    id: 'dock_session',
    currentTrackPath: '/audio/dock.mp3',
    loopMode: SessionLoopMode.single,
    nonSingleLoopMode: SessionLoopMode.single,
    volume: 1,
    createdAt: DateTime(2026),
    state: const PlayerState(true, ProcessingState.ready),
  );
  addTearDown(session.shutdown);
  fixture.playbackService.registerSession(session);
  final navigator = GlobalKey<NavigatorState>();
  final interactionObserver = UiInteractionNavigatorObserver();
  addTearDown(interactionObserver.resetForTest);
  await tester.pumpWidget(
    fixture.build(
      RoutedPlaybackDockHost(
        navigatorKey: navigator,
        builder: (context, observer, geometry, wrapNavigator) {
          final right = platform == TargetPlatform.windows ? 556.0 : 374.0;
          final top = size.height - 68;
          final dockWidth = dockCollapsed ? 56.0 : 244.0;
          geometry.updateMainGeometry(
            coverRect: Rect.fromLTWH(right - dockWidth + 4, top + 4, 48, 48),
            dockRect: Rect.fromLTWH(right - dockWidth, top, dockWidth, 56),
            expandedDockRect: Rect.fromLTWH(right - 244, top, 244, 56),
            dockCollapsed: dockCollapsed,
          );
          return MaterialApp(
            navigatorKey: navigator,
            navigatorObservers: [observer, interactionObserver],
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: reducedMotion),
              child: Builder(
                builder: (context) => wrapNavigator(context, child!),
              ),
            ),
            home: const Scaffold(body: Text('Home')),
          );
        },
      ),
      overrides: [
        mainOverlayUiProvider.overrideWithValue(
          MainOverlayUiState(
            overlaySessions: [PlaybackSessionSnapshot.fromRuntime(session)],
            playingSessionCount: 1,
            hasPlayingAudioSession: true,
            activeSessionCount: 1,
            isInitialized: true,
            startupReady: true,
          ),
        ),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return navigator;
}

PageRoute<void> _detailRoute(GlobalKey<NavigatorState> navigator) =>
    buildAppPageRoute<void>(
      context: navigator.currentContext!,
      settings: const RouteSettings(name: workDetailRouteName),
      workDetailTransition: true,
      child: const Scaffold(body: Text('Detail')),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'work detail opened from playback has no dock or bottom inset on $platform',
      (tester) async {
        final navigator = await _pumpHost(tester, platform);
        final playback = buildSessionDetailRoute(sessionId: 'dock_session');
        unawaited(navigator.currentState!.push(playback));
        await tester.pumpAndSettle();
        final detail = _detailRoute(navigator);
        unawaited(navigator.currentState!.push(detail));
        await tester.pump();
        await tester.pump();
        void expectNoDock() {
          expect(_dock, findsNothing);
          expect(MobileOverlayInset.of(tester.element(find.text('Detail'))), 0);
        }

        expectNoDock();
        await tester.pump(const Duration(milliseconds: 150));
        expectNoDock();
        await tester.pumpAndSettle();
        expectNoDock();
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Detail child')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(_dock, findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expectNoDock();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expectNoDock();
        await tester.pumpAndSettle();
        expect(navigator.currentState!.canPop(), true);
        expect(_dock, findsNothing);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        unawaited(navigator.currentState!.push(_detailRoute(navigator)));
        await tester.pumpAndSettle();
        expect(_dock, findsOneWidget);
        expect(
          MobileOverlayInset.of(tester.element(find.text('Detail'))),
          greaterThan(0),
        );
        unawaited(navigator.currentState!.push(
          buildSessionDetailRoute(sessionId: 'dock_session'),
        ));
        await tester.pumpAndSettle();
        unawaited(navigator.currentState!.push(_detailRoute(navigator)));
        await tester.pumpAndSettle();
        expect(_dock, findsNothing);
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(_dock, findsNothing);
        expect(
          MobileOverlayInset.of(tester.element(find.text('Detail').first)),
          0,
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(_dock, findsOneWidget);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pump(UiInteractionCoordinator.instance.idleDelay);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'playing dock content keeps its width through enter and exit on $platform',
      (tester) async {
        final navigator = await _pumpHost(tester, platform);
        unawaited(navigator.currentState!.push(_detailRoute(navigator)));
        await tester.pump();
        await tester.pump();
        expect(_content, findsOneWidget);
        final state = tester.state(_content);
        final contentSize = tester.getSize(_content);
        expect(contentSize.width, greaterThan(200));
        final cover = find.descendant(
          of: _dock,
          matching: find.byKey(
            const ValueKey<String>('active_session_cover_dock_session'),
            skipOffstage: false,
          ),
        );
        void expectVisibleCover({bool interactive = true}) {
          final bounds = tester.getRect(_dock);
          final artwork = tester.getRect(cover);
          expect(artwork.width, closeTo(48, 0.01));
          expect(artwork.height, closeTo(48, 0.01));
          expect(artwork.left, closeTo(bounds.left + 4, 0.01));
          expect(artwork.right, lessThanOrEqualTo(bounds.right - 4 + 0.01));
          expect(
            cover.hitTestable(),
            interactive ? findsOneWidget : findsNothing,
          );
        }

        expectVisibleCover();
        final enteringWidths = <double>[];
        for (var frame = 0; frame < 32; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          enteringWidths.add(tester.getSize(_dock).width);
          expect(tester.getSize(_content), contentSize);
          expect(tester.state(_content), same(state));
          expectVisibleCover();
        }
        expect(enteringWidths.toSet().length, greaterThan(2));
        expect(enteringWidths.last, closeTo(contentSize.width, 0.01));
        navigator.currentState!.pop();
        await tester.pump();
        final exitingWidths = <double>[];
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (_dock.evaluate().isEmpty) break;
          exitingWidths.add(tester.getSize(_dock).width);
          expect(tester.getSize(_content), contentSize);
          expect(tester.state(_content), same(state));
          expectVisibleCover(interactive: false);
        }
        expect(exitingWidths.toSet().length, greaterThan(2));
        await tester.pumpAndSettle();
        expect(_dock, findsNothing);
        await tester.pump(UiInteractionCoordinator.instance.idleDelay);
        expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'covered dock preserves content and quick route removal disposes it on $platform',
      (tester) async {
        final navigator = await _pumpHost(tester, platform);
        final detail = _detailRoute(navigator);
        unawaited(navigator.currentState!.push(detail));
        await tester.pumpAndSettle();
        final state = tester.state(_content);
        final size = tester.getSize(_content);
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Covered')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final interaction = tester.widget<IgnorePointer>(
          find.byKey(
            const ValueKey<String>('routed_playback_dock_interaction'),
            skipOffstage: false,
          ),
        );
        expect(interaction.ignoring, isTrue);
        expect(tester.state(_content), same(state));
        expect(tester.getSize(_content), size);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(tester.state(_content), same(state));
        navigator.currentState!.removeRoute(detail);
        await tester.pumpAndSettle();
        expect(_dock, findsNothing);
        final quick = _detailRoute(navigator);
        unawaited(navigator.currentState!.push(quick));
        await tester.pump();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(_dock, findsNothing);
        await tester.pump(UiInteractionCoordinator.instance.idleDelay);
        expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'reduced motion has one final dock width and cleans up on $platform',
      (tester) async {
        final navigator = await _pumpHost(
          tester,
          platform,
          reducedMotion: true,
        );
        unawaited(navigator.currentState!.push(_detailRoute(navigator)));
        await tester.pumpAndSettle();
        expect(tester.getSize(_dock), tester.getSize(_content));
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(_dock, findsNothing);
        await tester.pump(UiInteractionCoordinator.instance.idleDelay);
        expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'play pause button does not displace when entering detail from expanded dock on $platform',
      (tester) async {
        final navigator = await _pumpHost(
          tester,
          platform,
          dockCollapsed: false,
        );
        unawaited(navigator.currentState!.push(_detailRoute(navigator)));
        await tester.pump();
        await tester.pump();
        expect(_dock, findsOneWidget);
        final playButton = find.descendant(
          of: _dock,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Icon &&
                (w.icon == Icons.play_arrow_rounded ||
                    w.icon == Icons.pause_rounded),
          ),
        );
        expect(playButton, findsWidgets);
        final initialCenter = tester
            .getRect(playButton.hitTestable().first)
            .center;

        for (var frame = 0; frame < 32; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final currentCenter = tester
              .getRect(playButton.hitTestable().first)
              .center;
          expect(currentCenter.dx, closeTo(initialCenter.dx, 0.01));
          expect(currentCenter.dy, closeTo(initialCenter.dy, 0.01));
        }

        navigator.currentState!.pop();
        await tester.pump();
        for (var frame = 0; frame < 14; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          if (_dock.evaluate().isEmpty) break;
          final currentCenter = tester.getRect(playButton.first).center;
          expect(currentCenter.dx, closeTo(initialCenter.dx, 0.01));
          expect(currentCenter.dy, closeTo(initialCenter.dy, 0.01));
        }

        await tester.pumpAndSettle();
        expect(_dock, findsNothing);
        await tester.pump(UiInteractionCoordinator.instance.idleDelay);
        expect(UiInteractionCoordinator.instance.isInteracting, isFalse);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
