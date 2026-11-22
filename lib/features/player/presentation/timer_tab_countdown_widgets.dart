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

  final TimerConfigurationUiState timerState;
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
    final showAutoResumeCountdown = timerExpired && autoResumeAt != null;

    final title = showAutoResumeCountdown
        ? i18n.tr('waiting_for_auto_resume')
        : timerExpired
        ? i18n.tr(
            timerState.stopAfterCurrentTrack
                ? 'waiting_for_track_end'
                : 'countdown_finished',
          )
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
              child: Consumer(
                builder: (context, ref, _) {
                  final remaining =
                      ref.watch(
                        timerStateProvider.select(
                          (state) => state.value?.remaining,
                        ),
                      ) ??
                      ref.read(timerFacadeProvider).state.remaining ??
                      Duration.zero;
                  return TargetCountdownBuilder(
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
                          color: timeColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (!timerExpired &&
                !waitingTrigger &&
                !showAutoResumeCountdown) ...[
              SizedBox(height: compact ? 10 : 14),
              Center(
                child: Consumer(
                  builder: (context, ref, _) {
                    final (canSub15, canSub5) = ref.watch(
                      timerStateProvider.select((state) {
                        final rem = state.value?.remaining ?? Duration.zero;
                        return (
                          rem > const Duration(minutes: 15),
                          rem > const Duration(minutes: 5),
                        );
                      }),
                    );
                    final radius = BorderRadius.circular(999);
                    const adjustments = [-15, -5, 5, 15];
                    final chipSpacing = compact ? 6.0 : 8.0;
                    return FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < adjustments.length; i++) ...[
                            if (i > 0) SizedBox(width: chipSpacing),
                            Builder(
                              builder: (context) {
                                final minutes = adjustments[i];
                                final enabled = switch (minutes) {
                                  -15 => canSub15,
                                  -5 => canSub5,
                                  _ => true,
                                };
                                final sign = minutes > 0 ? '+' : '-';
                                final absMinutes = minutes.abs();
                                final label =
                                    '$sign${i18n.tr('minutes_duration', {'count': absMinutes})}';
                                final alpha = enabled ? 1.0 : 0.4;
                                return Tooltip(
                                  message: label,
                                  child: Material(
                                    color: cs.surfaceContainerHighest
                                        .withValues(alpha: alpha),
                                    shape: StadiumBorder(
                                      side: BorderSide(
                                        color: cs.outlineVariant.withValues(
                                          alpha: alpha,
                                        ),
                                      ),
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: AppEntryInkWell(
                                      key: ValueKey('timer_extend_${minutes}m'),
                                      borderRadius: radius,
                                      onTap: enabled
                                          ? () {
                                              AppInteractionFeedback.trigger(
                                                AppInteractionFeedbackType
                                                    .selection,
                                              );
                                              ref
                                                  .read(timerFacadeProvider)
                                                  .extendCountdown(
                                                    Duration(minutes: minutes),
                                                  );
                                            }
                                          : null,
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: compact ? 10 : 12,
                                          vertical: compact ? 5 : 6,
                                        ),
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          softWrap: false,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelMedium
                                              ?.copyWith(
                                                color: cs.onSurfaceVariant
                                                    .withValues(alpha: alpha),
                                                fontWeight: FontWeight.w700,
                                                fontFeatures: const [
                                                  FontFeature.tabularFigures(),
                                                ],
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            if (timerExpired &&
                !showAutoResumeCountdown &&
                !timerState.stopAfterCurrentTrack) ...[
              Builder(
                builder: (context) {
                  final chips = <Widget>[
                    if (timerState.pausedSessionCount > 0)
                      _TimerSummaryChip(
                        icon: Icons.pause_circle_outline_rounded,
                        text: i18n.tr('paused_audio_count', {
                          'count': timerState.pausedSessionCount,
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
                  child: AppFixedExtentWheel(
                    value: value,
                    itemCount: max + 1,
                    labelAt: (index) => index.toString().padLeft(2, '0'),
                    looping: true,
                    selectionColor: cs.primaryContainer.withValues(alpha: 0.5),
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
              12,
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
