import 'dart:async';

import 'package:audio_session/audio_session.dart';

import '../../core/logging/app_log_service.dart';
import '../../core/platform/app_platform.dart';
import '../../features/library/application/cover_image_cache_policy.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/application/timer_runtime_calculator.dart';
import '../../features/settings/application/settings_repository.dart';

/// Coordinates playback/timer keep-alive state without owning UI state.
final class PlaybackKeepAliveCoordinator {
  PlaybackKeepAliveCoordinator({
    required PlaybackFacade playback,
    required TimerFacade timer,
    required NotificationFacade notifications,
    required SettingsRepository settings,
    required void Function() enterBackgroundWarmup,
    required void Function() resumeForegroundWarmup,
  }) : _playback = playback,
       _timer = timer,
       _notifications = notifications,
       _settings = settings,
       _enterBackgroundWarmup = enterBackgroundWarmup,
       _resumeForegroundWarmup = resumeForegroundWarmup;

  static const TimerRuntimeCalculator _timerRuntimeCalculator =
      TimerRuntimeCalculator();

  final PlaybackFacade _playback;
  final TimerFacade _timer;
  final NotificationFacade _notifications;
  final SettingsRepository _settings;
  final void Function() _enterBackgroundWarmup;
  final void Function() _resumeForegroundWarmup;

  bool get hasPlayingSession =>
      _playback.service.sessions.values.any((session) => session.state.playing);

  bool get hasPlaybackToKeepAlive => _playback.service.sessions.values.any(
    (session) =>
        session.state.playing ||
        session.isLoading ||
        session.isPlaybackStarting ||
        session.loadedPath != null,
  );

  bool get hasRetainedPlaybackSession => _playback.service.sessions.isNotEmpty;

  bool get hasPendingAutoResume => _timerRuntimeCalculator.hasPendingAutoResume(
    autoResumeAt: _timer.service.autoResumeAt,
    hasPausedByTimerSessionIds:
        _timer.service.pausedByTimerSessionIds.isNotEmpty,
  );

  void sync() {
    final hasPlayback = hasPlaybackToKeepAlive;
    final hasTimer =
        _timer.service.timerActive ||
        _timer.service.timerWaitingForPlayback ||
        hasPendingAutoResume;
    final usesUnifiedNotifications =
        _settings.multiThreadPlaybackEnabled && _settings.notificationsEnabled;
    final shouldKeepAwake = hasPlayback || hasTimer || hasPendingAutoResume;
    final keepForegroundServiceAlive = shouldKeepAwake;
    if (_settings.keepCpuAwake == shouldKeepAwake &&
        _timer.keepAliveHasPlayback == hasPlayback &&
        _timer.keepAliveHasTimer == hasTimer &&
        _timer.keepAliveUsesUnifiedNotifications == usesUnifiedNotifications &&
        _timer.keepAliveKeepsForegroundService == keepForegroundServiceAlive) {
      return;
    }
    _settings.keepCpuAwake = shouldKeepAwake;
    _timer.keepAliveHasPlayback = hasPlayback;
    _timer.keepAliveHasTimer = hasTimer;
    _timer.keepAliveUsesUnifiedNotifications = usesUnifiedNotifications;
    _timer.keepAliveKeepsForegroundService = keepForegroundServiceAlive;
    if (_notifications.stateService.notificationActionRefreshPending) {
      _notifications.stateService.keepAliveSyncDeferred = true;
    } else {
      _notifications.stateService.keepAliveSyncDeferred = false;
      unawaited(
        _setKeepCpuAwake(
          shouldKeepAwake,
          hasActivePlayback: hasPlayback,
          hasActiveTimer: hasTimer,
          usesUnifiedPlaybackNotifications: usesUnifiedNotifications,
          keepForegroundServiceAlive: keepForegroundServiceAlive,
        ),
      );
    }
    if (!hasPlayback && !hasRetainedPlaybackSession) {
      unawaited(deactivateAudioSession());
    }
  }

  void enterBackground() {
    if (AppPlatform.isAndroid) {
      _enterBackgroundWarmup();
      compactCoverImageCacheForBackground();
    }
    final hasPlayback = hasPlaybackToKeepAlive;
    final hasTimer =
        _timer.service.timerActive ||
        _timer.service.timerWaitingForPlayback ||
        hasPendingAutoResume;
    final usesUnifiedNotifications =
        _settings.multiThreadPlaybackEnabled && _settings.notificationsEnabled;
    final shouldKeepAwake = hasPlayback || hasTimer || hasPendingAutoResume;
    _timer.keepAliveHasPlayback = hasPlayback;
    _timer.keepAliveHasTimer = hasTimer;
    _timer.keepAliveUsesUnifiedNotifications = usesUnifiedNotifications;
    _timer.keepAliveKeepsForegroundService = shouldKeepAwake;
    _settings.keepCpuAwake = shouldKeepAwake;
    unawaited(
      _setKeepCpuAwake(
        shouldKeepAwake,
        hasActivePlayback: hasPlayback,
        hasActiveTimer: hasTimer,
        usesUnifiedPlaybackNotifications: usesUnifiedNotifications,
        keepForegroundServiceAlive: shouldKeepAwake,
      ),
    );
  }

  void resumeForeground() {
    if (!AppPlatform.isAndroid) return;
    _resumeForegroundWarmup();
    applyCoverImageCachePolicy(_settings.coverImageResolution);
  }

  Future<bool> activateAudioSession() async {
    if (AppPlatform.isAndroid) return true;
    try {
      final audioSession = await AudioSession.instance;
      return await audioSession.setActive(true);
    } catch (error, stackTrace) {
      AppLogService.error(
        'activate_audio_session_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return true;
    }
  }

  Future<void> deactivateAudioSession() async {
    if (AppPlatform.isAndroid) return;
    try {
      final audioSession = await AudioSession.instance;
      await audioSession.setActive(false);
    } catch (error, stackTrace) {
      AppLogService.error(
        'deactivate_audio_session_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> shutdown() async {
    await _setKeepCpuAwake(
      false,
      hasActivePlayback: false,
      hasActiveTimer: false,
      usesUnifiedPlaybackNotifications: false,
      keepForegroundServiceAlive: false,
    );
    await deactivateAudioSession();
  }

  Future<void> _setKeepCpuAwake(
    bool enabled, {
    required bool hasActivePlayback,
    required bool hasActiveTimer,
    required bool usesUnifiedPlaybackNotifications,
    required bool keepForegroundServiceAlive,
  }) async {
    try {
      await _timer.powerPlatformService.setKeepCpuAwake(
        enabled: enabled,
        hasActivePlayback: hasActivePlayback,
        hasActiveTimer: hasActiveTimer,
        usesUnifiedPlaybackNotifications: usesUnifiedPlaybackNotifications,
        keepForegroundServiceAlive: keepForegroundServiceAlive,
      );
    } catch (error, stackTrace) {
      AppLogService.error(
        'set_keep_cpu_awake_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }
}
