import 'dart:async';

import '../../features/player/application/notification_facade.dart';
import '../../features/player/application/playback_facade.dart';
import '../../features/player/application/timer_facade.dart';
import '../../features/player/application/playback_command_coordinator.dart';
import 'playback_keep_alive_coordinator.dart';
import 'runtime_binding.dart';

final class TimerRuntimeBinding implements RuntimeBinding {
  TimerRuntimeBinding._(this._timer);

  static final Expando<TimerRuntimeBinding> _attached =
      Expando<TimerRuntimeBinding>();

  static TimerRuntimeBinding attach({
    required TimerFacade timer,
    required PlaybackFacade playback,
    required NotificationFacade notifications,
    required PlaybackCommandCoordinator playbackCommands,
    required PlaybackKeepAliveCoordinator keepAlive,
    required void Function() syncTimerState,
  }) {
    final existing = _attached[timer];
    if (existing != null && !existing._disposed) return existing;
    timer.attachRuntime(
      hasPlayingSession: () => keepAlive.hasPlayingSession,
      sessions: () => playback.sessions.values,
      pauseSession: playbackCommands.pauseSession,
      activateAudioSession: keepAlive.activateAudioSession,
      resumeSession: (session) async {
        final fade = await playback.nativeRepository.setFadeMultiplier(
          session.id,
          0,
        );
        if (fade.isFailure) return false;
        return playbackCommands.startSession(
          session,
          shouldStartTriggerCountdown: false,
        );
      },
      onStateChanged: () {
        keepAlive.sync();
        syncTimerState();
      },
      onRuntimeRestored: () {
        notifications.syncPlaybackState();
        keepAlive.sync();
        syncTimerState();
      },
      applyFadeMultiplier: playback.applyFadeMultiplierToPlayingSessions,
      applySessionFadeMultiplier: (sessionId, multiplier) {
        unawaited(
          playback.nativeRepository.setFadeMultiplier(sessionId, multiplier),
        );
      },
      flushSessionPersistence: (sessionId) =>
          playback.flushSessionStatePersistence(sessionId: sessionId),
      setNativeTrackStop: (sessionId, enabled) async {
        final result = await playback.nativeRepository.setStopAfterCurrentTrack(
          sessionId,
          enabled,
        );
        final snapshot = result.valueOrNull;
        if (snapshot != null) playbackCommands.handleNativeSnapshot(snapshot);
        return result.isOk;
      },
    );
    final binding = TimerRuntimeBinding._(timer);
    _attached[timer] = binding;
    return binding;
  }

  final TimerFacade _timer;
  bool _disposed = false;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer.detachRuntime();
    _attached[_timer] = null;
  }
}
