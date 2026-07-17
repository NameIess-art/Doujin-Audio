import 'dart:async';

import 'package:audio_session/audio_session.dart';

import '../../core/logging/app_log_service.dart';
import '../../core/platform/app_platform.dart';
import '../../features/library/application/cover_image_cache_policy.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/settings/application/settings_repository.dart';

/// Coordinates retained playback lifecycle work without owning UI state.
final class PlaybackKeepAliveCoordinator {
  PlaybackKeepAliveCoordinator({
    required PlaybackFacade playback,
    required SettingsRepository settings,
    required void Function() enterBackgroundWarmup,
    required void Function() resumeForegroundWarmup,
  }) : _playback = playback,
       _settings = settings,
       _enterBackgroundWarmup = enterBackgroundWarmup,
       _resumeForegroundWarmup = resumeForegroundWarmup;

  final PlaybackFacade _playback;
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

  void sync() {
    if (!hasPlaybackToKeepAlive && !hasRetainedPlaybackSession) {
      unawaited(deactivateAudioSession());
    }
  }

  void enterBackground() {
    if (AppPlatform.isAndroid) {
      _enterBackgroundWarmup();
      compactCoverImageCacheForBackground();
    }
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
    await deactivateAudioSession();
  }
}
