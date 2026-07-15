part of 'timer_tab.dart';

class _CountdownCard extends ConsumerWidget {
  const _CountdownCard({
    required this.timerState,
    required this.timerExpired,
    required this.waitingTrigger,
    required this.fmtDuration,
    required this.cs,
    this.autoResumeAt,
    this.compact = false,
  });

  final TimerStateSliceData timerState;
  final bool timerExpired;
  final bool waitingTrigger;
  final String Function(Duration) fmtDuration;
  final ColorScheme cs;
  final DateTime? autoResumeAt;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final remaining = timerState.remaining ?? Duration.zero;

    final showAutoResumeCountdown = timerExpired && autoResumeAt != null;

    final title = showAutoResumeCountdown
        ? i18n.tr('waiting_for_auto_resume')
        : timerExpired
        ? i18n.tr('countdown_finished')
        : waitingTrigger
        ? i18n.tr('waiting_to_start_countdown')
        : i18n.tr('counting_down');

    final accent = showAutoResumeCountdown
        ? cs.primary
        : timerExpired
        ? cs.error
        : waitingTrigger
        ? cs.onSurfaceVariant
        : cs.primary;

    final timeColor = showAutoResumeCountdown
        ? cs.onPrimaryContainer
        : timerExpired
        ? cs.error
        : waitingTrigger
        ? cs.onSurface
        : cs.onPrimaryContainer;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cs.surfaceContainerLow,
      ),
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!compact) ...[
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: showAutoResumeCountdown
                          ? cs.primaryContainer
                          : timerExpired
                          ? cs.errorContainer
                          : waitingTrigger
                          ? cs.surfaceContainerHighest
                          : cs.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      showAutoResumeCountdown
                          ? Icons.restore_rounded
                          : timerExpired
                          ? Icons.alarm_off_rounded
                          : waitingTrigger
                          ? Icons.schedule_rounded
                          : Icons.timer_rounded,
                      size: 24,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],
            Center(
              child: TargetCountdownBuilder(
                target: showAutoResumeCountdown ? autoResumeAt : null,
                builder: (context, autoResumeRemaining) {
                  return Text(
                    showAutoResumeCountdown
                        ? fmtDuration(autoResumeRemaining)
                        : fmtDuration(remaining),
                    style: TextStyle(
                      fontSize: compact ? 32 : 46,
                      fontWeight: FontWeight.bold,
                      letterSpacing: compact ? 1.4 : 2.6,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: timeColor,
                    ),
                  );
                },
              ),
            ),
            if (timerExpired && !showAutoResumeCountdown) ...[
              Builder(
                builder: (context) {
                  final chips = <Widget>[
                    if (timerState.pausedByTimerSessionIds.isNotEmpty)
                      _TimerSummaryChip(
                        icon: Icons.pause_circle_outline_rounded,
                        text: i18n.tr('paused_audio_count', {
                          'count': timerState.pausedByTimerSessionIds.length,
                        }),
                        foregroundColor: cs.onErrorContainer,
                        backgroundColor: cs.errorContainer,
                        compact: compact,
                      ),
                  ];

                  if (chips.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  return Padding(
                    padding: EdgeInsets.only(top: compact ? 12 : 16),
                    child: compact
                        ? Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: chips,
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < chips.length; i++) ...[
                                if (i > 0) const SizedBox(height: 8),
                                chips[i],
                              ],
                            ],
                          ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DurationPicker extends ConsumerWidget {
  const _DurationPicker({
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.onChanged,
    this.showLabels = true,
  });

  final int hours;
  final int minutes;
  final int seconds;
  final void Function(int h, int m, int s) onChanged;
  final bool showLabels;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final separatorWidth = constraints.maxWidth < 330 ? 18.0 : 24.0;
        final pickerWidth =
            (constraints.maxWidth - (separatorWidth * 2) - 12) / 3;

        Widget picker(
          String label,
          int value,
          int max,
          void Function(int) onChange,
        ) {
          return SizedBox(
            width: pickerWidth.clamp(84.0, 132.0).toDouble(),
            child: Column(
              children: [
                Container(
                  height: 140,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: _WheelPicker(
                    value: value,
                    max: max,
                    onChanged: onChange,
                  ),
                ),
                if (showLabels) ...[
                  const SizedBox(height: 8),
                  _TimerFieldLabel(icon: Icons.timelapse_rounded, text: label),
                ],
              ],
            ),
          );
        }

        Widget separator() {
          return SizedBox(
            width: separatorWidth,
            height: 140,
            child: Center(
              child: Text(
                ':',
                style: TextStyle(
                  fontSize: constraints.maxWidth < 330 ? 20 : 24,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            picker(
              i18n.tr('hour'),
              hours,
              5,
              (v) => onChanged(v, minutes, seconds),
            ),
            separator(),
            picker(
              i18n.tr('minute'),
              minutes,
              59,
              (v) => onChanged(hours, v, seconds),
            ),
            separator(),
            picker(
              i18n.tr('second'),
              seconds,
              59,
              (v) => onChanged(hours, minutes, v),
            ),
          ],
        );
      },
    );
  }
}

class _WheelPicker extends StatefulWidget {
  const _WheelPicker({
    required this.value,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<_WheelPicker> createState() => _WheelPickerState();
}

class _WheelPickerState extends State<_WheelPicker> {
  late FixedExtentScrollController _controller;
  int _lastReportedValue = -1;

  @override
  void initState() {
    super.initState();
    _controller = FixedExtentScrollController(initialItem: widget.value);
    _lastReportedValue = widget.value;
  }

  @override
  void didUpdateWidget(_WheelPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      if (_controller.hasClients) {
        final currentLogicalIndex = _controller.selectedItem;
        final maxCount = widget.max + 1;
        // In Dart, % operator on negative numbers returns a positive modulo
        // consistent with Euclidean division, which is perfect for this.
        final currentItemIndex = currentLogicalIndex % maxCount;

        int diff = widget.value - currentItemIndex;
        if (diff > maxCount ~/ 2) {
          diff -= maxCount;
        } else if (diff < -(maxCount ~/ 2)) {
          diff += maxCount;
        }

        final targetLogicalIndex = currentLogicalIndex + diff;

        if (currentLogicalIndex != targetLogicalIndex) {
          _controller.animateToItem(
            targetLogicalIndex,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          height: 42,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
            },
          ),
          child: ListWheelScrollView.useDelegate(
            controller: _controller,
            itemExtent: 42,
            perspective: 0.005,
            diameterRatio: 1.5,
            physics: const FixedExtentScrollPhysics(),
            onSelectedItemChanged: (index) {
              final actualIndex = index % (widget.max + 1);
              if (actualIndex != _lastReportedValue) {
                _lastReportedValue = actualIndex;
                AppInteractionFeedback.trigger(
                  AppInteractionFeedbackType.selection,
                );
                widget.onChanged(actualIndex);
              }
            },
            childDelegate: ListWheelChildLoopingListDelegate(
              children: List.generate(widget.max + 1, (index) {
                return Center(
                  child: Text(
                    index.toString().padLeft(2, '0'),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: cs.onSurface,
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ],
    );
  }
}
