import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../widgets/top_page_header.dart';

class TimerTab extends StatefulWidget {
  const TimerTab({
    super.key,
    this.showHeader = true,
    this.useSafeArea = true,
    this.compactOnly = false,
    this.initialCompactDetail = false,
  });

  final bool showHeader;
  final bool useSafeArea;
  final bool compactOnly;
  final bool initialCompactDetail;

  @override
  State<TimerTab> createState() => _TimerTabState();
}

class _TimerTabState extends State<TimerTab> {
  int _hours = 0;
  int _minutes = 30;
  int _seconds = 0;
  TimerMode _selectedMode = TimerMode.manual;
  bool _showCompactDetail = false;
  bool _draftInitialized = false;
  String? _lastSyncedDraftKey;
  int _lastTimerHash = 0;

  @override
  void initState() {
    super.initState();
    _showCompactDetail = widget.initialCompactDetail;
  }

  Duration get _pickedDuration =>
      Duration(hours: _hours, minutes: _minutes, seconds: _seconds);

  bool get _durationIsZero => _pickedDuration == Duration.zero;

  String _draftKey(TimerMode mode, Duration duration) =>
      '${mode.index}:${duration.inSeconds}';

  void _syncDraftFromProvider(AudioProvider provider) {
    final duration =
        provider.timerDuration ??
        provider.timerRemaining ??
        provider.timerDraftDuration;
    final mode = provider.timerMode ?? provider.timerDraftMode;
    final key = _draftKey(mode, duration);
    if (_draftInitialized && _lastSyncedDraftKey == key) {
      return;
    }
    _draftInitialized = true;
    _lastSyncedDraftKey = key;
    final nextHours = duration.inHours;
    final nextMinutes = duration.inMinutes.remainder(60);
    final nextSeconds = duration.inSeconds.remainder(60);
    if (_hours == nextHours &&
        _minutes == nextMinutes &&
        _seconds == nextSeconds &&
        _selectedMode == mode) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _hours = nextHours;
        _minutes = nextMinutes;
        _seconds = nextSeconds;
        _selectedMode = mode;
      });
    });
  }

  String _fmtClockTime(int h, int m) =>
      '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _onConfirm(AudioProvider provider) {
    if (_durationIsZero) return;
    provider.configureTimer(_selectedMode, _pickedDuration);
    if (_selectedMode == TimerMode.manual) {
      provider.startCountdown();
    }
    if (widget.compactOnly && mounted) {
      setState(() => _showCompactDetail = true);
    }
  }

  String _modeTitle(AppLanguageProvider i18n, TimerMode mode) {
    return mode == TimerMode.manual
        ? i18n.tr('manual_start')
        : i18n.tr('auto_start_after_play');
  }

  String _modeSubtitle(AppLanguageProvider i18n, TimerMode mode) {
    return mode == TimerMode.manual
        ? i18n.tr('manual_start_subtitle')
        : i18n.tr('trigger_start_subtitle');
  }

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final provider = context.read<AudioProvider>();
    // Rebuild only on timer/auto-resume state changes, not playback/persistence events.
    final timerHash = context.select<AudioProvider, int>((p) => Object.hash(
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
    ));
    if (_lastTimerHash != timerHash) {
      _lastTimerHash = timerHash;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncDraftFromProvider(provider);
      });
    }
    final cs = Theme.of(context).colorScheme;
    final timerConfigured = provider.timerDuration != null;
    final timerActive = provider.timerActive;
    final timerExpired =
        timerConfigured &&
        !timerActive &&
        provider.timerRemaining != null &&
        provider.timerRemaining! <= Duration.zero;
    final timerWaitingTrigger =
        timerConfigured &&
        !timerActive &&
        !timerExpired &&
        provider.timerMode == TimerMode.trigger &&
        provider.timerRemaining != null &&
        provider.timerRemaining! > Duration.zero;
    final summaryDuration =
        provider.timerRemaining ?? provider.timerDuration ?? _pickedDuration;
    final summaryMode = provider.timerMode ?? _selectedMode;
    final draftModeTitle = _modeTitle(i18n, summaryMode);
    final showCompactOnly = widget.compactOnly;
    final showCompactDetail =
        showCompactOnly && _showCompactDetail && timerConfigured;
    Future<void> pickAutoResumeTime() async {
      Feedback.forTap(context);
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

    Widget buildCompactSheetFrame({required Widget child, Color? accentColor}) {
      return SizedBox.expand(
        child: _TimerPanelCard(accentColor: accentColor, child: child),
      );
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
              onChanged: (h, m, s) => setState(() {
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
                final timerConfigured = provider.timerDuration != null;
                if (timerConfigured && provider.timerMode != mode) {
                  provider.configureTimer(mode, _pickedDuration);
                  if (mode == TimerMode.manual) {
                    provider.startCountdown();
                  }
                } else {
                  provider.setTimerDraft(mode, _pickedDuration);
                }
                setState(() {
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
        return buildCompactSheetFrame(child: content);
      }
      return _TimerPanelCard(child: content);
    }

    Widget buildCompactDetailPage() {
      final backTooltip = MaterialLocalizations.of(context).backButtonTooltip;
      final detailAccent = timerExpired
          ? cs.error
          : timerWaitingTrigger
          ? cs.outline
          : cs.primary;

      return buildCompactSheetFrame(
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
                      setState(() => _showCompactDetail = false);
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
                      subtitle: '',
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
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      cs.surface.withValues(alpha: 0.9),
                      cs.surfaceContainerHigh.withValues(alpha: 0.82),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.72),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHighest.withValues(
                            alpha: 0.72,
                          ),
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
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Switch.adaptive(
                        value: provider.autoResumeEnabled,
                        onChanged: (value) {
                          HapticFeedback.selectionClick();
                          provider.setAutoResume(
                            value,
                            provider.autoResumeHour,
                            provider.autoResumeMinute,
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
                        color: cs.surfaceContainerHighest.withValues(
                          alpha: 0.54,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.56),
                        ),
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
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
                    setState(() => _showCompactDetail = false);
                  },
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(i18n.tr('cancel_timer')),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    foregroundColor: cs.error,
                    side: BorderSide(color: cs.error.withValues(alpha: 0.52)),
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
                    ? buildCompactDetailPage()
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
                        foregroundColor: cs.error,
                        side: BorderSide(color: cs.error.withValues(alpha: 0.6)),
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
                                subtitle: Text(i18n.tr('tap_choose_resume_time')),
                                trailing: const Icon(Icons.chevron_right_rounded),
                                onTap: () async {
                                  Feedback.forTap(context);
                                  final picked = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay(
                                      hour: provider.autoResumeHour,
                                      minute: provider.autoResumeMinute,
                                    ),
                                    helpText: i18n.tr('choose_auto_resume_time'),
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
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            cs.surface.withValues(alpha: 0.94),
            cs.surfaceContainerHigh.withValues(alpha: 0.86),
          ],
        ),
        border: Border.all(color: accent.withValues(alpha: 0.18), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
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
    final bg =
        backgroundColor ?? cs.surfaceContainerHighest.withValues(alpha: 0.64);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.12)),
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
            color: cs.primaryContainer.withValues(alpha: 0.9),
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

class _CountdownCard extends StatelessWidget {
  const _CountdownCard({
    required this.provider,
    required this.timerExpired,
    required this.waitingTrigger,
    required this.fmtDuration,
    required this.cs,
    this.compact = false,
  });

  final AudioProvider provider;
  final bool timerExpired;
  final bool waitingTrigger;
  final String Function(Duration) fmtDuration;
  final ColorScheme cs;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final remaining = provider.timerRemaining ?? Duration.zero;
    final title = timerExpired
        ? i18n.tr('countdown_finished')
        : waitingTrigger
        ? i18n.tr('waiting_to_start_countdown')
        : i18n.tr('counting_down');
    final accent = timerExpired
        ? cs.error
        : waitingTrigger
        ? cs.onSurfaceVariant
        : cs.primary;
    final timeColor = timerExpired
        ? cs.error
        : waitingTrigger
        ? cs.onSurface
        : cs.onPrimaryContainer;

    return _TimerPanelCard(
      accentColor: accent,
      child: Padding(
        padding: EdgeInsets.all(compact ? 14 : 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!compact) ...[
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      timerExpired
                          ? Icons.alarm_off_rounded
                          : waitingTrigger
                          ? Icons.schedule_rounded
                          : Icons.timer_rounded,
                      size: 24,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
            ],
            Center(
              child: Text(
                fmtDuration(remaining),
                style: TextStyle(
                  fontSize: compact ? 32 : 46,
                  fontWeight: FontWeight.bold,
                  letterSpacing: compact ? 1.4 : 2.6,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: timeColor,
                ),
              ),
            ),
            if (timerExpired) ...[
              Builder(
                builder: (context) {
                  final chips = <Widget>[
                    if (provider.pausedByTimerPaths.isNotEmpty)
                      _TimerSummaryChip(
                        icon: Icons.pause_circle_outline_rounded,
                        text: i18n.tr('paused_audio_count', {
                          'count': provider.pausedByTimerPaths.length,
                        }),
                        foregroundColor: cs.onErrorContainer,
                        backgroundColor: cs.error.withValues(alpha: 0.08),
                        compact: compact,
                      ),
                    if (provider.autoResumeEnabled)
                      _TimerSummaryChip(
                        icon: Icons.alarm_rounded,
                        text: i18n.tr('auto_resume_at', {
                          'time':
                              '${provider.autoResumeHour.toString().padLeft(2, '0')}:${provider.autoResumeMinute.toString().padLeft(2, '0')}',
                        }),
                        foregroundColor: cs.onErrorContainer,
                        backgroundColor: cs.error.withValues(alpha: 0.08),
                        compact: compact,
                      ),
                  ];

                  if (chips.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  return Padding(
                    padding: EdgeInsets.only(top: compact ? 12 : 16),
                    child: compact
                        ? Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: chips,
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var i = 0; i < chips.length; i++) ...[
                                if (i > 0) const SizedBox(height: 8),
                                chips[i],
                              ],
                            ],
                          ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DurationPicker extends StatelessWidget {
  const _DurationPicker({
    required this.hours,
    required this.minutes,
    required this.seconds,
    required this.onChanged,
    this.showLabels = true,
  });

  final int hours;
  final int minutes;
  final int seconds;
  final void Function(int h, int m, int s) onChanged;
  final bool showLabels;

  @override
  Widget build(BuildContext context) {
    final i18n = context.watch<AppLanguageProvider>();
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final separatorWidth = constraints.maxWidth < 330 ? 18.0 : 24.0;
        final pickerWidth =
            (constraints.maxWidth - (separatorWidth * 2) - 12) / 3;

        Widget picker(
          String label,
          int value,
          int max,
          void Function(int) onChange,
        ) {
          return SizedBox(
            width: pickerWidth.clamp(84.0, 132.0).toDouble(),
            child: Column(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        cs.surface.withValues(alpha: 0.92),
                        cs.surfaceContainerHigh.withValues(alpha: 0.86),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: cs.outlineVariant.withValues(alpha: 0.8),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withValues(alpha: 0.06),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: value,
                      isExpanded: true,
                      alignment: Alignment.center,
                      icon: const Icon(Icons.expand_more_rounded, size: 20),
                      iconEnabledColor: cs.onSurfaceVariant,
                      menuMaxHeight: 280,
                      borderRadius: BorderRadius.circular(12),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      selectedItemBuilder: (context) =>
                          List.generate(max + 1, (i) {
                            return Center(
                              child: Text(
                                i.toString().padLeft(2, '0'),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.visible,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            );
                          }),
                      items: List.generate(max + 1, (i) => i)
                          .map(
                            (v) => DropdownMenuItem(
                              value: v,
                              alignment: Alignment.center,
                              child: Text(
                                v.toString().padLeft(2, '0'),
                                maxLines: 1,
                                softWrap: false,
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) onChange(v);
                      },
                    ),
                  ),
                ),
                if (showLabels) ...[
                  const SizedBox(height: 8),
                  _TimerFieldLabel(icon: Icons.timelapse_rounded, text: label),
                ],
              ],
            ),
          );
        }

        Widget separator() {
          return SizedBox(
            width: separatorWidth,
            child: Center(
              child: Text(
                ':',
                style: TextStyle(
                  fontSize: constraints.maxWidth < 330 ? 18 : 22,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            picker(
              i18n.tr('hour'),
              hours,
              5,
              (v) => onChanged(v, minutes, seconds),
            ),
            separator(),
            picker(
              i18n.tr('minute'),
              minutes,
              59,
              (v) => onChanged(hours, v, seconds),
            ),
            separator(),
            picker(
              i18n.tr('second'),
              seconds,
              59,
              (v) => onChanged(hours, minutes, v),
            ),
          ],
        );
      },
    );
  }
}

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
