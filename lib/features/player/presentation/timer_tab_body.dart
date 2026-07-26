part of 'timer_tab.dart';

extension _TimerTabBody on _TimerTabState {
  Widget _buildTimerTab(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final timer = ref.read(timerFacadeProvider);
    final timerSlice =
        ref.watch(timerStateProvider).value ?? TimerStateSliceData();
    // Rebuild only on timer/auto-resume state changes, not playback/persistence events.
    final timerHash = Object.hash(
      timerSlice.mode,
      timerSlice.duration,
      timerSlice.active,
      timerSlice.remaining,
      timerSlice.draftMode,
      timerSlice.draftDuration,
      timerSlice.autoResumeEnabled,
      timerSlice.autoResumeHour,
      timerSlice.autoResumeMinute,
      timerSlice.pausedByTimerSessionIds.length,
    );
    if (_lastTimerHash != timerHash) {
      _lastTimerHash = timerHash;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncDraftFromState(timerSlice);
      });
    }
    final cs = Theme.of(context).colorScheme;
    final timerConfigured = timerSlice.duration != null;
    final timerActive = timerSlice.active;
    final timerExpired =
        timerConfigured &&
        !timerSlice.active &&
        timerSlice.remaining != null &&
        timerSlice.remaining! <= Duration.zero;
    final autoResumeCountdownTarget = _TimerTabState._timerRuntimeCalculator
        .autoResumeCountdownTarget(
          timerExpired: timerExpired,
          autoResumeEnabled: timerSlice.autoResumeEnabled,
          autoResumeAt: timerSlice.autoResumeAt,
          hour: timerSlice.autoResumeHour,
          minute: timerSlice.autoResumeMinute,
          now: DateTime.now(),
        );
    final timerWaitingTrigger =
        timerConfigured &&
        !timerExpired &&
        !timerSlice.active &&
        timerSlice.mode == TimerMode.trigger &&
        timerSlice.remaining != null &&
        timerSlice.remaining! > Duration.zero;
    final summaryDuration =
        timerSlice.remaining ?? timerSlice.duration ?? _pickedDuration;
    final summaryMode = timerSlice.mode ?? _selectedMode;
    final draftModeTitle = _modeTitle(i18n, summaryMode);
    final showCompactOnly = widget.compactOnly;
    final showCompactDetail =
        showCompactOnly && _showCompactDetail && timerConfigured;
    Future<TimeOfDay?> showAutoResumeTimePicker() {
      return showTimePicker(
        context: context,
        initialTime: TimeOfDay(
          hour: timerSlice.autoResumeHour,
          minute: timerSlice.autoResumeMinute,
        ),
        helpText: i18n.tr('choose_auto_resume_time'),
        builder: (ctx, child) {
          final mediaQuery = MediaQuery.of(ctx);
          return MediaQuery(
            data: mediaQuery.copyWith(
              alwaysUse24HourFormat: true,
              gestureSettings: const DeviceGestureSettings(touchSlop: 4),
            ),
            child: child!,
          );
        },
      );
    }

    Future<void> pickAutoResumeTime() async {
      unawaited(
        AppInteractionFeedback.trigger(
          AppInteractionFeedbackType.tap,
          context: context,
        ),
      );
      final picked = await showAutoResumeTimePicker();
      if (picked != null) {
        timer.setAutoResume(
          timerSlice.autoResumeEnabled,
          picked.hour,
          picked.minute,
        );
      }
    }

    Widget buildReliabilityCard() {
      return FutureBuilder<_TimerReliabilityStatus>(
        future: _reliabilityStatusFuture,
        builder: (context, snapshot) {
          final status = snapshot.data;
          if (snapshot.connectionState != ConnectionState.done &&
              status == null) {
            return _TimerPanelCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(i18n.tr('timer_reliability_checking')),
                    ),
                  ],
                ),
              ),
            );
          }

          final resolvedStatus =
              status ??
              const _TimerReliabilityStatus(
                notificationsEnabled: true,
                exactAlarmsEnabled: true,
                backgroundRunAllowed: true,
              );
          final toneColor = resolvedStatus.isStronglyReliable
              ? cs.primary
              : cs.error;
          final summary = resolvedStatus.isStronglyReliable
              ? i18n.tr('timer_reliability_ready')
              : i18n.tr('timer_reliability_missing');
          final detail = [
            resolvedStatus.notificationsEnabled
                ? i18n.tr('notification_permission_ready')
                : i18n.tr('notification_permission_missing'),
            resolvedStatus.exactAlarmsEnabled
                ? i18n.tr('exact_alarm_permission_ready')
                : i18n.tr('exact_alarm_permission_missing'),
            resolvedStatus.backgroundRunAllowed
                ? i18n.tr('allow_background_run_ready')
                : i18n.tr('allow_background_run_subtitle'),
          ].join('\n');

          return _TimerPanelCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.verified_user_rounded, color: toneColor),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          summary,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(detail, style: Theme.of(context).textTheme.bodySmall),
                  if (!resolvedStatus.isStronglyReliable) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!resolvedStatus.notificationsEnabled)
                          OutlinedButton(
                            onPressed: () {
                              unawaited(_openNotificationSettings());
                            },
                            child: Text(i18n.tr('open_notification_settings')),
                          ),
                        if (!resolvedStatus.exactAlarmsEnabled)
                          OutlinedButton(
                            onPressed: () {
                              unawaited(_openExactAlarmSettings());
                            },
                            child: Text(i18n.tr('open_exact_alarm_settings')),
                          ),
                        if (!resolvedStatus.backgroundRunAllowed)
                          OutlinedButton(
                            onPressed: () {
                              unawaited(_openBackgroundRunSettings());
                            },
                            child: Text(i18n.tr('allow_background_run')),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
    }

    Widget buildConfiguratorSection({required bool compactMode}) {
      final children = [
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
            timer.setTimerDraft(_selectedMode, _pickedDuration);
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
            AppInteractionFeedback.trigger(
              AppInteractionFeedbackType.selection,
            );
            if (timerConfigured && timerSlice.mode != mode) {
              timer.configureTimer(mode, _pickedDuration);
              if (mode == TimerMode.manual) {
                timer.startCountdown();
              }
            } else {
              timer.setTimerDraft(mode, _pickedDuration);
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
                  AppInteractionFeedback.trigger(
                    AppInteractionFeedbackType.confirmation,
                  );
                  _onConfirm(timer);
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
            shape: const StadiumBorder(),
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
      ];

      Widget content = Padding(
        padding: EdgeInsets.all(compactMode ? 14 : 18),
        child: compactMode
            ? LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: children,
                        ),
                      ),
                    ),
                  );
                },
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
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
            child: KeyedSubtree(
              key: ValueKey<bool>(showCompactDetail),
              child: showCompactDetail
                  ? _buildCompactDetailPage(
                      context: context,
                      i18n: i18n,
                      timer: timer,
                      timerState: timerSlice,
                      cs: cs,
                      timerExpired: timerExpired,
                      timerWaitingTrigger: timerWaitingTrigger,
                      timerConfigured: timerConfigured,
                      pickAutoResumeTime: pickAutoResumeTime,
                      autoResumeAt: autoResumeCountdownTarget,
                    )
                  : buildConfiguratorSection(compactMode: true),
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
                physics: const ClampingScrollPhysics(),
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
                      timerState: timerSlice,
                      timerExpired: timerExpired,
                      waitingTrigger: timerWaitingTrigger,
                      fmtDuration: _fmtDuration,
                      cs: cs,
                      autoResumeAt: autoResumeCountdownTarget,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (!showCompactOnly &&
                      (timerConfigured || timerSlice.autoResumeEnabled)) ...[
                    buildReliabilityCard(),
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
                        AppInteractionFeedback.trigger(
                          AppInteractionFeedbackType.destructive,
                        );
                        timer.cancelTimer();
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
                              value: timerSlice.autoResumeEnabled,
                              onChanged: (value) {
                                AppInteractionFeedback.trigger(
                                  AppInteractionFeedbackType.selection,
                                );
                                unawaited(
                                  _setAutoResumeWithCapabilityCheck(
                                    timer,
                                    enabled: value,
                                    hour: timerSlice.autoResumeHour,
                                    minute: timerSlice.autoResumeMinute,
                                    promptForCapability:
                                        value && !timerSlice.autoResumeEnabled,
                                  ),
                                );
                              },
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            if (timerSlice.autoResumeEnabled) ...[
                              const SizedBox(height: 4),
                              ListTile(
                                leading: const Icon(Icons.alarm_rounded),
                                title: Text(
                                  i18n.tr('resume_time', {
                                    'time': _fmtClockTime(
                                      timerSlice.autoResumeHour,
                                      timerSlice.autoResumeMinute,
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
                                  unawaited(
                                    AppInteractionFeedback.trigger(
                                      AppInteractionFeedbackType.tap,
                                      context: context,
                                    ),
                                  );
                                  final picked =
                                      await showAutoResumeTimePicker();
                                  if (picked != null) {
                                    timer.setAutoResume(
                                      timerSlice.autoResumeEnabled,
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
