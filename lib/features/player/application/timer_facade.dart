import 'dart:async';

import '../../../core/platform/power_platform_service.dart';
import '../domain/playback_mode.dart';
import 'audio_state_services.dart';
import 'timer_runtime_calculator.dart';

/// Owns timer state and timer-related platform power coordination.
final class TimerFacade {
  TimerFacade({required this.service, required this.powerPlatformService});

  factory TimerFacade.create({
    TimerService? service,
    PowerPlatformService? powerPlatformService,
  }) {
    return TimerFacade(
      service: service ?? TimerService(),
      powerPlatformService: powerPlatformService ?? PowerPlatformService(),
    );
  }

  final TimerService service;
  final PowerPlatformService powerPlatformService;
  static const TimerRuntimeCalculator _runtimeCalculator =
      TimerRuntimeCalculator();

  bool Function() _hasPlayingSession = () => false;
  void Function() _onStateChanged = _noop;
  void Function(double multiplier) _applyFadeMultiplier = _noopFade;
  Future<void> Function() _saveSettings = _noopAsync;
  Future<void> Function() _saveRuntime = _noopAsync;
  Future<void> Function() _syncNativeAlarms = _noopAsync;
  Future<void> Function(int generation) _onTimerExpired = _noopGeneration;
  Future<void> Function(int generation) _onAutoResume = _noopGeneration;

  TimerStateSliceData get state => service.slice.state;
  Stream<TimerStateSliceData> get states => service.slice.stream;

  bool get hasArmedRuntime => _runtimeCalculator.hasArmedRuntime(
    mode: service.timerMode,
    duration: service.timerDuration,
    waitingForPlayback: service.timerWaitingForPlayback,
    active: service.timerActive,
    endsAt: service.timerEndsAt,
    autoResumeAt: service.autoResumeAt,
    hasPausedByTimerSessionIds: service.pausedByTimerSessionIds.isNotEmpty,
  );

  void attachRuntime({
    required bool Function() hasPlayingSession,
    required void Function() onStateChanged,
    required void Function(double multiplier) applyFadeMultiplier,
    required Future<void> Function() saveSettings,
    required Future<void> Function() saveRuntime,
    required Future<void> Function() syncNativeAlarms,
    required Future<void> Function(int generation) onTimerExpired,
    required Future<void> Function(int generation) onAutoResume,
  }) {
    _hasPlayingSession = hasPlayingSession;
    _onStateChanged = onStateChanged;
    _applyFadeMultiplier = applyFadeMultiplier;
    _saveSettings = saveSettings;
    _saveRuntime = saveRuntime;
    _syncNativeAlarms = syncNativeAlarms;
    _onTimerExpired = onTimerExpired;
    _onAutoResume = onAutoResume;
  }

  void configureTimer(TimerMode mode, Duration duration) {
    service.timerDraftMode = mode;
    service.timerDraftDuration = duration > Duration.zero
        ? duration
        : const Duration(minutes: 30);
    _cancelTimerInternal();
    service.timerMode = mode;
    service.timerDuration = duration;
    service.timerRemaining = duration;
    service.timerEndsAt = null;
    service.timerActive = false;
    service.timerWaitingForPlayback = mode == TimerMode.trigger;
    if (mode == TimerMode.trigger && _hasPlayingSession()) {
      startCountdown();
      return;
    }
    _changed();
    unawaited(_saveSettings());
    unawaited(_saveRuntime());
    unawaited(_syncNativeAlarms());
  }

