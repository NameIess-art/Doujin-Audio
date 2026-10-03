import '../../../core/widgets/app_transitions.dart';
import 'playback_providers.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/localization/app_language_provider.dart';
import '../../../app/state/app_runtime_providers.dart';
import '../../../app/theme/app_design_tokens.dart';
import '../application/audio_state_services.dart';
import '../application/timer_facade.dart';
import '../domain/playback_mode.dart';
import '../../settings/application/permission_status_service.dart';
import '../../../core/media/time_text_formatters.dart';
import '../application/timer_runtime_calculator.dart';
import '../../../core/ui/ui_operation_service.dart';
import '../../../core/ui/ui_interaction_coordinator.dart';
import '../../../core/widgets/app_feedback.dart';
import '../../../core/widgets/confirm_action_dialog.dart';
import '../../../core/widgets/target_countdown_builder.dart';
import '../../../core/widgets/page_header_inset.dart';
import '../../../core/widgets/top_page_header.dart';

part 'timer_tab_body.dart';
part 'timer_tab_detail_body.dart';
part 'timer_tab_widgets.dart';
part 'timer_tab_countdown_widgets.dart';

const double kTimerCompactPanelHeight = 448;

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
  int _hours = 0;
  int _minutes = 30;
  int _seconds = 0;
  TimerMode _selectedMode = TimerMode.manual;
  bool _showCompactDetail = false;
  bool _draftInitialized = false;
  String? _lastSyncedDraftKey;
  Future<_TimerReliabilityStatus>? _reliabilityStatusFuture;
  bool _reliabilityRefreshNeeded = true;
  late final String _reliabilityLoadKey =
      'timer_reliability:${identityHashCode(this)}';

  void _setLocalState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _showCompactDetail = widget.initialCompactDetail;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reliabilityRefreshNeeded &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      _scheduleReliabilityRefresh();
    }
  }

  @override
  void dispose() {
    UiInteractionCoordinator.instance.cancelCommit(_reliabilityLoadKey);
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
    if (!mounted || defaultTargetPlatform == TargetPlatform.windows) return;
    _reliabilityRefreshNeeded = true;
    _scheduleReliabilityRefresh();
  }

  void _scheduleReliabilityRefresh() {
    if (defaultTargetPlatform == TargetPlatform.windows) return;
    UiInteractionCoordinator.instance.scheduleCommit(
      key: _reliabilityLoadKey,
      commit: () {
        if (!mounted ||
            !_reliabilityRefreshNeeded ||
            !(ModalRoute.of(context)?.isCurrent ?? true)) {
          return;
        }
        _reliabilityRefreshNeeded = false;
        final reliabilityStatus = _loadReliabilityStatus();
        setState(() {
          _reliabilityStatusFuture = reliabilityStatus;
        });
      },
    );
  }

  Duration get _pickedDuration =>
      Duration(hours: _hours, minutes: _minutes, seconds: _seconds);

  bool get _durationIsZero => _pickedDuration == Duration.zero;

  PermissionStatusService get _permissionStatusService =>
      ref.read(permissionStatusServiceProvider);

  String _draftKey(TimerMode mode, Duration duration) =>
      '${mode.index}:${duration.inSeconds}';

  void _syncDraftFromState(TimerStateSliceData state) {
    final duration = state.duration ?? state.remaining ?? state.draftDuration;
    final mode = state.mode ?? state.draftMode;
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

  void _onConfirm(TimerFacade timer) {
    if (_durationIsZero) return;
    timer.configureTimer(_selectedMode, _pickedDuration);
    if (_selectedMode == TimerMode.manual) {
      timer.startCountdown();
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
    return _permissionStatusService.isGranted(PermissionCapability.exactAlarms);
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    return _permissionStatusService.isGranted(
      PermissionCapability.backgroundRun,
      errorDefault: true,
    );
  }

  Future<void> _openExactAlarmSettings() async {
    await _permissionStatusService.openSettings(
      PermissionCapability.exactAlarms,
    );
  }

  Future<void> _openBackgroundRunSettings() async {
    await _permissionStatusService.openSettings(
      PermissionCapability.backgroundRun,
    );
  }

  Future<_TimerReliabilityStatus> _loadReliabilityStatus() async {
    return ref
        .read(uiOperationServiceProvider)
        .run<_TimerReliabilityStatus>(
          scope: UiOperationScope.timerReliability,
          labelKey: 'timer_reliability_checking',
          task: (_) async {
            final results = await Future.wait<bool>([
              _canScheduleExactAlarms(),
              _isIgnoringBatteryOptimizations(),
            ]);
            return _TimerReliabilityStatus(
              exactAlarmsEnabled: results[0],
              backgroundRunAllowed: results[1],
            );
          },
        );
  }

  Future<void> _setAutoResumeWithCapabilityCheck(
    TimerFacade timer, {
    required bool enabled,
    required int hour,
    required int minute,
    required bool promptForCapability,
  }) async {
    timer.setAutoResume(enabled, hour, minute);
    if (!promptForCapability ||
        defaultTargetPlatform == TargetPlatform.windows) {
      return;
    }
    final canScheduleExactAlarms = await _canScheduleExactAlarms();
    if (canScheduleExactAlarms || !mounted) return;
    final i18n = ref.read(appLanguageProviderInstanceProvider);
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
    if (!mounted || !openSettings) return;
    await _openExactAlarmSettings();
  }

  @override
  Widget build(BuildContext context) => _buildTimerTab(context);
}

class _TimerReliabilityStatus {
  const _TimerReliabilityStatus({
    required this.exactAlarmsEnabled,
    required this.backgroundRunAllowed,
  });

  final bool exactAlarmsEnabled;
  final bool backgroundRunAllowed;

  bool get isStronglyReliable => exactAlarmsEnabled && backgroundRunAllowed;
}
