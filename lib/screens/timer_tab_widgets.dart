part of 'timer_tab.dart';

class _ModeSelector extends StatelessWidget {
  const _ModeSelector({
    required this.value,
    required this.onChanged,
    this.showSubtitle = true,
    this.compact = false,
  });

  final TimerMode value;
  final ValueChanged<TimerMode> onChanged;
  final bool showSubtitle;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;

    Widget modeCard(
      TimerMode mode,
      String title,
      String subtitle,
      IconData icon,
    ) {
      final selected = value == mode;
      return InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          Feedback.forTap(context);
          onChanged(mode);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: EdgeInsets.only(bottom: compact ? 6 : 8),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: compact ? 10 : 12,
          ),
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer.withValues(alpha: 0.7) : cs.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? cs.primary.withValues(alpha: 0.5) : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: compact ? 30 : 36,
                height: compact ? 30 : 36,
                decoration: BoxDecoration(
                  color: selected
                      ? cs.primary
                      : cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: compact ? 16 : 18,
                  color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                ),
              ),
              SizedBox(width: compact ? 10 : 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: compact ? 13 : 15,
                        fontWeight: FontWeight.w800,
                        color: selected ? cs.onPrimaryContainer : cs.onSurface,
                      ),
                    ),
                    if (showSubtitle)
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: compact ? 10 : 11,
                          color: selected ? cs.onPrimaryContainer.withValues(alpha: 0.7) : cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded, color: cs.primary, size: 20),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        modeCard(
          TimerMode.manual,
          i18n.tr('manual_start'),
          i18n.tr('manual_start_subtitle'),
          Icons.play_circle_outline_rounded,
        ),
        modeCard(
          TimerMode.trigger,
          i18n.tr('auto_start_after_play'),
          i18n.tr('trigger_start_subtitle'),
          Icons.sensors_rounded,
        ),
      ],
    );
  }
}

class _TimerPanelCard extends StatelessWidget {
  const _TimerPanelCard({required this.child, this.accentColor});

  final Widget child;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = accentColor ?? cs.primary;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: cs.surfaceContainerLow.withValues(alpha: 0.6),
        border: accentColor == null
            ? null
            : Border.all(color: accent.withValues(alpha: 0.3), width: 1.5),
      ),
      child: child,
    );
  }
}

class _TimerSummaryChip extends StatelessWidget {
  const _TimerSummaryChip({
    required this.icon,
    required this.text,
    this.foregroundColor,
    this.backgroundColor,
    this.compact = false,
  });

  final IconData icon;
  final String text;
  final Color? foregroundColor;
  final Color? backgroundColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = foregroundColor ?? cs.onSurfaceVariant;
    final bg = backgroundColor ?? cs.surfaceContainerHighest;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 13 : 14, color: fg),
          SizedBox(width: compact ? 5 : 6),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: compact ? 180 : 220),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  (compact
                          ? Theme.of(context).textTheme.labelSmall
                          : Theme.of(context).textTheme.labelMedium)
                      ?.copyWith(color: fg, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _TimerSectionTitle extends StatelessWidget {
  const _TimerSectionTitle({
    required this.icon,
    required this.title,
    this.subtitle = '',
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: cs.onPrimaryContainer, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TimerFieldLabel extends StatelessWidget {
  const _TimerFieldLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 12, color: cs.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}
