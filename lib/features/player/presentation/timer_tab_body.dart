part of 'timer_tab.dart';

extension _TimerTabBody on _TimerTabState {
  Widget _buildTimerTab(BuildContext context) {
    ref.watch(appLanguageStateProvider);
    final i18n = ref.read(appLanguageProviderInstanceProvider);
    final timer = ref.read(timerFacadeProvider);
    final timerSlice = ref.watch(timerConfigurationUiProvider);
    _syncDraftFromState(timerSlice, timer);
    final cs = Theme.of(context).colorScheme;
    final timerConfigured = timerSlice.duration != null;
    final timerActive = timerSlice.active;
    final timerExpired = timerSlice.expired;
    final autoResumeCountdownTarget = _TimerTabState._timerRuntimeCalculator
        .autoResumeCountdownTarget(
          timerExpired: timerExpired && !timerSlice.stopAfterCurrentTrack,
          autoResumeEnabled: timerSlice.autoResumeEnabled,
          autoResumeAt: timerSlice.autoResumeAt,
          hour: timerSlice.autoResumeHour,
          minute: timerSlice.autoResumeMinute,
          now: DateTime.now(),
        );
    final timerWaitingTrigger = timerSlice.waitingTrigger;
    final summaryMode = timerExpired
        ? _selectedMode
        : (timerSlice.mode ?? _selectedMode);
    final draftModeTitle = _modeTitle(i18n, summaryMode);
    final showCompactOnly = widget.compactOnly;
    final showCompactDetail =
        showCompactOnly && _showCompactDetail && timerConfigured;
    Future<TimeOfDay?> showAutoResumeTimePicker() {
      return showAppDialog<TimeOfDay>(
        context: context,
        builder: (ctx) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(
            alwaysUse24HourFormat: true,
            gestureSettings: const DeviceGestureSettings(touchSlop: 4),
          ),
          child: TimePickerDialog(
            initialTime: TimeOfDay(
              hour: timerSlice.autoResumeHour,
              minute: timerSlice.autoResumeMinute,
            ),
            helpText: i18n.tr('choose_auto_resume_time'),
          ),
        ),
      );
    }

