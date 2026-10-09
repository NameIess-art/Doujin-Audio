import 'dart:async';

import '../../../core/errors/native_result.dart';
import '../../../core/logging/app_log_service.dart';
import 'audio_state_services.dart';
import 'native_playback_bridge.dart';
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
  final _runs = <String, _SeekRun>{};

  Future<void> dispatch(
    PlaybackSession session,
    Duration position,
    int generation, {
    required bool Function(NativePlaybackSnapshot) correctPosition,
  }) {
    var run = _runs[session.id];
    if (run != null && !identical(run.session, session)) {
      forgetSession(session.id);
      run = null;
    }
    final start = run == null;
    run ??= _SeekRun(session);
    _runs[session.id] = run;
    final completer = run.pending?.completer ?? Completer<void>();
    run.pending = _SeekRequest(
      position: position,
      generation: generation,
      path: session.currentTrackPath,
      queueIndex: session.currentQueueIndex,
      revision: ++run.revision,
      correctPosition: correctPosition,
      completer: completer,
    );
    if (start) unawaited(_drain(run));
    return completer.future;
  }

  bool _isCurrent(_SeekRun run, _SeekRequest request) =>
      identical(_runs[run.session.id], run) &&
      identical(_service.sessions[run.session.id], run.session) &&
      !run.session.isDisposed &&
      run.session.loadGeneration == request.generation &&
      run.session.currentTrackPath == request.path &&
      run.session.currentQueueIndex == request.queueIndex &&
      run.revision == request.revision;

  Future<void> _drain(_SeekRun run) async {
    while (identical(_runs[run.session.id], run) && run.pending != null) {
      final request = run.pending!;
      run.pending = null;
      try {
        if (_isCurrent(run, request)) await _seek(run, request);
      } catch (error, stackTrace) {
        AppLogService.warning(
          'PlaybackSeekDispatcher.seek failed sessionId=${run.session.id}',
          error: error,
          stackTrace: stackTrace,
        );
      } finally {
        _complete(request);
      }
    }
    // A removed session can be replaced with the same ID while native work runs.
    if (identical(_runs[run.session.id], run)) _runs.remove(run.session.id);
  }

  Future<void> _seek(_SeekRun run, _SeekRequest request) async {
    NativeResult<NativePlaybackSnapshot> response;
    try {
      response = await nativeRepository.seek(run.session.id, request.position);
    } catch (error, stackTrace) {
      response = NativeFailure(
        error.toString(),
        details: stackTrace,
      );
    }
    // Normal native events own successful seek state.
    if (response.isOk) return;
    AppLogService.warning(
      'PlaybackSeekDispatcher.seek failed code=${response.errorCodeOrNull} '
      'sessionId=${run.session.id} error=${response.errorOrNull} '
      'details=${response.errorDetailsOrNull}',
    );
    if (!_isCurrent(run, request)) return;

    // A previous optimistic position may also belong to a failed seek. Read the
    // existing authoritative source instead of rolling back to that position.
    try {
      final bundle = await nativeRepository.snapshot();
      if (!_isCurrent(run, request)) return;
      final snapshots = bundle.valueOrNull?.sessions;
      NativePlaybackSnapshot? snapshot;
      if (snapshots != null) {
        for (final candidate in snapshots) {
          if (candidate.sessionId == run.session.id) {
            snapshot = candidate;
            break;
          }
        }
      }
      if (snapshot == null ||
          snapshot.queueIndex != request.queueIndex ||
          !request.correctPosition(snapshot)) {
        AppLogService.warning(
          'PlaybackSeekDispatcher.seek correction unavailable '
          'sessionId=${run.session.id} code=${bundle.errorCodeOrNull} '
          'error=${bundle.errorOrNull}',
        );
      }
    } catch (error, stackTrace) {
      AppLogService.warning(
        'PlaybackSeekDispatcher.seek correction failed '
        'sessionId=${run.session.id}',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  static void _complete(_SeekRequest? request) {
    if (request != null && !request.completer.isCompleted) {
      request.completer.complete();
    }
  }

  void forgetSession(String sessionId) =>
      _complete(_runs.remove(sessionId)?.pending);

  void clear() {
    for (final run in _runs.values) {
      _complete(run.pending);
    }
    _runs.clear();
  }
}

final class _SeekRun {
  _SeekRun(this.session);
  final PlaybackSession session;
  int revision = 0;
  _SeekRequest? pending;
}

final class _SeekRequest {
  const _SeekRequest({
    required this.position,
    required this.generation,
    required this.path,
    required this.queueIndex,
    required this.revision,
    required this.correctPosition,
    required this.completer,
  });
  final Duration position;
  final int generation;
  final String path;
  final int queueIndex;
  final int revision;
  final bool Function(NativePlaybackSnapshot) correctPosition;
  final Completer<void> completer;
}
