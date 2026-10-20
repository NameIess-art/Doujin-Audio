import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/routed_playback_dock_host.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_bottom_sheet.dart';
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

class _MenuSessionDetailRoute extends SessionDetailRoute {
  _MenuSessionDetailRoute() : super(sessionId: 'dock_session');

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const Scaffold(body: Text('Playback'));
}

Future<GlobalKey<NavigatorState>> _pumpHost(
  WidgetTester tester,
  TargetPlatform platform, {
  bool reducedMotion = false,
  bool dockCollapsed = true,
  Size? viewportSize,
  EdgeInsets padding = EdgeInsets.zero,
  Widget? home,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.devicePixelRatio = 1;
  final size =
      viewportSize ??
      (platform == TargetPlatform.windows
          ? const Size(1280, 800)
          : const Size(390, 820));
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
              ).copyWith(disableAnimations: reducedMotion, padding: padding),
              child: Builder(
                builder: (context) => wrapNavigator(context, child!),
              ),
            ),
            home: home ?? const Scaffold(body: Text('Home')),
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

PageRoute<void> _detailRoute(
  GlobalKey<NavigatorState> navigator, {
  Widget? child,
}) => buildAppPageRoute<void>(
  context: navigator.currentContext!,
  settings: const RouteSettings(name: workDetailRouteName),
  child: child ?? const Scaffold(body: Text('Detail')),
);

