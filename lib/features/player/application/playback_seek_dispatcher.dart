import 'dart:async';

import 'audio_state_services.dart';
import 'native_playback_repository.dart';
import 'playback_session.dart';

/// Coalesces native seeks while the session service remains the state owner.
final class PlaybackSeekDispatcher {
  PlaybackSeekDispatcher({
    required this.nativeRepository,
    required PlaybackSessionService service,
  }) : _service = service;

  final NativePlaybackRepository nativeRepository;
  final PlaybackSessionService _service;
  final Map<
    String,
    ({PlaybackSession session, Duration position, int generation})
  >
  _pendingNativeSeeks =
      <
        String,
        ({PlaybackSession session, Duration position, int generation})
      >{};
  final Map<String, Completer<void>> _pendingNativeSeekCompleters =
      <String, Completer<void>>{};
  final Set<String> _activeNativeSeeks = <String>{};
  Future<void> dispatch(
    PlaybackSession session,
    Duration position,
    int generation,
  ) async {
    final sessionId = session.id;
    if (_activeNativeSeeks.contains(sessionId)) {
      _pendingNativeSeeks[sessionId] = (
        session: session,
        position: position,
        generation: generation,
      );
      final completer = _pendingNativeSeekCompleters.putIfAbsent(
        sessionId,
        () => Completer<void>(),
      );
      return completer.future;
    }
    _activeNativeSeeks.add(sessionId);
    try {
      await nativeRepository.seek(sessionId, position);
    } finally {
      _activeNativeSeeks.remove(sessionId);
      final pending = _pendingNativeSeeks.remove(sessionId);
      final completer = _pendingNativeSeekCompleters.remove(sessionId);
      if (pending != null &&
          identical(_service.sessions[sessionId], pending.session) &&
          !pending.session.isDisposed &&
          pending.session.loadGeneration == pending.generation) {
        unawaited(
          dispatch(
            pending.session,
            pending.position,
            pending.generation,
          ).whenComplete(() {
            if (completer != null && !completer.isCompleted) {
              completer.complete();
            }
          }),
        );
      } else if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  void forgetSession(String sessionId) {
    _activeNativeSeeks.remove(sessionId);
    _pendingNativeSeeks.remove(sessionId);
    _pendingNativeSeekCompleters.remove(sessionId)?.complete();
  }

  void clear() {
    _activeNativeSeeks.clear();
    _pendingNativeSeeks.clear();
    for (final completer in _pendingNativeSeekCompleters.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _pendingNativeSeekCompleters.clear();
  }
}
