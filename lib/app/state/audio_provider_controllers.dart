part of 'audio_provider.dart';

class LibraryController {
  LibraryController({
    required void Function() beginBatch,
    required Future<void> Function({bool notify}) endBatch,
    required void Function(bool scanning) setScanning,
    required void Function({
      String? currentFolder,
      int? foundCount,
      int? duplicateCount,
      int? failureCount,
    })
    setScanProgress,
    required void Function(List<MusicTrack> tracks, {bool notify, bool persist})
    addTracks,
  }) : _beginBatch = beginBatch,
       _endBatch = endBatch,
       _setScanning = setScanning,
       _setScanProgress = setScanProgress,
       _addTracks = addTracks;

  final void Function() _beginBatch;
  final Future<void> Function({bool notify}) _endBatch;
  final void Function(bool scanning) _setScanning;
  final void Function({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
  })
  _setScanProgress;
  final void Function(List<MusicTrack> tracks, {bool notify, bool persist})
  _addTracks;

  void beginBatch() => _beginBatch();

  Future<void> endBatch({bool notify = true}) => _endBatch(notify: notify);

  void setScanning(bool scanning) => _setScanning(scanning);

  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
  }) {
    _setScanProgress(
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
    _addTracks(tracks, notify: notify, persist: persist);
  }
}

class PlaybackSessionController {
  PlaybackSessionController({
    required Future<void> Function(MusicTrack track, {bool? autoPlay}) spawn,
    required Future<void> Function(String sessionId) toggle,
    required Future<void> Function() pauseAll,
    required Future<void> Function() clearAll,
  }) : _spawn = spawn,
       _toggle = toggle,
       _pauseAll = pauseAll,
       _clearAll = clearAll;

  final Future<void> Function(MusicTrack track, {bool? autoPlay}) _spawn;
  final Future<void> Function(String sessionId) _toggle;
  final Future<void> Function() _pauseAll;
  final Future<void> Function() _clearAll;

  Future<void> spawn(MusicTrack track, {bool? autoPlay}) =>
      _spawn(track, autoPlay: autoPlay);

  Future<void> toggle(String sessionId) => _toggle(sessionId);

  Future<void> pauseAll() => _pauseAll();

  Future<void> clearAll() => _clearAll();
}

class TimerController {
  TimerController({
    required void Function(TimerMode mode, Duration duration) configure,
    required void Function() startCountdown,
    required void Function() cancel,
    required void Function(bool enabled, int hour, int minute) setAutoResume,
  }) : _configure = configure,
       _startCountdown = startCountdown,
       _cancel = cancel,
       _setAutoResume = setAutoResume;

  final void Function(TimerMode mode, Duration duration) _configure;
  final void Function() _startCountdown;
  final void Function() _cancel;
  final void Function(bool enabled, int hour, int minute) _setAutoResume;

  void configure(TimerMode mode, Duration duration) =>
      _configure(mode, duration);

  void startCountdown() => _startCountdown();

  void cancel() => _cancel();

  void setAutoResume(bool enabled, int hour, int minute) =>
      _setAutoResume(enabled, hour, minute);
}

class NotificationCoordinator {
  NotificationCoordinator({
    required void Function() resyncAfterResume,
    required Future<void> Function() restoreAfterSystemClear,
    required Future<void> Function() dismissAfterPauseAll,
  }) : _resyncAfterResume = resyncAfterResume,
       _restoreAfterSystemClear = restoreAfterSystemClear,
       _dismissAfterPauseAll = dismissAfterPauseAll;

  final void Function() _resyncAfterResume;
  final Future<void> Function() _restoreAfterSystemClear;
  final Future<void> Function() _dismissAfterPauseAll;

  void resyncAfterResume() => _resyncAfterResume();

  Future<void> restoreAfterSystemClear() => _restoreAfterSystemClear();

  Future<void> dismissAfterPauseAll() => _dismissAfterPauseAll();
}
