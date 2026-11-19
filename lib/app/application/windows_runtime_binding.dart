import 'dart:async';

import '../../core/platform/windows_desktop_service.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import 'app_runtime_lifecycle.dart';

/// Owns desktop commands from bootstrap through runtime shutdown.
class WindowsRuntimeBinding {
  WindowsRuntimeBinding({WindowsDesktopService? desktop})
    : _desktop = desktop ?? WindowsDesktopService.instance;

  final WindowsDesktopService _desktop;
  AppRuntimeLifecycle? _runtime;
  PlaybackFacade? _playback;
  NotificationFacade? _notifications;
  TimerFacade? _timer;
  void Function()? _invalidateInitialization;
  Future<void>? _attachment;
  Future<void>? _initialization;
  Future<void>? _shutdown;
  bool _closing = false;
  bool _endingSession = false;
  bool _stateLoaded = false;
  final _pausedByTaskbar = <String>{};
  bool _taskbarPauseIncomplete = false;
  final Set<Future<void>> _inFlightActions = <Future<void>>{};

  Future<void> attach() => _attachment ??= _desktop.attach(_onAction);

  void bindRuntime({
    required AppRuntimeLifecycle runtime,
    required PlaybackFacade playback,
    required NotificationFacade notifications,
    required TimerFacade timer,
    void Function()? invalidateInitialization,
  }) {
    if (_closing || _runtime != null) {
      throw StateError('Windows runtime is closing or already attached');
    }
    _runtime = runtime;
    _playback = playback;
    _notifications = notifications;
    _timer = timer;
    _invalidateInitialization = invalidateInitialization;
  }

  Future<void> initializeStartup(Future<void> Function() initialize) =>
      _initialize(initialize, loadRuntime: false);

  Future<void> initializeRuntime(Future<void> Function() initialize) =>
      _initialize(initialize, loadRuntime: true);

  Future<void> _initialize(
    Future<void> Function() initialize, {
    required bool loadRuntime,
  }) {
    if (_closing) return Future.error(StateError('Windows runtime is closing'));
    final active = _initialization;
    if (active != null) return active;
    late final Future<void> attempt;
    attempt = Future<void>.sync(initialize)
        .then((_) {
          if (_closing) {
            throw StateError('Windows initialization was invalidated');
          }
          if (loadRuntime) _stateLoaded = true;
        })
        .whenComplete(() {
          if (identical(_initialization, attempt)) _initialization = null;
        });
    return _initialization = attempt;
  }

  Future<void> _onAction(String action) async {
    if (action == 'exit' || action == 'endSession') {
      if (action == 'endSession') _endingSession = true;
      if (!_closing) {
        _closing = true;
        _invalidateInitialization?.call();
      }
      await (_shutdown ??= _saveAndDispose(closeWindow: action == 'exit'));
      return;
    }
    if (!_stateLoaded || _closing) return;
    late final Future<void> task;
    task = _runAction(action).whenComplete(() => _inFlightActions.remove(task));
    _inFlightActions.add(task);
    await task;
  }

  Future<void> _runAction(String action) async {
    final runtime = _runtime!;
    final playback = _playback!;
    final notifications = _notifications!;
    switch (action) {
      case 'play':
        await notifications.playPrimarySession();
      case 'pause':
        await notifications.pausePrimarySession();
      case 'toggle':
        await notifications.togglePrimarySessionPlayPause();
      case 'taskbarToggle':
        if (playback.hasActivePlayback) {
          if (!_taskbarPauseIncomplete) _pausedByTaskbar.clear();
          await playback.pauseAllSessions(onPaused: _pausedByTaskbar.addAll);
          _taskbarPauseIncomplete = playback.hasActivePlayback;
        } else if (_pausedByTaskbar.isNotEmpty) {
          _taskbarPauseIncomplete = false;
          final resumeIds = _pausedByTaskbar.toList();
          _pausedByTaskbar.clear();
          for (final id in resumeIds) {
            final session = playback.sessionById(id);
            if (session != null && !session.playbackRequested) {
              await playback.toggleSessionPlayPause(id);
            }
          }
        } else {
          await notifications.playPrimarySession();
        }
      case 'next':
        await notifications.skipPrimarySessionToNext();
      case 'previous':
        await notifications.skipPrimarySessionToPrevious();
      case 'resume':
        await runtime.resumeForeground();
      case 'background':
        await runtime.enterBackground();
      case 'deviceDisconnected':
        await playback.handleAudioDeviceDisconnected();
    }
  }

  Future<void> _saveAndDispose({required bool closeWindow}) async {
    final initialization = _initialization;
    if (initialization != null) {
      // The bootstrap caller receives the error; shutdown still drains its work.
      try {
        await initialization;
      } catch (_) {
        // Initialization errors are reported by AppBootstrapController; cleanup
        // must still release the partially created runtime.
      }
    }
    while (_inFlightActions.isNotEmpty) {
      for (final action in _inFlightActions.toList()) {
        try {
          await action;
        } catch (_) {
          // Action errors are returned to their caller; shutdown still drains.
        }
      }
    }
    Object? firstError;
    StackTrace? firstStack;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }

    if (_stateLoaded) {
      await attempt(_playback!.savePersistedState);
      await attempt(_timer!.saveRuntime);
    }
    if (_runtime != null) await attempt(_runtime!.dispose);
    // Windows needs the channel reply before WM_ENDSESSION returns.
    if (closeWindow && !_endingSession) await attempt(_desktop.exit);
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
  }
}
