import '../../core/logging/app_log_service.dart';
import '../../core/ui/app_interaction_feedback_settings.dart';
import '../../features/library/application/cover_image_cache_policy.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/playback_subtitle_service.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/settings/application/settings_repository.dart';
import '../../features/settings/application/settings_state.dart';
import 'audio_ui_warmup_coordinator.dart';
import 'persisted_state_reloader.dart';
import 'playback_command_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';

/// Owns ordered startup loading and backup-restore runtime reloading.
final class AppPersistenceCoordinator
    implements
        PersistedStateReloader,
        PersistedStateExportPreparer,
        PersistedStateReplacementPreparer {
  AppPersistenceCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required SettingsRepository settings,
    required TimerFacade timer,
    required NotificationFacade notifications,
    required PlaybackCommandCoordinator playbackCommands,
    required PlaybackKeepAliveCoordinator keepAlive,
    required AudioUiWarmupCoordinator uiWarmup,
    required PlaybackSubtitleService subtitles,
  }) : _library = library,
       _playback = playback,
       _settings = settings,
       _timer = timer,
       _notifications = notifications,
       _playbackCommands = playbackCommands,
       _keepAlive = keepAlive,
       _uiWarmup = uiWarmup,
       _subtitles = subtitles;

  final LibraryFacade _library;
  final PlaybackFacade _playback;
  final SettingsRepository _settings;
  final TimerFacade _timer;
  final NotificationFacade _notifications;
  final PlaybackCommandCoordinator _playbackCommands;
  final PlaybackKeepAliveCoordinator _keepAlive;
  final AudioUiWarmupCoordinator _uiWarmup;
  final PlaybackSubtitleService _subtitles;

  int _loadEpoch = 0;
  bool _disposed = false;
  bool _reloading = false;

  Future<void> loadPersistedState() async {
    final epoch = ++_loadEpoch;
    bool isCurrent() => !_disposed && epoch == _loadEpoch;
    try {
      await _settings.loadPersistedState();
      if (!isCurrent()) return;
      AppInteractionFeedbackSettings.hapticFeedbackEnabled =
          _settings.hapticFeedbackEnabled;
      applyCoverImageCachePolicy(_settings.coverImageResolution);
      await _playback.nativeRepository.setPlaybackBehavior(
        pauseOnAudioDeviceDisconnect:
            _settings.audioDeviceDisconnectBehavior ==
            AudioDeviceDisconnectBehavior.pause,
        pauseOnTransientAudioFocusLoss:
            _settings.transientAudioFocusLossBehavior ==
            TransientAudioFocusLossBehavior.pause,
        resumeAfterTransientAudioFocusGain:
            _settings.interruptionResumeBehavior ==
            InterruptionResumeBehavior.resume,
        resumePlaybackOnStartupRestore:
            _settings.startupPlaybackRestoreBehavior ==
            StartupPlaybackRestoreBehavior.resume,
      );
      if (_settings.startupPlaybackRestoreBehavior ==
          StartupPlaybackRestoreBehavior.pause) {
        await _playback.nativeRepository.pauseAll();
      }

      await Future.wait<void>(<Future<void>>[
        _library.loadPersistedState(),
        _timer.loadPersistedState(),
      ]);
      if (!isCurrent()) return;
      if (!_settings.notificationsEnabled) {
        await _playback.nativeRepository.setForegroundEnabled(false);
      }

      await _playback.loadPersistedState();
      if (!isCurrent()) return;
      if (!_settings.multiThreadPlaybackEnabled) {
        await AppLogService.measureAsync(
          'playback_enforce_single_thread_on_restore',
          _playbackCommands.enforceSingleThreadPlayback,
        );
      }
      await AppLogService.measureAsync(
        'timer_runtime_load',
        _timer.loadRuntimeFromSystem,
      );
      if (!isCurrent()) return;
      _notifications.syncPlaybackState(immediateUnifiedSync: true);
    } catch (error, stackTrace) {
      AppLogService.error(
        'app_persistence_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (isCurrent()) await _completeLoad();
    }
  }

  Future<void> _completeLoad() async {
    if (_reloading) {
      _uiWarmup.resumeForeground();
      _library.coverArtworkCacheService.invalidateAll();
      _uiWarmup.schedule(currentPageIndex: 0, immediate: true);
      _reloading = false;
    } else {
      _uiWarmup.schedule(currentPageIndex: 0);
    }
    _keepAlive.sync();
    await _library.ensureCardSnapshot();
    _syncInitializedSlices();
    _library.schedulePostStartupMaintenance();
  }

  void _syncInitializedSlices() {
    _library.syncPresentationState(isInitialized: true);
    _playback.syncPresentationState(
      focusedSessionId: _notifications.focusedSessionId,
      multiThreadPlaybackEnabled: _settings.multiThreadPlaybackEnabled,
      coverGeneration: _library.coverArtworkCacheService.generation,
      isInitialized: true,
    );
    _timer.syncPresentationState(isInitialized: true);
    _settings.syncSlice(isInitialized: true);
    _notifications.syncPresentationState(
      activeQueueLength: _playback.activeSessions.length,
    );
  }

  @override
  Future<void> prepareForPersistedStateExport() async {
    if (_disposed) return;
    await _settings.prepareForBackupExport();
    await _library.prepareForBackupExport();
  }

  @override
  Future<void> prepareForPersistedStateReplacement() async {
    if (_disposed) return;
    _loadEpoch++;
    _playback.cancelScheduledPersistence();
    _library.cancelPendingScanProgressNotification();
    _notifications.prepareForPersistenceReset();
    await _library.prepareForBackupRestore();
  }

  @override
  Future<void> reloadPersistedState() async {
    if (_disposed) return;
    _loadEpoch++;
    _reloading = true;
    _playback.cancelScheduledPersistence();
    _library.cancelPendingScanProgressNotification();
    _uiWarmup.enterBackground();
    _notifications.prepareForPersistenceReset();

    await _playback.resetForBackupRestore();
    await _library.resetForBackupRestore();
    await _timer.resetForBackupRestore();
    await _settings.resetForBackupRestore();
    _subtitles.clear();
    await _notifications.resetForBackupRestore();
    if (_disposed) return;
    await loadPersistedState();
  }

  void dispose() {
    _disposed = true;
    _loadEpoch++;
  }
}
