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
  DateTime? includeDate,
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
  final includedStart = includeDate == null ? null : startOf(includeDate);
  var latest = startOf(now);
  if (includedStart != null && includedStart.isAfter(latest)) {
    latest = includedStart;
  }
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
  if (includedStart != null && includedStart.isBefore(first)) {
    first = includedStart;
  }
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
  const ListeningTimeChart({
    super.key,
    required this.days,
    required this.i18n,
    required this.builder,
  });
  final List<ListeningDay> days;
  final AppLanguageProvider i18n;
  final Widget Function(Widget duration, Widget chart) builder;

  @override
  State<ListeningTimeChart> createState() => _ListeningTimeChartState();
}

class _ListeningTimeChartState extends State<ListeningTimeChart> {
  static const double _itemExtent = 48;
  final ScrollController _scrollController = ScrollController();
  ListeningInterval _interval = ListeningInterval.day;
  DateTime? _selected;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final periods = aggregateListeningPeriods(
        widget.days,
        _interval,
        now: DateTime.now(),
        includeDate: _selected,
      );
      final selectedIndex = periods.indexWhere(
        (period) => _containsSelection(period),
      );
      final reversedIndex = selectedIndex < 0
          ? 0
          : periods.length - selectedIndex - 1;
      final position = _scrollController.position;
      final offset =
          (reversedIndex * _itemExtent -
                  (position.viewportDimension - _itemExtent) / 2)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (MediaQuery.disableAnimationsOf(context)) {
        _scrollController.jumpTo(offset);
      } else {
        _scrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _containsSelection(ListeningPeriod period) =>
      _selected != null &&
      !_selected!.isBefore(period.start) &&
      _selected!.isBefore(period.end);

  Future<void> _selectDate(
    List<ListeningPeriod> periods,
    ListeningPeriod selected,
  ) async {
    final latest = periods.last;
    final date = await showDatePicker(
      context: context,
      initialDate: _containsSelection(selected) ? _selected : selected.start,
      firstDate: periods.first.start,
      lastDate: DateTime(latest.end.year, latest.end.month, latest.end.day - 1),
      initialEntryMode: DatePickerEntryMode.input,
    );
    if (!mounted || date == null) return;
    setState(() => _selected = date);
    _revealSelection();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = widget.i18n;
    final periods = aggregateListeningPeriods(
      widget.days,
      _interval,
      now: DateTime.now(),
      includeDate: _selected,
    );
    final maximum = periods.fold<int>(
      1,
      (value, p) => math.max(value, p.duration.inMilliseconds),
    );
    final selected =
        periods.where(_containsSelection).firstOrNull ?? periods.last;
    final localizations = MaterialLocalizations.of(context);
    final labelStyle = Theme.of(context).textTheme.labelSmall!;
    final labelHeight =
        MediaQuery.textScalerOf(context).scale(labelStyle.fontSize!) *
        (labelStyle.height ?? 1.2);
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
    final duration = Text(
      listeningDurationText(i18n, selected.duration),
      key: const ValueKey('listening-duration'),
      style: Theme.of(context).textTheme.titleMedium,
      textAlign: TextAlign.right,
      maxLines: 2,
    );
    final chart = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('listening-date-selector'),
            onPressed: () => _selectDate(periods, selected),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 2),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              alignment: Alignment.centerLeft,
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              textStyle: Theme.of(context).textTheme.bodySmall,
            ),
            icon: const Icon(Icons.calendar_month_outlined, size: 16),
            label: Text(
              range(selected),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 2),
        SizedBox(
          key: const ValueKey('listening-chart-bars'),
          height: 146 + labelHeight.ceilToDouble(),
          child: WindowsHorizontalWheelScroll(
            controller: _scrollController,
            builder: (controller) => ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
              child: ListView.builder(
                controller: controller,
                reverse: true,
                scrollDirection: Axis.horizontal,
                itemExtent: _itemExtent,
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
                        key: ValueKey(period.start),
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
                                    width: 18,
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
                                style: labelStyle,
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
        const SizedBox(height: 2),
        WindowsHorizontalWheelScroll(
          builder: (controller) => ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
            child: SingleChildScrollView(
              key: const ValueKey('listening-chart-intervals'),
              controller: controller,
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 8,
                children: [
                  for (final interval in ListeningInterval.values)
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(i18n.tr('my_interval_${interval.name}')),
                      selected: _interval == interval,
                      onSelected: (_) {
                        setState(() => _interval = interval);
                        _revealSelection();
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    return widget.builder(duration, chart);
  }
}
