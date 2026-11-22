part of 'timer_tab.dart';

extension _TimerTabDetailBody on _TimerTabState {
  Widget _buildCompactSheetFrame({required Widget child, Color? accentColor}) {
    return SizedBox.expand(
      key: const ValueKey('timer_compact_panel'),
      child: _TimerPanelCard(accentColor: accentColor, child: child),
    );
  }

  Widget _buildCompactDetailPage({
    required BuildContext context,
    required AppLanguageProvider i18n,
    required TimerFacade timer,
    required TimerConfigurationUiState timerState,
    required ColorScheme cs,
    required bool timerExpired,
    required bool timerWaitingTrigger,
    required bool timerConfigured,
    required Future<void> Function() pickAutoResumeTime,
    DateTime? autoResumeAt,
  }) {
    final showAutoResumeCountdown = timerExpired && autoResumeAt != null;
    final tokens = AppDesignTokens.of(context);
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
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                primary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KeyedSubtree(
                      key: const ValueKey('timer_compact_title'),
                      child: _TimerSectionTitle(
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
                            ? i18n.tr(
                                timerState.stopAfterCurrentTrack
                                    ? 'waiting_for_track_end'
                                    : 'countdown_finished',
                              )
                            : timerWaitingTrigger
                            ? i18n.tr('waiting_to_start_countdown')
                            : i18n.tr('counting_down'),
                      ),
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
                    if (timerConfigured) ...[
                      const SizedBox(height: 8),
                      Material(
                        color: cs.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            tokens.radiusCard,
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: AppEntryInkWell(
                          onTap: () {
                            final nextValue = !timerState.autoResumeEnabled;
                            AppInteractionFeedback.trigger(
                              AppInteractionFeedbackType.selection,
                            );
                            unawaited(
                              _setAutoResumeWithCapabilityCheck(
                                timer,
                                enabled: nextValue,
                                hour: timerState.autoResumeHour,
                                minute: timerState.autoResumeMinute,
                                promptForCapability:
                                    nextValue && !timerState.autoResumeEnabled,
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: cs.primary.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(
                                      tokens.radiusSmall,
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
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
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
                      ),
                      if (timerState.autoResumeEnabled) ...[
                        const SizedBox(height: 8),
                        Material(
                          color: cs.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              tokens.radiusCard,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: AppEntryInkWell(
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
                                      color: cs.primary.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(
                                        tokens.radiusSmall,
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
                                    color: cs.onSurface.withValues(alpha: 0.5),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (!timerExpired) ...[
                        const SizedBox(height: 8),
                        Material(
                          color: cs.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              tokens.radiusCard,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: AppEntryInkWell(
                            onTap: () {
                              AppInteractionFeedback.trigger(
                                AppInteractionFeedbackType.selection,
                              );
                              timer.setStopAfterCurrentTrack(
                                !timerState.stopAfterCurrentTrack,
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: cs.primary.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(
                                        tokens.radiusSmall,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.music_note_rounded,
                                      size: 20,
                                      color: cs.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      i18n.tr('stop_after_current_track'),
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
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    value: timerState.stopAfterCurrentTrack,
                                    onChanged: (value) {
                                      AppInteractionFeedback.trigger(
                                        AppInteractionFeedbackType.selection,
                                      );
                                      timer.setStopAfterCurrentTrack(value);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ).withWindowsSmoothScroll(),
            ),
            const SizedBox(height: 12),
            if (timerConfigured)
              AppSecondaryButton(
                isDestructive: true,
                onPressed: () {
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.destructive,
                  );
                  timer.cancelTimer();
                  _setLocalState(() => _showCompactDetail = false);
                },
                icon: Icons.stop_circle_outlined,
                label: i18n.tr('cancel_timer'),
              ),
          ],
        ),
      ),
    );
  }
}
