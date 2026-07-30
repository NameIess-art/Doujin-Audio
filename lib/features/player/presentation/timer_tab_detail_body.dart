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
    required TimerFacade timer,
    required TimerStateSliceData timerState,
    required ColorScheme cs,
    required bool timerExpired,
    required bool timerWaitingTrigger,
    required bool timerConfigured,
    required Future<void> Function() pickAutoResumeTime,
    DateTime? autoResumeAt,
  }) {
    final showAutoResumeCountdown = timerExpired && autoResumeAt != null;
    final detailAccent = showAutoResumeCountdown
        ? cs.primary
        : timerExpired
        ? cs.error
        : timerWaitingTrigger
        ? cs.outline
        : cs.primary;

    return _buildCompactSheetFrame(
      accentColor: detailAccent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TimerSectionTitle(
                        icon: showAutoResumeCountdown
                            ? Icons.timer_rounded
                            : timerExpired
                            ? Icons.alarm_off_rounded
                            : timerWaitingTrigger
                            ? Icons.schedule_rounded
                            : Icons.timer_rounded,
                        title: showAutoResumeCountdown
                            ? i18n.tr('waiting_for_auto_resume')
                            : timerExpired
                            ? i18n.tr('countdown_finished')
                            : timerWaitingTrigger
                            ? i18n.tr('waiting_to_start_countdown')
                            : i18n.tr('counting_down'),
                      ),
                      const SizedBox(height: 10),
                      if (timerConfigured)
                        _CountdownCard(
                          timerState: timerState,
                          timerExpired: timerExpired,
                          waitingTrigger: timerWaitingTrigger,
                          fmtDuration: _fmtDuration,
                          cs: cs,
                          autoResumeAt: autoResumeAt,
                          compact: true,
                        )
                      else
                        const SizedBox.shrink(),
                      if (!showAutoResumeCountdown) ...[
                        const SizedBox(height: 8),
                        Container(
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerLow,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: cs.primary.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(
                                      AppDesignTokens.of(context).radiusSmall,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.restore_rounded,
                                    size: 20,
                                    color: cs.primary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    i18n.tr('auto_resume_after_timer'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14,
                                        ),
                                  ),
                                ),
                                Switch.adaptive(
                                  value: timerState.autoResumeEnabled,
                                  onChanged: (value) {
                                    AppInteractionFeedback.trigger(
                                      AppInteractionFeedbackType.selection,
                                    );
                                    unawaited(
                                      _setAutoResumeWithCapabilityCheck(
                                        timer,
                                        enabled: value,
                                        hour: timerState.autoResumeHour,
                                        minute: timerState.autoResumeMinute,
                                        promptForCapability:
                                            value &&
                                            !timerState.autoResumeEnabled,
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (timerState.autoResumeEnabled) ...[
                          const SizedBox(height: 8),
                          Material(
                            color: cs.surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: pickAutoResumeTime,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                        color: cs.primary.withValues(
                                          alpha: 0.12,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          AppDesignTokens.of(
                                            context,
                                          ).radiusSmall,
                                        ),
                                      ),
                                      child: Icon(
                                        Icons.alarm_rounded,
                                        size: 20,
                                        color: cs.primary,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        i18n.tr('resume_time', {
                                          'time': _fmtClockTime(
                                            timerState.autoResumeHour,
                                            timerState.autoResumeMinute,
                                          ),
                                        }),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 14,
                                            ),
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      size: 20,
                                      color: cs.onSurface.withValues(
                                        alpha: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                      const Spacer(),
                      if (timerConfigured)
                        OutlinedButton.icon(
                          onPressed: () {
                            AppInteractionFeedback.trigger(
                              AppInteractionFeedbackType.destructive,
                            );
                            timer.cancelTimer();
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
                            shape: const StadiumBorder(),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
