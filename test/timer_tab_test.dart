import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/player/presentation/timer_tab.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/settings/application/permission_status_service.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
  });
  tearDown(() {
    UiInteractionCoordinator.instance.resetForTest();
    UiInteractionNavigatorObserver.instance.resetForTest();
  });

  testWidgets(
    'timer permission checks wait for opening and resume interactions',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final permissions = _CountingPermissionStatusService();
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.beginInteraction(Object());
      await tester.pumpWidget(
        fixture.build(
          const TimerTab(showHeader: false),
          overrides: [
            permissionStatusServiceProvider.overrideWithValue(permissions),
          ],
        ),
      );
      await tester.pump();
      expect(permissions.checks, isEmpty);
      coordinator.finishInteractionsForTest();
      await tester.pump();
      expect(permissions.checks, [
        PermissionCapability.exactAlarms,
        PermissionCapability.backgroundRun,
      ]);

      coordinator.beginInteraction(Object());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(permissions.checks, hasLength(2));
      coordinator.finishInteractionsForTest();
      await tester.pump();
      expect(permissions.checks, hasLength(4));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'covered timer refreshes only after its route becomes visible',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final permissions = _CountingPermissionStatusService();
      await tester.pumpWidget(
        fixture.build(
          const TimerTab(showHeader: false),
          navigatorObservers: [UiInteractionNavigatorObserver.instance],
          overrides: [
            permissionStatusServiceProvider.overrideWithValue(permissions),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(permissions.checks, hasLength(2));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(permissions.checks, hasLength(2));

      navigator.pop();
      await tester.pump();
      expect(permissions.checks, hasLength(2));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(permissions.checks, hasLength(4));
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'exiting timer cancels its deferred permission checks',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final permissions = _CountingPermissionStatusService();
      final coordinator = UiInteractionCoordinator.instance;
      coordinator.beginInteraction(Object());
      await tester.pumpWidget(
        fixture.build(
          const TimerTab(showHeader: false),
          overrides: [
            permissionStatusServiceProvider.overrideWithValue(permissions),
          ],
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.finishInteractionsForTest();
      await tester.pump();
      expect(permissions.checks, isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Windows timer does not query Android permissions',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      final permissions = _CountingPermissionStatusService();
      await tester.pumpWidget(
        fixture.build(
          const TimerTab(showHeader: false),
          overrides: [
            permissionStatusServiceProvider.overrideWithValue(permissions),
          ],
        ),
      );
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(permissions.checks, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'timer retains cached reliability while checking changed permissions',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.timer.configureTimer(
        TimerMode.manual,
        const Duration(minutes: 30),
      );
      final permissions = _CountingPermissionStatusService()..granted = false;
      await tester.pumpWidget(
        fixture.build(
          const TimerTab(showHeader: false),
          overrides: [
            permissionStatusServiceProvider.overrideWithValue(permissions),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final missing = fixture.languageProvider.tr('timer_reliability_missing');
      expect(find.text(missing), findsOneWidget);

      final pending = Completer<bool>();
      permissions.nextResult = pending.future;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(find.text(missing), findsOneWidget);
      pending.complete(true);
      await tester.pumpAndSettle();
      expect(find.text(missing), findsNothing);
      expect(
        find.text(fixture.languageProvider.tr('timer_reliability_ready')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('timer tab loads reliability status without async setState', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture();
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.build(const TimerTab(showHeader: false)));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced motion timer wheels apply draft changes without scrolling frames',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(const TimerTab(showHeader: false, compactOnly: true)),
      );
      await tester.pumpAndSettle();
      fixture.timer.setTimerDraft(
        TimerMode.manual,
        const Duration(minutes: 45),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final minuteWheel = find.byType(ListWheelScrollView).at(1);
      final controller = tester
          .widget<ListWheelScrollView>(minuteWheel)
          .controller!;
      expect(controller.position.pixels, 45 * 42);
      expect(fixture.timer.state.draftDuration, const Duration(minutes: 45));
      if (Theme.of(tester.element(minuteWheel)).platform ==
          TargetPlatform.windows) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(minuteWheel),
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pump();
        expect(controller.position.pixels, 46 * 42);
        expect(fixture.timer.state.draftDuration, const Duration(minutes: 46));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'enabling reduced motion stops timer scrolling and commits its final value',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        fixture.build(const TimerTab(showHeader: false, compactOnly: true)),
      );
      await tester.pumpAndSettle();
      final minuteWheel = find.byType(ListWheelScrollView).at(1);
      final controller = tester
          .widget<ListWheelScrollView>(minuteWheel)
          .controller!;
      final isWindows =
          Theme.of(tester.element(minuteWheel)).platform ==
          TargetPlatform.windows;
      final expectedDraft = isWindows
          ? const Duration(minutes: 31)
          : const Duration(hours: 1, minutes: 45, seconds: 20);
      if (isWindows) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(minuteWheel),
            scrollDelta: const Offset(0, 120),
          ),
        );
      } else {
        fixture.timer.setTimerDraft(TimerMode.manual, expectedDraft);
        await tester.pump();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(controller.position.isScrollingNotifier.value, isTrue);
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      final expectedItems = [
        expectedDraft.inHours,
        expectedDraft.inMinutes.remainder(60),
        expectedDraft.inSeconds.remainder(60),
      ];
      for (var index = 0; index < expectedItems.length; index++) {
        final wheelController = tester
            .widget<ListWheelScrollView>(
              find.byType(ListWheelScrollView).at(index),
            )
            .controller!;
        expect(wheelController.position.pixels, expectedItems[index] * 42);
        expect(wheelController.position.isScrollingNotifier.value, isFalse);
      }
      await tester.pumpAndSettle();
      expect(fixture.timer.state.draftDuration, expectedDraft);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'compact timer panels share a centered full-height layout',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);

      await tester.pumpWidget(
        fixture.build(
          const TimerTab(
            showHeader: false,
            useSafeArea: false,
            compactOnly: true,
          ),
        ),
      );
      await tester.pump();

      final panel = find.byKey(const ValueKey('timer_compact_panel')).last;
      final title = find.byKey(const ValueKey('timer_compact_title')).last;
      final setupPanelRect = tester.getRect(panel);
      final setupTitleRect = tester.getRect(title);
      expect(setupPanelRect.height, kTimerCompactPanelHeight);
      expect(
        tester.getRect(find.text('确认并立即开始')).bottom,
        lessThanOrEqualTo(setupPanelRect.bottom),
      );
      expect(
        find.text(fixture.languageProvider.tr('stop_after_current_track')),
        findsNothing,
      );

      await tester.tap(find.text('确认并立即开始'));
      await tester.pump();
      await tester.pump();

      expect(find.text('倒计时进行中'), findsOneWidget);
      expect(find.text('确认并立即开始'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 150));
      final detailFade = find
          .ancestor(
            of: find.text('倒计时进行中'),
            matching: find.byType(FadeTransition),
          )
          .first;
      expect(
        tester.widget<FadeTransition>(detailFade).opacity.value,
        closeTo(0.5, 0.03),
      );
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('确认并立即开始'), findsOneWidget);
      expect(find.text('确认并立即开始').hitTestable(), findsNothing);
      expect(
        find.text(fixture.languageProvider.tr('stop_after_current_track')),
        findsOneWidget,
      );
      final detailPanelRect = tester.getRect(panel);
      final detailTitleRect = tester.getRect(title);
      expect(detailPanelRect.size, setupPanelRect.size);
      expect(detailTitleRect.left, setupTitleRect.left);

      fixture.timer.cancelTimer();
      await tester.pump();
      await tester.pump();
      expect(find.text('倒计时进行中'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('倒计时进行中'), findsNothing);
      expect(tester.getRect(panel).size, setupPanelRect.size);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

class _CountingPermissionStatusService extends PermissionStatusService {
  final checks = <PermissionCapability>[];
  bool granted = true;
  Future<bool>? nextResult;

  @override
  Future<bool> isGranted(
    PermissionCapability capability, {
    bool errorDefault = false,
  }) async {
    checks.add(capability);
    return nextResult ?? granted;
  }
}
