part of 'timer_tab.dart';

extension _TimerTabDetailBody on _TimerTabState {
  Widget _buildCompactSheetFrame({required Widget child, Color? accentColor}) {
    return SizedBox.expand(
      child: _TimerPanelCard(accentColor: accentColor, child: child),
    );
  }

  Widget _buildCompactDetailPage({
    required BuildContext context,
    required AppLanguageProvider i18n,
    required AudioProvider provider,
    required ColorScheme cs,
    required bool timerExpired,
    required bool timerWaitingTrigger,
    required bool timerConfigured,
    required Future<void> Function() pickAutoResumeTime,
  }) {
    final backTooltip = MaterialLocalizations.of(context).backButtonTooltip;
    final detailAccent = timerExpired
        ? cs.error
        : timerWaitingTrigger
        ? cs.outline
        : cs.primary;

    return _buildCompactSheetFrame(
      accentColor: detailAccent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () {
                    Feedback.forTap(context);
                    HapticFeedback.selectionClick();
                    _setLocalState(() => _showCompactDetail = false);
                  },
                  tooltip: backTooltip,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _TimerSectionTitle(
                    icon: timerExpired
                        ? Icons.alarm_off_rounded
                        : timerWaitingTrigger
                        ? Icons.schedule_rounded
                        : Icons.timer_rounded,
                    title: timerExpired
                        ? i18n.tr('countdown_finished')
                        : timerWaitingTrigger
                        ? i18n.tr('waiting_to_start_countdown')
                        : i18n.tr('counting_down'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (timerConfigured)
              _CountdownCard(
                provider: provider,
                timerExpired: timerExpired,
                waitingTrigger: timerWaitingTrigger,
                fmtDuration: _fmtDuration,
                cs: cs,
                compact: true,
              )
            else
              const SizedBox.shrink(),
            const SizedBox(height: 8),
            DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: cs.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.restore_rounded,
                        size: 17,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        i18n.tr('auto_resume_after_timer'),
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Switch.adaptive(
                      value: provider.autoResumeEnabled,
                      onChanged: (value) {
                        HapticFeedback.selectionClick();
                        unawaited(
                          _setAutoResumeWithCapabilityCheck(
                            provider,
                            enabled: value,
                            hour: provider.autoResumeHour,
                            minute: provider.autoResumeMinute,
                            promptForCapability:
                                value && !provider.autoResumeEnabled,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            if (provider.autoResumeEnabled) ...[
              const SizedBox(height: 8),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: pickAutoResumeTime,
                  borderRadius: BorderRadius.circular(16),
                  child: Ink(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.alarm_rounded, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  i18n.tr('resume_time', {
                                    'time': _fmtClockTime(
                                      provider.autoResumeHour,
                                      provider.autoResumeMinute,
                                    ),
                                  }),
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            const Spacer(),
            if (timerConfigured)
              OutlinedButton.icon(
                onPressed: () {
                  Feedback.forTap(context);
                  HapticFeedback.mediumImpact();
                  provider.cancelTimer();
                  _setLocalState(() => _showCompactDetail = false);
                },
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(i18n.tr('cancel_timer')),
                style: OutlinedButton.styleFrom(
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: cs.error,
                  side: BorderSide(color: cs.error),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
