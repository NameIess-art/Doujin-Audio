import 'dart:math' as math;

import '../../core/widgets/app_buttons.dart';
import '../../core/widgets/app_dialog.dart';
import '../../core/widgets/app_feedback.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../features/player/domain/listening_activity.dart';
import '../../features/settings/application/settings_state.dart';
import '../../core/widgets/app_transitions.dart';
import '../../core/widgets/windows_horizontal_wheel_scroll.dart';
import '../../core/widgets/shimmer_loading.dart';
import '../localization/app_language_provider.dart';
import '../theme/theme_provider.dart';

/// Computes clean, non-muddy heatmap step fills for levels `0..4`.
Color listeningHeatmapFillColor(ColorScheme colors, int level) {
  final emptyColor = colors.brightness == Brightness.dark
      ? colors.surfaceContainerHigh
      : colors.surfaceContainer;
  final clamped = level.clamp(0, 4);
  if (clamped == 0) return emptyColor;
  const alphas = <double>[0.0, 0.24, 0.48, 0.74, 1.0];
  return Color.alphaBlend(
    colors.primary.withValues(alpha: alphas[clamped]),
    emptyColor,
  );
}

enum ListeningInterval { day, week, month, quarter, year }

const _minimumBarColumns = 7;

class ListeningPeriod {
  const ListeningPeriod(this.start, this.end, this.duration);
  final DateTime start;
  final DateTime end;
  final Duration duration;
}

DateTime _moveListeningPeriod(
  DateTime date,
  ListeningInterval interval,
  int amount,
) => switch (interval) {
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
  DateTime move(DateTime date, int amount) =>
      _moveListeningPeriod(date, interval, amount);
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
    ListeningInterval.year => _minimumBarColumns,
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

String _compactAxisDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  if (minutes > 0) return '${minutes}m';
  return '${seconds}s';
}

class ListeningTimeChart extends StatefulWidget {
  const ListeningTimeChart({
    super.key,
    required this.days,
    required this.i18n,
    required this.builder,
    this.style = ListeningChartStyle.bar,
    this.onStyleChanged,
  }) : _skeleton = false;

  const ListeningTimeChart.skeleton({
    super.key,
    required this.i18n,
    required this.builder,
    this.style = ListeningChartStyle.bar,
  }) : days = const [],
       onStyleChanged = null,
       _skeleton = true;

  final bool _skeleton;
  final ListeningChartStyle style;
  final ValueChanged<ListeningChartStyle>? onStyleChanged;
  final List<ListeningDay> days;
  final AppLanguageProvider i18n;
  final Widget Function(Widget duration, Widget chart) builder;

  @override
  State<ListeningTimeChart> createState() => _ListeningTimeChartState();
}

class _ListeningTimeChartState extends State<ListeningTimeChart> {
  static const double _preferredBarExtent = 48;
  double _heatmapExtent = 0;
  int _heatmapColumnCount = 0;
  static const int _heatmapRows = 7;
  ScrollController? _scrollController;
  ListeningInterval _interval = ListeningInterval.day;
  DateTime? _selected;
  List<ListeningDay>? _aggregatedDays;
  ListeningInterval? _aggregatedInterval;
  DateTime? _aggregatedDay;
  DateTime? _aggregatedSelected;
  List<ListeningPeriod> _periods = const [];
  int _maximum = 1;
  MaterialLocalizations? _formattedLocalizations;
  ListeningInterval? _formattedInterval;
  Locale? _formattedLocale;
  List<ListeningDay>? _formattedDays;
  final Map<(DateTime, DateTime), String> _periodRangeCache =
      <(DateTime, DateTime), String>{};
  final Map<(DateTime, DateTime, int), String> _periodDescriptionCache =
      <(DateTime, DateTime, int), String>{};

  void _syncFormatCaches(
    MaterialLocalizations localizations,
    ListeningInterval interval,
    Locale locale,
  ) {
    final rangeInvalidated =
        _formattedLocalizations != localizations ||
        _formattedInterval != interval;
    if (rangeInvalidated) {
      _periodRangeCache.clear();
      _periodDescriptionCache.clear();
      _formattedLocalizations = localizations;
      _formattedInterval = interval;
      _formattedLocale = locale;
      _formattedDays = widget.days;
      return;
    }
    if (_formattedLocale != locale || !identical(_formattedDays, widget.days)) {
      _periodDescriptionCache.clear();
      _formattedLocale = locale;
      _formattedDays = widget.days;
    }
  }

