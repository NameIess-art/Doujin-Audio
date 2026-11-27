import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/theme/app_design_tokens.dart';
import 'package:doujin_audio/core/media/time_text_formatters.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:doujin_audio/app/state/app_runtime_providers.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_buttons.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/player/presentation/timer_tab.dart';
import 'package:doujin_audio/features/player/domain/playback_mode.dart';
import 'package:doujin_audio/features/settings/application/permission_status_service.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  AppRuntimeTestFixture.initialize();

  setUp(() {
    UiInteractionCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });
  tearDown(() {
    UiInteractionCoordinator.instance.resetForTest();
    UiInteractionNavigatorObserver.instance.resetForTest();
  });

  testWidgets(
    'full timer content starts eight pixels below its title bar',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: const EdgeInsets.only(top: 24)),
              child: const TimerTab(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final summary = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Wrap),
          )
          .first;
      expect(
        tester.getTopLeft(summary).dy -
            tester.getBottomLeft(find.byType(TopPageHeader)).dy,
        8,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'automatic resume time keeps clock and shared keyboard input styles',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.timerService
        ..timerMode = TimerMode.manual
        ..timerDuration = const Duration(minutes: 10)
        ..timerActive = true
        ..timerRemaining = const Duration(minutes: 10)
        ..autoResumeEnabled = true
        ..autoResumeHour = 9
        ..autoResumeMinute = 15;
      fixture.timer.syncPresentationState();
      await tester.pumpWidget(fixture.build(const TimerTab(showHeader: false)));
      await tester.pumpAndSettle();
      final open = find.text(
        fixture.languageProvider.tr('tap_choose_resume_time'),
      );
      await tester.scrollUntilVisible(
        open,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();

      final picker = find.byType(TimePickerDialog);
      final pickerContext = tester.element(picker);
      final localizations = MaterialLocalizations.of(pickerContext);
      final theme = Theme.of(pickerContext);
      expect(MediaQuery.alwaysUse24HourFormatOf(pickerContext), isTrue);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip(localizations.inputTimeModeButtonLabel));
      await tester.pumpAndSettle();

      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(dialog.backgroundColor, theme.colorScheme.surfaceContainerLow);
      expect(
        dialog.shape,
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            theme.extension<AppDesignTokens>()!.radiusOverlay,
          ),
        ),
      );
      final fields = find.descendant(
        of: picker,
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      for (final field in tester.widgetList<TextField>(fields)) {
        expect(field.decoration?.fillColor, theme.inputDecorationTheme.fillColor);
        expect(
          field.decoration?.focusedBorder,
          theme.inputDecorationTheme.focusedBorder,
        );
      }
      await tester.enterText(fields.first, '23');
      await tester.enterText(fields.last, '45');
      await tester.tap(find.text(localizations.okButtonLabel));
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      expect(fixture.timerService.autoResumeHour, 23);
      expect(fixture.timerService.autoResumeMinute, 45);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final compact in [false, true]) {
    testWidgets(
      '${compact ? 'compact' : 'full'} timer isolates ten seconds of ticks and refreshes phase and language',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        fixture.timerService
          ..timerMode = TimerMode.manual
          ..timerDuration = const Duration(minutes: 1)
          ..timerActive = true
          ..timerRemaining = const Duration(minutes: 1);
        fixture.timer.syncPresentationState();
        await tester.pumpWidget(
          fixture.build(
            TimerTab(
              showHeader: false,
              compactOnly: compact,
              initialCompactDetail: compact,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final builds = <String, int>{};
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          final name = element.widget.runtimeType.toString();
          builds.update(name, (count) => count + 1, ifAbsent: () => 1);
          previous?.call(element, builtOnce);
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        for (var second = 1; second <= 10; second++) {
          fixture.timerService.timerRemaining = Duration(seconds: 60 - second);
          fixture.timer.syncPresentationState();
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();
          expect(
            find.text(formatDurationHms(Duration(seconds: 60 - second))),
            findsWidgets,
          );
        }
        for (final name in [
          'TimerTab',
          '_CountdownCard',
          '_DurationPicker',
          '_TimerSectionTitle',
        ]) {
          expect(builds[name] ?? 0, 0, reason: name);
        }
        fixture.timerService
          ..timerActive = false
          ..timerRemaining = Duration.zero;
        fixture.timer.syncPresentationState();
        await tester.pumpAndSettle();
        expect(
          find.text(fixture.languageProvider.tr('countdown_finished')),
          findsWidgets,
        );
        fixture.timerService
          ..autoResumeEnabled = true
          ..autoResumeHour = 9
          ..autoResumeMinute = 15
          ..autoResumeAt = DateTime.now().add(const Duration(hours: 1));
        fixture.timer.syncPresentationState();
        await tester.pump();
        await tester.pump();
        expect(
          find.text(fixture.languageProvider.tr('waiting_for_auto_resume')),
          findsWidgets,
        );
        await fixture.languageProvider.setLanguage(AppLanguage.en);
        await tester.pump();
        await tester.pump();
        expect(
          find.text(fixture.languageProvider.tr('waiting_for_auto_resume')),
          findsWidgets,
        );
        fixture.timer.cancelTimer();
        await tester.pumpAndSettle();
        expect(
          find.text(fixture.languageProvider.tr('waiting_for_auto_resume')),
          findsNothing,
        );
        expect(find.byType(ListWheelScrollView), findsNWidgets(3));
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.windows,
      }),
    );
  }

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
    'timer permission check failure offers a retry instead of readiness',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.timer.configureTimer(
        TimerMode.manual,
        const Duration(minutes: 30),
      );
      final pending = Completer<bool>();
      final permissions = _CountingPermissionStatusService()
        ..nextResult = pending.future;
      await tester.pumpWidget(
        fixture.build(
          const TimerTab(showHeader: false),
          overrides: [
            permissionStatusServiceProvider.overrideWithValue(permissions),
          ],
        ),
      );
      await tester.pump();
      pending.completeError(StateError('Permission check failed'));
      await tester.pumpAndSettle();
      expect(
        find.text(fixture.languageProvider.tr('timer_reliability_ready')),
        findsNothing,
      );
      expect(
        find.text(fixture.languageProvider.tr('operation_failed_retry')),
        findsOneWidget,
      );

      permissions.nextResult = null;
      await tester.tap(find.byTooltip(fixture.languageProvider.tr('retry')));
      await tester.pumpAndSettle();
      expect(
        find.text(fixture.languageProvider.tr('timer_reliability_ready')),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

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
    'compact timer entry selects the 45-minute preset',
    (tester) async {
      await tester.binding.setSurfaceSize(
        Size(defaultTargetPlatform == TargetPlatform.android ? 320 : 960, 800),
      );
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTimerSettingsPanel(
                  context,
                  initialCompactDetail: false,
                ),
                child: const Text('Open timer'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open timer'));
      await tester.pumpAndSettle();
      expect(find.byType(TimerTab), findsOneWidget);

      final preset = find.byKey(const ValueKey('timer_preset_45m'));
      await tester.tap(preset);
      await tester.pumpAndSettle();

      expect(fixture.timer.state.draftDuration, const Duration(minutes: 45));
      final minuteWheel = tester.widget<ListWheelScrollView>(
        find.byType(ListWheelScrollView).at(1),
      );
      final minuteController =
          minuteWheel.controller as FixedExtentScrollController;
      expect(minuteController.selectedItem % 60, 45);
      final presetMaterial = find
          .ancestor(of: preset, matching: find.byType(Material))
          .first;
      expect(
        tester.widget<Material>(presetMaterial).color,
        Theme.of(tester.element(preset)).colorScheme.primaryContainer,
      );
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
      final halfFade = kAppFadeDuration ~/ 2;
      await tester.pump(halfFade);
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
      await tester.pump(kAppFadeDuration - halfFade);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('确认并立即开始'), findsOneWidget);
      expect(find.text('确认并立即开始').hitTestable(), findsNothing);
      expect(
        find.text(fixture.languageProvider.tr('stop_after_current_track')),
        findsOneWidget,
      );
      fixture.timer.setAutoResume(true, 7, 0);
      await tester.pump();
      await tester.pump();
      Finder rowCard(String text) => find
          .ancestor(of: find.text(text), matching: find.byType(Material))
          .first;
      final autoResumeHeight = tester
          .getRect(
            rowCard(fixture.languageProvider.tr('auto_resume_after_timer')),
          )
          .height;
      final resumeTimeHeight = tester
          .getRect(
            rowCard(
              fixture.languageProvider.tr('resume_time', {'time': '07:00'}),
            ),
          )
          .height;
      final stopAfterTrackHeight = tester
          .getRect(
            rowCard(fixture.languageProvider.tr('stop_after_current_track')),
          )
          .height;
      expect(autoResumeHeight, closeTo(resumeTimeHeight, 0.01));
      expect(stopAfterTrackHeight, closeTo(resumeTimeHeight, 0.01));
      final trackEndToggle = find
          .byWidgetPredicate(
            (widget) => widget is Switch && widget.value == false,
          )
          .last;
      await tester.ensureVisible(trackEndToggle);
      await tester.tap(trackEndToggle);
      await tester.pump();
      expect(fixture.timer.stopAfterCurrentTrack, isTrue);
      final detailPanelRect = tester.getRect(panel);
      final detailTitleRect = tester.getRect(title);
      expect(detailPanelRect.size, setupPanelRect.size);
      expect(detailTitleRect.left, setupTitleRect.left);

      fixture.timer.cancelTimer();
      await tester.pump();
      await tester.pump();
      expect(find.text('倒计时进行中'), findsOneWidget);
      await tester.pump(kAppFadeDuration);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('倒计时进行中'), findsNothing);
      expect(tester.getRect(panel).size, setupPanelRect.size);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Windows timer cards highlight their existing shape and keep its size',
    (tester) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      await tester.pumpWidget(
        fixture.build(
          const Scaffold(
            body: Center(
              child: SizedBox(
                width: 420,
                height: kTimerCompactPanelHeight,
                child: TimerTab(showHeader: false, compactOnly: true),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final manualLabel = fixture.languageProvider.tr('manual_start');
      final triggerLabel = fixture.languageProvider.tr('auto_start_after_play');
      final manualText = find.text(manualLabel);
      final triggerText = find.text(triggerLabel);

      Finder card(Finder label) =>
          find.ancestor(of: label, matching: find.byType(Material)).first;
      final row = card(triggerText);
      final rest = tester.widget<Material>(row);
      final bounds = tester.getRect(row);
      final restTextColor = tester.widget<Text>(triggerText).style?.color;
      final dynamic controller = Material.of(tester.element(triggerText));
      Iterable<InteractiveInkFeature> visibleInk() =>
          (controller.debugInkFeatures as List<InkFeature>? ?? [])
              .whereType<InteractiveInkFeature>()
              .where((feature) => feature.color.a > 0);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(triggerText));
      await tester.pumpAndSettle();
      final scheme = Theme.of(tester.element(triggerText)).colorScheme;
      expect(visibleInk().single.color, appHoverTint(scheme));
      expect(tester.widget<Material>(row).shape, rest.shape);
      expect(tester.widget<Text>(triggerText).style?.color, restTextColor);
      expect(tester.getRect(row), bounds);
      expect(
        tester.widget<Material>(card(manualText)).shape,
        isNot(rest.shape),
      );

      await mouse.down(tester.getCenter(triggerText));
      await tester.pumpAndSettle();
      expect(
        visibleInk().map((feature) => feature.color),
        contains(appPressedTint(scheme)),
      );
      await mouse.cancel();
      await tester.pumpAndSettle();
      expect(
        visibleInk().map((feature) => feature.color),
        isNot(contains(appPressedTint(scheme))),
      );
      expect(fixture.timerService.timerDraftMode, TimerMode.manual);

      // Clicking switches the selected timer mode.
      await tester.tap(triggerText);
      await tester.pumpAndSettle();
      expect(fixture.timerService.timerDraftMode, TimerMode.trigger);

      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'expired timer keeps preset and mode changes without snapping back',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.timerService
        ..timerMode = TimerMode.manual
        ..timerDuration = const Duration(minutes: 15)
        ..timerActive = false
        ..timerRemaining = Duration.zero
        ..timerDraftMode = TimerMode.manual
        ..timerDraftDuration = const Duration(minutes: 15);
      fixture.timer.syncPresentationState();

      await tester.pumpWidget(fixture.build(const TimerTab(showHeader: false)));
      await tester.pumpAndSettle();

      final preset60 = find.byKey(const ValueKey('timer_preset_60m'));
      await tester.scrollUntilVisible(
        preset60,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(preset60);
      await tester.pumpAndSettle();
      await tester.tap(preset60);
      await tester.pumpAndSettle();

      expect(fixture.timer.state.draftDuration, const Duration(minutes: 60));
      final hourController =
          tester
                  .widget<ListWheelScrollView>(
                    find.byType(ListWheelScrollView).at(0),
                  )
                  .controller!
              as FixedExtentScrollController;
      final minuteController =
          tester
                  .widget<ListWheelScrollView>(
                    find.byType(ListWheelScrollView).at(1),
                  )
                  .controller!
              as FixedExtentScrollController;
      expect(hourController.selectedItem % 13, 1);
      expect(minuteController.selectedItem % 60, 0);

      final triggerOption = find.text(
        fixture.languageProvider.tr('auto_start_after_play'),
      );
      await tester.scrollUntilVisible(
        triggerOption,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(triggerOption);
      await tester.pumpAndSettle();
      await tester.tap(triggerOption);
      await tester.pumpAndSettle();

      expect(fixture.timer.state.draftMode, TimerMode.trigger);
      expect(
        find.text(fixture.languageProvider.tr('confirm_wait_playback')),
        findsOneWidget,
      );
      expect(hourController.selectedItem % 13, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'duration wheel stays at 00:00:00 and clamps hours above 12 without wrapping',
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

      // Extended duration past 12 hours clamps hour wheel to 12 rather than wrapping modulo 13.
      fixture.timer.setTimerDraft(
        TimerMode.manual,
        const Duration(hours: 13, minutes: 5),
      );
      await tester.pumpAndSettle();
      final hourController =
          tester
                  .widget<ListWheelScrollView>(
                    find.byType(ListWheelScrollView).at(0),
                  )
                  .controller!
              as FixedExtentScrollController;
      expect(hourController.selectedItem % 13, 12);

      // Scrolling down to 00:00:00 keeps the wheel at zero instead of snapping back to 00:30:00.
      fixture.timer.setTimerDraft(TimerMode.manual, const Duration(minutes: 1));
      await tester.pumpAndSettle();
      final minuteWheel = find.byType(ListWheelScrollView).at(1);
      final minuteController =
          tester.widget<ListWheelScrollView>(minuteWheel).controller!
              as FixedExtentScrollController;
      expect(minuteController.selectedItem % 60, 1);
      minuteController.jumpToItem(minuteController.selectedItem - 1);
      await tester.pumpAndSettle();

      expect(minuteController.selectedItem % 60, 0);
      expect(
        find.text(fixture.languageProvider.tr('set_duration_first')),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'rapid wheel edits to 00:00:00 are not snapped back by lagging draft stream events',
    (tester) async {
      tester.binding.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      fixture.timer.setTimerDraft(TimerMode.manual, const Duration(minutes: 2));
      await tester.pumpWidget(
        fixture.build(const TimerTab(showHeader: false, compactOnly: true)),
      );
      await tester.pumpAndSettle();

      final minuteWheel = find.byType(ListWheelScrollView).at(1);
      final minuteController =
          tester.widget<ListWheelScrollView>(minuteWheel).controller!
              as FixedExtentScrollController;
      expect(minuteController.selectedItem % 60, 2);

      // Step 2m -> 1m -> 0m in quick succession before async stream events flush.
      minuteController.jumpToItem(minuteController.selectedItem - 1);
      minuteController.jumpToItem(minuteController.selectedItem - 1);
      await tester.pumpAndSettle();

      expect(minuteController.selectedItem % 60, 0);
      expect(
        find.text(fixture.languageProvider.tr('set_duration_first')),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
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
