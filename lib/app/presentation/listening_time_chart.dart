import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../features/player/domain/listening_activity.dart';
import '../../core/widgets/windows_horizontal_wheel_scroll.dart';
import '../localization/app_language_provider.dart';

enum ListeningInterval { day, week, month, quarter, year }

class ListeningPeriod {
  const ListeningPeriod(this.start, this.end, this.duration);
  final DateTime start;
  final DateTime end;
  final Duration duration;
}

/// Calendar arithmetic preserves local midnight through daylight-saving changes.
List<ListeningPeriod> aggregateListeningPeriods(
  List<ListeningDay> days,
  ListeningInterval interval, {
  required DateTime now,
}) {
  DateTime startOf(DateTime date) => switch (interval) {
    ListeningInterval.day => DateTime(date.year, date.month, date.day),
    ListeningInterval.week => DateTime(
      date.year,
      date.month,
      date.day - date.weekday + DateTime.monday,
    ),
    ListeningInterval.month => DateTime(date.year, date.month),
    ListeningInterval.quarter => DateTime(
      date.year,
      ((date.month - 1) ~/ 3) * 3 + 1,
    ),
    ListeningInterval.year => DateTime(date.year),
  };
  DateTime move(DateTime date, int amount) => switch (interval) {
    ListeningInterval.day => DateTime(date.year, date.month, date.day + amount),
    ListeningInterval.week => DateTime(
      date.year,
      date.month,
      date.day + amount * 7,
    ),
    ListeningInterval.month => DateTime(date.year, date.month + amount),
    ListeningInterval.quarter => DateTime(date.year, date.month + amount * 3),
    ListeningInterval.year => DateTime(date.year + amount),
  };
  final totals = <DateTime, Duration>{};
  for (final day in days) {
    final key = startOf(day.date);
    totals[key] = (totals[key] ?? Duration.zero) + day.duration;
  }
  var latest = startOf(now);
  for (final date in totals.keys) {
    if (date.isAfter(latest)) latest = date;
  }
  final minimum = switch (interval) {
    ListeningInterval.day => 30,
    ListeningInterval.week || ListeningInterval.month => 12,
    ListeningInterval.quarter => 8,
    ListeningInterval.year => 5,
  };
  var first = move(latest, 1 - minimum);
  for (final key in totals.keys) {
    if (key.isBefore(first)) first = key;
  }
  final periods = <ListeningPeriod>[];
  for (var date = first; !date.isAfter(latest); date = move(date, 1)) {
    periods.add(
      ListeningPeriod(date, move(date, 1), totals[date] ?? Duration.zero),
    );
  }
  return periods;
}

String listeningDurationText(AppLanguageProvider i18n, Duration duration) =>
    i18n.tr('my_duration', {
      'hours': duration.inHours,
      'minutes': duration.inMinutes.remainder(60),
      'seconds': duration.inSeconds.remainder(60),
    });

class ListeningTimeChart extends StatefulWidget {
  const ListeningTimeChart({super.key, required this.days, required this.i18n});
  final List<ListeningDay> days;
  final AppLanguageProvider i18n;

  @override
  State<ListeningTimeChart> createState() => _ListeningTimeChartState();
}

class _ListeningTimeChartState extends State<ListeningTimeChart> {
  ListeningInterval _interval = ListeningInterval.day;
  DateTime? _selected;

  @override
  Widget build(BuildContext context) {
    final i18n = widget.i18n;
    final periods = aggregateListeningPeriods(
      widget.days,
      _interval,
      now: DateTime.now(),
    );
    final maximum = periods.fold<int>(
      1,
      (value, p) => math.max(value, p.duration.inMilliseconds),
    );
    final selected =
        periods.where((p) => p.start == _selected).firstOrNull ?? periods.last;
    final localizations = MaterialLocalizations.of(context);
    String range(ListeningPeriod period) {
      final start = localizations.formatMediumDate(period.start);
      if (_interval == ListeningInterval.day) return start;
      return '$start – ${localizations.formatMediumDate(DateTime(period.end.year, period.end.month, period.end.day - 1))}';
    }

    String label(ListeningPeriod period) => switch (_interval) {
      ListeningInterval.day ||
      ListeningInterval.week => '${period.start.month}/${period.start.day}',
      ListeningInterval.month => '${period.start.year}/${period.start.month}',
      ListeningInterval.quarter =>
        '${period.start.year} Q${(period.start.month - 1) ~/ 3 + 1}',
      ListeningInterval.year => '${period.start.year}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final interval in ListeningInterval.values)
              ChoiceChip(
                label: Text(i18n.tr('my_interval_${interval.name}')),
                selected: _interval == interval,
                onSelected: (_) => setState(() {
                  _interval = interval;
                  _selected = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(range(selected), style: Theme.of(context).textTheme.bodySmall),
        Text(
          listeningDurationText(i18n, selected.duration),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 178,
          child: WindowsHorizontalWheelScroll(
            key: ValueKey(_interval),
            builder: (controller) => ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
              child: ListView.builder(
                controller: controller,
                reverse: true,
                scrollDirection: Axis.horizontal,
                itemExtent: 72,
                itemCount: periods.length,
                itemBuilder: (context, index) {
                  final period = periods[periods.length - index - 1];
                  final active = selected.start == period.start;
                  final color = Theme.of(context).colorScheme;
                  final description =
                      '${range(period)}: ${listeningDurationText(i18n, period.duration)}';
                  return Tooltip(
                    message: description,
                    child: Semantics(
                      label: description,
                      selected: active,
                      button: true,
                      child: InkWell(
                        onTap: () => setState(() => _selected = period.start),
                        borderRadius: BorderRadius.circular(8),
                        child: ExcludeSemantics(
                          child: Column(
                            children: [
                              SizedBox(
                                height: 138,
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    width: 30,
                                    height: math.max(
                                      2,
                                      132 *
                                          period.duration.inMilliseconds /
                                          maximum,
                                    ),
                                    decoration: BoxDecoration(
                                      color: active
                                          ? color.primary
                                          : color.primaryContainer,
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(5),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                label(period),
                                maxLines: 1,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
