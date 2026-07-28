import '../../../core/media/music_track.dart';
import 'audio_effects.dart';
import 'playback_queue.dart';
import 'time_segment_label.dart';

final class PersistedPlaybackSession {
  PersistedPlaybackSession({
    required this.id,
    required this.trackPath,
    required this.loopModeIndex,
    required this.volume,
    this.speed = 1,
    required this.positionMs,
    required this.durationMs,
    required this.customQueueTracks,
    this.playbackQueue,
    this.currentQueueIndex = 0,
    required this.channelSwapEnabled,
    AudioEffectsState? audioEffects,
    required this.sortOrder,
    this.createdAtMs,
    this.updatedAtMs,
    this.lastPlayedAtMs,
  }) : audioEffects = audioEffects ?? AudioEffectsState.flat;

  final String id;
  final String trackPath;
  final int loopModeIndex;
  final double volume;
  final double speed;
  final int positionMs;
  final int durationMs;
  final List<MusicTrack>? customQueueTracks;
  final PlaybackQueueDefinition? playbackQueue;
  final int currentQueueIndex;
  final bool channelSwapEnabled;
  final AudioEffectsState audioEffects;
  final int sortOrder;
  final int? createdAtMs;
  final int? updatedAtMs;
  final int? lastPlayedAtMs;
}

abstract interface class PlaybackPersistenceRepository {
  Future<List<PersistedPlaybackSession>> loadAllSessions();
  Future<void> saveAllSessions(List<PersistedPlaybackSession> sessions);
  Future<void> updateSessionOrder(List<String> sessionIds);
  Future<void> updatePlaybackQueueEntryOrder(
    String sessionId,
    List<String> entryIds,
  );
  Future<void> upsertSessionPlaybackState(PersistedPlaybackSession session);
  Future<void> upsertTracks(List<MusicTrack> tracks);
  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey);
  Future<void> upsertTimeSegmentLabel(TimeSegmentLabel label);
  Future<void> deleteTimeSegmentLabel(String id);
}
