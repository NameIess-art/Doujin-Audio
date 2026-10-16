import 'package:doujin_audio/features/player/application/playback_facade.dart';
import 'package:doujin_audio/features/player/application/playback_session.dart';
import 'package:doujin_audio/features/player/application/playback_command_port.dart';
import 'package:doujin_audio/features/player/application/playback_queue_resolver.dart';
import 'package:doujin_audio/features/player/application/native_playback_bridge.dart';

typedef PlaybackSessionPreparer =
    Future<bool> Function(
      PlaybackSession session, {
      required String nextPath,
      bool autoPlay,
      bool forceStartAtZero,
      bool showLoading,
      int? targetQueueIndex,
    });
typedef PlaybackSessionPauser = Future<void> Function(PlaybackSession session);
typedef PlaybackSessionStarter =
    Future<bool> Function(
      PlaybackSession session, {
      required bool shouldStartTriggerCountdown,
    });
typedef PlaybackAdvanceResolver =
    PlaybackAdvanceResult? Function(
      PlaybackSession session, {
      required bool forward,
    });
typedef PlaybackAdjacentResolver =
    bool Function(PlaybackSession session, {required bool forward});

extension TestPlaybackCommands on PlaybackFacade {
  void attachPlaybackCommands({
    required PlaybackSessionPreparer prepareSession,
    required PlaybackSessionPauser pauseSession,
    required PlaybackSessionStarter startSession,
    required PlaybackAdvanceResolver resolveAdvance,
    required PlaybackAdjacentResolver hasAdjacent,
  }) {
    attachCommandPort(
      _DelegatePlaybackCommandPort(
        prepareSession: prepareSession,
        pauseSession: pauseSession,
        startSession: startSession,
        resolveAdvance: resolveAdvance,
        hasAdjacent: hasAdjacent,
        handleNativeSnapshot: (snapshot) {
          applyNativeSnapshot(snapshot, hasLibraryTrack: (_) => false);
        },
      ),
    );
  }
}

final class _DelegatePlaybackCommandPort implements PlaybackCommandPort {
  const _DelegatePlaybackCommandPort({
    required PlaybackSessionPreparer prepareSession,
    required PlaybackSessionPauser pauseSession,
    required PlaybackSessionStarter startSession,
    required PlaybackAdvanceResolver resolveAdvance,
    required PlaybackAdjacentResolver hasAdjacent,
    required void Function(NativePlaybackSnapshot) handleNativeSnapshot,
  }) : _prepareSession = prepareSession,
       _pauseSession = pauseSession,
       _startSession = startSession,
       _resolveAdvance = resolveAdvance,
       _hasAdjacent = hasAdjacent,
       _handleNativeSnapshot = handleNativeSnapshot;

  final PlaybackSessionPreparer _prepareSession;
  final PlaybackSessionPauser _pauseSession;
  final PlaybackSessionStarter _startSession;
  final PlaybackAdvanceResolver _resolveAdvance;
  final PlaybackAdjacentResolver _hasAdjacent;
  final void Function(NativePlaybackSnapshot) _handleNativeSnapshot;

  @override
  void handleNativeSnapshot(NativePlaybackSnapshot snapshot) =>
      _handleNativeSnapshot(snapshot);

  @override
  Future<bool> prepareSession(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
    bool forceStartAtZero = false,
    bool showLoading = true,
    int? targetQueueIndex,
  }) => _prepareSession(
    session,
    nextPath: nextPath,
    autoPlay: autoPlay,
    forceStartAtZero: forceStartAtZero,
    showLoading: showLoading,
    targetQueueIndex: targetQueueIndex,
  );

  @override
  Future<bool> startSession(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  }) => _startSession(
    session,
    shouldStartTriggerCountdown: shouldStartTriggerCountdown,
  );

  @override
  Future<bool> pauseSession(PlaybackSession session) async {
    await _pauseSession(session);
    return true;
  }

  @override
  PlaybackAdvanceResult? resolveAdvance(
    PlaybackSession session, {
    required bool forward,
    bool manualAdvance = false,
  }) => _resolveAdvance(session, forward: forward);

  @override
  bool hasAdjacent(PlaybackSession session, {required bool forward}) =>
      _hasAdjacent(session, forward: forward);
}
