import 'dart:collection';

import 'package:doujin_audio/app/localization/app_language_provider.dart';
import 'package:doujin_audio/app/presentation/listening_time_chart.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:doujin_audio/features/player/domain/listening_activity.dart';
import 'package:flutter/material.dart';
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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: MediaQuery(
                data: MediaQueryData(
                  disableAnimations: reducedMotion,
                  textScaler: TextScaler.linear(textScale),
                ),
                child: ListeningTimeChart(
                  days: days,
                  i18n: i18n,
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
