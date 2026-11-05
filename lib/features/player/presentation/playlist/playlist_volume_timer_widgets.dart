import 'package:flutter/material.dart';

import '../../../../core/media/time_text_formatters.dart';
import '../../../../core/widgets/app_feedback.dart';
import '../../../../core/widgets/target_countdown_builder.dart';
import '../../../../core/widgets/top_page_header.dart';
import 'playlist_shared_helpers.dart';

class TimerCountdownCapsule extends StatelessWidget {
  const TimerCountdownCapsule({
    super.key,
    required this.remaining,
    required this.active,
    required this.autoResumeAt,
    required this.onTap,
    this.onLongPress,
    this.showBackground = true,
  });

  final Duration remaining;
  final bool active;
  final DateTime? autoResumeAt;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showBackground;

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

        final content = Material(
          color: showBackground
              ? cs.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(19),
          child: InkWell(
            borderRadius: BorderRadius.circular(19),
            onTap: () {
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              );
              onTap?.call();
            },
            onLongPress: () {
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              );
              onLongPress?.call();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                    color: cs.primary,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    hasRemaining
                        ? formatDurationCompact(displayDuration)
                        : '00:00',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        return showBackground
            ? HeaderFloatingSurface(padding: EdgeInsets.zero, child: content)
            : SizedBox(height: 38, child: content);
      },
    );
  }
}

class TimecodeLabel extends StatelessWidget {
  const TimecodeLabel({
    super.key,
    required this.text,
    this.alignEnd = false,
    this.reserveText,
  });

  final String text;
  final bool alignEnd;
  final String? reserveText;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final label = Text(
      text,
      textAlign: alignEnd ? TextAlign.end : TextAlign.start,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: sessionDetailForeground(
          cs,
          SessionDetailForegroundLevel.muted,
          darkFallback: cs.onSurface.withValues(alpha: 0.8),
        ),
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        fontSize: 13,
        height: 1.1,
        // Inline labels reserve space by digit count. Outfit has tabular digits.
        fontFamily: reserveText == null ? null : 'Outfit',
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final reserved = reserveText;
    if (reserved == null) return label;
    return Stack(
      children: [
        // Keep a stable layout while the visible time changes its hour fields.
        // The zero-opacity template neither paints nor contributes semantics.
        Opacity(
          opacity: 0,
          child: Text(reserved, style: label.style, maxLines: 1),
        ),
        Positioned.fill(child: label),
      ],
    );
  }
}
