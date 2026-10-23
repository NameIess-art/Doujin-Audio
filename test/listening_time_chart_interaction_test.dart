import 'dart:collection';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/listening_time_chart.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/core/widgets/drag_only_scrollbar.dart';
import 'package:doujin_audio/features/player/domain/listening_activity.dart';
import 'package:doujin_audio/features/settings/application/settings_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppLanguageProvider i18n;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final earlier = DateTime(today.year, today.month, today.day - 120);

  setUp(() async {
    SharedPreferences.setMockInitialValues({'app_language': 'en'});
    await AppPreferences.init();
    i18n = AppLanguageProvider();
    await i18n.initialized;
  });
  tearDown(() => i18n.dispose());

  Future<void> pumpChart(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.android,
    bool reducedMotion = false,
    double textScale = 1,
    List<ListeningDay> days = const [],
    ListeningChartStyle style = ListeningChartStyle.bar,
    Brightness brightness = Brightness.light,
    double width = 320,
  }) async {
    var selectedStyle = style;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform, brightness: brightness),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: MediaQuery(
                data: MediaQueryData(
                  disableAnimations: reducedMotion,
                  textScaler: TextScaler.linear(textScale),
                ),
                child: StatefulBuilder(
                  builder: (context, update) => ListeningTimeChart(
                    days: days,
                    i18n: i18n,
                    style: selectedStyle,
                    onStyleChanged: (value) =>
                        update(() => selectedStyle = value),
                    builder: (duration, chart) => Column(
                      children: [
                        Row(
                          children: [
                            Expanded(child: Text(i18n.tr('my_listening_time'))),
                            Flexible(child: duration),
                          ],
                        ),
                        chart,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final selector = find.byKey(const ValueKey('listening-date-selector'));
  for (final textScale in [1.0, 1.6]) {
    testWidgets('compact chart summary and spacing at text scale $textScale', (
      tester,
    ) async {
      await pumpChart(tester, textScale: textScale);
      final dateHeight = tester.getSize(selector).height;
      expect(dateHeight, greaterThanOrEqualTo(28));
      expect(dateHeight, lessThan(36));
      final durationBounds = tester.getRect(
        find.byKey(const ValueKey('listening-duration')),
      );
      expect(
        tester.getRect(selector).top,
        greaterThanOrEqualTo(durationBounds.bottom),
      );
      final bars = tester.getRect(
        find.byKey(const ValueKey('listening-chart-bars')),
      );
      final intervals = tester.getRect(
        find.byKey(const ValueKey('listening-chart-intervals')),
      );
      expect(intervals.top - bars.bottom, closeTo(2, 0.1));
      final chips = find.byType(ChoiceChip);
      final chipCenters = [
        for (var i = 0; i < chips.evaluate().length; i++)
          tester.getCenter(chips.at(i)).dy,
      ];
      expect(chipCenters.toSet().length, 1);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('listening-chart-intervals')),
          )
          .controller!;
      if (textScale > 1) {
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        await tester.drag(
          find.byKey(const ValueKey('listening-chart-intervals')),
          const Offset(-250, 0),
        );
        await tester.pumpAndSettle();
        expect(scroll.offset, greaterThan(0));
      }
      expect(tester.takeException(), isNull);
    });
  }
  ScrollController controller(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!;

  Future<void> chooseDate(WidgetTester tester, DateTime date) async {
    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(find.byType(InputDatePickerFormField), findsOneWidget);
    final localizations = MaterialLocalizations.of(
      tester.element(find.byType(DatePickerDialog)),
    );
    await tester.enterText(
      find.byType(TextFormField),
      localizations.formatCompactDate(date),
    );
    await tester.tap(find.text(localizations.okButtonLabel));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);
  }

  final heatmapSwitch = find.byKey(const ValueKey('listening-style-heatmap'));
  final barSwitch = find.byKey(const ValueKey('listening-style-bar'));

  for (final width in [280.0, 720.0]) {
    testWidgets(
      'heatmap fills seven rows and anchors latest at bottom right at width $width',
      (tester) async {
        await pumpChart(
          tester,
          style: ListeningChartStyle.heatmap,
          width: width,
        );
        for (final interval in ListeningInterval.values) {
          await tester.ensureVisible(
            find.text(i18n.tr('my_interval_${interval.name}')),
          );
          await tester.tap(find.text(i18n.tr('my_interval_${interval.name}')));
          await tester.pumpAndSettle();
          final latest = aggregateListeningPeriods(
            const [],
            interval,
            now: today,
          ).last;
          final bounds = tester.getRect(
            find.byKey(const ValueKey('listening-chart-bars')),
          );
          final last = tester.getRect(find.byKey(ValueKey(latest.start)));
          expect(last.width, greaterThan(18));
          expect(last.width, closeTo(last.height, 0.001));
          expect(last.right, closeTo(bounds.right, 0.1));
          expect(last.bottom, closeTo(bounds.bottom, 0.1));
          final cells = find.descendant(
            of: find.byKey(const ValueKey('listening-chart-heatmap')),
            matching: find.byType(InkWell),
          );
          final rows =
              cells
                  .evaluate()
                  .map((e) => tester.getRect(find.byWidget(e.widget)).top)
                  .toSet()
                  .toList()
                ..sort();
          expect(rows, hasLength(7));
          expect(rows.first, closeTo(bounds.top, 0.1));
          final starts =
              cells
                  .evaluate()
                  .map((e) => tester.getRect(find.byWidget(e.widget)).left)
                  .toSet()
                  .toList()
                ..sort();
          expect(starts.first - bounds.left, lessThan(last.width));
          for (var i = 2; i < starts.length; i++) {
            expect(
              starts[i] - starts[i - 1],
              closeTo(starts[1] - starts[0], 0.1),
            );
          }
          expect(tester.takeException(), isNull);
        }
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'heatmap keeps chronological rows and pads older periods on $platform',
      (tester) async {
        final first = DateTime(today.year, today.month, today.day - 30);
        await pumpChart(
          tester,
          platform: platform,
          style: ListeningChartStyle.heatmap,
          days: [
            ListeningDay(date: first, duration: const Duration(minutes: 1)),
          ],
        );
        final firstCell = find.byKey(ValueKey(first));
        expect(tester.getSize(firstCell).width, greaterThan(18));
        final last = find.byKey(ValueKey(today));
        final origin = tester.getTopLeft(last);
        final size = tester.getSize(last).width;
        final extent = tester
            .widget<ListView>(find.byType(ListView))
            .itemExtent!;
        for (var i = 1; i <= 14; i++) {
          final date = DateTime(today.year, today.month, today.day - i);
          expect(
            tester.getTopLeft(find.byKey(ValueKey(date))),
            within<Offset>(
              from: origin + Offset(-extent * (i ~/ 7), -(size + 3) * (i % 7)),
              distance: 0.001,
            ),
          );
        }
        final column = find
            .ancestor(of: last, matching: find.byType(Column))
            .first;
        expect(
          find.descendant(of: column, matching: find.byType(InkWell)),
          findsNWidgets(7),
        );
        final older = DateTime(first.year, first.month, first.day - 1);
        await tester.tap(find.byKey(ValueKey(older)));
        await tester.pumpAndSettle();
        expect(
          find.text(listeningDurationText(i18n, Duration.zero)),
          findsOneWidget,
        );
        await chooseDate(tester, older);
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect(
          find.text(listeningDurationText(i18n, Duration.zero)),
          findsOneWidget,
        );
        final tooltip = tester.widget<Tooltip>(
          find.ancestor(of: last, matching: find.byType(Tooltip)).first,
        );
        expect(
          tooltip.message,
          contains(listeningDurationText(i18n, Duration.zero)),
        );
        expect(
          tester.getRect(heatmapSwitch).right,
          closeTo(
            tester
                .getRect(find.byKey(const ValueKey('listening-chart-bars')))
                .right,
            0.1,
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'heatmap date and interval selection survives style changes on $platform',
      (tester) async {
        final days = _CountingDays(
          List.generate(
            3650,
            (i) => ListeningDay(
              date: DateTime(today.year, today.month, today.day - i),
              duration: const Duration(minutes: 1),
            ),
          ),
        );
        await pumpChart(tester, platform: platform, days: days, textScale: 1.6);
        await chooseDate(tester, earlier);
        final height = tester
            .getSize(find.byKey(const ValueKey('listening-chart-bars')))
            .height;
        final date = tester
            .widget<Text>(
              find.descendant(of: selector, matching: find.byType(Text)),
            )
            .data;
        days.reads = 0;
        await tester.tap(heatmapSwitch);
        await tester.pumpAndSettle();
        expect(days.reads, 0);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('listening-chart-bars')))
              .height,
          height,
        );
        expect(
          tester
              .widget<Text>(
                find.descendant(of: selector, matching: find.byType(Text)),
              )
              .data,
          date,
        );
        expect(controller(tester).offset, greaterThan(0));
        expect(find.byKey(ValueKey(earlier)).hitTestable(), findsOneWidget);
        await tester.tap(barSwitch);
        await tester.pumpAndSettle();
        expect(days.reads, 0);
        expect(find.byKey(ValueKey(earlier)).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'heatmap resizing fills the viewport without rescanning history',
    (tester) async {
      final days = _CountingDays([
        ListeningDay(date: today, duration: const Duration(minutes: 2)),
      ]);
      await pumpChart(tester, style: ListeningChartStyle.heatmap, days: days);
      days.reads = 0;
      await pumpChart(
        tester,
        style: ListeningChartStyle.heatmap,
        days: days,
        width: 720,
        textScale: 1.6,
      );
      expect(days.reads, 0);
      final bounds = tester.getRect(
        find.byKey(const ValueKey('listening-chart-bars')),
      );
      final latest = tester.getRect(find.byKey(ValueKey(today)));
      expect(latest.bottomRight, bounds.bottomRight);
      expect(latest.width, closeTo((bounds.height - 3 * 6) / 7, 0.001));
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'heatmap uses stable zero and four theme color levels in $brightness',
      (tester) async {
        const values = [0, 1, 250, 251, 500, 501, 750, 751, 1000];
        const levels = [0, 1, 1, 2, 2, 3, 3, 4, 4];
        final days = List.generate(
          values.length,
          (i) => ListeningDay(
            date: DateTime(today.year, today.month, today.day - i),
            duration: Duration(milliseconds: values[i]),
          ),
        );
        await pumpChart(
          tester,
          style: ListeningChartStyle.heatmap,
          brightness: brightness,
          days: days,
        );
        final colors = Theme.of(tester.element(selector)).colorScheme;
        for (var i = 0; i < days.length; i++) {
          final cell = find.byKey(ValueKey(days[i].date));
          final decoration =
              tester
                      .widget<Container>(
                        find.descendant(
                          of: cell,
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration
                  as BoxDecoration;
          expect(
            decoration.color,
            Color.lerp(
              colors.surfaceContainerHighest,
              colors.primary,
              levels[i] / 4,
            ),
          );
          expect(decoration.borderRadius, BorderRadius.circular(3));
        }
        await tester.tap(find.byKey(ValueKey(days[3].date)));
        await tester.pumpAndSettle();
        expect(
          find.text(listeningDurationText(i18n, days[3].duration)),
          findsOneWidget,
        );
        final selected =
            tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byKey(ValueKey(days[3].date)),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        expect(selected.border, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('heatmap follows all five aggregated intervals', (tester) async {
    final days = [
      ListeningDay(date: today, duration: const Duration(minutes: 2)),
      ListeningDay(
        date: DateTime(today.year, today.month, today.day - 1),
        duration: const Duration(minutes: 3),
      ),
    ];
    await pumpChart(tester, days: days, style: ListeningChartStyle.heatmap);
    for (final interval in ListeningInterval.values) {
      await tester.ensureVisible(
        find.text(i18n.tr('my_interval_${interval.name}')),
      );
      await tester.tap(find.text(i18n.tr('my_interval_${interval.name}')));
      await tester.pumpAndSettle();
      final period = aggregateListeningPeriods(days, interval, now: today).last;
      final cell = find.byKey(ValueKey(period.start));
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(
        find.text(listeningDurationText(i18n, period.duration)),
        findsOneWidget,
      );
      final message = tester
          .widget<Tooltip>(
            find.ancestor(of: cell, matching: find.byType(Tooltip)).first,
          )
          .message!;
      expect(message, contains(listeningDurationText(i18n, period.duration)));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'Windows heatmap supports mouse drag, wheel, trackpad and hover',
    (tester) async {
      final days = List.generate(
        1000,
        (i) => ListeningDay(
          date: DateTime(today.year, today.month, today.day - i),
          duration: const Duration(minutes: 1),
        ),
      );
      await pumpChart(
        tester,
        platform: TargetPlatform.windows,
        style: ListeningChartStyle.heatmap,
        days: days,
      );
      final list = find.byKey(const ValueKey('listening-chart-heatmap'));
      final scroll = controller(tester);
      expect(find.byType(DragOnlyScrollbar), findsOneWidget);
      expect(find.byKey(ValueKey(days.last.date)), findsNothing);
      final cell = find.byKey(ValueKey(today));
      final message = tester
          .widget<Tooltip>(
            find.ancestor(of: cell, matching: find.byType(Tooltip)).first,
          )
          .message!;
      await tester.sendEventToBinding(
        const PointerAddedEvent(device: 42, kind: PointerDeviceKind.mouse),
      );
      await tester.sendEventToBinding(
        PointerHoverEvent(
          device: 42,
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(cell),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(find.text(message, findRichText: true), findsOneWidget);
      await tester.sendEventToBinding(
        const PointerRemovedEvent(device: 42, kind: PointerDeviceKind.mouse),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        list,
        const Offset(150, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      scroll.jumpTo(0);
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, 120),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      scroll.jumpTo(0);
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(-120, 0),
          kind: PointerDeviceKind.trackpad,
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
      scroll.jumpTo(0);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'unchanged chart data does not rescan a large listening history',
    (tester) async {
      final days = _CountingDays(
        List.generate(
          3650,
          (index) => ListeningDay(
            date: DateTime(today.year, today.month, today.day - index),
            duration: const Duration(minutes: 1),
          ),
        ),
      );
      await pumpChart(tester, days: days);
      expect(days.reads, days.length);
      days.reads = 0;

      await pumpChart(tester, days: days, textScale: 1.6);
      expect(days.reads, 0);
      await chooseDate(tester, earlier);
      expect(days.reads, days.length);
      days.reads = 0;

      await tester.ensureVisible(find.text(i18n.tr('my_interval_month')));
      await tester.tap(find.text(i18n.tr('my_interval_month')));
      await tester.pumpAndSettle();
      expect(days.reads, days.length);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new day snapshot refreshes the selected period and scale', (
    tester,
  ) async {
    final original = _CountingDays([
      ListeningDay(date: today, duration: const Duration(minutes: 1)),
    ]);
    await pumpChart(tester, days: original);
    expect(
      find.text(listeningDurationText(i18n, const Duration(minutes: 1))),
      findsOneWidget,
    );
    final updated = _CountingDays([
      ListeningDay(date: today, duration: const Duration(minutes: 12)),
    ]);
    await pumpChart(tester, days: updated);
    expect(updated.reads, 1);
    expect(
      find.text(listeningDurationText(i18n, const Duration(minutes: 12))),
      findsOneWidget,
    );
    expect(original.reads, 1);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final reducedMotion in [false, true]) {
      testWidgets(
        'date input selects and reveals an older day on $platform, reduced motion $reducedMotion',
        (tester) async {
          await pumpChart(
            tester,
            platform: platform,
            reducedMotion: reducedMotion,
            days: [
              ListeningDay(
                date: earlier,
                duration: const Duration(minutes: 37),
              ),
            ],
          );
          expect(controller(tester).offset, 0);
          await chooseDate(tester, earlier);

          expect(
            find.text(listeningDurationText(i18n, const Duration(minutes: 37))),
            findsOneWidget,
          );
          expect(controller(tester).offset, greaterThan(0));
          final bar = find.byKey(ValueKey(earlier));
          expect(bar, findsOneWidget);
          final chartBounds = tester.getRect(find.byType(ListView));
          expect(chartBounds.overlaps(tester.getRect(bar)), isTrue);

          await tester.ensureVisible(find.text(i18n.tr('my_interval_month')));
          await tester.tap(find.text(i18n.tr('my_interval_month')));
          await tester.pumpAndSettle();
          expect(
            find.text(listeningDurationText(i18n, const Duration(minutes: 37))),
            findsOneWidget,
          );
          await tester.ensureVisible(find.text(i18n.tr('my_interval_day')));
          await tester.tap(find.text(i18n.tr('my_interval_day')));
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: selector,
              matching: find.text(
                MaterialLocalizations.of(
                  tester.element(selector),
                ).formatMediumDate(earlier),
              ),
            ),
            findsOneWidget,
          );
          expect(controller(tester).offset, greaterThan(0));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'invalid dates stay in input and cancellation preserves selection',
    (tester) async {
      await pumpChart(tester);
      final before = tester
          .widget<Text>(
            find.descendant(of: selector, matching: find.byType(Text)),
          )
          .data;
      await tester.tap(selector);
      await tester.pumpAndSettle();
      final localizations = MaterialLocalizations.of(
        tester.element(find.byType(DatePickerDialog)),
      );
      await tester.enterText(find.byType(TextFormField), 'invalid date');
      await tester.tap(find.text(localizations.okButtonLabel));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text(localizations.cancelButtonLabel));
      await tester.pumpAndSettle();
      expect(find.text(before!), findsOneWidget);
      expect(controller(tester).offset, 0);
      expect(
        find.text(listeningDurationText(i18n, Duration.zero)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('date input maps to a quarter and keeps future recorded data', (
    tester,
  ) async {
    final future = DateTime(today.year + 1, 7, 22);
    await pumpChart(
      tester,
      days: [ListeningDay(date: future, duration: const Duration(minutes: 5))],
    );
    await tester.ensureVisible(find.text(i18n.tr('my_interval_quarter')));
    await tester.tap(find.text(i18n.tr('my_interval_quarter')));
    await tester.pumpAndSettle();
    await chooseDate(tester, future);
    expect(
      tester
          .widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, i18n.tr('my_interval_quarter')),
          )
          .selected,
      isTrue,
    );
    expect(
      find.text(listeningDurationText(i18n, const Duration(minutes: 5))),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey(DateTime(future.year, 7))), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty historical year selection remains selected as a day', (
    tester,
  ) async {
    final oldDate = DateTime(today.year - 3, 2, 12);
    await pumpChart(tester);
    await tester.ensureVisible(find.text(i18n.tr('my_interval_year')));
    await tester.tap(find.text(i18n.tr('my_interval_year')));
    await tester.pumpAndSettle();
    await chooseDate(tester, oldDate);
    await tester.ensureVisible(find.text(i18n.tr('my_interval_day')));
    await tester.tap(find.text(i18n.tr('my_interval_day')));
    await tester.pumpAndSettle();

    final localizations = MaterialLocalizations.of(tester.element(selector));
    expect(
      find.descendant(
        of: selector,
        matching: find.text(localizations.formatMediumDate(oldDate)),
      ),
      findsOneWidget,
    );
    expect(
      find.text(listeningDurationText(i18n, Duration.zero)),
      findsOneWidget,
    );
    final bar = find.byKey(ValueKey(oldDate));
    expect(bar, findsOneWidget);
    expect(
      tester.getRect(find.byType(ListView)).overlaps(tester.getRect(bar)),
      isTrue,
    );
    expect(controller(tester).offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}

class _CountingDays extends ListBase<ListeningDay> {
  _CountingDays(this._days);
  final List<ListeningDay> _days;
  int reads = 0;

  @override
  int get length => _days.length;

  @override
  set length(int value) => throw UnsupportedError('read-only history');

  @override
  ListeningDay operator [](int index) {
    reads++;
    return _days[index];
  }

  @override
  void operator []=(int index, ListeningDay value) =>
      throw UnsupportedError('read-only history');
}
