import 'dart:async';

import '../../core/logging/app_log_service.dart';
import '../../core/platform/windows_desktop_service.dart';
import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import 'app_lifecycle_binding.dart';
import 'app_runtime_lifecycle.dart';

/// Owns desktop commands from bootstrap through runtime shutdown.
class WindowsRuntimeBinding {
  static const defaultEndSessionDrainBudget = Duration(milliseconds: 800);

  WindowsRuntimeBinding({
    WindowsDesktopService? desktop,
    Duration endSessionDrainBudget = defaultEndSessionDrainBudget,
  }) : _desktop = desktop ?? WindowsDesktopService.instance,
       _endSessionDrainBudget = endSessionDrainBudget;

  final WindowsDesktopService _desktop;
  final Duration _endSessionDrainBudget;
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
  String? _pendingLifecycleAction;
  final _pausedByTaskbar = <String>{};
  bool _taskbarPauseIncomplete = false;
  final Set<Future<void>> _inFlightActions = <Future<void>>{};

  Future<void> attach() => _attachment ??= _attach();

  Future<void> _attach() async {
    try {
      await _desktop.attach(_onAction);
    } catch (_) {
      _attachment = null;
      rethrow;
    }
  }

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
        .then((_) async {
          if (_closing) {
            throw StateError('Windows initialization was invalidated');
          }
          if (loadRuntime) {
            _stateLoaded = true;
            final pendingLifecycle = _pendingLifecycleAction;
            _pendingLifecycleAction = null;
            if (pendingLifecycle != null && _runtime != null) {
              try {
                await _dispatchAction(pendingLifecycle);
              } catch (error, stackTrace) {
                AppLogService.warning(
                  'windows_runtime_deferred_lifecycle_failed',
                  error: error,
                  stackTrace: stackTrace,
                );
              }
            }
          }
        })
        .whenComplete(() {
          if (identical(_initialization, attempt)) _initialization = null;
        });
    return _initialization = attempt;
  }

  Future<void> _onAction(String action) async {
    if (action == 'exit' || action == 'endSession') {
      if (action == 'endSession') _endingSession = true;
      _pendingLifecycleAction = null;
      if (!_closing) {
        _closing = true;
        _invalidateInitialization?.call();
      }
      await (_shutdown ??= _saveAndDispose(closeWindow: action == 'exit'));
      return;
    }
    if (_closing) return;
    if (!_stateLoaded) {
      if (action == 'background' || action == 'resume') {
        _pendingLifecycleAction = action;
      }
      return;
    }
    await _dispatchAction(action);
  }

  Future<void> _dispatchAction(String action) {
    late final Future<void> task;
    task = _runAction(action).whenComplete(() => _inFlightActions.remove(task));
    _inFlightActions.add(task);
    return task;
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
          final toResume = <Future<void>>[
            for (final id in resumeIds)
              if (playback.sessionById(id) case final session?
                  when !session.playbackRequested)
                playback.toggleSessionPlayPause(id),
          ];
          if (toResume.isNotEmpty) await Future.wait<void>(toResume);
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
    final drainDeadline = _endingSession ? (Stopwatch()..start()) : null;
    final initialization = _initialization;
    if (initialization != null) {
      // The bootstrap caller receives the error; shutdown still drains its work.
      try {
        if (drainDeadline != null) {
          final remaining = _endSessionDrainBudget - drainDeadline.elapsed;
          if (remaining > Duration.zero) {
            await initialization.timeout(remaining, onTimeout: () {});
          }
        } else {
          await initialization;
        }
      } catch (_) {
        // Initialization errors are reported by AppBootstrapController; cleanup
        // must still release the partially created runtime.
      }
    }
    while (_inFlightActions.isNotEmpty) {
      final batch = _inFlightActions.toList();
      final waitBatch = Future.wait<void>(
        batch.map<Future<void>>((action) async {
          try {
            await action;
          } catch (_) {
            // Action errors are returned to their caller; shutdown still drains.
          }
        }),
      );
      if (drainDeadline != null) {
        final remaining = _endSessionDrainBudget - drainDeadline.elapsed;
        if (remaining <= Duration.zero) break;
        var timedOut = false;
        await waitBatch.timeout(
          remaining,
          onTimeout: () {
            timedOut = true;
            return const <void>[];
          },
        );
        if (timedOut) break;
      } else {
        await waitBatch;
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
      await Future.wait<void>([
        attempt(_playback!.savePersistedState),
        attempt(_timer!.saveRuntime),
      ]);
    }
    if (_runtime != null) {
      await attempt(() {
        final runtime = _runtime!;
        if (runtime is AppLifecycleBinding) {
          return runtime.dispose(fastShutdown: _endingSession);
        }
        return runtime.dispose();
      });
    }
    // Windows needs the channel reply before WM_ENDSESSION returns.
    if (closeWindow && !_endingSession) await attempt(_desktop.exit);
    if (firstError != null) Error.throwWithStackTrace(firstError!, firstStack!);
  }
}