    Future<void> pickAutoResumeTime() async {
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

          if (status == null) {
            return OperationStatusBanner(
              label: i18n.tr('operation_failed_retry'),
              tone: OperationStatusTone.error,
              onRetry: _refreshReliabilityStatus,
              retryTooltip: i18n.tr('retry'),
            );
          }
          final toneColor = status.isStronglyReliable ? cs.primary : cs.error;
          final summary = status.isStronglyReliable
              ? i18n.tr('timer_reliability_ready')
              : i18n.tr('timer_reliability_missing');
          final detail = [
            status.exactAlarmsEnabled
                ? i18n.tr('exact_alarm_permission_ready')
                : i18n.tr('exact_alarm_permission_missing'),
            status.backgroundRunAllowed
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
                      Icon(
                        status.isStronglyReliable
                            ? Icons.verified_user_rounded
                            : Icons.gpp_maybe_rounded,
                        color: toneColor,
                      ),
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
                  if (!status.isStronglyReliable) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!status.exactAlarmsEnabled)
                          AppPillButton.outlined(
                            onPressed: () {
                              unawaited(_openExactAlarmSettings());
                            },
                            child: Text(i18n.tr('open_exact_alarm_settings')),
                          ),
                        if (!status.backgroundRunAllowed)
                          AppPillButton.outlined(
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
      final sectionChildren = [
        KeyedSubtree(
          key: const ValueKey('timer_compact_title'),
          child: _TimerSectionTitle(
            icon: Icons.timer_rounded,
            title: i18n.tr('set_countdown'),
            subtitle: compactMode ? '' : _modeSubtitle(i18n, _selectedMode),
          ),
        ),
        SizedBox(height: compactMode ? 8 : 16),
        _DurationPicker(
          hours: _hours,
          minutes: _minutes,
          seconds: _seconds,
          showLabels: !compactMode,
          onChanged: (h, m, s) => _setLocalState(() {
            _hours = h;
            _minutes = m;
            _seconds = s;
            _commitLocalDraft(timer, _selectedMode, _pickedDuration);
          }),
        ),
        SizedBox(height: compactMode ? 8 : 14),
        if (!compactMode) ...[
          _TimerFieldLabel(
            icon: Icons.bolt_rounded,
            text: i18n.tr('timer_presets_label'),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final minutes in const [15, 30, 45, 60])
              Builder(
                builder: (context) {
                  final presetDuration = Duration(minutes: minutes);
                  final selected = _pickedDuration == presetDuration;
                  final radius = BorderRadius.circular(999);
                  return Material(
                    color: selected
                        ? cs.primaryContainer
                        : cs.surfaceContainerHighest,
                    shape: StadiumBorder(
                      side: BorderSide(
                        color: selected ? cs.primary : cs.outlineVariant,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: AppEntryInkWell(
                      key: ValueKey('timer_preset_${minutes}m'),
                      borderRadius: radius,
                      onTap: () {
                        AppInteractionFeedback.trigger(
                          AppInteractionFeedbackType.selection,
                        );
                        final nextHours = presetDuration.inHours;
                        final nextMinutes = presetDuration.inMinutes.remainder(
                          60,
                        );
                        _setLocalState(() {
                          _hours = nextHours;
                          _minutes = nextMinutes;
                          _seconds = 0;
                          _commitLocalDraft(
                            timer,
                            _selectedMode,
                            presetDuration,
                          );
                        });
                      },
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compactMode ? 12 : 14,
                          vertical: compactMode ? 5 : 6,
                        ),
                        child: Text(
                          i18n.tr('minutes_duration', {'count': minutes}),
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: selected
                                    ? cs.onPrimaryContainer
                                    : cs.onSurfaceVariant,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
        SizedBox(height: compactMode ? 8 : 18),
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
            if (_selectedMode != mode) {
              AppInteractionFeedback.trigger(
                AppInteractionFeedbackType.selection,
              );
            }
            _setLocalState(() {
              _selectedMode = mode;
              _commitLocalDraft(timer, mode, _pickedDuration);
            });
          },
        ),
      ];
      final confirmButton = AppLabelledButton(
        FilledButton.icon,
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
              : Icons.sensors_rounded,
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
      );

      Widget content = Padding(
        padding: EdgeInsets.all(compactMode ? 14 : 18),
        child: compactMode
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      primary: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: sectionChildren,
                      ),
                    ).withWindowsSmoothScroll(),
                  ),
                  const SizedBox(height: 12),
                  confirmButton,
                  AnimatedSectionReveal(
                    visible: _durationIsZero,
                    builder: (context) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        i18n.tr('set_duration_first'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.error, fontSize: 12),
                      ),
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...sectionChildren,
                  const SizedBox(height: 14),
                  confirmButton,
                  AnimatedSectionReveal(
                    visible: _durationIsZero,
                    builder: (context) => Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        i18n.tr('set_duration_first'),
                        style: TextStyle(color: cs.error, fontSize: 12),
                      ),
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
            ? math.min(kTimerCompactPanelHeight, constraints.maxHeight)
            : kTimerCompactPanelHeight;

        return SizedBox(
          height: compactHeight,
          child: AppMenuContentTransition(
            primary: buildConfiguratorSection(compactMode: true),
            secondary: showCompactDetail
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
                : null,
          ),
        );
      },
    );

    final timerTopInset = widget.showHeader
        ? AppPageHeaderMetrics.contentTopInset(context)
        : 0.0;

    final content = showCompactOnly
        ? compactContent
        : PageHeaderInset(
            topInset: timerTopInset,
            child: Stack(
              children: [
                AppPageContentTransition(
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      widget.showHeader ? timerTopInset : 6,
                      16,
                      MediaQuery.paddingOf(context).bottom +
                          MobileOverlayInset.of(context) +
                          24,
                    ),
                    physics: const ClampingScrollPhysics(),
                    children: [
                      if (!showCompactOnly) ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Consumer(
                              builder: (context, ref, _) {
                                final remaining =
                                    ref.watch(
                                      timerStateProvider.select(
                                        (state) => state.value?.remaining,
                                      ),
                                    ) ??
                                    ref
                                        .read(timerFacadeProvider)
                                        .state
                                        .remaining;
                                return _TimerSummaryChip(
                                  icon: Icons.timer_outlined,
                                  text: _fmtDuration(
                                    remaining ??
                                        timerSlice.duration ??
                                        _pickedDuration,
                                  ),
                                );
                              },
                            ),
                            _TimerSummaryChip(
                              icon: summaryMode == TimerMode.manual
                                  ? Icons.play_arrow_rounded
                                  : Icons.sensors_rounded,
                              text: draftModeTitle,
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                      ],
                      AppDeferredFade(
                        visible:
                            !showCompactOnly &&
                            (timerActive ||
                                timerExpired ||
                                timerWaitingTrigger),
                        child: Column(
                          children: [
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
                        ),
                      ),
                      AppDeferredFade(
                        visible:
                            !showCompactOnly &&
                            (timerConfigured || timerSlice.autoResumeEnabled),
                        child: Column(
                          children: [
                            if (defaultTargetPlatform != TargetPlatform.windows)
                              buildReliabilityCard(),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                      AppDeferredFade(
                        visible:
                            showCompactOnly ||
                            (!timerActive && !timerWaitingTrigger),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            buildConfiguratorSection(compactMode: false),
                            if (!showCompactOnly) const SizedBox(height: 14),
                          ],
                        ),
                      ),
                      AppDeferredFade(
                        visible: !showCompactOnly && timerConfigured,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AppSecondaryButton(
                              isDestructive: true,
                              onPressed: () {
                                AppInteractionFeedback.trigger(
                                  AppInteractionFeedbackType.destructive,
                                );
                                timer.cancelTimer();
                              },
                              icon: Icons.stop_circle_outlined,
                              label: i18n.tr('cancel_timer'),
                            ),
                            const SizedBox(height: 14),
                          ],
                        ),
                      ),
                      AppDeferredFade(
                        visible: !showCompactOnly && timerConfigured,
                        child: _TimerPanelCard(
                          child: Theme(
                            data: AppEntryInkWell.entryTheme(context),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                SwitchListTile(
                                  title: Text(
                                    i18n.tr('auto_resume_after_timer'),
                                  ),
                                  subtitle: Text(
                                    i18n.tr('auto_resume_subtitle'),
                                  ),
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
                                            value &&
                                            !timerSlice.autoResumeEnabled,
                                      ),
                                    );
                                  },
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                AppDeferredFade(
                                  visible: timerSlice.autoResumeEnabled,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const SizedBox(height: 4),
                                      ListTile(
                                        leading: const Icon(
                                          Icons.alarm_rounded,
                                        ),
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
                                  ),
                                ),
                                AppDeferredFade(
                                  visible: !timerExpired,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const Divider(height: 1),
                                      SwitchListTile(
                                        title: Text(
                                          i18n.tr('stop_after_current_track'),
                                        ),
                                        subtitle: Text(
                                          i18n.tr(
                                            'stop_after_current_track_subtitle',
                                          ),
                                        ),
                                        secondary: const Icon(
                                          Icons.music_note_rounded,
                                        ),
                                        value: timerSlice.stopAfterCurrentTrack,
                                        onChanged: (value) {
                                          AppInteractionFeedback.trigger(
                                            AppInteractionFeedbackType
                                                .selection,
                                          );
                                          timer.setStopAfterCurrentTrack(value);
                                        },
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      AppDeferredFade(
                        visible: !showCompactOnly && !timerConfigured,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            child: _TimerSummaryChip(
                              icon: Icons.info_outline_rounded,
                              text: i18n.tr('set_timer_to_enable_auto_resume'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ).withWindowsSmoothScroll(),
                ),
                if (widget.showHeader && !showCompactOnly)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: TopPageHeader(
                      icon: Icons.timer_rounded,
                      title: i18n.tr('timer_title'),
                    ),
                  ),
              ],
            ),
          );

    if (widget.useSafeArea) {
      return SafeArea(
        top: !widget.showHeader || showCompactOnly,
        child: content,
      );
    }
    return content;
  }
}
