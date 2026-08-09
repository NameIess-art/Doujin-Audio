import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('defers commits while interaction is active', (tester) async {
    final coordinator = UiInteractionCoordinator(
      idleDelay: const Duration(milliseconds: 10),
    );
    final source = Object();
    var committed = false;

    coordinator.beginInteraction(source);
    coordinator.scheduleCommit(key: 'snapshot', commit: () => committed = true);
    await tester.pump();
    expect(committed, isFalse);

    coordinator.endInteraction(source);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(committed, isTrue);
    coordinator.dispose();
  });

  testWidgets('deduplicates commits by key and keeps the newest result', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator();
    var value = 0;

    coordinator.scheduleCommit(key: 'snapshot', commit: () => value = 1);
    coordinator.scheduleCommit(key: 'snapshot', commit: () => value = 2);
    await tester.pump();

    expect(value, 2);
    coordinator.dispose();
  });

  testWidgets('drops commits from stale generations', (tester) async {
    final coordinator = UiInteractionCoordinator();
    final generation = coordinator.beginGeneration();
    var committed = false;

    coordinator.scheduleCommit(
      key: 'stale',
      generation: generation,
      commit: () => committed = true,
    );
    coordinator.beginGeneration();
    await tester.pump();

    expect(committed, isFalse);
    coordinator.dispose();
  });

  testWidgets('runs background task only after interaction becomes idle', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator(
      idleDelay: const Duration(milliseconds: 10),
    );
    final source = Object();
    final completed = Completer<void>();
    final generation = coordinator.beginGeneration();

    coordinator.beginInteraction(source);
    coordinator.scheduleAfterIdle(
      key: 'background',
      generation: generation,
      priority: 0,
      task: () async => completed.complete(),
    );
    await tester.pump();
    expect(completed.isCompleted, isFalse);

    coordinator.endInteraction(source);
    await tester.pump(const Duration(milliseconds: 11));
    await tester.pump();
    expect(completed.isCompleted, isTrue);
    coordinator.dispose();
  });

  testWidgets('rejects background work from a stale generation', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator();
    final staleGeneration = coordinator.beginGeneration();
    coordinator.beginGeneration();
    var ran = false;

    final accepted = coordinator.scheduleAfterIdle(
      key: 'stale_background',
      generation: staleGeneration,
      priority: 0,
      task: () async => ran = true,
    );
    await tester.pump();

    expect(accepted, isFalse);
    expect(ran, isFalse);
    coordinator.dispose();
  });

  testWidgets('runs at least one visible commit within interaction budget', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator(
      interactionFrameBudget: Duration.zero,
    );
    final source = Object();
    var visibleCommitted = false;
    var deferredCommitted = false;
    coordinator.beginInteraction(source);

    coordinator.scheduleCommit(
      key: 'visible',
      allowDuringInteraction: true,
      commit: () => visibleCommitted = true,
    );
    coordinator.scheduleCommit(
      key: 'deferred',
      commit: () => deferredCommitted = true,
    );
    await tester.pump();

    expect(visibleCommitted, isTrue);
    expect(deferredCommitted, isFalse);
    coordinator.cancelInteraction(source);
    await tester.pump();
    expect(deferredCommitted, isTrue);
    coordinator.dispose();
  });

  testWidgets('releases overlapping interaction sources independently', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator(
      idleDelay: const Duration(milliseconds: 10),
    );
    final scrollSource = Object();
    final pageSource = Object();

    coordinator.beginInteraction(scrollSource);
    coordinator.beginInteraction(pageSource);
    coordinator.endInteraction(scrollSource);
    await tester.pump(const Duration(milliseconds: 5));
    coordinator.endInteraction(pageSource);
    await tester.pump(const Duration(milliseconds: 6));
    expect(coordinator.isInteracting, isTrue);

    await tester.pump(const Duration(milliseconds: 5));
    expect(coordinator.isInteracting, isFalse);
    coordinator.dispose();
  });

  testWidgets('cancel releases a disposed interaction source immediately', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator();
    final source = Object();
    coordinator.beginInteraction(source);

    coordinator.cancelInteraction(source);

    expect(coordinator.isInteracting, isFalse);
    coordinator.dispose();
  });

  testWidgets(
    'throttled commits run immediately and keep only latest pending',
    (tester) async {
      final coordinator = UiInteractionCoordinator();
      final values = <int>[];

      coordinator.scheduleThrottledCommit(
        key: 'volume',
        interval: const Duration(milliseconds: 50),
        commit: () => values.add(1),
      );
      coordinator.scheduleThrottledCommit(
        key: 'volume',
        interval: const Duration(milliseconds: 50),
        commit: () => values.add(2),
      );
      coordinator.scheduleThrottledCommit(
        key: 'volume',
        interval: const Duration(milliseconds: 50),
        commit: () => values.add(3),
      );

      expect(values, <int>[1]);
      await tester.pump(const Duration(milliseconds: 51));
      expect(values, <int>[1, 3]);
      coordinator.dispose();
    },
  );

  testWidgets('cancelled throttled commit does not publish pending value', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator();
    var value = 0;

    coordinator.scheduleThrottledCommit(
      key: 'eq',
      interval: const Duration(milliseconds: 50),
      commit: () => value = 1,
    );
    coordinator.scheduleThrottledCommit(
      key: 'eq',
      interval: const Duration(milliseconds: 50),
      commit: () => value = 2,
    );
    coordinator.cancelThrottledCommit('eq');
    await tester.pump(const Duration(milliseconds: 51));

    expect(value, 1);
    coordinator.dispose();
  });

  testWidgets('navigator observer follows push and pop animation status', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator(idleDelay: Duration.zero);
    final observer = UiInteractionNavigatorObserver(coordinator: coordinator);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() {
      observer.resetForTest();
      coordinator.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: <NavigatorObserver>[observer],
        home: const SizedBox(),
      ),
    );

    final route = PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, _, _) => const SizedBox(key: ValueKey('route-page')),
    );
    unawaited(navigatorKey.currentState!.push(route));
    await tester.pump();
    expect(coordinator.isInteracting, isTrue);

    await tester.pump(const Duration(milliseconds: 100));
    expect(route.animation!.status, AnimationStatus.forward);
    expect(coordinator.isInteracting, isTrue);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpAndSettle();
    expect(coordinator.isInteracting, isFalse);

    navigatorKey.currentState!.pop();
    await tester.pump();
    expect(coordinator.isInteracting, isTrue);
    await tester.pump(const Duration(milliseconds: 180));
    await tester.pumpAndSettle();
    expect(coordinator.isInteracting, isFalse);
  });

  testWidgets('navigator observer releases zero-duration and gesture routes', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator(idleDelay: Duration.zero);
    final observer = UiInteractionNavigatorObserver(coordinator: coordinator);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() {
      observer.resetForTest();
      coordinator.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: <NavigatorObserver>[observer],
        home: const SizedBox(),
      ),
    );
    final route = PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => const SizedBox(),
    );
    unawaited(navigatorKey.currentState!.push(route));
    await tester.pumpAndSettle();
    expect(coordinator.isInteracting, isFalse);

    observer.didStartUserGesture(route, null);
    expect(coordinator.isInteracting, isTrue);
    observer.didStopUserGesture();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(coordinator.isInteracting, isFalse);
  });

  testWidgets('navigator observer handles replacement and consecutive routes', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator(idleDelay: Duration.zero);
    final observer = UiInteractionNavigatorObserver(coordinator: coordinator);
    final navigatorKey = GlobalKey<NavigatorState>();
    addTearDown(() {
      observer.resetForTest();
      coordinator.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: <NavigatorObserver>[observer],
        home: const SizedBox(),
      ),
    );
    PageRoute<void> route(String name, Duration duration) =>
        PageRouteBuilder<void>(
          settings: RouteSettings(name: name),
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (_, _, _) => SizedBox(key: ValueKey<String>(name)),
        );

    unawaited(
      navigatorKey.currentState!.push(
        route('replace-source', const Duration(milliseconds: 180)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    unawaited(
      navigatorKey.currentState!.pushReplacement(
        route('replace-target', const Duration(milliseconds: 220)),
      ),
    );
    await tester.pump();
    expect(coordinator.isInteracting, isTrue);
    await tester.pumpAndSettle();
    expect(coordinator.isInteracting, isFalse);

    unawaited(
      navigatorKey.currentState!.push(
        route('rapid-first', const Duration(milliseconds: 180)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 40));
    unawaited(
      navigatorKey.currentState!.push(
        route('rapid-second', const Duration(milliseconds: 240)),
      ),
    );
    await tester.pump();
    expect(coordinator.isInteracting, isTrue);
    await tester.pumpAndSettle();
    expect(coordinator.isInteracting, isFalse);
  });
}
