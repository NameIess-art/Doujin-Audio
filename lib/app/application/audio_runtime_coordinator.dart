import 'dart:async';

import '../../features/player/application/native_playback_bridge.dart';
import 'app_runtime_lifecycle.dart';

typedef AudioRuntimeAction = FutureOr<void> Function();

/// Owns application-wide audio runtime startup, lifecycle, and shutdown.
final class AudioRuntimeCoordinator implements AppRuntimeLifecycle {
  AudioRuntimeCoordinator({
    required Stream<NativePlaybackSnapshot> snapshots,
    required Stream<NativePlaybackProgressUpdate> progressUpdates,
    required void Function() startListening,
    required Future<void> Function() stopListening,
    required void Function(NativePlaybackSnapshot snapshot) onSnapshot,
    required void Function(NativePlaybackProgressUpdate progress) onProgress,
    required AudioRuntimeAction onStart,
    required AudioRuntimeAction onEnterBackground,
    required AudioRuntimeAction onResumeForeground,
    required AudioRuntimeAction onDispose,
    AudioRuntimeAction? onMemoryPressure,
  }) : _snapshots = snapshots,
       _progressUpdates = progressUpdates,
       _startListening = startListening,
       _stopListening = stopListening,
       _onSnapshot = onSnapshot,
       _onProgress = onProgress,
       _onStart = onStart,
       _onEnterBackground = onEnterBackground,
       _onResumeForeground = onResumeForeground,
       _onDispose = onDispose,
       _onMemoryPressure = onMemoryPressure;

  final Stream<NativePlaybackSnapshot> _snapshots;
  final Stream<NativePlaybackProgressUpdate> _progressUpdates;
  final void Function() _startListening;
  final Future<void> Function() _stopListening;
  final void Function(NativePlaybackSnapshot snapshot) _onSnapshot;
  final void Function(NativePlaybackProgressUpdate progress) _onProgress;
  final AudioRuntimeAction _onStart;
  final AudioRuntimeAction _onEnterBackground;
  final AudioRuntimeAction _onResumeForeground;
  final AudioRuntimeAction _onDispose;
  final AudioRuntimeAction? _onMemoryPressure;

  StreamSubscription<NativePlaybackSnapshot>? _snapshotSubscription;
  StreamSubscription<NativePlaybackProgressUpdate>? _progressSubscription;
  Future<void>? _startFuture;
  Future<void>? _lifecycleFuture;
  bool? _lifecycleBackground;
  bool _listenersStarted = false;
  bool _started = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  @override
  Future<void> start() {
    if (_started || _disposed) return Future<void>.value();
    final active = _startFuture;
    if (active != null) return active;
    final attempt = _start();
    _startFuture = attempt;
    return attempt.whenComplete(() {
      if (identical(_startFuture, attempt)) _startFuture = null;
    });
  }

  Future<void> _start() async {
    if (!_listenersStarted) {
      _listenersStarted = true;
      _startListening();
      _snapshotSubscription = _snapshots.listen(_onSnapshot);
      _progressSubscription = _progressUpdates.listen(_onProgress);
    }
    await _onStart();
    if (!_disposed) _started = true;
  }

  @override
  Future<void> enterBackground() => _queueLifecycle(background: true);

  @override
  Future<void> resumeForeground() => _queueLifecycle(background: false);

  Future<void> _queueLifecycle({required bool background}) {
    if (!_started || _disposed) return Future<void>.value();
    final active = _lifecycleFuture;
    if (active != null && _lifecycleBackground == background) return active;

    Future<void> run() async {
      if (_disposed) return;
      if (background) {
        await _onEnterBackground();
      } else {
        _startListening();
        await _onResumeForeground();
      }
    }

    late final Future<void> queued;
    queued = (active ?? Future<void>.value())
        .then<void>(
          (_) => run(),
          // A failed transition reaches its caller without blocking the next.
          onError: (Object error, StackTrace stackTrace) => run(),
        )
        .whenComplete(() {
          if (!identical(_lifecycleFuture, queued)) return;
          _lifecycleFuture = null;
          _lifecycleBackground = null;
        });
    _lifecycleBackground = background;
    return _lifecycleFuture = queued;
  }

  @override
  Future<void> handleMemoryPressure() async {
    if (_disposed) return;
    await _onMemoryPressure?.call();
  }

  @override
  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _snapshotSubscription?.cancel();
    await _progressSubscription?.cancel();
    if (_listenersStarted) await _stopListening();
    await _onDispose();
  }
}
