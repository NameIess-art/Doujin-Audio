part of 'app_database.dart';

typedef _SessionRestoreRows = ({
  List<Map<String, dynamic>> sessions,
  Map<String, Map<int, double>> eqBands,
  Map<String, List<Map<String, dynamic>>> queueEntries,
  Map<String, List<Map<String, dynamic>>> queueTracks,
});

extension AppDatabaseSessions on AppDatabase {
  Future<List<PlaybackSessionRecord>> loadAllSessions() async {
    final data = await _runDatabaseRead<_SessionRestoreRows?>((db) async {
      final rows = await db.rawQuery('''
      SELECT
        s.id,
        s.track_path,
        s.is_temporary,
        s.loop_mode,
        s.created_at_ms,
        s.updated_at_ms,
        s.last_played_at_ms,
        s.sort_order,
        playback.volume,
        playback.speed,
        playback.position_ms,
        playback.duration_ms,
        playback.current_queue_index,
        playback.channel_swap,
        effects.skip_silence_enabled,
        effects.noise_reduction_enabled,
        effects.volume_normalization_enabled,
        effects.eq_enabled,
        effects.eq_preset_id,
        effects.panning,
        queue.name AS queue_name,
        queue.color_value AS queue_color_value
      FROM sessions s
      LEFT JOIN session_playback_state playback ON playback.session_id = s.id
      LEFT JOIN session_audio_effects effects ON effects.session_id = s.id
      LEFT JOIN playback_queues queue ON queue.session_id = s.id
      ORDER BY s.sort_order ASC
    ''');
      if (rows.isEmpty) return null;
      final sessionIds = rows.map((row) => row['id'] as String).toList();
      final eqBandsBySession = await _loadSessionEqBandsBySession(
        db,
        sessionIds,
      );
      final queueEntriesBySession = await _loadPlaybackQueueEntriesBySession(
        db,
        sessionIds,
      );
      final queueTracksByEntry = await _loadQueueTracksByEntry(db, sessionIds);
      return (
        sessions: rows,
        eqBands: eqBandsBySession,
        queueEntries: queueEntriesBySession,
        queueTracks: queueTracksByEntry,
      );
    });
    if (data == null) return const <PlaybackSessionRecord>[];
    // Queue JSON decoding and deep immutable copies can dominate large restores.
    // Only detached query results cross the isolate boundary, never the database.
    return compute(_sessionsFromRows, data, debugLabel: 'restore_sessions');
  }

  Future<void> updateSessionOrder(List<String> sessionIds) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (var i = 0; i < sessionIds.length; i++) {
        batch.update(
          'sessions',
          {'sort_order': i},
          where: 'id = ?',
          whereArgs: [sessionIds[i]],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertSession(
    PlaybackSessionRecord session, {
    bool includeQueue = true,
    bool includeEffects = true,
  }) async {
    final queueRows = includeQueue
        ? await compute(_playbackQueueRows, session)
        : null;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      final row = _sessionCoreRow(session, session.sortOrder);
      batch.insert(
        'sessions',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      batch.update('sessions', row, where: 'id = ?', whereArgs: [session.id]);
      _writeSessionDetailsToBatch(
        batch,
        session,
        includeQueue: includeQueue,
        includeEffects: includeEffects,
        queueRows: queueRows,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteSessions(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final id in sessionIds) {
        for (final table in const [
          'playback_queue_entry_tracks',
          'playback_queue_entries',
          'playback_queues',
          'session_eq_bands',
          'session_audio_effects',
          'session_playback_state',
        ]) {
          batch.delete(table, where: 'session_id = ?', whereArgs: [id]);
        }
        batch.delete('sessions', where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> updatePlaybackQueueEntryOrder(
    String sessionId,
    List<String> entryIds,
  ) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (var i = 0; i < entryIds.length; i++) {
        batch.update(
          'playback_queue_entries',
          {'sort_order': i},
          where: 'session_id = ? AND entry_id = ?',
          whereArgs: [sessionId, entryIds[i]],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertSessionPlaybackState(PlaybackSessionRecord session) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.insert(
        'session_playback_state',
        _sessionPlaybackStateRow(session),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await batch.commit(noResult: true);
    });
  }
}

List<PlaybackSessionRecord> _sessionsFromRows(_SessionRestoreRows data) => [
  for (final row in data.sessions)
    _sessionFromRow(
      row,
      customQueueTracks: _customQueueTracksForSession(
        row['id'] as String,
        data.queueTracks,
      ),
      playbackQueue: _playbackQueueForSession(
        row['id'] as String,
        row,
        data.queueEntries,
        data.queueTracks,
      ),
      audioEffects: _sessionAudioEffectsFromRow(
        row,
        data.eqBands[row['id']] ?? const <int, double>{},
      ),
    ),
];