  void startCountdown() {
    if (service.timerDuration == null || service.timerActive) return;
    service.countdownTimer?.cancel();
    final generation = ++service.timerGeneration;
    service.timerActive = true;
    service.timerWaitingForPlayback = false;
    service.timerRemaining = service.timerDuration;
    service.timerEndsAt = DateTime.now().add(service.timerDuration!);
    service.countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (generation != service.timerGeneration) return;
      _tickCountdown();
    });
    _changed();
    unawaited(_saveRuntime());
    unawaited(_syncNativeAlarms());
  }

  void cancelTimer() {
    resetRuntimeState();
    _changed();
    unawaited(_saveRuntime());
    unawaited(_syncNativeAlarms());
  }

  void setTimerDraft(TimerMode mode, Duration duration) {
    final normalizedDuration = duration > Duration.zero
        ? duration
        : const Duration(minutes: 30);
    if (service.timerDraftMode == mode &&
        service.timerDraftDuration == normalizedDuration) {
      return;
    }
    service.timerDraftMode = mode;
    service.timerDraftDuration = normalizedDuration;
    _changed();
    unawaited(_saveSettings());
  }

  void setAutoResume(bool enabled, int hour, int minute) {
    service.autoResumeEnabled = enabled;
    service.autoResumeHour = hour;
    service.autoResumeMinute = minute;
    if (!enabled) {
      service.autoResumeTimer?.cancel();
      service.autoResumeTimer = null;
      service.autoResumeAt = null;
    } else if (service.pausedByTimerSessionIds.isNotEmpty) {
      scheduleAutoResumeTimer(
        _runtimeCalculator.nextClockTime(
          now: DateTime.now(),
          hour: hour,
          minute: minute,
        ),
      );
    }
    _changed();
    unawaited(_saveSettings());
    unawaited(_saveRuntime());
    unawaited(_syncNativeAlarms());
  }

  void retryOverdueAutoResume() {
    final autoResumeAt = service.autoResumeAt;
    if (autoResumeAt == null || service.pausedByTimerSessionIds.isEmpty) {
      return;
    }
    if (autoResumeAt.isAfter(DateTime.now())) {
      scheduleAutoResumeTimer(autoResumeAt);
      _changed();
      unawaited(_saveRuntime());
      unawaited(_syncNativeAlarms());
      return;
    }
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    unawaited(_onAutoResume(service.timerGeneration));
  }

  void maybeStartTriggerCountdown() {
    if (service.timerMode != TimerMode.trigger ||
        service.timerDuration == null ||
        service.timerActive ||
        !service.timerWaitingForPlayback) {
      return;
    }
    startCountdown();
  }

  void resetRuntimeState({bool clearPausedSessions = true}) {
    service.timerGeneration++;
    service.countdownTimer?.cancel();
    service.countdownTimer = null;
    service.timerMode = null;
    service.timerDuration = null;
    service.timerActive = false;
    service.timerRemaining = null;
    service.timerEndsAt = null;
    service.timerWaitingForPlayback = false;
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    service.autoResumeAt = null;
    if (clearPausedSessions) {
      service.pausedByTimerSessionIds.clear();
    }
    _applyFadeMultiplier(1.0);
  }

  void scheduleAutoResumeTimer(DateTime target) {
    service.autoResumeTimer?.cancel();
    service.autoResumeAt = target;
    final delay = target.difference(DateTime.now());
    if (delay <= Duration.zero) {
      service.autoResumeTimer = null;
      unawaited(_onAutoResume(service.timerGeneration));
      return;
    }
    service.autoResumeTimer = Timer(delay, () {
      service.autoResumeTimer = null;
      unawaited(_onAutoResume(service.timerGeneration));
    });
  }

  void restoreCountdownTimer() {
    final endsAt = service.timerEndsAt;
    if (endsAt == null) return;
    final generation = service.timerGeneration;
    service.countdownTimer?.cancel();
    service.countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (generation != service.timerGeneration) return;
      _tickCountdown();
    });
  }

  void _cancelTimerInternal() {
    service.timerGeneration++;
    service.countdownTimer?.cancel();
    service.countdownTimer = null;
    service.timerEndsAt = null;
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    service.autoResumeAt = null;
    service.timerActive = false;
    service.timerWaitingForPlayback = false;
    unawaited(_saveRuntime());
    unawaited(_syncNativeAlarms());
  }

  void _tickCountdown() {
    final tick = _runtimeCalculator.countdownTick(
      active: service.timerActive,
      endsAt: service.timerEndsAt,
      now: DateTime.now(),
      currentRemaining: service.timerRemaining,
    );
    if (tick.expired) {
      service.timerRemaining = tick.remaining;
      _applyFadeMultiplier(1.0);
      _changed();
      _expireTimer();
      return;
    }
    if (!tick.changed) return;
    service.timerRemaining = tick.remaining;
    final duration = service.timerDuration;
    if (duration != null && duration.inMinutes >= 2) {
      final remainingMs = service.timerRemaining!.inMilliseconds;
      if (remainingMs <= 120000) {
        _applyFadeMultiplier((remainingMs / 120000.0).clamp(0.0, 1.0));
      }
    }
    _changed();
  }

  void _expireTimer() {
    final generation = service.timerGeneration;
    service.timerActive = false;
    service.countdownTimer?.cancel();
    service.countdownTimer = null;
    service.timerEndsAt = null;
    service.timerWaitingForPlayback = false;
    service.timerRemaining = Duration.zero;
    service.autoResumeTimer?.cancel();
    service.autoResumeTimer = null;
    _changed();
    unawaited(_onTimerExpired(generation));
  }

  void _changed() => _onStateChanged();

  bool keepAliveHasPlayback = false;
  bool keepAliveHasTimer = false;
  bool keepAliveUsesUnifiedNotifications = false;
  bool keepAliveKeepsForegroundService = false;

  Future<void> dispose() async {
    service.countdownTimer?.cancel();
    service.autoResumeTimer?.cancel();
    await service.dispose();
  }
}

void _noop() {}
void _noopFade(double _) {}
Future<void> _noopAsync() async {}
Future<void> _noopGeneration(int _) async {}
