import '../../core/media/music_track.dart';
import '../../core/persistence/app_database.dart';
import '../../core/persistence/persistence_records.dart';
import '../../features/player/domain/audio_effects.dart';
import '../../features/player/domain/playback_persistence_repository.dart';
import '../../features/player/domain/playback_queue.dart';
import '../../features/player/domain/time_segment_label.dart';

class SqlitePlaybackRepository implements PlaybackPersistenceRepository {
  SqlitePlaybackRepository({required AppDatabase database})
    : _database = database;

  final AppDatabase _database;

  @override
  Future<List<PersistedPlaybackSession>> loadAllSessions() async =>
      (await _database.loadAllSessions())
          .map(_sessionFromRecord)
          .toList(growable: false);
  @override
  Future<void> saveAllSessions(List<PersistedPlaybackSession> sessions) =>
      _database.saveAllSessions(
        sessions.map(_sessionToRecord).toList(growable: false),
      );
  @override
  Future<void> updateSessionOrder(List<String> sessionIds) =>
      _database.updateSessionOrder(sessionIds);
  @override
  Future<void> updatePlaybackQueueEntryOrder(
    String sessionId,
    List<String> entryIds,
  ) => _database.updatePlaybackQueueEntryOrder(sessionId, entryIds);
  @override
  Future<void> upsertSessionPlaybackState(PersistedPlaybackSession session) =>
      _database.upsertSessionPlaybackState(_sessionToRecord(session));
  @override
  Future<void> upsertTracks(List<MusicTrack> tracks) =>
      _database.upsertTracks(tracks);
  @override
  Future<List<TimeSegmentLabel>> loadTimeSegmentLabels(String trackKey) async =>
      (await _database.loadTimeSegmentLabels(
        trackKey,
      )).map(_labelFromRecord).toList(growable: false);
  @override
  Future<void> upsertTimeSegmentLabel(TimeSegmentLabel label) =>
      _database.upsertTimeSegmentLabel(_labelToRecord(label));
  @override
  Future<void> deleteTimeSegmentLabel(String id) =>
      _database.deleteTimeSegmentLabel(id);
}

PlaybackSessionRecord _sessionToRecord(PersistedPlaybackSession session) =>
    PlaybackSessionRecord(
      id: session.id,
      trackPath: session.trackPath,
      loopModeIndex: session.loopModeIndex,
      volume: session.volume,
      speed: session.speed,
      positionMs: session.positionMs,
      durationMs: session.durationMs,
      customQueueTracks: session.customQueueTracks,
      playbackQueue: _queueToRecord(session.playbackQueue),
      currentQueueIndex: session.currentQueueIndex,
      channelSwapEnabled: session.channelSwapEnabled,
      audioEffects: _effectsToRecord(session.audioEffects),
      sortOrder: session.sortOrder,
      createdAtMs: session.createdAtMs,
      updatedAtMs: session.updatedAtMs,
      lastPlayedAtMs: session.lastPlayedAtMs,
    );

PersistedPlaybackSession _sessionFromRecord(PlaybackSessionRecord record) =>
    PersistedPlaybackSession(
      id: record.id,
      trackPath: record.trackPath,
      loopModeIndex: record.loopModeIndex,
      volume: record.volume,
      speed: record.speed,
      positionMs: record.positionMs,
      durationMs: record.durationMs,
      customQueueTracks: record.customQueueTracks,
      playbackQueue: _queueFromRecord(record.playbackQueue),
      currentQueueIndex: record.currentQueueIndex,
      channelSwapEnabled: record.channelSwapEnabled,
      audioEffects: _effectsFromRecord(record.audioEffects),
      sortOrder: record.sortOrder,
      createdAtMs: record.createdAtMs,
      updatedAtMs: record.updatedAtMs,
      lastPlayedAtMs: record.lastPlayedAtMs,
    );

AudioEffectsRecord _effectsToRecord(AudioEffectsState state) =>
    AudioEffectsRecord(
      skipSilenceEnabled: state.skipSilenceEnabled,
      noiseReductionEnabled: state.noiseReductionEnabled,
      volumeNormalizationEnabled: state.volumeNormalizationEnabled,
      eqEnabled: state.eqEnabled,
      eqPresetId: state.eqPresetId,
      eqBandLevels: state.eqBandLevels,
      panning: state.panning,
    );

AudioEffectsState _effectsFromRecord(AudioEffectsRecord record) =>
    AudioEffectsState(
      skipSilenceEnabled: record.skipSilenceEnabled,
      noiseReductionEnabled: record.noiseReductionEnabled,
      volumeNormalizationEnabled: record.volumeNormalizationEnabled,
      eqEnabled: record.eqEnabled,
      eqPresetId: record.eqPresetId,
      eqBandLevels: record.eqBandLevels,
      panning: record.panning,
    );

PlaybackQueueRecord? _queueToRecord(PlaybackQueueDefinition? queue) =>
    queue == null
    ? null
    : PlaybackQueueRecord(
        name: queue.name,
        colorValue: queue.colorValue,
        entries: queue.entries
            .map(
              (entry) => PlaybackQueueEntryRecord(
                id: entry.id,
                kind: entry.kind.name,
                title: entry.title,
                tracks: entry.tracks,
                workRootPath: entry.workRootPath,
              ),
            )
            .toList(growable: false),
      );

PlaybackQueueDefinition? _queueFromRecord(PlaybackQueueRecord? queue) =>
    queue == null
    ? null
    : PlaybackQueueDefinition(
        name: queue.name,
        colorValue: queue.colorValue,
        entries: queue.entries
            .map(
              (entry) => PlaybackQueueEntry(
                id: entry.id,
                kind: PlaybackQueueEntryKind.values.firstWhere(
                  (kind) => kind.name == entry.kind,
                  orElse: () => PlaybackQueueEntryKind.track,
                ),
                title: entry.title,
                tracks: entry.tracks,
                workRootPath: entry.workRootPath,
              ),
            )
            .toList(growable: false),
      );

TimeSegmentLabelRecord _labelToRecord(TimeSegmentLabel label) =>
    TimeSegmentLabelRecord(
      id: label.id,
      trackKey: label.trackKey,
      name: label.name,
      startMs: label.start.inMilliseconds,
      endMs: label.end.inMilliseconds,
      colorValue: label.colorValue,
      createdAtMs: label.createdAt.millisecondsSinceEpoch,
      updatedAtMs: label.updatedAt.millisecondsSinceEpoch,
    );

TimeSegmentLabel _labelFromRecord(TimeSegmentLabelRecord record) =>
    TimeSegmentLabel(
      id: record.id,
      trackKey: record.trackKey,
      name: record.name,
      start: Duration(milliseconds: record.startMs),
      end: Duration(milliseconds: record.endMs),
      colorValue: record.colorValue,
      createdAt: DateTime.fromMillisecondsSinceEpoch(record.createdAtMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(record.updatedAtMs),
    );
