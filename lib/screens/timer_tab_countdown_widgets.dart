part of 'timer_tab.dart';

class _CountdownCard extends StatefulWidget {
  const _CountdownCard({
    required this.provider,
    required this.timerExpired,
    required this.waitingTrigger,
    required this.fmtDuration,
    required this.cs,
    this.autoResumeAt,
    this.compact = false,
  });

  final AudioProvider provider;
  final bool timerExpired;
  final bool waitingTrigger;
  final String Function(Duration) fmtDuration;
  final ColorScheme cs;
  final DateTime? autoResumeAt;
  final bool compact;

  @override
  State<_CountdownCard> createState() => _CountdownCardState();
}

class _CountdownCardState extends State<_CountdownCard> {
  Timer? _ticker;
  Duration _autoResumeRemaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _updateAutoResumeRemaining();
    if (_shouldTick()) {
      _startTicker();
    }
  }

  @override
  void didUpdateWidget(covariant _CountdownCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateAutoResumeRemaining();
    if (_shouldTick()) {
      _startTicker();
    } else {
      _stopTicker();
    }
  }

  @override
  void dispose() {
    _stopTicker();
    super.dispose();
  }

  bool _shouldTick() {
    return widget.timerExpired && widget.autoResumeAt != null;
  }

  void _startTicker() {
    if (_ticker?.isActive == true) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _updateAutoResumeRemaining();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _updateAutoResumeRemaining() {
    final target = widget.autoResumeAt;
    if (target == null) return;
    final diff = target.difference(DateTime.now());
    final next = diff > Duration.zero ? diff : Duration.zero;
    if (mounted) {
      setState(() => _autoResumeRemaining = next);
    } else {
      _autoResumeRemaining = next;
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final remaining = widget.provider.timerRemaining ?? Duration.zero;

    final showAutoResumeCountdown =
        widget.timerExpired && widget.autoResumeAt != null;

    final title = showAutoResumeCountdown
        ? i18n.tr('waiting_for_auto_resume')
        : widget.timerExpired
        ? i18n.tr('countdown_finished')
        : widget.waitingTrigger
        ? i18n.tr('waiting_to_start_countdown')
        : i18n.tr('counting_down');

    final accent = showAutoResumeCountdown
        ? widget.cs.primary
        : widget.timerExpired
        ? widget.cs.error
        : widget.waitingTrigger
        ? widget.cs.onSurfaceVariant
        : widget.cs.primary;

    final timeColor = showAutoResumeCountdown
        ? widget.cs.onPrimaryContainer
        : widget.timerExpired
        ? widget.cs.error
        : widget.waitingTrigger
        ? widget.cs.onSurface
        : widget.cs.onPrimaryContainer;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        color: widget.cs.surfaceContainerLow,
      ),
      child: Padding(
        padding: EdgeInsets.all(widget.compact ? 14 : 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.compact) ...[
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: showAutoResumeCountdown
                          ? widget.cs.primaryContainer
                          : widget.timerExpired
                          ? widget.cs.errorContainer
                          : widget.waitingTrigger
                          ? widget.cs.surfaceContainerHighest
                          : widget.cs.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      showAutoResumeCountdown
                          ? Icons.restore_rounded
                          : widget.timerExpired
                          ? Icons.alarm_off_rounded
                          : widget.waitingTrigger
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
                        color: widget.cs.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],
            Center(
              child: Text(
                showAutoResumeCountdown
                    ? widget.fmtDuration(_autoResumeRemaining)
                    : widget.fmtDuration(remaining),
                style: TextStyle(
                  fontSize: widget.compact ? 32 : 46,
                  fontWeight: FontWeight.bold,
                  letterSpacing: widget.compact ? 1.4 : 2.6,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: timeColor,
                ),
              ),
            ),
            if (widget.timerExpired && !showAutoResumeCountdown) ...[
              Builder(
                builder: (context) {
                  final chips = <Widget>[
                    if (widget.provider.pausedByTimerSessionIds.isNotEmpty)
                      _TimerSummaryChip(
                        icon: Icons.pause_circle_outline_rounded,
                        text: i18n.tr('paused_audio_count', {
                          'count':
                              widget.provider.pausedByTimerSessionIds.length,
                        }),
                        foregroundColor: widget.cs.onErrorContainer,
                        backgroundColor: widget.cs.errorContainer,
                        compact: widget.compact,
                      ),
                  ];

                  if (chips.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  return Padding(
                    padding: EdgeInsets.only(top: widget.compact ? 12 : 16),
                    child: widget.compact
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

class _DurationPicker extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
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

  @override
  void initState() {
    super.initState();
    _controller = FixedExtentScrollController(initialItem: widget.value);
  }

  @override
  void didUpdateWidget(_WheelPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      if (_controller.hasClients && _controller.selectedItem != widget.value) {
        _controller.animateToItem(
          widget.value,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
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
            borderRadius: BorderRadius.circular(12),
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
              HapticFeedback.selectionClick();
              widget.onChanged(index);
            },
            childDelegate: ListWheelChildBuilderDelegate(
              childCount: widget.max + 1,
              builder: (context, index) {
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
              },
            ),
          ),
        ),
      ],
    );
  }
}