  List<ListeningPeriod> _currentPeriods() {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    if (!identical(_aggregatedDays, widget.days) ||
        _aggregatedInterval != _interval ||
        _aggregatedDay != day ||
        _aggregatedSelected != _selected) {
      _periods = aggregateListeningPeriods(
        widget.days,
        _interval,
        now: now,
        includeDate: _selected,
      );
      _maximum = _periods.fold<int>(
        1,
        (value, period) => math.max(value, period.duration.inMilliseconds),
      );
      _aggregatedDays = widget.days;
      _aggregatedInterval = _interval;
      _aggregatedDay = day;
      _aggregatedSelected = _selected;
    }
    return _periods;
  }

  @override
  void didUpdateWidget(ListeningTimeChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style) _revealSelection();
  }

  double _barExtent(double width) {
    final columns = math.max(
      _minimumBarColumns,
      (width / _preferredBarExtent).floor(),
    );
    return width / columns;
  }

  void _revealSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = _scrollController;
      if (!mounted || controller == null || !controller.hasClients) return;
      final periods = _currentPeriods();
      final selectedIndex = periods.indexWhere(
        (period) => _containsSelection(period),
      );
      final heatmap = widget.style == ListeningChartStyle.heatmap;
      final position = controller.position;
      final extent = heatmap
          ? _heatmapExtent
          : _barExtent(position.viewportDimension);
      final periodsAfterSelection = selectedIndex < 0
          ? 0
          : periods.length - 1 - selectedIndex;
      final reversedIndex = heatmap
          ? periodsAfterSelection ~/ _heatmapRows
          : periodsAfterSelection;
      final offset =
          (reversedIndex * extent - (position.viewportDimension - extent) / 2)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (MediaQuery.disableAnimationsOf(context)) {
        controller.jumpTo(offset);
      } else {
        controller.animateTo(
          offset,
          duration: const Duration(milliseconds: 280),
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
    final date = await showAppDialog<DateTime>(
      context: context,
      maxWidth: double.infinity,
      outerPadding: EdgeInsets.zero,
      builder: (_) => DatePickerDialog(
        initialDate: _containsSelection(selected) ? _selected : selected.start,
        firstDate: widget.style == ListeningChartStyle.heatmap
            ? _moveListeningPeriod(
                latest.start,
                _interval,
                1 - _heatmapColumnCount * _heatmapRows,
              )
            : periods.first.start,
        lastDate: DateTime(latest.end.year, latest.end.month, latest.end.day - 1),
      ),
    );
    if (!mounted || date == null) return;
    setState(() => _selected = date);
    _revealSelection();
  }

  @override
  Widget build(BuildContext context) {
    final i18n = widget.i18n;
    final chartStyle = widget.style;
    // The outgoing list can still lay out cells while it fades.
    final interval = _interval;
    final skeleton = widget._skeleton;
    final heatmap = chartStyle == ListeningChartStyle.heatmap;
    final periods = _currentPeriods();
    final maximum = _maximum;
    final selected = _selected == null
        ? periods.last
        : periods.where(_containsSelection).firstOrNull ?? periods.last;
    final localizations = MaterialLocalizations.of(context);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    _syncFormatCaches(localizations, interval, i18n.locale);
    final labelStyle = Theme.of(context).textTheme.labelSmall!;
    final labelHeight =
        MediaQuery.textScalerOf(context).scale(labelStyle.fontSize!) *
        (labelStyle.height ?? 1.2);
    // Keep the real controls' theme and text metrics in the loading layout.
    Widget placeholderFor(
      Widget child, {
      double? width,
      double height = 16,
      double radius = 6,
      Alignment alignment = Alignment.centerLeft,
    }) => skeleton
        ? Stack(
            children: [
              Opacity(opacity: 0, child: child),
              Positioned.fill(
                child: Align(
                  alignment: alignment,
                  child: ShimmerContainer(
                    width: width,
                    height: height,
                    borderRadius: radius,
                  ),
                ),
              ),
            ],
          )
        : child;
    String range(ListeningPeriod period) => _periodRangeCache.putIfAbsent(
      (period.start, period.end),
      () {
        final start = localizations.formatMediumDate(period.start);
        if (interval == ListeningInterval.day) return start;
        return '$start – ${localizations.formatMediumDate(DateTime(period.end.year, period.end.month, period.end.day - 1))}';
      },
    );

    String descriptionFor(ListeningPeriod period) =>
        _periodDescriptionCache.putIfAbsent(
          (period.start, period.end, period.duration.inSeconds),
          () =>
              '${range(period)}: ${listeningDurationText(i18n, period.duration)}',
        );

    String label(ListeningPeriod period) {
      final date = period.start;
      final year = (date.year % 100).toString().padLeft(2, '0');
      return switch (interval) {
        ListeningInterval.day ||
        ListeningInterval.week => '${date.month}/${date.day}',
        ListeningInterval.month => '$year/${date.month}',
        ListeningInterval.quarter => '$year Q${(date.month - 1) ~/ 3 + 1}',
        ListeningInterval.year => year,
      };
    }

    Widget selectablePeriod(
      ListeningPeriod period,
      Widget child, {
      double radius = 8,
    }) {
      final description = descriptionFor(period);
      return Tooltip(
        message: description,
        child: Semantics(
          label: description,
          selected: selected.start == period.start,
          button: true,
          child: InkWell(
            mouseCursor: WidgetStateMouseCursor.clickable,
            key: ValueKey(period.start),
            onTap: () => setState(() => _selected = period.start),
            borderRadius: BorderRadius.circular(radius),
            child: ExcludeSemantics(child: child),
          ),
        ),
      );
    }

    final colors = Theme.of(context).colorScheme;
    final heatmapFillColors = heatmap && !skeleton
        ? List<Color>.generate(
            5,
            (level) => listeningHeatmapFillColor(colors, level),
            growable: false,
          )
        : null;
    final heatmapBorderColors = heatmapFillColors == null
        ? null
        : List<Color>.generate(5, (level) {
            final fillColor = heatmapFillColors[level];
            return appColorContrastRatio(colors.onSurface, fillColor) >= 3.0
                ? colors.onSurface
                : appReadableOnColor(fillColor);
          }, growable: false);
    Widget heatmapCell(int index) {
      if (skeleton) return const ShimmerContainer(borderRadius: 3);
      final period = index >= 0
          ? periods[index]
          : ListeningPeriod(
              _moveListeningPeriod(periods.first.start, interval, index),
              _moveListeningPeriod(periods.first.start, interval, index + 1),
              Duration.zero,
            );
      final milliseconds = period.duration.inMilliseconds;
      final level = milliseconds <= 0
          ? 0
          : ((milliseconds * 4 + maximum - 1) ~/ maximum).clamp(1, 4);
      return _HeatmapPeriodCell(
        periodKey: ValueKey(period.start),
        description: descriptionFor(period),
        selected: selected.start == period.start,
        fillColor: heatmapFillColors![level],
        borderColor: heatmapBorderColors![level],
        onTap: () => setState(() => _selected = period.start),
      );
    }

    String heatmapColumnLabel(int reversedColumn) {
      final oldestIndex =
          periods.length -
          1 -
          (reversedColumn * _heatmapRows + _heatmapRows - 1);
      final newestIndex = periods.length - 1 - (reversedColumn * _heatmapRows);
      DateTime periodStartAt(int idx) => idx >= 0
          ? periods[idx].start
          : _moveListeningPeriod(periods.first.start, interval, idx);
      final newest = periodStartAt(newestIndex);
      final oldest = periodStartAt(oldestIndex);
      final prevNewest = periodStartAt(
        periods.length - 1 - ((reversedColumn + 1) * _heatmapRows),
      );
      if (interval == ListeningInterval.year) {
        return newest.year != prevNewest.year
            ? (newest.year % 100).toString().padLeft(2, '0')
            : '';
      }
      if (interval == ListeningInterval.month ||
          interval == ListeningInterval.quarter) {
        if (newest.year != prevNewest.year) {
          return (newest.year % 100).toString().padLeft(2, '0');
        }
        return '';
      }
      if (newest.month != prevNewest.month || oldest.month != newest.month) {
        if (newest.month == 1 || newest.year != prevNewest.year) {
          return '${(newest.year % 100).toString().padLeft(2, '0')}/${newest.month}';
        }
        return '${newest.month}';
      }
      return '';
    }

    Widget heatmapColumn(
      int reversedColumn,
      double cellSize,
      double monthHeaderHeight,
    ) {
      final header = skeleton ? '' : heatmapColumnLabel(reversedColumn);
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: cellSize,
          child: Column(
            children: [
              SizedBox(
                height: monthHeaderHeight,
                child: header.isEmpty
                    ? null
                    : Align(
                        alignment: Alignment.bottomLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            header,
                            maxLines: 1,
                            style: labelStyle.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var row = 0; row < _heatmapRows; row++)
                      SizedBox(
                        width: cellSize,
                        height: cellSize,
                        child: heatmapCell(
                          periods.length -
                              1 -
                              (reversedColumn * _heatmapRows +
                                  _heatmapRows -
                                  1 -
                                  row),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget heatmapWeekdayAxis(double cellSize, double monthHeaderHeight) {
      final latestDay = periods.last.start;
      final narrowWeekdays = localizations.narrowWeekdays;
      return Padding(
        padding: const EdgeInsets.only(right: 4),
        child: SizedBox(
          width: 16,
          child: Column(
            children: [
              SizedBox(height: monthHeaderHeight),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var row = 0; row < _heatmapRows; row++)
                      SizedBox(
                        width: 16,
                        height: cellSize,
                        child: row.isEven
                            ? Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    narrowWeekdays[DateTime(
                                          latestDay.year,
                                          latestDay.month,
                                          latestDay.day -
                                              (_heatmapRows - 1 - row),
                                        ).weekday %
                                        7],
                                    maxLines: 1,
                                    style: labelStyle.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget heatmapLegend() => Padding(
      key: const ValueKey('listening-heatmap-legend'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            i18n.tr('my_heatmap_less'),
            style: labelStyle.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
          for (var level = 0; level <= 4; level++)
            Container(
              width: 10,
              height: 10,
              margin: EdgeInsets.only(left: level == 0 ? 0 : 3),
              decoration: BoxDecoration(
                color: listeningHeatmapFillColor(colors, level),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          const SizedBox(width: 6),
          Text(
            i18n.tr('my_heatmap_more'),
            style: labelStyle.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );

    final duration = placeholderFor(
      Text(
        listeningDurationText(i18n, selected.duration),
        key: const ValueKey('listening-duration'),
        style: Theme.of(context).textTheme.titleMedium,
        textAlign: TextAlign.right,
        maxLines: 2,
      ),
      width: 116,
      height: 18,
      alignment: Alignment.centerRight,
    );
    final chart = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: placeholderFor(
                  AppLabelledButton(
                    TextButton.icon,
                    key: const ValueKey('listening-date-selector'),
                    onPressed: () => _selectDate(periods, selected),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      alignment: Alignment.centerLeft,
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant,
                      textStyle: Theme.of(context).textTheme.bodySmall,
                    ),
                    icon: const Icon(Icons.calendar_month_outlined, size: 16),
                    label: Text(
                      range(selected),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  width: 140,
                ),
              ),
            ),
            const SizedBox(width: 8),
            for (final style in ListeningChartStyle.values)
              placeholderFor(
                Semantics(
                  selected: widget.style == style,
                  child: IconButton(
                    key: ValueKey('listening-style-${style.name}'),
                    tooltip: i18n.tr('my_chart_style_${style.name}'),
                    onPressed: widget.onStyleChanged == null
                        ? null
                        : () => widget.onStyleChanged!(style),
                    style: appIconButtonStyle(
                      IconButton.styleFrom(
                        minimumSize: const Size(40, 40),
                        maximumSize: const Size(40, 40),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: widget.style == style
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : Colors.transparent,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    icon: Icon(
                      style == ListeningChartStyle.bar
                          ? Icons.bar_chart_rounded
                          : Icons.grid_view_rounded,
                      size: 18,
                    ),
                  ),
                ),
                width: 40,
                height: 40,
                alignment: Alignment.center,
              ),
          ],
        ),
        const SizedBox(height: 2),
        SizedBox(
          key: const ValueKey('listening-chart-bars'),
          height: 152 + labelHeight.ceilToDouble(),
          child: AnimatedSwitcher(
            duration: disableAnimations ? Duration.zero : kAppFadeDuration,
            switchInCurve: kAppFadeCurve,
            switchOutCurve: kAppFadeCurve,
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              children: [
                for (final child in previous)
                  ExcludeFocus(
                    child: ExcludeSemantics(child: IgnorePointer(child: child)),
                  ),
                ?current,
              ],
            ),
            child: WindowsHorizontalWheelScroll(
              key: ValueKey((chartStyle, interval)),
              // Each fading chart owns its scroll position, including rapid
              // reversals while an older instance is still fading out.
              builder: (controller) {
                if (_interval == interval && widget.style == chartStyle) {
                  _scrollController = controller;
                }
                return ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: PointerDeviceKind.values.toSet(),
                    scrollbars: false,
                  ),
                  child: LayoutBuilder(
                    builder: (_, constraints) {
                      final monthHeaderHeight = labelHeight.ceilToDouble() + 2;
                      final showWeekdayAxis =
                          heatmap && !skeleton && interval == ListeningInterval.day;
                      final listWidth = showWeekdayAxis
                          ? math.max(1.0, constraints.maxWidth - 20)
                          : constraints.maxWidth;
                      final cellSize = math.min(
                        listWidth,
                        (constraints.maxHeight -
                                monthHeaderHeight -
                                3 * (_heatmapRows - 1)) /
                            _heatmapRows,
                      );
                      var itemExtent = _barExtent(constraints.maxWidth);
                      var itemCount = periods.length;
                      if (heatmap) {
                        final visibleColumns = math.max(
                          1,
                          ((listWidth + 3) / (cellSize + 3)).floor(),
                        );
                        itemExtent = listWidth / visibleColumns;
                        itemCount = math.max(
                          visibleColumns,
                          (periods.length + _heatmapRows - 1) ~/ _heatmapRows,
                        );
                        if (identical(_scrollController, controller)) {
                          _heatmapExtent = itemExtent;
                          _heatmapColumnCount = itemCount;
                        }
                        final heatmapList = ListView.builder(
                          key: ValueKey('listening-chart-${chartStyle.name}'),
                          controller: controller,
                          reverse: true,
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.zero,
                          itemExtent: itemExtent,
                          itemCount: itemCount,
                          itemBuilder: (context, index) => heatmapColumn(
                            index,
                            cellSize,
                            monthHeaderHeight,
                          ),
                        );
                        if (!showWeekdayAxis) return heatmapList;
                        return Row(
                          children: [
                            heatmapWeekdayAxis(cellSize, monthHeaderHeight),
                            Expanded(child: heatmapList),
                          ],
                        );
                      }

                      return _BarListeningChart(
                        listKey: ValueKey('listening-chart-${chartStyle.name}'),
                        controller: controller,
                        periods: periods,
                        itemExtent: itemExtent,
                        viewportWidth: constraints.maxWidth,
                        skeleton: skeleton,
                        fallbackMaximum: maximum,
                        selectedStart: selected.start,
                        disableAnimations: disableAnimations,
                        labelHeight: labelHeight,
                        labelStyle: labelStyle,
                        colors: colors,
                        labelFor: label,
                        wrapPeriod: selectablePeriod,
                        wrapPlaceholder: (child) => placeholderFor(
                          child,
                          width: 30,
                          height: 12,
                          alignment: Alignment.center,
                        ),
                      );
                    },
                  ),
                );
              },
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
                    placeholderFor(
                      appNoPointerInkTheme(
                        context: context,
                        androidPressHighlight: true,
                        child: ChoiceChip(
                          mouseCursor: WidgetStateMouseCursor.clickable,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          label: Text(i18n.tr('my_interval_${interval.name}')),
                          selected: _interval == interval,
                          onSelected: (_) {
                            if (_interval != interval) {
                              AppInteractionFeedback.trigger(
                                AppInteractionFeedbackType.selection,
                              );
                            }
                            setState(() => _interval = interval);
                            _revealSelection();
                          },
                        ),
                      ),
                      radius: 12,
                      height: 32,
                      alignment: Alignment.center,
                    ),
                ],
              ),
            ),
          ),
        ),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: heatmap ? 1.0 : 0.0),
          duration: disableAnimations ? Duration.zero : kAppFadeDuration,
          curve: kAppFadeCurve,
          builder: (context, factor, child) {
            if (factor == 0 && !heatmap) {
              return const SizedBox.shrink();
            }
            return ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: factor,
                child: Opacity(opacity: factor, child: child),
              ),
            );
          },
          child: placeholderFor(
            heatmapLegend(),
            width: 120,
            height: 12,
            alignment: Alignment.centerRight,
          ),
        ),
      ],
    );
    return widget.builder(duration, chart);
  }
}

class _BarListeningChart extends StatefulWidget {
  const _BarListeningChart({
    required this.listKey,
    required this.controller,
    required this.periods,
    required this.itemExtent,
    required this.viewportWidth,
    required this.skeleton,
    required this.fallbackMaximum,
    required this.selectedStart,
    required this.disableAnimations,
    required this.labelHeight,
    required this.labelStyle,
    required this.colors,
    required this.labelFor,
    required this.wrapPeriod,
    required this.wrapPlaceholder,
  });

  final Key listKey;
  final ScrollController controller;
  final List<ListeningPeriod> periods;
  final double itemExtent;
  final double viewportWidth;
  final bool skeleton;
  final int fallbackMaximum;
  final DateTime selectedStart;
  final bool disableAnimations;
  final double labelHeight;
  final TextStyle labelStyle;
  final ColorScheme colors;
  final String Function(ListeningPeriod period) labelFor;
  final Widget Function(ListeningPeriod period, Widget child) wrapPeriod;
  final Widget Function(Widget child) wrapPlaceholder;

  @override
  State<_BarListeningChart> createState() => _BarListeningChartState();
}

class _BarListeningChartState extends State<_BarListeningChart> {
  static const double _barPlotHeight = 144.0;
  static const Duration _barHeightTransitionDuration = Duration(
    milliseconds: 140,
  );

  int _windowMaxMs = 0;
  final ValueNotifier<int> _windowMaxNotifier = ValueNotifier<int>(0);
  ValueNotifier<bool>? _scrollingNotifier;

  @override
  void initState() {
    super.initState();
    _windowMaxMs = _computeWindowMax();
    widget.controller.addListener(_handleScroll);
  }

  @override
  void didUpdateWidget(covariant _BarListeningChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleScroll);
      _detachScrollingListener();
      widget.controller.addListener(_handleScroll);
    }
    _windowMaxMs = _computeWindowMax();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleScroll);
    _detachScrollingListener();
    _windowMaxNotifier.dispose();
    super.dispose();
  }

  void _detachScrollingListener() {
    _scrollingNotifier?.removeListener(_handleScrollingChanged);
    _scrollingNotifier = null;
  }

  void _ensureScrollingListener() {
    if (!widget.controller.hasClients) return;
    final notifier = widget.controller.position.isScrollingNotifier;
    if (identical(_scrollingNotifier, notifier)) return;
    _detachScrollingListener();
    _scrollingNotifier = notifier;
    notifier.addListener(_handleScrollingChanged);
  }

  void _handleScrollingChanged() {
    if (_scrollingNotifier?.value == true || !mounted || widget.skeleton) {
      return;
    }
    final next = _computeWindowMax();
    if (next == _windowMaxMs) return;
    _windowMaxMs = next;
    _windowMaxNotifier.value++;
  }

  void _handleScroll() {
    if (widget.skeleton) return;
    _ensureScrollingListener();
    if (_scrollingNotifier?.value == true) return;
    final next = _computeWindowMax();
    if (next == _windowMaxMs) return;
    _windowMaxMs = next;
    _windowMaxNotifier.value++;
  }

  int _computeWindowMax() {
    if (widget.skeleton) return widget.fallbackMaximum;
    final periods = widget.periods;
    if (periods.isEmpty) return 0;
    final offset = widget.controller.hasClients ? widget.controller.offset : 0.0;
    final firstReversed = (offset / widget.itemExtent).floor().clamp(
      0,
      periods.length - 1,
    );
    final lastReversed = ((offset + widget.viewportWidth) / widget.itemExtent)
        .ceil()
        .clamp(0, periods.length - 1);
    final startIdx = (periods.length - 1 - lastReversed).clamp(
      0,
      periods.length - 1,
    );
    final endIdx = (periods.length - 1 - firstReversed).clamp(
      0,
      periods.length - 1,
    );
    var windowMax = 0;
    for (var i = startIdx; i <= endIdx; i++) {
      final ms = periods[i].duration.inMilliseconds;
      if (ms > windowMax) windowMax = ms;
    }
    return windowMax;
  }

  @override
  Widget build(BuildContext context) {
    final periods = widget.periods;
    final colors = widget.colors;
    final barDuration = widget.disableAnimations
        ? Duration.zero
        : _barHeightTransitionDuration;
    return Stack(
      children: [
        if (!widget.skeleton)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: ListenableBuilder(
                listenable: _windowMaxNotifier,
                builder: (context, _) {
                  final windowMaxMs = _windowMaxMs;
                  if (windowMaxMs <= 0) return const SizedBox.shrink();
                  return Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 1,
                          color: colors.outlineVariant.withValues(alpha: 0.35),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        key: const ValueKey('listening-chart-window-max'),
                        _compactAxisDuration(
                          Duration(milliseconds: windowMaxMs),
                        ),
                        style: widget.labelStyle.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ListView.builder(
          key: widget.listKey,
          controller: widget.controller,
          reverse: true,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.zero,
          itemExtent: widget.itemExtent,
          itemCount: periods.length,
          itemBuilder: (context, index) {
            final period = periods[periods.length - index - 1];
            final active = widget.selectedStart == period.start;
            final barColor = active ? colors.primary : colors.primaryContainer;
            final durationMs = period.duration.inMilliseconds;
            return widget.wrapPeriod(
              period,
              Column(
                children: [
                  SizedBox(
                    height: _barPlotHeight,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: widget.skeleton
                          ? ShimmerContainer(
                              width: 18,
                              height: 28.0 + (index % 4) * 30,
                              borderRadius: 5,
                            )
                          : ListenableBuilder(
                              listenable: _windowMaxNotifier,
                              builder: (context, _) {
                                final scaleDenom = math.max(1, _windowMaxMs);
                                return AnimatedContainer(
                                  duration: barDuration,
                                  curve: Curves.easeOutCubic,
                                  width: 18,
                                  height: math.max(
                                    2,
                                    132 * durationMs / scaleDenom,
                                  ),
                                  decoration: BoxDecoration(
                                    color: barColor,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(5),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: widget.labelHeight.ceilToDouble() + 2,
                    child: widget.wrapPlaceholder(
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.labelFor(period),
                          maxLines: 1,
                          style: widget.labelStyle,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _HeatmapPeriodCell extends StatefulWidget {
  const _HeatmapPeriodCell({
    required this.periodKey,
    required this.description,
    required this.selected,
    required this.fillColor,
    required this.borderColor,
    required this.onTap,
  });

  final Key periodKey;
  final String description;
  final bool selected;
  final Color fillColor;
  final Color borderColor;
  final VoidCallback onTap;

  @override
  State<_HeatmapPeriodCell> createState() => _HeatmapPeriodCellState();
}

class _HeatmapPeriodCellState extends State<_HeatmapPeriodCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.description,
      child: Semantics(
        label: widget.description,
        selected: widget.selected,
        button: true,
        child: InkWell(
          key: widget.periodKey,
          mouseCursor: WidgetStateMouseCursor.clickable,
          onTap: widget.onTap,
          onHover: (hovering) {
            if (_hovered != hovering) setState(() => _hovered = hovering);
          },
          borderRadius: BorderRadius.circular(3),
          child: ExcludeSemantics(
            child: Container(
              decoration: BoxDecoration(
                color: widget.fillColor,
                borderRadius: BorderRadius.circular(3),
                border: widget.selected || _hovered
                    ? Border.all(color: widget.borderColor, width: 1.5)
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
