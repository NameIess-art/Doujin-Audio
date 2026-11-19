import 'package:flutter/foundation.dart' show compute;

import '../../core/media/music_track.dart';
import '../../core/persistence/app_database.dart';
import '../../core/persistence/persistence_records.dart';
import '../../features/player/domain/audio_effects.dart';
import '../../features/player/domain/playback_persistence_repository.dart';
import '../../features/player/domain/playback_queue.dart';
import '../../features/player/domain/time_segment_label.dart';

class SqlitePlaybackRepository
    implements PlaybackPersistenceRepository, PlaybackQueueStorage {
  SqlitePlaybackRepository({required AppDatabase database})
    : _database = database;

  final AppDatabase _database;

  @override
  Future<List<PersistedPlaybackSession>> loadAllSessions() async =>
      (await _database.loadAllSessions())
          .map(_sessionFromRecord)
          .toList(growable: false);

  @override
  Future<
    List<
      ({
        PersistedPlaybackSession session,
        MusicTrack? currentTrack,
        bool requiresQueueLoad,
      })
    >
  >
  loadSessionSummaries() async => [
    for (final summary in await _database.loadSessionSummaries())
      (
        session: _sessionFromRecord(
          summary.session,
          entryCount: summary.entryCount,
          trackCount: summary.trackCount,
        ),
        currentTrack: summary.currentTrack,
        requiresQueueLoad:
            summary.hasCustomTracks || (summary.entryCount ?? 0) > 0,
      ),
  ];

  @override
  Future<PersistedPlaybackSession?> loadSessionQueue(String sessionId) async {
    final records = await _database.loadAllSessions(sessionId: sessionId);
    if (records.isEmpty) return null;
    return compute(
      _sessionFromRecord,
      records.single,
      debugLabel: 'decode_session_queue',
    );
  }

  @override
  Future<PlaybackQueueEntry?> loadQueueEntry(
    String sessionId,
    String entryId,
  ) async {
    final entry = await _database.loadQueueEntry(sessionId, entryId);
    return entry == null ? null : _entryFromRecord(entry);
  }

  @override
  Future<List<PlaybackQueueEntryPreview>> loadQueueEntryPage(
    String sessionId, {
    required int start,
    required int limit,
  }) async => [
    for (final entry in await _database.loadQueueEntryPage(
      sessionId,
      start: start,
      limit: limit,
    ))
      (
        id: entry.id,
        kind: _entryKind(entry.kind),
        title: entry.title,
        trackCount: entry.trackCount,
        firstTrack: entry.firstTrack,
      ),
  ];

  @override
  Future<Set<String>> loadQueueContentUris() =>
      _database.loadQueueContentUris();

  @override
  Future<Set<String>> findQueuesReferencingPath(String path) =>
      _database.findQueuesReferencingPath(path);

  @override
  Future<void> upsertSessionDelta(
    PersistedPlaybackSession session, {
    required PersistedPlaybackSession previous,
    required bool includeQueue,
    required bool includeEffects,
    bool includeSessionState = true,
  }) async {
    if (includeQueue &&
        previous.playbackQueue != null &&
        session.playbackQueue == null) {
      await upsertSession(session, includeEffects: includeEffects);
      return;
    }
    await _database.upsertSession(
      _sessionToRecord(
        session,
        includeQueue: false,
        includeEffects: includeEffects,
      ),
      includeQueue: false,
      includeEffects: includeEffects,
      includeSessionState: includeSessionState,
      queueDelta: includeQueue ? _queueDelta(previous, session) : null,
    );
  }

  @override
  Future<void> upsertSession(
    PersistedPlaybackSession session, {
    bool includeQueue = true,
    bool includeEffects = true,
    Map<String, int>? queueEntryPositions,
  }) async {
    final record = includeQueue
        ? await compute(
            (input) => _sessionToRecord(input.$1, includeEffects: input.$2),
            (session, includeEffects),
          )
        : _sessionToRecord(
            session,
            includeQueue: false,
            includeEffects: includeEffects,
          );
    await _database.upsertSession(
      record,
      includeQueue: includeQueue,
      includeEffects: includeEffects,
      queueEntryPositions: queueEntryPositions,
    );
  }

  @override
  Future<void> deleteSessions(List<String> sessionIds) =>
      _database.deleteSessions(sessionIds);
  @override
  Future<void> updateSessionOrder(List<String> sessionIds) =>
      _database.updateSessionOrder(sessionIds);
  @override
  Future<void> upsertSessionPlaybackStates(
    List<PersistedPlaybackSession> sessions,
  ) => _database.upsertSessionPlaybackStates(
    sessions.map(
      (session) =>
          _sessionToRecord(session, includeQueue: false, includeEffects: false),
    ),
  );
  @override
  Future<void> updateTrackPlaybackHistory(List<MusicTrack> tracks) =>
      _database.updateTrackPlaybackHistory(tracks);
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

PlaybackSessionRecord _sessionToRecord(
  PersistedPlaybackSession session, {
  bool includeQueue = true,
  bool includeEffects = true,
}) => PlaybackSessionRecord(
  id: session.id,
  trackPath: session.trackPath,
  isTemporary: session.isTemporary,
  loopModeIndex: session.loopModeIndex,
  volume: session.volume,
  speed: session.speed,
  positionMs: session.positionMs,
  durationMs: session.durationMs,
  customQueueTracks: includeQueue ? session.customQueueTracks : null,
  playbackQueue: includeQueue ? _queueToRecord(session.playbackQueue) : null,
  currentQueueIndex: session.currentQueueIndex,
  channelSwapEnabled: session.channelSwapEnabled,
  audioEffects: includeEffects ? _effectsToRecord(session.audioEffects) : null,
  sortOrder: session.sortOrder,
  createdAtMs: session.createdAtMs,
  updatedAtMs: session.updatedAtMs,
  lastPlayedAtMs: session.lastPlayedAtMs,
);

PersistedPlaybackSession _sessionFromRecord(
  PlaybackSessionRecord record, {
  int? entryCount,
  int? trackCount,
}) => PersistedPlaybackSession(
  id: record.id,
  trackPath: record.trackPath,
  isTemporary: record.isTemporary,
  loopModeIndex: record.loopModeIndex,
  volume: record.volume,
  speed: record.speed,
  positionMs: record.positionMs,
  durationMs: record.durationMs,
  customQueueTracks: record.customQueueTracks,
  playbackQueue: _queueFromRecord(
    record.playbackQueue,
    entryCount: entryCount,
    trackCount: trackCount,
  ),
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
      frontBack: state.frontBack,
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
      frontBack: record.frontBack,
    );

PlaybackQueueRecord? _queueToRecord(PlaybackQueueDefinition? queue) =>
    queue == null
    ? null
    : PlaybackQueueRecord(
        name: queue.name,
        colorValue: queue.colorValue,
        entries: queue.entries.map(_entryToRecord).toList(growable: false),
      );

PlaybackQueueEntryRecord _entryToRecord(PlaybackQueueEntry entry) =>
    PlaybackQueueEntryRecord(
      id: entry.id,
      kind: entry.kind.name,
      title: entry.title,
      tracks: entry.tracks,
      workRootPath: entry.workRootPath,
    );

PlaybackQueueEntryKind _entryKind(String kind) =>
    kind == 'work' ? PlaybackQueueEntryKind.work : PlaybackQueueEntryKind.track;

PlaybackQueueEntry _entryFromRecord(PlaybackQueueEntryRecord entry) =>
    PlaybackQueueEntry(
      id: entry.id,
      kind: _entryKind(entry.kind),
      title: entry.title,
      tracks: entry.tracks,
      workRootPath: entry.workRootPath,
    );

PlaybackQueueDefinition? _queueFromRecord(
  PlaybackQueueRecord? queue, {
  int? entryCount,
  int? trackCount,
}) => queue == null
    ? null
    : PlaybackQueueDefinition(
        name: queue.name,
        colorValue: queue.colorValue,
        storedEntryCount: entryCount,
        storedTrackCount: trackCount,
        entries: queue.entries.map(_entryFromRecord).toList(growable: false),
      );

PlaybackQueueDeltaRecord _queueDelta(
  PersistedPlaybackSession previous,
  PersistedPlaybackSession next,
) {
  final before = previous.playbackQueue;
  final after = next.playbackQueue;
  final deleted = <String>[];
  final upserted =
      <({PlaybackQueueEntryRecord entry, int position, bool writeTracks})>[];
  final moved = <String, int>{};
  if (after != null && !identical(before?.entries, after.entries)) {
    final old = {
      for (final (index, entry)
          in (before?.entries ?? const <PlaybackQueueEntry>[]).indexed)
        entry.id: (index, entry),
    };
    for (final (index, entry) in after.entries.indexed) {
      final prior = old.remove(entry.id);
      if (prior == null || !identical(prior.$2, entry)) {
        upserted.add((
          entry: _entryToRecord(entry),
          position: index,
          writeTracks:
              prior == null || !identical(prior.$2.tracks, entry.tracks),
        ));
      } else if (prior.$1 != index) {
        moved[entry.id] = index;
      }
    }
    deleted.addAll(old.keys);
  }
  List<MusicTrack>? storedCustom(PersistedPlaybackSession session) {
    final queue = session.playbackQueue;
    final custom = session.customQueueTracks;
    if (queue == null) return custom;
    return custom?.length == queue.trackCount + 1 ? [custom!.first] : null;
  }

  final beforeCustom = storedCustom(previous);
  final afterCustom = storedCustom(next);
  return (
    header:
        after == null ||
            (before != null &&
                before.name == after.name &&
                before.colorValue == after.colorValue &&
                before.entryCount == after.entryCount &&
                before.trackCount == after.trackCount)
        ? null
        : (
            name: after.name,
            colorValue: after.colorValue,
            entryCount: after.entryCount,
            trackCount: after.trackCount,
          ),
    deleted: deleted,
    upserted: upserted,
    moved: moved,
    replaceCustomTracks:
        !identical(beforeCustom, afterCustom) &&
        !(before != null &&
            after != null &&
            identical(beforeCustom?.first, afterCustom?.first)),
    customTracks: afterCustom,
  );
}

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
