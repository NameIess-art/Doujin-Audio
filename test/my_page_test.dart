import 'dart:async';
import 'dart:collection';

import 'package:doujin_audio/app/presentation/listening_time_chart.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/presentation/my_page.dart';
import 'package:doujin_audio/app/presentation/my_tag_management_page.dart';
import 'package:doujin_audio/app/state/listening_activity_provider.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/path_display.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/core/ui/interaction_deferred_stream.dart';
import 'package:doujin_audio/features/player/application/listening_activity_service.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/core/widgets/async_cover_image.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';
import 'support/asmr_controller_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPreferences.init();
  });

  testWidgets('first taste projections wait for scrolling to finish', (
    tester,
  ) async {
    final controller = _InterestController(createTestAsmrServices());
    final container = ProviderContainer(
      overrides: [asmrLibraryControllerProvider.overrideWithValue(controller)],
    );
    addTearDown(controller.dispose);
    addTearDown(container.dispose);
    final interaction = UiInteractionCoordinator.instance;
    final drag = Object();
    addTearDown(() => interaction.cancelInteraction(drag));
    interaction.beginInteraction(drag);
    container.listen(asmrTagInterestsProvider, (_, _) {});
    container.listen(asmrVoiceActorInterestsProvider, (_, _) {});
    await tester.pump();
    expect(controller.interestReads, 0);
    expect(controller.voiceInterestReads, 0);
    interaction.cancelInteraction(drag);
    await pumpUntilUiIdle(tester);
    expect(controller.interestReads, greaterThan(0));
    expect(controller.voiceInterestReads, greaterThan(0));
    expect(container.read(asmrTagInterestsProvider).hasValue, isTrue);
    expect(container.read(asmrVoiceActorInterestsProvider).hasValue, isTrue);
  });

  test(
    'interest providers stay loading until initialization publishes real content',
    () async {
      final controller = _PendingInterestController(createTestAsmrServices());
      final container = ProviderContainer(
        overrides: [
          asmrLibraryControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(controller.dispose);
      addTearDown(container.dispose);
      final published = <List<AsmrTagInterest>>[];
      container.listen(asmrTagInterestsProvider, (_, next) {
        if (next.hasValue) published.add(next.requireValue);
      });
      await Future<void>.delayed(Duration.zero);
      UiInteractionCoordinator.instance.flushPendingCommitsForTest();
      await Future<void>.delayed(Duration.zero);
      expect(container.read(asmrTagInterestsProvider).isLoading, isTrue);
      expect(published, isEmpty);
      controller.ready.complete();
      await Future<void>.delayed(Duration.zero);
      UiInteractionCoordinator.instance.flushPendingCommitsForTest();
      await Future<void>.delayed(Duration.zero);
      expect(published.single.single.tag.name, 'Sleep');
    },
  );

  test(
    'merged My and settings is permanent after playlist in all visibility combinations',
    () {
      for (final local in [false, true]) {
        for (final remote in [false, true]) {
          for (final mode in MySettingsPageMode.values) {
            final destinations = resolveMainDestinations(
              showLocalLibrary: local,
              showAsmrOne: remote,
              mySettingsPageMode: mode,
            );
            expect(destinations.length, 2 + (local ? 1 : 0) + (remote ? 1 : 0));
            expect(
              destinations
                  .map((e) => e.type)
                  .toList()
                  .sublist(destinations.length - 2),
              [MainDestinationType.playlist, MainDestinationType.settings],
            );
            expect(
              destinations.last.labelKey,
              mode == MySettingsPageMode.my ? 'nav_my' : 'nav_settings',
            );
            expect(
              destinations.last.selectedIcon,
              mode == MySettingsPageMode.my
                  ? Icons.person_rounded
                  : Icons.settings_rounded,
            );
          }
        }
      }
    },
  );

  test('daily columns fill missing dates without inferring listening', () {
    final periods = aggregateListeningPeriods(
      [
        ListeningDay(
          date: DateTime(2026, 10, 20),
          duration: const Duration(minutes: 30),
        ),
        ListeningDay(
          date: DateTime(2026, 10, 22),
          duration: const Duration(minutes: 10),
        ),
      ],
      ListeningInterval.day,
      now: DateTime(2026, 10, 23),
    );
    expect(periods.length, 30);
    expect(periods.last.start, DateTime(2026, 10, 23));
    expect(periods.last.duration, Duration.zero);
    expect(
      periods.firstWhere((p) => p.start == DateTime(2026, 10, 21)).duration,
      Duration.zero,
    );
    expect(
      periods.fold<Duration>(Duration.zero, (sum, p) => sum + p.duration),
      const Duration(minutes: 40),
    );
  });

  test('weeks start Monday and group Sunday across year boundary', () {
    final periods = aggregateListeningPeriods(
      [
        ListeningDay(
          date: DateTime(2025, 12, 29),
          duration: const Duration(minutes: 4),
        ),
        ListeningDay(
          date: DateTime(2026, 1, 4),
          duration: const Duration(minutes: 6),
        ),
        ListeningDay(
          date: DateTime(2026, 1, 5),
          duration: const Duration(minutes: 7),
        ),
      ],
      ListeningInterval.week,
      now: DateTime(2026, 1, 5),
    );
    expect(periods[periods.length - 2].start, DateTime(2025, 12, 29));
    expect(periods[periods.length - 2].duration, const Duration(minutes: 10));
    expect(periods.last.duration, const Duration(minutes: 7));
    expect(
      periods.every((period) => period.start.weekday == DateTime.monday),
      isTrue,
    );
  });

  test('month quarter and year use natural calendar boundaries', () {
    final days = [
      ListeningDay(
        date: DateTime(2025, 12, 31),
        duration: const Duration(minutes: 1),
      ),
      ListeningDay(date: DateTime(2026), duration: const Duration(minutes: 2)),
      ListeningDay(
        date: DateTime(2026, 3, 31),
        duration: const Duration(minutes: 3),
      ),
      ListeningDay(
        date: DateTime(2026, 4),
        duration: const Duration(minutes: 4),
      ),
    ];
    final quarters = aggregateListeningPeriods(
      days,
      ListeningInterval.quarter,
      now: DateTime(2026, 4),
    );
    expect(quarters.last.start, DateTime(2026, 4));
    expect(quarters[quarters.length - 2].duration, const Duration(minutes: 5));
    final months = aggregateListeningPeriods(
      days,
      ListeningInterval.month,
      now: DateTime(2026, 4),
    );
    expect(
      months.firstWhere((p) => p.start == DateTime(2026, 2)).duration,
      Duration.zero,
    );
    final years = aggregateListeningPeriods(
      days,
      ListeningInterval.year,
      now: DateTime(2026, 4),
    );
    expect(years.last.duration, const Duration(minutes: 9));
    expect(years[years.length - 2].duration, const Duration(minutes: 1));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'activity updates after scrolling rebuild only dependent My sections on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _InterestController(createTestAsmrServices());
        final updates = StreamController<ListeningActivityView>();
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        addTearDown(updates.close);
        tester.view.physicalSize = const Size(390, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyPage(tabIndex: 3),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              listeningActivityProvider.overrideWith(
                (ref) => interactionDeferredValueStream(
                  updates.stream,
                  structural: true,
                ),
              ),
            ],
          ),
        );
        updates.add(const ListeningActivityView());
        await pumpAndSettleWithAsync(tester);
        final view = ListeningActivityView(
          days: [
            ListeningDay(
              date: DateTime.now(),
              duration: const Duration(minutes: 10),
            ),
          ],
          history: [
            ListeningHistoryEntry(
              workKey: 'updated',
              track: MusicTrack(
                path: 'https://example.com/updated.mp3',
                displayName: 'Updated track',
                groupKey: 'updated',
                groupTitle: 'Updated work',
                groupSubtitle: '',
                isSingle: false,
                remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
                remoteMetadata: const {'title': 'Updated work'},
              ),
            ),
          ],
        );
        final root = tester.element(find.byType(MyPage));
        var rootBuilds = 0;
        final previousRebuildHook = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previousRebuildHook?.call(element, builtOnce);
          if (identical(element, root)) rootBuilds++;
        };
        try {
          final list = find.byWidgetPredicate(
            (widget) =>
                widget is ListView && widget.scrollDirection == Axis.vertical,
          );
          final gesture = await tester.startGesture(tester.getCenter(list));
          await gesture.moveBy(const Offset(0, -40));
          await tester.pump(const Duration(milliseconds: 16));
          updates.add(view);
          await tester.pump();
          expect(
            tester
                .widget<ListeningTimeChart>(find.byType(ListeningTimeChart))
                .days,
            isEmpty,
          );
          await gesture.up();
          await pumpUntilUiIdle(tester);
          await pumpAndSettleWithAsync(tester);
          expect(
            tester
                .widget<ListeningTimeChart>(find.byType(ListeningTimeChart))
                .days,
            same(view.days),
          );
          expect(find.text('Updated work'), findsOneWidget);
          expect(rootBuilds, 0);
        } finally {
          debugOnRebuildDirtyWidget = previousRebuildHook;
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'vertical round trips retain chart and history state on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _InterestController(createTestAsmrServices());
        for (var i = 0; i < 30; i++) {
          controller.state.learned[controller.state.resolve('Interest $i')] =
              i + 1;
          controller.voices.learned[controller.voices.resolve('Voice $i')] =
              i + 1;
        }
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        tester.view.physicalSize = const Size(360, 400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final days = _CountingListeningDays(
          List.generate(
            3650,
            (i) => ListeningDay(
              date: DateTime(2026, 10, 24 - i),
              duration: const Duration(minutes: 5),
            ),
          ),
        );
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyPage(tabIndex: 3),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              listeningActivityProvider.overrideWith(
                (ref) => Stream.value(
                  ListeningActivityView(
                    days: days,
                    history: List.generate(
                      20,
                      (i) => ListeningHistoryEntry(
                        workKey: 'history-$i',
                        track: MusicTrack(
                          path: 'https://example.com/history-$i.mp3',
                          displayName: 'History track $i',
                          groupKey: 'history-$i',
                          groupTitle: 'History work $i',
                          groupSubtitle: '',
                          isSingle: false,
                          remoteMetadataKind:
                              MusicTrack.remoteMetadataKindAsmrOne,
                          remoteMetadata: {'title': 'History work $i'},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        await pumpAndSettleWithAsync(tester);
        final chart = tester.state(find.byType(ListeningTimeChart));
        final vertical = find.byWidgetPredicate(
          (widget) =>
              widget is ListView && widget.scrollDirection == Axis.vertical,
        );
        final scroll = tester.widget<ListView>(vertical).controller!;
        final week = find.widgetWithText(
          ChoiceChip,
          fixture.languageProvider.tr('my_interval_week'),
        );
        await tester.tap(week);
        await tester.pumpAndSettle();
        days.reads = 0;
        // Visit the horizontal row once before moving it beyond the cache window.
        scroll.jumpTo(240);
        await pumpAndSettleWithAsync(tester);
        final history = find.byKey(const ValueKey('my-history-viewport'));
        final historyScroll = tester
            .widget<ListView>(
              find.descendant(of: history, matching: find.byType(ListView)),
            )
            .controller!;
        historyScroll.jumpTo(150);
        await tester.pumpAndSettle();
        // Hold the scroll interaction while the taste sections first enter.
        final interaction = UiInteractionCoordinator.instance;
        final drag = Object();
        interaction.beginInteraction(drag);
        addTearDown(() => interaction.cancelInteraction(drag));
        final tagReads = controller.interestReads;
        final voiceReads = controller.voiceInterestReads;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        for (var i = 0; i < 20; i++) {
          controller.notifyListeners();
        }
        await tester.pump();
        expect(controller.interestReads, tagReads);
        expect(controller.voiceInterestReads, voiceReads);
        interaction.cancelInteraction(drag);
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        final settledTagReads = controller.interestReads;
        final settledVoiceReads = controller.voiceInterestReads;
        for (var i = 0; i < 3; i++) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          scroll.jumpTo(0);
          await pumpAndSettleWithAsync(tester);
        }
        expect(tester.state(find.byType(ListeningTimeChart)), same(chart));
        expect(tester.widget<ChoiceChip>(week).selected, isTrue);
        scroll.jumpTo(240);
        await pumpAndSettleWithAsync(tester);
        final restored = tester
            .widget<ListView>(
              find.descendant(of: history, matching: find.byType(ListView)),
            )
            .controller!;
        expect(restored, same(historyScroll));
        expect(restored.offset, 150);
        expect(controller.interestReads, settledTagReads);
        expect(controller.voiceInterestReads, settledVoiceReads);
        expect(days.reads, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'My refresh and interest sorting wait until navigation ends on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _InterestController(createTestAsmrServices());
        final repository = _ListeningRepository();
        var usageReads = 0;
        final activity = ListeningActivityService(
          repository: repository,
          readUsage: () async {
            usageReads++;
            return const [];
          },
          acknowledgeUsage: (_) async {},
          resolveTrack: (_) => null,
          recordInterests:
              ({required batchId, required contributions}) async {},
        );
        addTearDown(controller.dispose);
        addTearDown(fixture.dispose);
        final interaction = UiInteractionCoordinator.instance;
        final motion = Object();
        addTearDown(() => interaction.cancelNavigation(motion));
        interaction.beginNavigation(motion);
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyPage(tabIndex: 3),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              listeningActivityServiceProvider.overrideWithValue(activity),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(usageReads, 0);
        expect(find.byKey(const ValueKey('my-page-skeleton')), findsOneWidget);
        interaction.cancelNavigation(motion);
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        expect(usageReads, 1);
        final chart = tester.widget<ListeningTimeChart>(
          find.byType(ListeningTimeChart),
        );
        expect(chart.days, isEmpty);
        controller.interestReads = 0;
        interaction.beginNavigation(motion);
        for (var i = 0; i < 20; i++) {
          controller.notifyListeners();
        }
        repository.days = [
          ListeningDay(
            date: DateTime.now(),
            duration: const Duration(minutes: 3),
          ),
        ];
        await activity.refresh();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.interestReads, 0);
        expect(
          tester.widget<ListeningTimeChart>(find.byType(ListeningTimeChart)),
          same(chart),
        );
        interaction.cancelNavigation(motion);
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        expect(controller.interestReads, 1);
        expect(
          tester
              .widget<ListeningTimeChart>(find.byType(ListeningTimeChart))
              .days
              .single
              .duration,
          const Duration(minutes: 3),
        );
        final readsBeforeStyleChange = usageReads;
        await tester.tap(find.byKey(const ValueKey('listening-style-heatmap')));
        await pumpAndSettleWithAsync(tester);
        expect(
          fixture.settings.listeningChartStyle,
          ListeningChartStyle.heatmap,
        );
        expect(
          find.byKey(const ValueKey('listening-chart-heatmap')),
          findsOneWidget,
        );
        expect(usageReads, readsBeforeStyleChange);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final disposing = activity.dispose();
        await tester.pump();
        await disposing;
      },
    );

    for (final style in ListeningChartStyle.values) {
      for (final reducedMotion in [false, true]) {
        testWidgets(
          'My skeleton matches sections and resolves on $platform, reduced motion $reducedMotion, style $style',
          (tester) async {
            final fixture = AppRuntimeWidgetTestFixture(
              configureSettingsRepository: (settings) {
                settings.listeningChartStyle = style;
                settings.syncSlice();
              },
            );
            final activity = StreamController<ListeningActivityView>();
            addTearDown(fixture.dispose);
            addTearDown(activity.close);
            tester.view.physicalSize = Size(
              platform == TargetPlatform.android ? 390 : 960,
              900,
            );
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            await tester.pumpWidget(
              fixture.build(
                Theme(
                  data: ThemeData(platform: platform),
                  child: Builder(
                    builder: (context) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        disableAnimations: reducedMotion,
                        textScaler: TextScaler.linear(reducedMotion ? 1.6 : 1),
                      ),
                      child: const MyPage(tabIndex: 3),
                    ),
                  ),
                ),
                overrides: [
                  listeningActivityProvider.overrideWith(
                    (ref) => activity.stream,
                  ),
                ],
              ),
            );
            await tester.pump(const Duration(milliseconds: 400));
            final skeleton = find.byKey(const ValueKey('my-page-skeleton'));
            expect(skeleton, findsOneWidget);
            expect(
              find.byKey(ValueKey('listening-chart-${style.name}')),
              findsOneWidget,
            );
            expect(find.byType(TopPageHeader), findsOneWidget);
            expect(find.byType(CircularProgressIndicator), findsNothing);
            expect(
              find.text(fixture.languageProvider.tr('my_no_history')),
              findsNothing,
            );
            final history = find.byKey(const ValueKey('my-skeleton-history'));
            expect(tester.getSize(history).height, 113);
            final covers = find.descendant(
              of: history,
              matching: find.byType(ShimmerContainer),
            );
            expect(tester.getSize(covers.first), const Size(132, 99));
            final timeHeader = find.byKey(
              ValueKey(
                'my-section-header-${fixture.languageProvider.tr('my_listening_time')}',
              ),
            );
            final timeHeaderBounds = tester.getRect(timeHeader);
            final skeletonTimeBounds = tester.getRect(
              find.ancestor(of: timeHeader, matching: find.byType(Card)),
            );
            final verticalScroll = find.descendant(
              of: skeleton,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Scrollable && widget.axis == Axis.vertical,
              ),
            );
            final skeletonPosition = tester
                .state<ScrollableState>(verticalScroll)
                .position;
            expect(skeletonPosition.physics.allowUserScrolling, isFalse);
            await tester.dragFrom(
              tester.getCenter(skeleton),
              const Offset(0, -250),
            );
            await tester.pump(const Duration(milliseconds: 300));
            expect(skeletonPosition.pixels, 0);
            activity.add(
              ListeningActivityView(
                days: [
                  ListeningDay(
                    date: DateTime.now(),
                    duration: const Duration(minutes: 5, seconds: 38),
                  ),
                ],
              ),
            );
            if (!reducedMotion) {
              final content = find.byKey(const ValueKey('deferred_content'));
              for (
                var frame = 0;
                frame < 10 && content.evaluate().isEmpty;
                frame++
              ) {
                await tester.pump();
              }
              expect(content, findsOneWidget);
              await tester.pump();
              final skeletonFade = find
                  .ancestor(of: skeleton, matching: find.byType(FadeTransition))
                  .first;
              final contentFade = find
                  .ancestor(of: content, matching: find.byType(FadeTransition))
                  .first;
              expect(
                tester.widget<FadeTransition>(skeletonFade).opacity.value,
                1,
              );
              expect(
                tester.widget<FadeTransition>(contentFade).opacity.value,
                0,
              );
              await tester.pump(const Duration(milliseconds: 150));
              expect(
                tester.widget<FadeTransition>(skeletonFade).opacity.value,
                closeTo(1 - kAppFadeCurve.transform(0.5), 0.001),
              );
              expect(
                tester.widget<FadeTransition>(contentFade).opacity.value,
                closeTo(kAppFadeCurve.transform(0.5), 0.001),
              );
              await tester.pump(const Duration(milliseconds: 149));
              expect(skeleton, findsOneWidget);
              expect(
                tester.widget<FadeTransition>(skeletonFade).opacity.value,
                greaterThan(0),
              );
              await tester.pump(const Duration(milliseconds: 1));
              expect(
                tester.widget<FadeTransition>(skeletonFade).opacity.value,
                closeTo(0, 0.000001),
              );
              // Give the ticker's floating-point endpoint its final microsecond.
              await tester.pump(const Duration(microseconds: 1));
              expect(skeleton, findsNothing);
            }
            await pumpAndSettleWithAsync(tester);
            expect(skeleton, findsNothing);
            expect(find.byType(ListeningTimeChart), findsOneWidget);
            expect(
              tester
                  .widget<ListeningTimeChart>(find.byType(ListeningTimeChart))
                  .style,
              style,
            );
            expect(
              find.text(fixture.languageProvider.tr('my_no_history')),
              findsOneWidget,
            );
            expect(
              tester.getRect(timeHeader).topLeft,
              timeHeaderBounds.topLeft,
            );
            expect(tester.getRect(timeHeader).width, timeHeaderBounds.width);
            expect(
              tester.getRect(
                find.ancestor(of: timeHeader, matching: find.byType(Card)),
              ),
              skeletonTimeBounds,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          },
        );
      }
    }

    testWidgets(
      'My initial load error leaves the skeleton and can recover on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final activity = StreamController<ListeningActivityView>();
        addTearDown(fixture.dispose);
        addTearDown(activity.close);
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyPage(tabIndex: 3),
            ),
            overrides: [
              listeningActivityProvider.overrideWith((ref) => activity.stream),
            ],
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        activity.addError(StateError('initial read failed'));
        await pumpAndSettleWithAsync(tester);
        expect(find.byKey(const ValueKey('my-page-skeleton')), findsNothing);
        expect(
          find.text(fixture.languageProvider.tr('my_retry')),
          findsWidgets,
        );
        activity.add(const ListeningActivityView());
        await pumpAndSettleWithAsync(tester);
        expect(find.byType(ListeningTimeChart), findsOneWidget);
        expect(
          find.text(fixture.languageProvider.tr('my_retry')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'My shows only the twenty most listened interests on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _InterestController(createTestAsmrServices());
        for (var index = 0; index < 25; index++) {
          final key = controller.state.resolve('Tag $index');
          controller.state.setInterested(key, true);
          controller.state.learned[key] = index.toDouble();
        }
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        tester.view.physicalSize = const Size(960, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyPage(tabIndex: 3),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              listeningActivityProvider.overrideWith(
                (ref) => Stream.value(const ListeningActivityView()),
              ),
            ],
          ),
        );
        await pumpAndSettleWithAsync(tester);
        await tester.ensureVisible(
          find.text(fixture.languageProvider.tr('my_interests')),
        );
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        final chips = tester
            .widgetList<InputChip>(find.byType(InputChip))
            .toList();
        expect(chips, hasLength(20));
        expect((chips.first.label as Text).data, 'Tag 24');
        expect((chips.last.label as Text).data, 'Tag 5');
        expect(chips.every((chip) => chip.onDeleted == null), isTrue);
        final chip = find.byKey(const ValueKey('my-interest-local:tag 24'));
        expect(chips.first.backgroundColor, isNull);
        expect(chips.first.labelStyle, isNull);
        expect(
          chips.first.padding,
          const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        );
        expect(
          chips.first.labelPadding,
          const EdgeInsets.symmetric(horizontal: 4),
        );
        expect(
          chips.first.materialTapTargetSize,
          MaterialTapTargetSize.shrinkWrap,
        );
        expect(
          chips.first.side,
          BorderSide(
            color: Theme.of(tester.element(chip)).colorScheme.outlineVariant,
          ),
        );
        final wrap = tester.widget<Wrap>(
          find.ancestor(of: chip, matching: find.byType(Wrap)).first,
        );
        expect(wrap.spacing, 8);
        expect(wrap.runSpacing, 8);
        String? copied;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await tester.tap(chip);
        await tester.pump();
        expect(copied, 'Tag 24');
        expect(
          find.text(
            fixture.languageProvider.tr('copied_to_clipboard', {
              'value': 'Tag 24',
            }),
          ),
          findsOneWidget,
        );
        final header = find.byKey(
          ValueKey(
            'my-section-header-${fixture.languageProvider.tr('my_interests')}',
          ),
        );
        expect(
          find.descendant(of: header, matching: find.byType(TextButton)),
          findsNWidgets(3),
        );
        expect(controller.interestTags, hasLength(20));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
    testWidgets(
      'interest tabs share one card, show twenty voices and copy on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _InterestController(createTestAsmrServices());
        for (var index = 0; index < 25; index++) {
          final key = controller.voices.resolve('Voice $index');
          controller.voices.learned[key] = index.toDouble();
          controller.circles.learned[controller.circles.resolve(
            'Circle $index',
          )] = index
              .toDouble();
        }
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        tester.view.physicalSize = const Size(960, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyPage(tabIndex: 3),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
              listeningActivityProvider.overrideWith(
                (ref) => Stream.value(const ListeningActivityView()),
              ),
            ],
          ),
        );
        await pumpAndSettleWithAsync(tester);
        await tester.ensureVisible(
          find.text(fixture.languageProvider.tr('my_voice_interests')),
        );
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        expect(
          find.byKey(const ValueKey('my-interest-local:sleep')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_add_interest')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_add_voice_interest')),
          findsNothing,
        );
        final tagsTab = find.byKey(const ValueKey('my-interest-tab-tags'));
        final voicesTab = find.byKey(const ValueKey('my-interest-tab-voices'));
        expect(
          tester.element(
            find.ancestor(of: tagsTab, matching: find.byType(Card)).first,
          ),
          same(
            tester.element(
              find.ancestor(of: voicesTab, matching: find.byType(Card)).first,
            ),
          ),
        );
        await tester.tap(voicesTab);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('my-voice-interest-local:voice 24')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_no_voice_interests')),
          findsNothing,
        );
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        final chips = find.byWidgetPredicate(
          (widget) =>
              widget is InputChip &&
              (widget.key as ValueKey?)?.value.toString().startsWith(
                    'my-voice-interest-',
                  ) ==
                  true,
        );
        expect(chips, findsNWidgets(20));
        final first = find.byKey(
          const ValueKey('my-voice-interest-local:voice 24'),
        );
        expect(
          find.byKey(const ValueKey('my-voice-interest-local:voice 4')),
          findsNothing,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_add_interest')),
          findsNothing,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_excluded_tags')),
          findsNothing,
        );
        final addVoice = find.text(
          fixture.languageProvider.tr('my_add_voice_interest'),
        );
        await tester.ensureVisible(addVoice);
        await tester.tap(addVoice);
        await pumpAndSettleWithAsync(tester);
        expect(
          tester
              .widget<MyTagManagementPage>(find.byType(MyTagManagementPage))
              .type,
          MyInterestType.voiceActors,
        );
        await tester.pageBack();
        await pumpAndSettleWithAsync(tester);
        expect(chips, findsNWidgets(20));
        final chip = tester.widget<InputChip>(first);
        expect(chip.backgroundColor, isNull);
        expect(chip.labelStyle, isNull);
        expect(
          chip.padding,
          const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        );
        expect(chip.labelPadding, const EdgeInsets.symmetric(horizontal: 4));
        expect(chip.materialTapTargetSize, MaterialTapTargetSize.shrinkWrap);
        final wrap = tester.widget<Wrap>(
          find.ancestor(of: first, matching: find.byType(Wrap)).first,
        );
        expect(wrap.spacing, 8);
        expect(wrap.runSpacing, 8);
        String? copied;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                copied = (call.arguments as Map)['text'] as String;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        await tester.ensureVisible(first);
        await tester.tap(first);
        await tester.pump();
        expect(copied, 'Voice 24');
        expect(find.textContaining('（前'), findsNothing);
        await tester.ensureVisible(tagsTab);
        await tester.tap(tagsTab);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('my-interest-local:sleep')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_no_interests')),
          findsNothing,
        );
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        expect(chips, findsNothing);
        expect(
          find.byKey(const ValueKey('my-interest-local:sleep')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_excluded_tags')),
          findsOneWidget,
        );
        final circlesTab = find.byKey(
          const ValueKey('my-interest-tab-circles'),
        );
        await tester.tap(circlesTab);
        await tester.pump();
        expect(
          find.byKey(const ValueKey('my-circle-interest-local:circle 24')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_no_circle_interests')),
          findsNothing,
        );
        await pumpUntilUiIdle(tester);
        await pumpAndSettleWithAsync(tester);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is InputChip &&
                (widget.key as ValueKey?)?.value.toString().startsWith(
                      'my-circle-interest-',
                    ) ==
                    true,
          ),
          findsNWidgets(20),
        );
        expect(
          find.byKey(const ValueKey('my-circle-interest-local:circle 24')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('my-circle-interest-local:circle 4')),
          findsNothing,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_add_circle_interest')),
          findsOneWidget,
        );
        expect(
          find.text(fixture.languageProvider.tr('my_excluded_circles')),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
    for (final type in [MyInterestType.voiceActors, MyInterestType.circles]) {
      testWidgets(
        '$type catalog keeps automatic names and saves only on confirmation on $platform',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
          final controller = _InterestController(createTestAsmrServices());
          final preferences = type == MyInterestType.voiceActors
              ? controller.voices
              : controller.circles;
          final automatic = preferences.resolve('Frequent Voice');
          preferences.learned[automatic] = 60;
          for (var index = 0; index < 25; index++) {
            preferences.resolve('Other Voice $index');
          }
          addTearDown(fixture.dispose);
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            fixture.build(
              Theme(
                data: ThemeData(platform: platform),
                child: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            MyTagManagementPage(excluded: false, type: type),
                      ),
                    ),
                    child: const Text('Open voices'),
                  ),
                ),
              ),
              overrides: [
                asmrLibraryControllerProvider.overrideWithValue(controller),
              ],
            ),
          );
          await tester.tap(find.text('Open voices'));
          await tester.pumpAndSettle();
          final locked = tester.widget<CheckboxListTile>(
            find.byKey(ValueKey(automatic)),
          );
          expect(locked.value, isTrue);
          expect(locked.onChanged, isNull);
          expect(
            find.text(fixture.languageProvider.tr(type.listenedKey)),
            findsOneWidget,
          );
          await tester.enterText(find.byType(TextField), 'Other Voice 24');
          await tester.pump();
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
          expect(controller.voiceSaves + controller.circleSaves, 0);
          expect(controller.manualInterestVoiceActorKeys, isEmpty);
          await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
          await tester.pumpAndSettle();
          expect(controller.voiceSaves + controller.circleSaves, 1);
          expect(preferences.manualInterests, {'local:other voice 24'});
          expect(find.byType(MyTagManagementPage), findsNothing);
          expect(controller.state.manualInterests, {'local:sleep'});
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        },
      );

      testWidgets(
        '$type unwanted selections confirm, retry and discard on $platform',
        (tester) async {
          final fixture = AppRuntimeWidgetTestFixture();
          final controller = _InterestController(createTestAsmrServices());
          final preferences = type == MyInterestType.voiceActors
              ? controller.voices
              : controller.circles;
          final key = preferences.resolve('Automatic creator');
          preferences.learned[key] = 60;
          addTearDown(fixture.dispose);
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            fixture.build(
              Theme(
                data: ThemeData(platform: platform),
                child: const MyPage(tabIndex: 3),
              ),
              overrides: [
                asmrLibraryControllerProvider.overrideWithValue(controller),
                listeningActivityProvider.overrideWith(
                  (ref) => Stream.value(const ListeningActivityView()),
                ),
              ],
            ),
          );
          await pumpAndSettleWithAsync(tester);
          await pumpUntilUiIdle(tester);
          await pumpAndSettleWithAsync(tester);
          final tab = find.byKey(
            ValueKey(
              'my-interest-tab-${type == MyInterestType.voiceActors ? 'voices' : 'circles'}',
            ),
          );
          await tester.ensureVisible(tab);
          await tester.pumpAndSettle();
          await tester.tap(tab);
          await pumpUntilUiIdle(tester);
          await pumpAndSettleWithAsync(tester);
          Future<void> openExcluded() async {
            final button = find.text(
              fixture.languageProvider.tr(type.excludedKey),
            );
            await tester.ensureVisible(button);
            await tester.pumpAndSettle();
            await tester.tap(button);
            await pumpAndSettleWithAsync(tester);
            final page = tester.widget<MyTagManagementPage>(
              find.byType(MyTagManagementPage),
            );
            expect(page.type, type);
            expect(page.excluded, isTrue);
            await tester.enterText(find.byType(TextField), 'Automatic');
            await tester.pumpAndSettle();
          }

          await openExcluded();
          expect(
            tester
                .widget<CheckboxListTile>(find.byType(CheckboxListTile))
                .onChanged,
            isNotNull,
          );
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pump();
          expect(preferences.excluded, isEmpty);
          controller.failCreatorSave = true;
          await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
          await tester.pumpAndSettle();
          expect(find.byType(MyTagManagementPage), findsOneWidget);
          expect(
            tester
                .widget<CheckboxListTile>(find.byType(CheckboxListTile))
                .value,
            isTrue,
          );
          expect(preferences.excluded, isEmpty);
          controller.failCreatorSave = false;
          await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
          await pumpAndSettleWithAsync(tester);
          expect(preferences.excluded, {key});
          await openExcluded();
          expect(
            tester
                .widget<CheckboxListTile>(find.byType(CheckboxListTile))
                .value,
            isTrue,
          );
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pageBack();
          await pumpAndSettleWithAsync(tester);
          expect(preferences.excluded, {key});
          await openExcluded();
          await tester.tap(find.byType(CheckboxListTile));
          await tester.tap(find.byKey(const ValueKey('my_tags_confirm')));
          await pumpAndSettleWithAsync(tester);
          expect(preferences.excluded, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      'tag catalog uses floating header and retains search on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _InterestController(createTestAsmrServices())
          ..state.learned.clear();
        addTearDown(fixture.dispose);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyTagManagementPage(excluded: false),
            ),
            overrides: [
              asmrLibraryControllerProvider.overrideWithValue(controller),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppPageAppBar), findsNothing);
        final header = tester.widget<TopPageHeader>(find.byType(TopPageHeader));
        expect(header.floating, isTrue);
        expect(header.leading, isA<BackButton>());
        expect(
          find.descendant(
            of: find.byType(TopPageHeader),
            matching: find.byType(TextField),
          ),
          findsOneWidget,
        );
        await tester.enterText(find.byType(TextField), 'not a known tag');
        await tester.pump();
        expect(find.byType(CheckboxListTile), findsNothing);
        await tester.enterText(find.byType(TextField), 'sleep');
        await tester.pump();
        expect(find.byType(CheckboxListTile), findsOneWidget);
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isFalse,
        );
        expect(controller.state.manualInterests, {'local:sleep'});
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pumpAndSettle();
        expect(
          tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
          isTrue,
        );
        expect(controller.removals, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'history uses metadata titles over the cover and rounds the scrolling viewport on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        addTearDown(fixture.dispose);
        tester.view.physicalSize = Size(
          platform == TargetPlatform.android ? 390 : 960,
          900,
        );
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final track = MusicTrack(
          path: '/unavailable/track.mp3',
          displayName: 'Track',
          groupKey: 'work',
          groupTitle: 'Folder name instead of the work title',
          groupSubtitle: '',
          isSingle: false,
        );
        const workTitle =
            'Actual metadata work title that wraps to two lines inside the cover';
        final target = fixture.library.audioDetailTargetForTrack(track);
        fixture.library.detailCacheService.markChanged(
          AudioDetail.empty(target).copyWith(workTitle: workTitle),
        );
        final remote = MusicTrack(
          path: 'https://example.com/track.mp3',
          displayName: 'Remote track',
          groupKey: 'remote',
          groupTitle: 'Wrong legacy folder label',
          groupSubtitle: '',
          isSingle: false,
          remoteMetadataKind: MusicTrack.remoteMetadataKindAsmrOne,
          remoteMetadata: const {'title': 'Remote metadata work title'},
        );
        await tester.pumpWidget(
          fixture.build(
            Theme(
              data: ThemeData(platform: platform),
              child: const MyPage(tabIndex: 3),
            ),
            overrides: [
              listeningActivityProvider.overrideWith(
                (ref) => Stream.value(
                  ListeningActivityView(
                    history: [
                      ListeningHistoryEntry(workKey: 'work', track: track),
                      for (var i = 0; i < 8; i++)
                        ListeningHistoryEntry(
                          workKey: 'remote-$i',
                          track: remote,
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
        await pumpAndSettleWithAsync(tester);
        final title = find.byKey(const ValueKey('my-history-title-work'));
        await tester.ensureVisible(title);
        final text = tester.widget<Text>(title);
        expect(text.data, workTitle);
        expect(find.text(track.groupTitle), findsNothing);
        expect(text.maxLines, 2);
        expect(text.style?.fontSize, 12);
        expect(text.overflow, TextOverflow.ellipsis);
        expect(text.style?.color, Colors.white);
        expect(text.style?.backgroundColor, isNull);
        expect(text.style?.shadows?.single.blurRadius, 4);
        final card = find.byKey(const ValueKey('my-history-card-work'));
        expect(tester.getSize(card), const Size(132, 99));
        expect(tester.widget<CoverArtworkFrame>(card).showShadow, isTrue);
        final nextCard = find.byKey(const ValueKey('my-history-card-remote-0'));
        expect(tester.getTopLeft(nextCard).dx - tester.getTopRight(card).dx, 12);
        final cardClip = find.ancestor(
          of: card,
          matching: find.byWidgetPredicate(
            (widget) => widget is ClipRect && widget.child is Padding,
          ),
        );
        expect(tester.getSize(cardClip), const Size(144, 113));
        expect(
          tester.getSize(
            find.byKey(const ValueKey('my-history-card-remote-0')),
          ),
          const Size(132, 99),
        );
        expect(
          tester.getBottomLeft(card).dy - tester.getBottomLeft(title).dy,
          closeTo(8, .1),
        );
        expect(
          tester.getBottomLeft(title).dy,
          lessThan(tester.getBottomLeft(card).dy),
        );
        expect(find.text('Remote metadata work title'), findsWidgets);
        final viewport = find.byKey(const ValueKey('my-history-viewport'));
        expect(
          tester.widget<ClipRRect>(viewport).borderRadius,
          BorderRadius.circular(12),
        );
        expect(tester.getSize(viewport).height, 113);
        expect(tester.getTopLeft(card).dy - tester.getTopLeft(viewport).dy, 6);
        expect(
          tester.getBottomLeft(viewport).dy - tester.getBottomLeft(card).dy,
          8,
        );
        expect(tester.getTopLeft(card).dx - tester.getTopLeft(viewport).dx, 8);
        await pumpUntilUiIdle(tester);
        fixture.library.detailCacheService.markChanged(
          AudioDetail.empty(
            target,
          ).copyWith(workTitle: 'Edited actual work title'),
        );
        await pumpAndSettleWithAsync(tester);
        expect(tester.widget<Text>(title).data, 'Edited actual work title');
        await fixture.settings.setWorkNameDisplay(WorkNameDisplay.folderName);
        await pumpAndSettleWithAsync(tester);
        expect(
          tester.widget<Text>(title).data,
          PathDisplay.folderName(target.targetPath),
        );
        expect(find.text('Remote metadata work title'), findsWidgets);
        await fixture.settings.setWorkNameDisplay(WorkNameDisplay.workTitle);
        await pumpAndSettleWithAsync(tester);
        expect(tester.widget<Text>(title).data, 'Edited actual work title');
        fixture.library.detailCacheService.markChanged(
          AudioDetail.empty(target),
        );
        await pumpAndSettleWithAsync(tester);
        expect(
          tester.widget<Text>(title).data,
          PathDisplay.folderName(target.targetPath),
        );
        await tester.drag(viewport, const Offset(-100, 0));
        await tester.pumpAndSettle();
        final scrolling = find
            .descendant(of: viewport, matching: find.byType(Scrollable))
            .first;
        expect(
          tester.state<ScrollableState>(scrolling).position.pixels,
          greaterThan(0),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('My page empty state and interval interaction on $platform', (
      tester,
    ) async {
      final fixture = AppRuntimeWidgetTestFixture();
      addTearDown(fixture.dispose);
      tester.view.physicalSize = const Size(960, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        fixture.build(
          Theme(
            data: ThemeData(platform: platform),
            child: const MyPage(tabIndex: 3),
          ),
          overrides: [
            listeningActivityProvider.overrideWith(
              (ref) => Stream.value(const ListeningActivityView()),
            ),
          ],
        ),
      );
      await pumpAndSettleWithAsync(tester);
      final i18n = fixture.languageProvider;
      expect(find.text(i18n.tr('my_listening_time')), findsOneWidget);
      expect(find.text(i18n.tr('my_no_history')), findsOneWidget);
      final headerHeights = <double>[];
      for (final label in ['my_listening_time', 'my_history', 'my_interests']) {
        final header = find.byKey(
          ValueKey('my-section-header-${i18n.tr(label)}'),
        );
        await tester.ensureVisible(header);
        final bounds = tester.getRect(header);
        final card = find
            .ancestor(of: header, matching: find.byType(Card))
            .first;
        expect(bounds.top - tester.getRect(card).top, closeTo(12, .1));
        headerHeights.add(bounds.height);
      }
      expect(headerHeights.toSet().length, 1);
      expect(find.textContaining('（前'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('my-interest-tab-voices')));
      await pumpUntilUiIdle(tester);
      await pumpAndSettleWithAsync(tester);
      expect(find.text(i18n.tr('my_no_voice_interests')), findsOneWidget);
      final heading = find.text(i18n.tr('my_listening_time'));
      await tester.ensureVisible(heading);
      final headingBounds = tester.getRect(heading);
      final durationBounds = tester.getRect(
        find.byKey(const ValueKey('listening-duration')),
      );
      expect(headingBounds.center.dy, closeTo(durationBounds.center.dy, .1));
      expect(headingBounds.right, lessThan(durationBounds.left));
      expect(
        durationBounds.right,
        closeTo(
          tester
              .getRect(
                find.byKey(
                  ValueKey('my-section-header-${i18n.tr('my_listening_time')}'),
                ),
              )
              .right,
          .1,
        ),
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('listening-chart-intervals')))
            .dy,
        greaterThanOrEqualTo(
          tester
              .getBottomLeft(find.byKey(const ValueKey('listening-chart-bars')))
              .dy,
        ),
      );
      await tester.ensureVisible(find.text(i18n.tr('my_interval_quarter')));
      await tester.tap(find.text(i18n.tr('my_interval_quarter')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: find.text(i18n.tr('my_interval_quarter')),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

class _CountingListeningDays extends ListBase<ListeningDay> {
  _CountingListeningDays(this.values);
  final List<ListeningDay> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  ListeningDay operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, ListeningDay value) =>
      throw UnsupportedError('immutable');
}

class _InterestController extends AsmrLibraryController {
  _InterestController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      ) {
    final sleep = state.resolve('Sleep');
    state.setInterested(sleep, true);
    state.learned[sleep] = 1;
  }
  final voices = AsmrTagPreferences();
  final circles = AsmrTagPreferences();
  int circleSaves = 0;
  bool failCreatorSave = false;
  int voiceSaves = 0;
  int voiceInterestReads = 0;
  @override
  List<AsmrTagInterest> get voiceActorInterests {
    voiceInterestReads++;
    return voices.interests;
  }

  @override
  List<AsmrTagInterest> get listenedVoiceActorInterests =>
      voices.listenedInterests;
  @override
  Set<String> get manualInterestVoiceActorKeys => voices.manualInterests;
  @override
  Set<String> get excludedVoiceActorKeys => voices.excluded;
  @override
  List<AsmrTagInterest> get circleInterests => circles.interests;
  @override
  List<AsmrTagInterest> get listenedCircleInterests =>
      circles.listenedInterests;
  @override
  Set<String> get manualInterestCircleKeys => circles.manualInterests;
  @override
  Set<String> get excludedCircleKeys => circles.excluded;
  @override
  List<AsmrTag> get allCircles => circles.tags.values.toList();
  @override
  bool get circleCatalogComplete => true;
  @override
  Future<void> ensureCircleCatalog({bool force = false}) async {}
  @override
  Future<void> applyCircleSelections({
    bool excluded = false,
    required Map<String, bool> changes,
  }) async {
    if (failCreatorSave) throw StateError('save failed');
    circleSaves++;
    for (final change in changes.entries) {
      if (excluded) {
        change.value
            ? circles.excluded.add(change.key)
            : circles.excluded.remove(change.key);
      } else {
        circles.setInterested(change.key, change.value);
      }
    }
    notifyListeners();
  }

  @override
  List<AsmrTag> get allVoiceActors => voices.tags.values.toList();
  @override
  bool get voiceActorCatalogComplete => true;
  @override
  Future<void> ensureVoiceActorCatalog({bool force = false}) async {}
  @override
  Future<void> applyVoiceActorSelections({
    bool excluded = false,
    required Map<String, bool> changes,
  }) async {
    if (failCreatorSave) throw StateError('save failed');
    voiceSaves++;
    for (final change in changes.entries) {
      if (excluded) {
        change.value
            ? voices.excluded.add(change.key)
            : voices.excluded.remove(change.key);
      } else {
        voices.setInterested(change.key, change.value);
      }
    }
    notifyListeners();
  }

  final state = AsmrTagPreferences();
  @override
  Future<void> ensureTagInterests({List<MusicTrack>? localTracks}) async {}
  int removals = 0;
  int interestReads = 0;
  @override
  List<AsmrTagInterest> get interestTags {
    interestReads++;
    return state.interests;
  }

  @override
  List<AsmrTag> get allTags => state.tags.values.toList();
  @override
  List<AsmrTagInterest> get listenedTagInterests => state.listenedInterests;
  @override
  Set<String> get manualInterestTagKeys => state.manualInterests;
  @override
  bool get tagCatalogComplete => true;
  @override
  Future<void> ensureTagCatalog({bool force = false}) async {}
  @override
  Future<void> setTagInterested(String key, bool interested) async {
    if (!interested) removals++;
    state.setInterested(key, interested);
    notifyListeners();
  }
}

class _PendingInterestController extends _InterestController {
  _PendingInterestController(super.services);
  final ready = Completer<void>();

  @override
  Future<void> ensureTagInterests({List<MusicTrack>? localTracks}) =>
      ready.future;
}

class _ListeningRepository implements ListeningActivityRepository {
  List<ListeningDay> days = const [];
  @override
  Future<List<ListeningDay>> loadDays() async => days;
  @override
  Future<List<ListeningHistoryEntry>> loadHistory({
    int offset = 0,
    int limit = 40,
  }) async => const [];
  @override
  Future<MusicTrack?> findTrack(String workKey) async => null;
  @override
  Future<bool> importBatch(
    String batchId,
    List<ListeningDayContribution> days,
  ) async => false;
  @override
  Future<void> seedHistory(List<ListeningHistoryEntry> entries) async {}
}
