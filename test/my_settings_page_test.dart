import 'dart:async';

import 'package:doujin_audio/app/presentation/app_presentation_providers.dart';
import 'package:doujin_audio/app/presentation/listening_time_chart.dart';
import 'package:doujin_audio/app/presentation/my_page.dart';
import 'package:doujin_audio/app/presentation/my_settings_page.dart';
import 'package:doujin_audio/app/state/listening_activity_provider.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:doujin_audio/features/settings/application/settings_repository.dart';
import 'package:doujin_audio/features/settings/presentation/settings_tab.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  setUp(() async {
    UiInteractionCoordinator.instance.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await AppPreferences.init();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    UiInteractionCoordinator.instance.resetForTest();
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'merged page lazily retains both children on $platform, reduced=$reducedMotion',
        (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = platform == TargetPlatform.windows
              ? const Size(960, 600)
              : const Size(390, 600);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final fixture = AppRuntimeWidgetTestFixture();
          addTearDown(fixture.dispose);
          var activitySubscriptions = 0;
          await tester.pumpWidget(
            fixture.build(
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    disableAnimations: reducedMotion,
                    textScaler: TextScaler.linear(reducedMotion ? 1.5 : 1),
                  ),
                  child: const MySettingsPage(tabIndex: 3),
                ),
              ),
              overrides: [
                listeningActivityProvider.overrideWith((ref) {
                  activitySubscriptions++;
                  return Stream.value(const ListeningActivityView());
                }),
              ],
            ),
          );
          await pumpAndSettleWithAsync(tester);
          final settings = find.byType(SettingsTab, skipOffstage: false);
          final my = find.byType(MyPage, skipOffstage: false);
          expect(settings, findsOneWidget);
          expect(my, findsNothing);
          expect(activitySubscriptions, 0);
          _expectSeparateSwitch(tester, 'switch-to-my');
          final settingsState = tester.state(settings);
          final settingsScroll = _verticalScroll(tester, settings);
          settingsScroll.jumpTo(settingsScroll.maxScrollExtent);
          await tester.pump();
          final container = ProviderScope.containerOf(tester.element(settings));
          container.read(mainScreenControllerProvider).requestScrollToTop(3);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 80));
          final settingsOffset = settingsScroll.pixels;
          if (!reducedMotion) {
            expect(settingsOffset, greaterThan(0));
            expect(settingsScroll.isScrollingNotifier.value, isTrue);
          }

          await tester.tap(find.byKey(const ValueKey('switch-to-my')));
          await pumpAndSettleWithAsync(tester);
          await pumpUntilUiIdle(tester);
          expect(fixture.settings.mySettingsPageMode, MySettingsPageMode.my);
          expect(find.byType(MyPage), findsOneWidget);
          expect(find.byType(SettingsTab), findsNothing);
          _expectSeparateSwitch(tester, 'switch-to-settings');
          expect(activitySubscriptions, 1);
          final myState = tester.state(my);
          final chart = find.byType(ListeningTimeChart, skipOffstage: false);
          final chartState = tester.state(chart);
          final month = find.widgetWithText(
            ChoiceChip,
            fixture.languageProvider.tr('my_interval_month'),
            skipOffstage: false,
          );
          await tester.ensureVisible(month);
          await tester.tap(month);
          await pumpAndSettleWithAsync(tester);
          final myScroll = _verticalScroll(tester, my);
          myScroll.jumpTo(myScroll.maxScrollExtent);
          final myOffset = myScroll.pixels;
          if (platform == TargetPlatform.android) {
            expect(myOffset, greaterThan(0));
          }

          await tester.tap(find.byKey(const ValueKey('switch-to-settings')));
          await pumpAndSettleWithAsync(tester);
          await pumpUntilUiIdle(tester);
          expect(tester.state(settings), same(settingsState));
          expect(settingsScroll.pixels, settingsOffset);
          expect(TickerMode.valuesOf(tester.element(my)).enabled, isFalse);
          container.read(mainScreenControllerProvider).requestScrollToTop(3);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(settingsScroll.pixels, 0);
          expect(myScroll.pixels, myOffset);

          await tester.tap(find.byKey(const ValueKey('switch-to-my')));
          await pumpAndSettleWithAsync(tester);
          await pumpUntilUiIdle(tester);
          expect(tester.state(my), same(myState));
          expect(tester.state(chart), same(chartState));
          expect(tester.widget<ChoiceChip>(month).selected, isTrue);
          expect(myScroll.pixels, myOffset);
          expect(activitySubscriptions, 1);
          expect(
            TickerMode.valuesOf(tester.element(settings)).enabled,
            isFalse,
          );
          container.read(mainScreenControllerProvider).requestScrollToTop(3);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 350));
          expect(myScroll.pixels, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await pumpAndSettleWithAsync(tester);
          debugDefaultTargetPlatformOverride = null;
        },
      );
    }
  }

  testWidgets('remembered My creates no settings child until switching', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      configureSettingsRepository: (settings) {
        settings.mySettingsPageMode = MySettingsPageMode.my;
        settings.syncSlice();
      },
    );
    addTearDown(fixture.dispose);
    final track = testMusicTrack(
      name: 'History track',
      path: '/audio/history/track.mp3',
      groupKey: '/audio/history',
      groupTitle: 'History work',
    );
    fixture.library.addTracks([track], persist: false);
    await tester.pumpWidget(
      fixture.build(
        const MySettingsPage(tabIndex: 3),
        overrides: [
          listeningActivityProvider.overrideWith(
            (ref) => Stream.value(
              ListeningActivityView(
                history: [
                  ListeningHistoryEntry(workKey: 'history-work', track: track),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    await pumpAndSettleWithAsync(tester);
    expect(find.byType(MyPage), findsOneWidget);
    expect(find.byType(SettingsTab, skipOffstage: false), findsNothing);
    expect(
      tester
          .widget<AppFadeThroughIndexedStack>(
            find.byType(AppFadeThroughIndexedStack),
          )
          .duration,
      const Duration(milliseconds: 300),
    );
    await fixture.settings.setMySettingsPageMode(MySettingsPageMode.settings);
    await pumpAndSettleWithAsync(tester);
    expect(find.byType(SettingsTab), findsOneWidget);
    expect(find.byType(MyPage, skipOffstage: false), findsOneWidget);
    final myState = tester.state(find.byType(MyPage, skipOffstage: false));
    await tester.tap(find.text(fixture.languageProvider.tr('section_common')));
    await pumpAndSettleWithAsync(tester);
    await fixture.settings.setMySettingsPageMode(MySettingsPageMode.my);
    await pumpAndSettleWithAsync(tester);
    await pumpUntilUiIdle(tester);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    expect(navigator.canPop(), isTrue);
    navigator.pop();
    await pumpAndSettleWithAsync(tester);
    await pumpUntilUiIdle(tester);
    expect(tester.state(find.byType(MyPage)), same(myState));
    expect(find.byKey(const ValueKey('switch-to-settings')), findsOneWidget);
    final history = find.byKey(const ValueKey('my-history-card-history-work'));
    await tester.ensureVisible(history);
    await pumpUntilUiIdle(tester);
    await tester.tap(history);
    await pumpAndSettleWithAsync(tester);
    expect(find.byType(WorkDetailPage), findsOneWidget);
    navigator.pop();
    await pumpAndSettleWithAsync(tester);
    await pumpUntilUiIdle(tester);
    expect(tester.state(find.byType(MyPage)), same(myState));
    expect(find.byKey(const ValueKey('switch-to-settings')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpAndSettleWithAsync(tester);
  });

  testWidgets('failed mode save leaves settings visible and shows feedback', (
    tester,
  ) async {
    final fixture = AppRuntimeWidgetTestFixture(
      providedSettingsRepository: _FailingSettingsRepository(),
    );
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.build(const MySettingsPage(tabIndex: 3)));
    await pumpAndSettleWithAsync(tester);
    await tester.tap(find.byKey(const ValueKey('switch-to-my')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(fixture.settings.mySettingsPageMode, MySettingsPageMode.settings);
    expect(find.byType(SettingsTab), findsOneWidget);
    expect(find.byType(MyPage, skipOffstage: false), findsNothing);
    expect(
      find.textContaining(
        fixture.languageProvider.tr('operation_failed_retry'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpAndSettleWithAsync(tester);
  });
}

class _FailingSettingsRepository extends SettingsRepository {
  @override
  Future<void> persist() async => throw StateError('save failed');
}

void _expectSeparateSwitch(WidgetTester tester, String key) {
  final button = find.byKey(ValueKey(key));
  final floatingButton = find.ancestor(
    of: button,
    matching: find.byType(HeaderFloatingButton),
  );
  expect(floatingButton, findsOneWidget);
  final header = find.ancestor(
    of: button,
    matching: find.byType(TopPageHeader),
  );
  final title = find
      .descendant(of: header, matching: find.byType(HeaderFloatingSurface))
      .evaluate()
      .where(
        (element) =>
            element.findAncestorWidgetOfExactType<HeaderFloatingButton>() ==
            null,
      );
  expect(title, hasLength(1));
  final titleRect = tester.getRect(find.byWidget(title.single.widget));
  final buttonRect = tester.getRect(floatingButton);
  expect(buttonRect.left - titleRect.right, closeTo(8, 0.01));
  expect(buttonRect.center.dy, closeTo(titleRect.center.dy, 0.01));
  expect(buttonRect.width, buttonRect.height);
}

ScrollPosition _verticalScroll(WidgetTester tester, Finder page) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: page,
        matching: find.byType(Scrollable, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .firstWhere((state) => state.position.axis == Axis.vertical)
    .position;