Future<void> _exercisePointerInputs(
  WidgetTester tester,
  Offset point, {
  GlobalKey<NavigatorState>? navigator,
}) async {
  for (final input in <Future<void> Function()>[
    () => tester.tapAt(point),
    () => tester.longPressAt(point),
    () => tester.tapAt(point, buttons: kSecondaryMouseButton),
    () => tester.dragFrom(point, const Offset(0, -80)),
    () => tester.sendEventToBinding(
      PointerScrollEvent(position: point, scrollDelta: const Offset(0, 60)),
    ),
  ]) {
    await input();
    if (navigator != null) {
      await tester.pumpAndSettle();
      // Card gestures may open playback or a menu. Test each input against
      // the work detail again instead of the resulting route's barrier.
      navigator.currentState!.popUntil(
        (route) => route.settings.name == workDetailRouteName,
      );
      await tester.pumpAndSettle();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(UiInteractionCoordinator.instance.resetForTest);

  testWidgets('portrait dock blocks its full bottom strip and releases it', (
    tester,
  ) async {
    var backgroundEvents = 0;
    Widget background(String label) => Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => backgroundEvents++,
      onPointerMove: (_) => backgroundEvents++,
      onPointerSignal: (_) => backgroundEvents++,
      child: SizedBox.expand(child: Text(label)),
    );
    final navigator = await _pumpHost(
      tester,
      TargetPlatform.android,
      padding: const EdgeInsets.only(bottom: 30),
      home: Scaffold(body: background('Home')),
    );
    unawaited(
      navigator.currentState!.push(
        _detailRoute(navigator, child: Scaffold(body: background('Detail'))),
      ),
    );
    await tester.pumpAndSettle();
    for (final point in [
      const Offset(1, 735),
      const Offset(389, 735),
      const Offset(195, 819),
    ]) {
      await _exercisePointerInputs(tester, point);
      expect(
        backgroundEvents,
        0,
        reason: 'The whole dock strip blocks $point.',
      );
    }
    await tester.tapAt(const Offset(1, 733));
    expect(backgroundEvents, 1);

    var dialogTaps = 0;
    unawaited(
      showDialog<void>(
        context: navigator.currentContext!,
        useRootNavigator: false,
        builder: (_) => Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            key: const ValueKey('dock_overlay_dialog'),
            onTap: () => dialogTaps++,
            child: const SizedBox(
              width: 100,
              height: 100,
              child: ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dialog = find.byKey(const ValueKey('dock_overlay_dialog'));
    final dialogCenter = tester.getCenter(dialog);
    expect(dialogCenter.dy, greaterThanOrEqualTo(734));
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.ancestor(of: dialog, matching: find.byType(RepaintBoundary)).last,
      );
      final image = await boundary.toImage();
      try {
        final pixels = (await image.toByteData())!;
        final local = boundary.globalToLocal(dialogCenter);
        final offset = (local.dy.floor() * image.width + local.dx.floor()) * 4;
        expect(
          pixels.getUint32(offset),
          0xffffffff,
          reason: 'The white dialog must paint over the dock at its center.',
        );
      } finally {
        image.dispose();
      }
    });
    await tester.tap(dialog);
    expect(dialogTaps, 1);
    expect(backgroundEvents, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1, 819));
    expect(backgroundEvents, 1);

    final removedDialog = DialogRoute<void>(
      context: navigator.currentContext!,
      builder: (_) => const AlertDialog(content: Text('Removed popup')),
    );
    unawaited(navigator.currentState!.push(removedDialog));
    await tester.pumpAndSettle();
    navigator.currentState!.removeRoute(removedDialog);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1, 819));
    expect(backgroundEvents, 1);

    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(body: background('Covered')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1, 819));
    expect(backgroundEvents, 2);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1, 819));
    expect(backgroundEvents, 2);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1, 819));
    expect(backgroundEvents, 3);
    expect(_dock, findsNothing);
    await tester.pump(UiInteractionCoordinator.instance.idleDelay);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets('landscape dock blocks its rectangle only on $platform', (
      tester,
    ) async {
      var backgroundEvents = 0;
      final navigator = await _pumpHost(
        tester,
        platform,
        viewportSize: const Size(1280, 800),
      );
      unawaited(
        navigator.currentState!.push(
          _detailRoute(
            navigator,
            child: Scaffold(
              body: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => backgroundEvents++,
                onPointerMove: (_) => backgroundEvents++,
                onPointerSignal: (_) => backgroundEvents++,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bounds = tester.getRect(_dock);
      await _exercisePointerInputs(
        tester,
        bounds.topLeft + const Offset(1, 1),
        navigator: navigator,
      );
      expect(backgroundEvents, 0);
      await tester.tapAt(bounds.topLeft - const Offset(1, 0));
      await tester.tapAt(Offset(bounds.right + 1, bounds.center.dy));
      await tester.tapAt(Offset(bounds.center.dx, bounds.bottom + 1));
      expect(backgroundEvents, 3);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(UiInteractionCoordinator.instance.idleDelay);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'page opened from playback menu stays above it after a dialog on $platform',
      (tester) async {
        final navigator = await _pumpHost(tester, platform);
        double dockOpacity() => tester
            .renderObject<RenderAnimatedOpacity>(
              find
                  .ancestor(
                    of: _dock,
                    matching: find.byType(AnimatedOpacity, skipOffstage: false),
                  )
                  .first,
            )
            .opacity
            .value;
        unawaited(navigator.currentState!.push(_detailRoute(navigator)));
        await tester.pumpAndSettle();
        expect(dockOpacity(), 1);
        unawaited(navigator.currentState!.push(_MenuSessionDetailRoute()));
        await tester.pumpAndSettle();
        unawaited(
          AppBottomSheet.show<void>(
            context: navigator.currentContext!,
            // The fixture wraps the host in another MaterialApp.
            useRootNavigator: false,
            builder: (_) => const SizedBox(
              height: 250,
              child: Center(child: Text('Subtitle menu')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(dockOpacity(), 0);
        unawaited(
          showDialog<void>(
            context: tester.element(find.text('Subtitle menu')),
            useRootNavigator: false,
            builder: (_) => const AlertDialog(content: Text('Subtitle import')),
          ),
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(dockOpacity(), 0);
        final editor = buildAppPageRoute<void>(
          context: tester.element(find.text('Subtitle menu')),
          child: const Scaffold(body: Center(child: Text('Subtitle editor'))),
        );
        unawaited(navigator.currentState!.push(editor));
        await tester.pumpAndSettle();
        expect(find.text('Subtitle editor').hitTestable(), findsOneWidget);
        expect(find.text('Subtitle menu').hitTestable(), findsNothing);
        expect(dockOpacity(), 0);
        expect(tester.takeException(), isNull);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('Subtitle menu').hitTestable(), findsOneWidget);
        expect(dockOpacity(), 0);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        // The opaque playback page keeps this retained dock offstage and
        // mutes its fade ticker. It finishes fading when playback is closed.
        expect(TickerMode.valuesOf(tester.element(_dock)).enabled, isFalse);
        expect(
          tester
              .widget<AnimatedOpacity>(
                find
                    .ancestor(
                      of: _dock,
                      matching: find.byType(
                        AnimatedOpacity,
                        skipOffstage: false,
                      ),
                    )
                    .first,
              )
              .opacity,
          1,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(dockOpacity(), 1);
        expect(_dock.hitTestable(), findsOneWidget);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pump(UiInteractionCoordinator.instance.idleDelay);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'work detail opened from playback shows dock and returns home on $platform',
      (tester) async {
        final navigator = await _pumpHost(tester, platform);
        final playback = buildSessionDetailRoute(sessionId: 'dock_session');
        unawaited(navigator.currentState!.push(playback));
        await tester.pumpAndSettle();
        final detail = _detailRoute(navigator);
        unawaited(
          navigator.currentState!.pushAndRemoveUntil(
            detail,
            (route) => route.isFirst,
          ),
        );
        await tester.pump();
        await tester.pump();
        void expectDock() {
          expect(_dock, findsOneWidget);
          expect(
            MobileOverlayInset.of(tester.element(find.text('Detail'))),
            greaterThan(0),
          );
        }

        expectDock();
        await tester.pump(const Duration(milliseconds: 150));
        expectDock();
        await tester.pumpAndSettle();
        expectDock();
        expect(playback.isActive, false);
        unawaited(
          navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Detail child')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(_dock, findsOneWidget);
        expect(
          tester
              .widget<IgnorePointer>(
                find.byKey(
                  const ValueKey<String>('routed_playback_dock_interaction'),
                  skipOffstage: false,
                ),
              )
              .ignoring,
          true,
        );
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expectDock();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        expect(_dock, findsOneWidget);
        await tester.pumpAndSettle();
        expect(navigator.currentState!.canPop(), false);
        expect(find.text('Home'), findsOneWidget);
        expect(_dock, findsNothing);
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
