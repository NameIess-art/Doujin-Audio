part of 'timer_tab.dart';

class _CountdownCard extends StatelessWidget {
  const _CountdownCard({
    required this.provider,
    required this.timerExpired,
    required this.waitingTrigger,
    required this.fmtDuration,
    required this.cs,
    this.compact = false,
  });

  final AudioProvider provider;
  final bool timerExpired;
  final bool waitingTrigger;
  final String Function(Duration) fmtDuration;
  final ColorScheme cs;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final remaining = provider.timerRemaining ?? Duration.zero;
    final title = timerExpired
        ? i18n.tr('countdown_finished')
        : waitingTrigger
        ? i18n.tr('waiting_to_start_countdown')
        : i18n.tr('counting_down');
    final accent = timerExpired
        ? cs.error
        : waitingTrigger
        ? cs.onSurfaceVariant
        : cs.primary;
    final timeColor = timerExpired
        ? cs.error
        : waitingTrigger
        ? cs.onSurface
        : cs.onPrimaryContainer;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
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
                      color: timerExpired
                          ? cs.errorContainer
                          : waitingTrigger
                          ? cs.surfaceContainerHighest
                          : cs.primaryContainer,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      timerExpired
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
              child: Text(
                fmtDuration(remaining),
                style: TextStyle(
                  fontSize: compact ? 32 : 46,
                  fontWeight: FontWeight.bold,
                  letterSpacing: compact ? 1.4 : 2.6,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: timeColor,
                ),
              ),
            ),
            if (timerExpired) ...[
              Builder(
                builder: (context) {
                  final chips = <Widget>[
                    if (provider.pausedByTimerSessionIds.isNotEmpty)
                      _TimerSummaryChip(
                        icon: Icons.pause_circle_outline_rounded,
                        text: i18n.tr('paused_audio_count', {
                          'count': provider.pausedByTimerSessionIds.length,
                        }),
                        foregroundColor: cs.onErrorContainer,
                        backgroundColor: cs.errorContainer,
                        compact: compact,
                      ),
                    if (provider.autoResumeEnabled)
                      _TimerSummaryChip(
                        icon: Icons.alarm_rounded,
                        text: i18n.tr('auto_resume_at', {
                          'time':
                              '${provider.autoResumeHour.toString().padLeft(2, '0')}:${provider.autoResumeMinute.toString().padLeft(2, '0')}',
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
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: value,
                      isExpanded: true,
                      alignment: Alignment.center,
                      icon: const Icon(Icons.expand_more_rounded, size: 20),
                      iconEnabledColor: cs.onSurfaceVariant,
                      menuMaxHeight: 280,
                      borderRadius: BorderRadius.circular(12),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      selectedItemBuilder: (context) =>
                          List.generate(max + 1, (i) {
                            return Center(
                              child: Text(
                                i.toString().padLeft(2, '0'),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.visible,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            );
                          }),
                      items: List.generate(max + 1, (i) => i)
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              alignment: Alignment.center,
                              child: Text(
                                v.toString().padLeft(2, '0'),
                                maxLines: 1,
                                softWrap: false,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) onChange(v);
                      },
                    ),
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
            child: Center(
              child: Text(
                ':',
                style: TextStyle(
                  fontSize: constraints.maxWidth < 330 ? 18 : 22,
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
