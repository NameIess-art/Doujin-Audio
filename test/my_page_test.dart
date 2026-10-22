import 'package:doujin_audio/app/presentation/listening_time_chart.dart';
import 'package:doujin_audio/app/presentation/main_destination.dart';
import 'package:doujin_audio/app/presentation/my_page.dart';
import 'package:doujin_audio/app/state/listening_activity_provider.dart';
import 'package:doujin_audio/core/persistence/app_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_runtime_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppPreferences.init();
  });

  test(
    'My is permanent between playlist and settings in all visibility combinations',
    () {
      for (final local in [false, true]) {
        for (final remote in [false, true]) {
          final destinations = resolveMainDestinations(
            showLocalLibrary: local,
            showAsmrOne: remote,
          ).map((e) => e.type).toList();
          expect(destinations.sublist(destinations.length - 3), [
            MainDestinationType.playlist,
            MainDestinationType.my,
            MainDestinationType.settings,
          ]);
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
