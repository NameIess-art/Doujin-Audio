import 'playback_queue_resolver.dart';
import 'playback_session.dart';

abstract interface class PlaybackCommandPort {
  Future<bool> prepareSession(
    PlaybackSession session, {
    required String nextPath,
    bool autoPlay = true,
    bool forceStartAtZero = false,
    bool showLoading = true,
    int? targetQueueIndex,
  });

  Future<bool> startSession(
    PlaybackSession session, {
    required bool shouldStartTriggerCountdown,
  });

  Future<bool> pauseSession(PlaybackSession session);

  PlaybackAdvanceResult? resolveAdvance(
    PlaybackSession session, {
    required bool forward,
  });

  bool hasAdjacent(PlaybackSession session, {required bool forward});
}
