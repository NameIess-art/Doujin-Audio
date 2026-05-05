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
        borderRadius: BorderRadius.circular(18),
        onTap: () {
          Feedback.forTap(context);
          onChanged(mode);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          margin: EdgeInsets.only(bottom: compact ? 6 : 8),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: compact ? 10 : 12,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: selected
                  ? [
                      cs.primaryContainer.withValues(alpha: 0.96),
                      cs.primaryContainer.withValues(alpha: 0.72),
                    ]
                  : [
                      cs.surface.withValues(alpha: 0.94),
                      cs.surfaceContainerHigh.withValues(alpha: 0.84),
                    ],
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: 0.6)
                  : cs.outlineVariant.withValues(alpha: 0.8),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: cs.shadow.withValues(alpha: selected ? 0.12 : 0.05),
                blurRadius: selected ? 18 : 12,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: compact ? 22 : 24,
                height: compact ? 22 : 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected
                      ? cs.primary.withValues(alpha: 0.14)
                      : Colors.transparent,
                  border: Border.all(
                    color: selected ? cs.primary : cs.outline,
                    width: selected ? 7 : 2,
                  ),
                ),
              ),
              SizedBox(width: compact ? 8 : 10),
              Container(
                width: compact ? 30 : 34,
                height: compact ? 30 : 34,
                decoration: BoxDecoration(
                  color: selected
                      ? cs.primary.withValues(alpha: 0.12)
                      : cs.surfaceContainerHighest.withValues(alpha: 0.58),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: compact ? 18 : 20,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                ),
              ),
              SizedBox(width: compact ? 8 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: compact ? 14 : null,
                        fontWeight: FontWeight.w700,
                        color: selected ? cs.primary : null,
                      ),
                    ),
                    if (showSubtitle)
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: compact ? 10 : 11,
                          color: cs.onSurfaceVariant,
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
