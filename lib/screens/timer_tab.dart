import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';

import '../i18n/app_language_provider.dart';
import '../providers/audio_provider.dart';
import '../providers/audio_provider_riverpod.dart';
import '../services/audio_state_services.dart';
import '../services/platform_channels.dart';
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

class _TimerTabState extends ConsumerState<TimerTab> {
  static const MethodChannel _powerChannel = MethodChannel(PowerChannel.name);
  int _hours = 0;
  int _minutes = 30;
  int _seconds = 0;
  TimerMode _selectedMode = TimerMode.manual;
  bool _showCompactDetail = false;
  bool _draftInitialized = false;
  String? _lastSyncedDraftKey;
  int _lastTimerHash = 0;

  void _setLocalState(VoidCallback fn) => setState(fn);

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

  Future<bool> _canScheduleExactAlarms() async {
    try {
      return await _powerChannel.invokeMethod<bool>(
            PowerMethod.canScheduleExactAlarms,
          ) ??
          true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<void> _openExactAlarmSettings() async {
    try {
      await _powerChannel.invokeMethod<void>(
        PowerMethod.openExactAlarmSettings,
      );
    } on MissingPluginException {
      // Non-Android platforms do not expose this channel.
    } catch (_) {
      // Best effort only.
    }
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
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.alarm_on_rounded),
        title: Text(i18n.tr('exact_alarm_permission_title')),
        content: Text(i18n.tr('exact_alarm_permission_message')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(i18n.tr('later')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(i18n.tr('open_exact_alarm_settings')),
          ),
        ],
      ),
    );
    if (openSettings == true) {
      await _openExactAlarmSettings();
    }
  }

  @override
  Widget build(BuildContext context) => _buildTimerTab(context);
}
