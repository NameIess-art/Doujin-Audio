import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/notifications_platform_service.dart';
import '../services/power_platform_service.dart';
import '../services/time_text_formatters.dart';
import '../services/timer_runtime_calculator.dart';
import '../services/ui_operation_service.dart';
import '../widgets/app_feedback.dart';
import '../widgets/confirm_action_dialog.dart';
import '../widgets/target_countdown_builder.dart';
import '../widgets/top_page_header.dart';

part 'timer_tab_body.dart';
part 'timer_tab_detail_body.dart';
part 'timer_tab_widgets.dart';
part 'timer_tab_countdown_widgets.dart';

class TimerTab extends ConsumerStatefulWidget {
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
  ConsumerState<TimerTab> createState() => _TimerTabState();
}

class _TimerTabState extends ConsumerState<TimerTab>
    with WidgetsBindingObserver {
  static const TimerRuntimeCalculator _timerRuntimeCalculator =
      TimerRuntimeCalculator();
  final PowerPlatformService _powerPlatformService = PowerPlatformService();
  final NotificationsPlatformService _notificationsPlatformService =
      NotificationsPlatformService();
  int _hours = 0;
  int _minutes = 30;
  int _seconds = 0;
  TimerMode _selectedMode = TimerMode.manual;
  bool _showCompactDetail = false;
  bool _draftInitialized = false;
  String? _lastSyncedDraftKey;
  int _lastTimerHash = 0;
  late Future<_TimerReliabilityStatus> _reliabilityStatusFuture;

  void _setLocalState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _showCompactDetail = widget.initialCompactDetail;
    _reliabilityStatusFuture = _loadReliabilityStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshReliabilityStatus();
    }
  }

  void _refreshReliabilityStatus() {
    if (!mounted) return;
    setState(() {
      _reliabilityStatusFuture = _loadReliabilityStatus();
    });
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

  String _fmtClockTime(int h, int m) => formatClockTime(h, m);

  String _fmtDuration(Duration d) => formatDurationHms(d);

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

  Future<bool> _canScheduleExactAlarms() async {
    return _powerPlatformService.canScheduleExactAlarms();
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    return _powerPlatformService.isIgnoringBatteryOptimizations(
      errorDefault: true,
    );
  }

  Future<bool> _areNotificationsEnabled() async {
    return _notificationsPlatformService.areNotificationsEnabled();
  }

  Future<void> _openExactAlarmSettings() async {
    await _powerPlatformService.openExactAlarmSettings();
  }

  Future<void> _openBackgroundRunSettings() async {
    await _powerPlatformService.openBackgroundRunSettings();
  }

  Future<void> _openNotificationSettings() async {
    await _notificationsPlatformService.openNotificationSettings();
  }

  Future<_TimerReliabilityStatus> _loadReliabilityStatus() async {
    return UiOperationService.instance.run<_TimerReliabilityStatus>(
      scope: UiOperationScope.timerReliability,
      labelKey: 'timer_reliability_checking',
      task: (_) async {
        final results = await Future.wait<bool>([
          _areNotificationsEnabled(),
          _canScheduleExactAlarms(),
          _isIgnoringBatteryOptimizations(),
        ]);
        return _TimerReliabilityStatus(
          notificationsEnabled: results[0],
          exactAlarmsEnabled: results[1],
          backgroundRunAllowed: results[2],
        );
      },
    );
  }

  Future<void> _setAutoResumeWithCapabilityCheck(
    AudioProvider provider, {
    required bool enabled,
    required int hour,
    required int minute,
    required bool promptForCapability,
  }) async {
    provider.setAutoResume(enabled, hour, minute);
    if (!promptForCapability) return;
    final canScheduleExactAlarms = await _canScheduleExactAlarms();
    if (canScheduleExactAlarms || !mounted) return;
    final i18n = context.read<AppLanguageProvider>();
    final openSettings = await showConfirmActionDialog(
      context: context,
      title: i18n.tr('exact_alarm_permission_title'),
      message: i18n.tr('exact_alarm_permission_message'),
      cancelLabel: i18n.tr('later'),
      confirmLabel: i18n.tr('open_exact_alarm_settings'),
      icon: Icons.alarm_on_rounded,
      confirmIcon: Icons.settings_rounded,
      isDestructive: false,
    );
    if (openSettings) {
      await _openExactAlarmSettings();
    }
  }

  @override
  Widget build(BuildContext context) => _buildTimerTab(context);
}

class _TimerReliabilityStatus {
  const _TimerReliabilityStatus({
    required this.notificationsEnabled,
    required this.exactAlarmsEnabled,
    required this.backgroundRunAllowed,
  });

  final bool notificationsEnabled;
  final bool exactAlarmsEnabled;
  final bool backgroundRunAllowed;

  bool get isStronglyReliable =>
      notificationsEnabled && exactAlarmsEnabled && backgroundRunAllowed;
}
