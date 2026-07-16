import 'dart:async';

import '../../features/player/application/native_playback_bridge.dart';

typedef AudioRuntimeAction = FutureOr<void> Function();

/// Owns application-wide audio runtime startup, lifecycle, and shutdown.
final class AudioRuntimeCoordinator {
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
  }) : _snapshots = snapshots,
       _progressUpdates = progressUpdates,
       _startListening = startListening,
       _stopListening = stopListening,
       _onSnapshot = onSnapshot,
       _onProgress = onProgress,
       _onStart = onStart,
       _onEnterBackground = onEnterBackground,
       _onResumeForeground = onResumeForeground,
       _onDispose = onDispose;

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

  StreamSubscription<NativePlaybackSnapshot>? _snapshotSubscription;
  StreamSubscription<NativePlaybackProgressUpdate>? _progressSubscription;
  bool _started = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _startListening();
    _snapshotSubscription = _snapshots.listen(_onSnapshot);
    _progressSubscription = _progressUpdates.listen(_onProgress);
    await _onStart();
  }

  Future<void> enterBackground() async {
    if (!_started || _disposed) return;
    await _onEnterBackground();
  }

  Future<void> resumeForeground() async {
    if (!_started || _disposed) return;
    await _onResumeForeground();
  }

  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _snapshotSubscription?.cancel();
    await _progressSubscription?.cancel();
    if (_started) await _stopListening();
    await _onDispose();
  }
}
