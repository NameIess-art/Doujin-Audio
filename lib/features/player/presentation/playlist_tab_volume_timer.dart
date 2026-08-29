part of 'playlist_tab.dart';

class _TimerCountdownCapsule extends StatelessWidget {
  const _TimerCountdownCapsule({
    required this.remaining,
    required this.active,
    required this.autoResumeAt,
    required this.onTap,
  });

  final Duration remaining;
  final bool active;
  final DateTime? autoResumeAt;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    // When auto-resume is pending, show the auto-resume countdown instead.
    final showAutoResume = autoResumeAt != null;

    return TargetCountdownBuilder(
      target: autoResumeAt,
      builder: (context, autoResumeRemaining) {
        final displayDuration = showAutoResume
            ? autoResumeRemaining
            : remaining;
        final hasRemaining = displayDuration > Duration.zero;

        return Material(
          color: cs.primaryContainer.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () {
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              );
              onTap?.call();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    showAutoResume
                        ? Icons.alarm_rounded
                        : active
                        ? Icons.timer_rounded
                        : hasRemaining
                        ? Icons.timer_rounded
                        : Icons.alarm_off_rounded,
                    size: 14,
                    color: cs.onPrimaryContainer,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    hasRemaining
                        ? formatDurationCompact(displayDuration)
                        : '00:00',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimecodeLabel extends StatelessWidget {
  const _TimecodeLabel({required this.text, this.alignEnd = false});

  final String text;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Text(
      text,
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: _sessionDetailForeground(
          cs,
          _SessionDetailForegroundLevel.muted,
          darkFallback: cs.onSurface.withValues(alpha: 0.8),
        ),
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        fontSize: 13,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
