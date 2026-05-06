part of 'audio_provider.dart';

class LibraryController {
  LibraryController._(this._provider);

  final AudioProvider _provider;

  void beginBatch() => _provider.beginLibraryBatch();

  Future<void> endBatch({bool notify = true}) {
    return _provider.endLibraryBatch(notify: notify);
  }

  void setScanning(bool scanning) => _provider.setScanning(scanning);

  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
  }) {
    _provider.setScanProgress(
      currentFolder: currentFolder,
      foundCount: foundCount,
      duplicateCount: duplicateCount,
      failureCount: failureCount,
    );
  }

  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    _provider.addTracks(tracks, notify: notify, persist: persist);
  }
}

class PlaybackSessionController {
  PlaybackSessionController._(this._provider);

  final AudioProvider _provider;

  Future<void> spawn(MusicTrack track, {bool? autoPlay}) {
    return _provider.spawnSession(track, autoPlay: autoPlay);
  }

  Future<void> toggle(String sessionId) {
    return _provider.toggleSessionPlayPause(sessionId);
  }

  Future<void> pauseAll() => _provider.pauseAllSessions();

  Future<void> clearAll() => _provider.clearAllSessions();
}

class TimerController {
  TimerController._(this._provider);

  final AudioProvider _provider;

  void configure(TimerMode mode, Duration duration) {
    _provider.configureTimer(mode, duration);
  }

  void startCountdown() => _provider.startCountdown();

  void cancel() => _provider.cancelTimer();

  void setAutoResume(bool enabled, int hour, int minute) {
    _provider.setAutoResume(enabled, hour, minute);
  }
}

class NotificationCoordinator {
  NotificationCoordinator._(this._provider);

  final AudioProvider _provider;

  void resyncAfterResume() => _provider.resyncNotificationsAfterResume();

  Future<void> restoreAfterSystemClear() {
    return _provider.restoreNotificationsAfterSystemClear();
  }

  Future<void> dismissAfterPauseAll() {
    return _provider.dismissNotificationsAfterPauseAll();
  }
}
