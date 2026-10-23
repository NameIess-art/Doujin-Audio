import 'dart:async';

import 'package:doujin_audio/app/presentation/listening_time_chart.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/presentation/my_page.dart';
import 'package:doujin_audio/app/presentation/my_tag_management_page.dart';
import 'package:doujin_audio/app/state/listening_activity_provider.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/media/audio_detail.dart';
import 'package:doujin_audio/core/media/path_display.dart';
import 'package:doujin_audio/core/ui/ui_interaction_coordinator.dart';
import 'package:doujin_audio/features/player/application/listening_activity_service.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/widgets/app_transitions.dart';
import 'package:doujin_audio/core/widgets/top_page_header.dart';
import 'package:doujin_audio/core/widgets/shimmer_loading.dart';
import 'package:doujin_audio/features/asmr/application/asmr_library_controller.dart';
import 'package:doujin_audio/features/asmr/presentation/asmr_providers.dart';
import 'package:flutter/material.dart';
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
        final chips = tester
            .widgetList<InputChip>(find.byType(InputChip))
            .toList();
        expect(chips, hasLength(20));
        expect((chips.first.label as Text).data, 'Tag 24');
        expect((chips.last.label as Text).data, 'Tag 5');
        expect(chips.every((chip) => chip.onDeleted == null), isTrue);
        final header = find.byKey(
          ValueKey(
            'my-section-header-${fixture.languageProvider.tr('my_interests')}',
          ),
        );
        expect(
          find.descendant(of: header, matching: find.byType(TextButton)),
          findsNothing,
        );
        expect(controller.interestTags, hasLength(26));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
    testWidgets(
      'tag catalog uses floating header and retains search on $platform',
      (tester) async {
        final fixture = AppRuntimeWidgetTestFixture();
        final controller = _InterestController(createTestAsmrServices());
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
        expect(controller.state.weights['local:sleep'], 200);
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
        expect(tester.getSize(viewport).height, 99);
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
      final interestLimit = find.text(i18n.tr('my_interest_limit'));
      expect(interestLimit, findsOneWidget);
      expect(
        tester.widget<Text>(interestLimit).style?.color?.a,
        closeTo(0.7, 0.01),
      );
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

class _InterestController extends AsmrLibraryController {
  _InterestController(TestAsmrServices services)
    : super(
        preferencesStore: services.preferencesStore,
        remoteCatalogService: services.remoteCatalogService,
        accountSyncService: services.accountSyncService,
      ) {
    state.weights[state.resolve('Sleep')] = 200;
  }
  final state = AsmrTagPreferences();
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
