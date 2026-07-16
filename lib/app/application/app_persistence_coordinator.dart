import '../../core/logging/app_log_service.dart';
import '../../features/library/application/library_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/settings/application/settings_repository.dart';
import 'persisted_state_reloader.dart';

final class AppPersistenceCoordinator implements PersistedStateReloader {
  AppPersistenceCoordinator({
    required LibraryFacade library,
    required PlaybackFacade playback,
    required SettingsRepository settings,
    required TimerFacade timer,
    required Future<void> Function() beforeReset,
    required Future<void> Function() afterReset,
    required Future<void> Function() onSettingsLoaded,
    required Future<void> Function() onLibraryLoaded,
    required Future<void> Function() onPlaybackLoaded,
    required Future<void> Function() onLoadCompleted,
  }) : _library = library,
       _playback = playback,
       _settings = settings,
       _timer = timer,
       _beforeReset = beforeReset,
       _afterReset = afterReset,
       _onSettingsLoaded = onSettingsLoaded,
       _onLibraryLoaded = onLibraryLoaded,
       _onPlaybackLoaded = onPlaybackLoaded,
       _onLoadCompleted = onLoadCompleted;

  final LibraryFacade _library;
  final PlaybackFacade _playback;
  final SettingsRepository _settings;
  final TimerFacade _timer;
  final Future<void> Function() _beforeReset;
  final Future<void> Function() _afterReset;
  final Future<void> Function() _onSettingsLoaded;
  final Future<void> Function() _onLibraryLoaded;
  final Future<void> Function() _onPlaybackLoaded;
  final Future<void> Function() _onLoadCompleted;

  int _loadEpoch = 0;
  bool _disposed = false;

  Future<void> loadPersistedState() async {
    final epoch = ++_loadEpoch;
    bool isCurrent() => !_disposed && epoch == _loadEpoch;
    try {
      await _settings.loadPersistedState();
      if (!isCurrent()) return;
      await _onSettingsLoaded();

      await Future.wait<void>(<Future<void>>[
        _library.loadPersistedState(),
        _timer.loadPersistedState(),
      ]);
      if (!isCurrent()) return;
      await _onLibraryLoaded();

      await _playback.loadPersistedState();
      if (!isCurrent()) return;
      await _onPlaybackLoaded();
    } catch (error, stackTrace) {
      AppLogService.error(
        'app_persistence_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      if (isCurrent()) await _onLoadCompleted();
    }
  }

  @override
  Future<void> reloadPersistedState() async {
    if (_disposed) return;
    _loadEpoch++;
    await _beforeReset();
    if (_disposed) return;
    await _playback.resetForBackupRestore();
    await _library.resetForBackupRestore();
    await _timer.resetForBackupRestore();
    await _settings.resetForBackupRestore();
    if (_disposed) return;
    await _afterReset();
    if (_disposed) return;
    await loadPersistedState();
  }

  void dispose() {
    _disposed = true;
    _loadEpoch++;
  }
}
