part of 'timer_tab.dart';

extension _TimerTabBody on _TimerTabState {
  Widget _buildTimerTab(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    // Rebuild only on timer/auto-resume state changes, not playback/persistence events.
    final timerHash = context.select<AudioProvider, int>(
      (p) => Object.hash(
        p.timerMode,
        p.timerDuration,
        p.timerActive,
        p.timerRemaining,
        p.timerDraftMode,
        p.timerDraftDuration,
        p.autoResumeEnabled,
        p.autoResumeHour,
        p.autoResumeMinute,
        p.pausedByTimerPaths.length,
      ),
    );
    if (_lastTimerHash != timerHash) {
      _lastTimerHash = timerHash;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncDraftFromProvider(provider);
      });
    }
    final cs = Theme.of(context).colorScheme;
    final timerConfigured = provider.timerConfigured;
    final timerActive = provider.timerActive;
    final timerExpired = provider.timerExpired;
    final timerWaitingTrigger = provider.timerWaitingTrigger;
    final summaryDuration =
        provider.timerRemaining ?? provider.timerDuration ?? _pickedDuration;
    final summaryMode = provider.timerMode ?? _selectedMode;
    final draftModeTitle = _modeTitle(i18n, summaryMode);
    final showCompactOnly = widget.compactOnly;
    final showCompactDetail =
        showCompactOnly && _showCompactDetail && timerConfigured;
    Future<void> pickAutoResumeTime() async {
      unawaited(Feedback.forTap(context));
      final picked = await showTimePicker(
        context: context,
        initialTime: TimeOfDay(
          hour: provider.autoResumeHour,
          minute: provider.autoResumeMinute,
        ),
        helpText: i18n.tr('choose_auto_resume_time'),
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      );
      if (picked != null) {
        provider.setAutoResume(
          provider.autoResumeEnabled,
          picked.hour,
          picked.minute,
        );
      }
    }

    Widget buildConfiguratorSection({required bool compactMode}) {
      final content = Padding(
        padding: EdgeInsets.all(compactMode ? 14 : 18),
        child: Column(
          mainAxisSize: compactMode ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TimerSectionTitle(
              icon: Icons.timer_rounded,
              title: i18n.tr('set_countdown'),
              subtitle: compactMode ? '' : _modeSubtitle(i18n, _selectedMode),
            ),
            SizedBox(height: compactMode ? 12 : 16),
            _DurationPicker(
              hours: _hours,
              minutes: _minutes,
              seconds: _seconds,
              showLabels: !compactMode,
              onChanged: (h, m, s) => _setLocalState(() {
                _hours = h;
                _minutes = m;
                _seconds = s;
                _lastSyncedDraftKey = _draftKey(_selectedMode, _pickedDuration);
                provider.setTimerDraft(_selectedMode, _pickedDuration);
              }),
            ),
            SizedBox(height: compactMode ? 12 : 18),
            if (!compactMode) ...[
              _TimerFieldLabel(
                icon: Icons.tune_rounded,
                text: i18n.tr('start_mode'),
              ),
              const SizedBox(height: 8),
            ],
            _ModeSelector(
              value: _selectedMode,
              showSubtitle: !compactMode,
              compact: compactMode,
              onChanged: (mode) {
                HapticFeedback.selectionClick();
                final timerConfigured = provider.timerConfigured;
                if (timerConfigured && provider.timerMode != mode) {
                  provider.configureTimer(mode, _pickedDuration);
                  if (mode == TimerMode.manual) {
                    provider.startCountdown();
                  }
                } else {
                  provider.setTimerDraft(mode, _pickedDuration);
                }
                _setLocalState(() {
                  _selectedMode = mode;
                  _lastSyncedDraftKey = _draftKey(mode, _pickedDuration);
                });
              },
            ),
            if (compactMode) const Spacer(),
            SizedBox(height: compactMode ? 12 : 14),
            FilledButton.icon(
              onPressed: _durationIsZero
                  ? null
                  : () {
                      Feedback.forTap(context);
                      HapticFeedback.mediumImpact();
                      _onConfirm(provider);
                    },
              icon: Icon(
                _selectedMode == TimerMode.manual
                    ? Icons.play_arrow_rounded
                    : Icons.schedule_rounded,
              ),
              label: Text(
                _selectedMode == TimerMode.manual
                    ? i18n.tr('confirm_start_now')
                    : i18n.tr('confirm_wait_playback'),
              ),
              style: FilledButton.styleFrom(
                elevation: 0,
                shadowColor: Colors.transparent,
                minimumSize: Size.fromHeight(compactMode ? 50 : 56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
            ),
            if (_durationIsZero && !compactMode)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  i18n.tr('set_duration_first'),
                  style: TextStyle(color: cs.error, fontSize: 12),
                ),
              ),
          ],
        ),
      );

      if (compactMode) {
        return _buildCompactSheetFrame(child: content);
      }
      return _TimerPanelCard(child: content);
    }

    final compactContent = LayoutBuilder(
      builder: (context, constraints) {
        final compactHeight = constraints.maxHeight.isFinite
            ? math.min(500.0, constraints.maxHeight)
            : 500.0;

        return SizedBox(
          height: compactHeight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                final offsetTween = Tween<Offset>(
                  begin: Offset(showCompactDetail ? 0.04 : -0.04, 0),
                  end: Offset.zero,
                );
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: offsetTween.animate(animation),
                    child: child,
                  ),
                );
              },
              child: KeyedSubtree(
                key: ValueKey<bool>(showCompactDetail),
                child: showCompactDetail
                    ? _buildCompactDetailPage(
                        context: context,
                        i18n: i18n,
                        provider: provider,
                        cs: cs,
                        timerExpired: timerExpired,
                        timerWaitingTrigger: timerWaitingTrigger,
                        timerConfigured: timerConfigured,
                        pickAutoResumeTime: pickAutoResumeTime,
                      )
                    : buildConfiguratorSection(compactMode: true),
              ),
            ),
          ),
        );
      },
    );

    final topPadding = MediaQuery.paddingOf(context).top;

    final content = showCompactOnly
        ? compactContent
        : Stack(
            children: [
              ListView(
                padding: EdgeInsets.fromLTRB(
                  16,
                  widget.showHeader ? 82 + topPadding : 6,
                  16,
                  24,
                ),
                physics: const BouncingScrollPhysics(),
                children: [
                  if (!showCompactOnly) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _TimerSummaryChip(
                          icon: Icons.timer_outlined,
                          text: _fmtDuration(summaryDuration),
                        ),
                        _TimerSummaryChip(
                          icon: summaryMode == TimerMode.manual
                              ? Icons.play_arrow_rounded
                              : Icons.schedule_rounded,
                          text: draftModeTitle,
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (!showCompactOnly &&
                      (timerActive || timerExpired || timerWaitingTrigger)) ...[
                    _CountdownCard(
                      provider: provider,
                      timerExpired: timerExpired,
                      waitingTrigger: timerWaitingTrigger,
                      fmtDuration: _fmtDuration,
                      cs: cs,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (showCompactOnly ||
                      (!timerActive && !timerWaitingTrigger)) ...[
                    buildConfiguratorSection(compactMode: false),
                    if (!showCompactOnly) const SizedBox(height: 14),
                  ],
                  if (!showCompactOnly && timerConfigured) ...[
                    OutlinedButton.icon(
                      onPressed: () {
                        Feedback.forTap(context);
                        HapticFeedback.mediumImpact();
                        provider.cancelTimer();
                      },
                      icon: const Icon(Icons.cancel_outlined),
                      label: Text(i18n.tr('cancel_timer')),
                      style: OutlinedButton.styleFrom(
                        elevation: 0,
                        shadowColor: Colors.transparent,
                        foregroundColor: cs.error,
                        side: BorderSide(color: cs.error),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (!showCompactOnly && timerConfigured)
                    _TimerPanelCard(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SwitchListTile(
                              title: Text(i18n.tr('auto_resume_after_timer')),
                              subtitle: Text(i18n.tr('auto_resume_subtitle')),
                              secondary: const Icon(Icons.restore_rounded),
                              value: provider.autoResumeEnabled,
                              onChanged: (val) {
                                HapticFeedback.selectionClick();
                                provider.setAutoResume(
                                  val,
                                  provider.autoResumeHour,
                                  provider.autoResumeMinute,
                                );
                              },
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            if (provider.autoResumeEnabled) ...[
                              const Divider(height: 1),
                              ListTile(
                                leading: const Icon(Icons.alarm_rounded),
                                title: Text(
                                  i18n.tr('resume_time', {
                                    'time': _fmtClockTime(
                                      provider.autoResumeHour,
                                      provider.autoResumeMinute,
                                    ),
                                  }),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  i18n.tr('tap_choose_resume_time'),
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right_rounded,
                                ),
                                onTap: () async {
                                  unawaited(Feedback.forTap(context));
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay(
                                      hour: provider.autoResumeHour,
                                      minute: provider.autoResumeMinute,
                                    ),
                                    helpText: i18n.tr(
                                      'choose_auto_resume_time',
                                    ),
                                    builder: (ctx, child) => MediaQuery(
                                      data: MediaQuery.of(
                                        ctx,
                                      ).copyWith(alwaysUse24HourFormat: true),
                                      child: child!,
                                    ),
                                  );
                                  if (picked != null) {
                                    provider.setAutoResume(
                                      provider.autoResumeEnabled,
                                      picked.hour,
                                      picked.minute,
                                    );
                                  }
                                },
                                shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(
                                    bottom: Radius.circular(16),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  else if (!showCompactOnly)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        child: _TimerSummaryChip(
                          icon: Icons.info_outline_rounded,
                          text: i18n.tr('set_timer_to_enable_auto_resume'),
                        ),
                      ),
                    ),
                ],
              ),
              if (widget.showHeader && !showCompactOnly)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: TopPageHeader(
                    icon: Icons.timer_rounded,
                    title: i18n.tr('timer_title'),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    bottomSpacing: 16,
                  ),
                ),
            ],
          );

    if (widget.useSafeArea) {
      return SafeArea(child: content);
    }
    return content;
  }
}
