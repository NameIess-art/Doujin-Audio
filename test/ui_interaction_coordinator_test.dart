import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('overlapping sources publish only aggregate state changes', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator(idleDelay: Duration.zero);
    addTearDown(coordinator.dispose);
    final sources = List.generate(100, (_) => Object());
    final published = <(bool, bool)>[];
    coordinator.addListener(() {
      published.add((
        coordinator.isInteracting,
        coordinator.isVisualUpdateDeferred,
      ));
    });
    for (final source in sources) {
      coordinator.beginInteraction(source);
    }
    for (final source in sources.take(99)) {
      coordinator.cancelInteraction(source);
    }
    expect(coordinator.isInteracting, isTrue);
    expect(published, [(true, false)]);
    coordinator.endInteraction(sources.last);
    expect(published, [(true, false), (false, false)]);
  });

  testWidgets('navigation release publishes visual readiness during a scroll', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator();
    addTearDown(coordinator.dispose);
    final scroll = Object();
    final navigation = Object();
    final published = <(bool, bool)>[];
    coordinator.addListener(() {
      published.add((
        coordinator.isInteracting,
        coordinator.isVisualUpdateDeferred,
      ));
    });
    coordinator.beginInteraction(scroll);
    coordinator.beginNavigation(navigation);
    coordinator.endNavigation(navigation);
    expect(published, [(true, false), (true, true), (true, false)]);
    await tester.pump(coordinator.idleDelay);
    expect(published, hasLength(3));
    coordinator.cancelInteraction(scroll);
    expect(published.last, (false, false));
  });

  testWidgets(
    'reused navigation source reestablishes the guard during its idle tail',
    (tester) async {
      final coordinator = UiInteractionCoordinator();
      addTearDown(coordinator.dispose);
      final source = Object();
      final published = <(bool, bool)>[];
      coordinator.addListener(() {
        published.add((
          coordinator.isInteracting,
          coordinator.isVisualUpdateDeferred,
        ));
      });
      coordinator.beginNavigation(source);
      coordinator.endNavigation(source);
      await tester.pump(const Duration(milliseconds: 80));
      coordinator.beginNavigation(source);
      await tester.pump(coordinator.idleDelay);
      expect(coordinator.isVisualUpdateDeferred, isTrue);
      expect(coordinator.navigationAllowed.value, isFalse);
      coordinator.cancelNavigation(source);
      expect(published, [
        (true, true),
        (true, false),
        (true, true),
        (false, false),
      ]);
      expect(coordinator.navigationAllowed.value, isTrue);
    },
  );

  testWidgets(
    'overlapping visual guards release scroll commits only after both end',
    (tester) async {
      final coordinator = UiInteractionCoordinator(idleDelay: Duration.zero);
      addTearDown(coordinator.dispose);
      final scroll = Object();
      final navigation = Object();
      final firstFrame = Object();
      var notifications = 0;
      var committed = false;
      coordinator.addListener(() => notifications++);
      coordinator.beginInteraction(scroll);
      coordinator.beginNavigation(navigation);
      coordinator.beginInteraction(firstFrame, deferVisualUpdates: true);
      coordinator.scheduleCommit(
        key: 'visible-scroll-result',
        allowDuringScroll: true,
        commit: () => committed = true,
      );
      coordinator.endNavigation(navigation);
      await tester.pump();
      expect(committed, isFalse);
      expect(coordinator.isVisualUpdateDeferred, isTrue);
      expect(notifications, 2);
      coordinator.cancelInteraction(firstFrame);
      await tester.pump();
      expect(committed, isTrue);
      expect(coordinator.isInteracting, isTrue);
      expect(notifications, 3);
      coordinator.cancelInteraction(scroll);
      expect(notifications, 4);
    },
  );

  testWidgets('pending commits wake when their external condition resumes', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator();
    addTearDown(coordinator.dispose);
    var visible = false;
    var commits = 0;
    coordinator.scheduleCommit(
      key: 'retained-page',
      structural: true,
      canRun: () => visible,
      commit: () => commits++,
    );
    await tester.pump();
    expect(commits, 0);
    expect(coordinator.pendingCommitCount, 1);
    visible = true;
    coordinator.scheduleCommitFrame();
    await tester.pump();
    expect(commits, 1);
    expect(coordinator.pendingCommitCount, 0);
  });

  testWidgets('navigation blocks repeated clicks before the next frame', (
    tester,
  ) async {
    final allowed = ValueNotifier(true);
    addTearDown(allowed.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppNavigationInputLock(
          navigationAllowed: allowed,
          child: TextButton(
            onPressed: () {
              taps++;
              allowed.value = false;
            },
            child: const Text('navigate'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('navigate'));
    await tester.tap(find.text('navigate'), warnIfMissed: false);
    expect(taps, 1);
    allowed.value = true;
    await tester.tap(find.text('navigate'));
    expect(taps, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'navigation unlocks after all transitions without the idle delay',
    (tester) async {
      final coordinator = UiInteractionCoordinator();
      addTearDown(coordinator.dispose);
      final tab = Object();
      final route = Object();
      final scroll = Object();
      coordinator.beginInteraction(scroll);
      expect(coordinator.navigationAllowed.value, isTrue);
      coordinator.beginNavigation(tab);
      coordinator.beginNavigation(route);
      coordinator.endNavigation(tab);
      expect(coordinator.navigationAllowed.value, isFalse);
      coordinator.cancelNavigation(route);
      expect(coordinator.navigationAllowed.value, isTrue);
      expect(coordinator.isInteracting, isTrue);
      coordinator.cancelInteraction(scroll);
      await tester.pump(coordinator.idleDelay);
      expect(coordinator.isInteracting, isFalse);
    },
  );

  for (final reduced in [false, true]) {
    testWidgets('route input and back wait for transition (reduced=$reduced)', (
      tester,
    ) async {
      final coordinator = UiInteractionCoordinator();
      final observer = UiInteractionNavigatorObserver(coordinator: coordinator);
      final navigatorKey = GlobalKey<NavigatorState>();
      var destinationTaps = 0;
      addTearDown(() {
        observer.resetForTest();
        coordinator.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [observer],
          builder: (_, child) => AppNavigationInputLock(
            navigationAllowed: coordinator.navigationAllowed,
            child: child!,
          ),
          home: Scaffold(
            body: TextButton(
              onPressed: () => destinationTaps++,
              child: const Text('home destination'),
            ),
          ),
        ),
      );
      final route = buildAppPageRoute<void>(
        context: navigatorKey.currentContext!,
        duration: reduced ? Duration.zero : kAppMotionSlow,
        child: Scaffold(
          body: TextButton(
            onPressed: () => destinationTaps++,
            child: const Text('detail destination'),
          ),
        ),
      );
      unawaited(navigatorKey.currentState!.push(route));
      if (!reduced) {
        expect(coordinator.navigationAllowed.value, isFalse);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('detail destination'), warnIfMissed: false);
        expect(destinationTaps, 0);
        await navigatorKey.currentState!.maybePop();
        expect(route.isCurrent, isTrue);
      }
      await tester.pumpAndSettle();
      expect(coordinator.navigationAllowed.value, isTrue);
      await tester.tap(find.text('detail destination'));
      expect(destinationTaps, 1);
      await navigatorKey.currentState!.maybePop();
      if (!reduced) {
        expect(coordinator.navigationAllowed.value, isFalse);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('home destination'), warnIfMissed: false);
        expect(destinationTaps, 1);
      }
      await tester.pumpAndSettle();
      expect(coordinator.navigationAllowed.value, isTrue);
      await tester.tap(find.text('home destination'));
      expect(destinationTaps, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.resetForTest();
    });
  }

  testWidgets('prepared routes gate commits until their animation finishes', (
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
        navigatorObservers: [observer],
        home: const SizedBox(),
      ),
    );
    final route = buildAppPageRoute<void>(
      context: navigatorKey.currentContext!,
      child: const SizedBox(key: ValueKey('prepared-route')),
    );
    unawaited(navigatorKey.currentState!.push(route));
    var committed = false;
    coordinator.scheduleCommit(
      key: 'route-data',
      commit: () => committed = true,
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(route.animation!.value, 0);
    expect(coordinator.isInteracting, isTrue);
    expect(committed, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(route.animation!.value, 0);
    expect(coordinator.isInteracting, isTrue);
    expect(committed, isFalse);
    await tester.pump(const Duration(milliseconds: 299));
    expect(coordinator.isInteracting, isTrue);
    expect(committed, isFalse);
    await tester.pumpAndSettle();
    expect(coordinator.isInteracting, isFalse);
    expect(committed, isTrue);
  });

  testWidgets('route pop before preparation completes releases observers', (
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
        navigatorObservers: [observer],
        home: const SizedBox(),
      ),
    );
    final route = buildAppPageRoute<String>(
      context: navigatorKey.currentContext!,
      settings: const RouteSettings(name: '/prepared', arguments: 'work-id'),
      child: const SizedBox(key: ValueKey('never-prepared-route')),
    );
    expect(route.settings.name, '/prepared');
    expect(route.settings.arguments, 'work-id');
    final result = navigatorKey.currentState!.push(route);
    expect(coordinator.isInteracting, isTrue);
    navigatorKey.currentState!.pop('cancelled');
    await tester.pumpAndSettle();
    expect(await result, 'cancelled');
    expect(coordinator.isInteracting, isFalse);
    expect(find.byKey(const ValueKey('never-prepared-route')), findsNothing);
    expect(tester.takeException(), isNull);
  });

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

  for (final cancelled in [false, true]) {
    testWidgets(
      'structural commits span frames without delaying light feedback ($cancelled)',
      (tester) async {
        final coordinator = UiInteractionCoordinator(
          frameBudget: const Duration(seconds: 1),
          idleDelay: Duration.zero,
        );
        addTearDown(coordinator.dispose);
        final commits = <String>[];
        coordinator.scheduleCommit(
          key: 'catalog-a',
          structural: true,
          priority: 0,
          commit: () => commits.add('a'),
        );
        coordinator.scheduleCommit(
          key: 'catalog-b',
          structural: true,
          priority: 1,
          commit: () => commits.add('old'),
        );
        coordinator.scheduleCommit(
          key: 'catalog-b',
          structural: true,
          priority: 1,
          commit: () => commits.add('b'),
        );
        coordinator.scheduleCommit(
          key: 'feedback',
          priority: 2,
          commit: () => commits.add('feedback'),
        );
        await tester.pump();
        expect(commits, ['a', 'feedback']);
        expect(coordinator.pendingCommitCount, 1);
        if (cancelled) coordinator.cancelCommit('catalog-b');
        await tester.pump();
        expect(commits, cancelled ? ['a', 'feedback'] : ['a', 'feedback', 'b']);
        expect(coordinator.pendingCommitCount, 0);
      },
    );

    testWidgets(
      'first-frame protection ${cancelled ? 'cancels' : 'ends'} while a scroll remains active',
      (tester) async {
        final coordinator = UiInteractionCoordinator();
        addTearDown(coordinator.dispose);
        final source = Object();
        final scroll = Object();
        var notifications = 0;
        var committed = false;
        coordinator.addListener(() => notifications++);
        coordinator.beginInteraction(source);
        coordinator.beginInteraction(scroll);
        // A source already registered by ordinary work can upgrade its guard.
        coordinator.beginInteraction(source, deferVisualUpdates: true);
        expect(notifications, 2);
        expect(coordinator.navigationAllowed.value, isTrue);
        coordinator.scheduleCommit(
          key: 'visible-cover',
          allowDuringScroll: true,
          commit: () => committed = true,
        );
        await tester.pump();
        expect(committed, isFalse);
        if (cancelled) {
          coordinator.cancelInteraction(source);
        } else {
          coordinator.endInteraction(source);
          await tester.pump(
            coordinator.idleDelay - const Duration(milliseconds: 1),
          );
          expect(coordinator.isVisualUpdateDeferred, isTrue);
          expect(committed, isFalse);
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(coordinator.isVisualUpdateDeferred, isFalse);
        expect(coordinator.isInteracting, isTrue);
        expect(notifications, 3);
        await tester.pump();
        expect(committed, isTrue);
        coordinator.cancelInteraction(scroll);
      },
    );
  }

  testWidgets('restarting first-frame protection cancels its old idle tail', (
    tester,
  ) async {
    final coordinator = UiInteractionCoordinator();
    addTearDown(coordinator.dispose);
    final source = Object();
    coordinator.beginInteraction(source, deferVisualUpdates: true);
    coordinator.endInteraction(source);
    await tester.pump(const Duration(milliseconds: 80));
    coordinator.beginInteraction(source);
    await tester.pump(const Duration(milliseconds: 160));
    expect(coordinator.isVisualUpdateDeferred, isTrue);
    coordinator.endInteraction(source);
    await tester.pump(coordinator.idleDelay);
    expect(coordinator.isVisualUpdateDeferred, isFalse);
  });

  for (final cancelled in [false, true]) {
    testWidgets(
      'scroll commits resume after navigation ${cancelled ? 'is cancelled' : 'ends'} while scrolling continues',
      (tester) async {
        final coordinator = UiInteractionCoordinator();
        addTearDown(coordinator.dispose);
        final scroll = Object();
        final navigation = Object();
        var artwork = 0;
        var backgroundCommitted = false;
        var unrestrictedCommitted = false;
        coordinator.beginInteraction(scroll);
        coordinator.scheduleCommit(
          key: 'artwork',
          allowDuringScroll: true,
          commit: () => artwork = 1,
        );
        coordinator.scheduleCommit(
          key: 'background',
          commit: () => backgroundCommitted = true,
        );
        await tester.pump();
        expect(artwork, 1);
        expect(backgroundCommitted, isFalse);

        coordinator.beginNavigation(navigation);
        coordinator.scheduleCommit(
          key: 'artwork',
          allowDuringScroll: true,
          commit: () => artwork = 2,
        );
        coordinator.scheduleCommit(
          key: 'unrestricted',
          allowDuringInteraction: true,
          commit: () => unrestrictedCommitted = true,
        );
        await tester.pump();
        expect(artwork, 1);
        expect(unrestrictedCommitted, isTrue);
        if (cancelled) {
          coordinator.cancelNavigation(navigation);
        } else {
          coordinator.endNavigation(navigation);
        }
        await tester.pump();
        expect(coordinator.isInteracting, isTrue);
        expect(artwork, 2);
        expect(backgroundCommitted, isFalse);

        coordinator.cancelInteraction(scroll);
        await tester.pump(coordinator.idleDelay);
        await tester.pump();
        expect(backgroundCommitted, isTrue);
      },
    );
  }

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
    final route = buildAppPageRoute<void>(
      context: navigatorKey.currentContext!,
      duration: Duration.zero,
      child: const SizedBox(),
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
