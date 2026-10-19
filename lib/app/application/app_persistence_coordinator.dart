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
import '../../core/persistence/persisted_state_reloader.dart';
import 'playback_keep_alive_coordinator.dart';

/// Owns ordered startup loading and runtime state reloading.
final class AppPersistenceCoordinator implements PersistedStateReloader {
  AppPersistenceCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required SettingsRepository settings,
    required TimerFacade timer,
    required NotificationFacade notifications,
    required PlaybackKeepAliveCoordinator keepAlive,
    required AudioUiWarmupCoordinator uiWarmup,
    required PlaybackSubtitleService subtitles,
  }) : _library = library,
       _playback = playback,
       _settings = settings,
       _timer = timer,
       _notifications = notifications,
       _keepAlive = keepAlive,
       _uiWarmup = uiWarmup,
       _subtitles = subtitles;

  final LibraryFacade _library;
  final PlaybackFacade _playback;
  final SettingsRepository _settings;
  final TimerFacade _timer;
  final NotificationFacade _notifications;
  final PlaybackKeepAliveCoordinator _keepAlive;
  final AudioUiWarmupCoordinator _uiWarmup;
  final PlaybackSubtitleService _subtitles;

  int _loadEpoch = 0;
  bool _disposed = false;
  bool _reloading = false;
  bool _needsResetBeforeLoad = false;
  bool _hasLoadedState = false;
  bool _presentationInitialized = false;
  Future<void>? _presentationInitialization;

  bool get hasLoadedState => _hasLoadedState;

  void invalidatePendingLoad() {
    _loadEpoch++;
  }

  Future<void> initializePresentation() {
    if (_disposed || _presentationInitialized) return Future<void>.value();
    final active = _presentationInitialization;
    if (active != null) return active;
    late final Future<void> attempt;
    attempt = _initializePresentation().whenComplete(() {
      if (identical(_presentationInitialization, attempt)) {
        _presentationInitialization = null;
      }
    });
    return _presentationInitialization = attempt;
  }

  Future<void> _initializePresentation() async {
    await _settings.loadPersistedState(enforceCacheLimit: false);
    if (_disposed) return;
    AppInteractionFeedbackSettings.hapticFeedbackEnabled =
        _settings.hapticFeedbackEnabled;
    applyCoverImageCachePolicy(_settings.coverImageResolution);
    _presentationInitialized = true;
  }

  Future<void> loadPersistedState() async {
    _hasLoadedState = false;
    _syncSlices(isInitialized: false, syncSettings: false);
    final epoch = ++_loadEpoch;
    bool isCurrent() => !_disposed && epoch == _loadEpoch;
    try {
      if (_needsResetBeforeLoad) {
        _needsResetBeforeLoad = false;
        await _resetRuntimeState(resetSettings: false);
        if (!isCurrent()) return;
      }
      await initializePresentation();
      if (!isCurrent()) return;
      await _playback.nativeRepository.setPlaybackBehavior(
        pauseOnAudioDeviceDisconnect:
            _settings.audioDeviceDisconnectBehavior ==
            AudioDeviceDisconnectBehavior.pause,
        requestAudioFocus:
            _settings.audioFocusStrategy == AudioFocusStrategy.standard,
        pauseOnTransientAudioFocusLoss:
            _settings.transientAudioFocusLossBehavior ==
            TransientAudioFocusLossBehavior.pause,
        resumeAfterTransientAudioFocusGain:
            _settings.interruptionResumeBehavior ==
            InterruptionResumeBehavior.resume,
      );
      // A rebuilt Flutter engine reconnects to playback that may still be live.
      // Session restore below reconciles its native snapshot without pausing it.
      await Future.wait<void>(<Future<void>>[
        _library.coverArtworkCacheService.initialize(),
        _library.loadPersistedState(),
        _timer.loadPersistedState(),
      ]);
      if (!isCurrent()) return;
      await _playback.loadPersistedState();
      if (!isCurrent()) return;
      await AppLogService.measureAsync(
        'timer_runtime_load',
        _timer.loadRuntimeFromSystem,
      );
      if (!isCurrent()) return;
      _notifications.syncPlaybackState(immediateUnifiedSync: true);
      await _completeLoad(isCurrent);
    } catch (error, stackTrace) {
      if (isCurrent()) _needsResetBeforeLoad = true;
      AppLogService.error(
        'app_persistence_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _completeLoad(bool Function() isCurrent) async {
    if (!isCurrent()) return;
    if (_reloading) {
      _uiWarmup.resumeForeground();
      _library.coverArtworkCacheService.invalidateAll();
      _uiWarmup.schedule(immediate: true);
      _reloading = false;
    } else {
      _uiWarmup.schedule();
    }
    _keepAlive.sync();
    await _library.ensureCardSnapshot();
    if (!isCurrent()) return;
    _syncSlices(isInitialized: true);
    _hasLoadedState = true;
    _library.schedulePostStartupMaintenance();
  }

  void _syncSlices({required bool isInitialized, bool syncSettings = true}) {
    _library.syncPresentationState(isInitialized: isInitialized);
    _playback.syncPresentationState(
      focusedSessionId: _notifications.focusedSessionId,
      coverGeneration: _library.coverArtworkCacheService.generation,
      isInitialized: isInitialized,
    );
    _timer.syncPresentationState(isInitialized: isInitialized);
    if (syncSettings) _settings.syncSlice(isInitialized: isInitialized);
    _notifications.syncPresentationState(
      activeQueueLength: _playback.activeSessions.length,
    );
  }

  @override
  Future<void> reloadPersistedState() async {
    if (_disposed) return;
    _hasLoadedState = false;
    _syncSlices(isInitialized: false, syncSettings: false);
    _loadEpoch++;
    await _resetRuntimeState();
    if (_disposed) return;
    await loadPersistedState();
  }

  Future<void> _resetRuntimeState({bool resetSettings = true}) async {
    final presentation = _presentationInitialization;
    if (resetSettings && presentation != null) {
      try {
        await presentation;
      } catch (_) {
        // A failed settings read is reported by startup; reset must still
        // replace its partial values before the next attempt.
      }
    }
    _reloading = true;
    _playback.cancelScheduledPersistence();
    _library.cancelPendingScanProgressNotification();
    _uiWarmup.enterBackground();
    _notifications.prepareForPersistenceReset();

    await _playback.resetPersistedState();
    await _library.resetPersistedState();
    await _timer.resetPersistedState();
    if (resetSettings) {
      _presentationInitialized = false;
      await _settings.resetPersistedState();
    }
    _subtitles.clear();
    await _notifications.resetPersistedState();
    _syncSlices(isInitialized: false, syncSettings: resetSettings);
  }

  Future<void> dispose() async {
    _disposed = true;
    _loadEpoch++;
    final presentation = _presentationInitialization;
    if (presentation != null) {
      try {
        await presentation;
      } catch (_) {
        // The presentation bootstrap owns failure reporting; its settings read
        // must finish before the settings owner is closed.
      }
    }
  }
}
