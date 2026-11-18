part of 'app_database.dart';

typedef _SessionRestoreRows = ({
  List<Map<String, dynamic>> sessions,
  Map<String, Map<int, double>> eqBands,
  Map<String, List<Map<String, dynamic>>> queueEntries,
  Map<String, List<Map<String, dynamic>>> queueTracks,
});

extension AppDatabaseSessions on AppDatabase {
  Future<List<PlaybackSessionRecord>> loadAllSessions({
    String? sessionId,
  }) async {
    final data = await _runDatabaseRead<_SessionRestoreRows?>((db) async {
      final rows = await db.rawQuery(
        '''
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
      ${sessionId == null ? '' : 'WHERE s.id = ?'}
      ORDER BY s.sort_order ASC
    ''',
        [?sessionId],
      );
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

  Future<
    List<
      ({
        PlaybackSessionRecord session,
        MusicTrack? currentTrack,
        int? entryCount,
        int? trackCount,
        bool hasCustomTracks,
      })
    >
  >
  loadSessionSummaries() async {
    final data = await _runDatabaseRead((db) async {
      final rows = await db.rawQuery('''
        SELECT s.*, p.volume, p.speed, p.position_ms, p.duration_ms,
          p.current_queue_index, p.channel_swap, e.skip_silence_enabled,
          e.noise_reduction_enabled, e.volume_normalization_enabled, e.eq_enabled,
          e.eq_preset_id, e.panning, q.name AS queue_name, q.color_value AS queue_color_value,
          q.entry_count, q.track_count,
          t.track_path AS preview_path, t.display_name, t.group_key,
          t.group_title, t.group_subtitle, t.is_single, t.is_video,
          t.duration_ms AS preview_duration_ms, t.file_size_bytes,
          t.remote_cover_url, t.remote_metadata_kind, t.remote_metadata_json,
          EXISTS(SELECT 1 FROM playback_queue_entry_tracks c
            WHERE c.session_id = s.id AND c.entry_id = '__custom_queue__') AS has_custom
        FROM sessions s
        LEFT JOIN session_playback_state p ON s.id = p.session_id
        LEFT JOIN session_audio_effects e ON s.id = e.session_id
        LEFT JOIN playback_queues q ON s.id = q.session_id
        LEFT JOIN playback_queue_entry_tracks t ON t.rowid = COALESCE(
          (SELECT c.rowid FROM playback_queue_entry_tracks c
            WHERE c.session_id = s.id AND c.track_path = s.track_path LIMIT 1),
          (SELECT c.rowid FROM playback_queue_entry_tracks c
            WHERE c.session_id = s.id AND c.entry_id = '__custom_queue__' AND c.sort_order = 0),
          (SELECT c.rowid FROM playback_queue_entries a
            JOIN playback_queue_entry_tracks c ON c.session_id = a.session_id
              AND c.entry_id = a.entry_id AND c.sort_order = 0
            WHERE a.session_id = s.id ORDER BY a.sort_order LIMIT 1))
        ORDER BY s.sort_order ASC
      ''');
      final levels = await _loadSessionEqBandsBySession(
        db,
        rows.map((row) => row['id'] as String).toList(growable: false),
      );
      return (rows, levels);
    });
    return compute(
      (data) => [
        for (final row in data.$1)
          (
            session: _sessionFromRow(
              row,
              customQueueTracks: null,
              playbackQueue: _playbackQueueForSession(
                row['id'] as String,
                row,
                const {},
                const {},
              ),
              audioEffects: _sessionAudioEffectsFromRow(
                row,
                data.$2[row['id']] ?? const {},
              ),
            ),
            currentTrack: row['preview_path'] == null
                ? null
                : _queueTrackFromRow({
                    ...row,
                    'track_path': row['preview_path'],
                    'duration_ms': row['preview_duration_ms'],
                  }),
            entryCount: row['entry_count'] as int?,
            trackCount: row['track_count'] as int?,
            hasCustomTracks: row['has_custom'] == 1,
          ),
      ],
      data,
      debugLabel: 'restore_session_summaries',
    );
  }

  Future<PlaybackQueueEntryRecord?> loadQueueEntry(
    String sessionId,
    String entryId,
  ) async {
    final rows = await _runDatabaseRead(
      (db) => db.rawQuery(
        '''
      SELECT e.entry_id, e.kind, e.title, e.work_root_path,
        t.track_path, t.display_name, t.group_key, t.group_title,
        t.group_subtitle, t.is_single, t.is_video, t.duration_ms,
        t.file_size_bytes, t.remote_cover_url, t.remote_metadata_kind,
        t.remote_metadata_json
      FROM playback_queue_entries e
      LEFT JOIN playback_queue_entry_tracks t ON t.session_id = e.session_id
        AND t.entry_id = e.entry_id
      WHERE e.session_id = ? AND e.entry_id = ?
      ORDER BY t.sort_order
    ''',
        [sessionId, entryId],
      ),
    );
    if (rows.isEmpty) return null;
    return compute(
      (rows) => _queueEntryFromRows(
        rows.first,
        rows.first['track_path'] == null ? const [] : rows,
      ),
      rows,
      debugLabel: 'read_queue_entry',
    );
  }

  Future<List<PlaybackQueueEntryPreviewRecord>> loadQueueEntryPage(
    String sessionId, {
    required int start,
    required int limit,
  }) async {
    final rows = await _runDatabaseRead(
      (db) => db.rawQuery(
        '''
      SELECT a.entry_id, a.kind, a.title, t.track_path, t.display_name,
        t.group_key, t.group_title, t.group_subtitle, t.is_single, t.is_video,
        t.duration_ms, t.file_size_bytes, t.remote_cover_url,
        t.remote_metadata_kind, t.remote_metadata_json,
        (SELECT COUNT(*) FROM playback_queue_entry_tracks c
          WHERE c.session_id = a.session_id AND c.entry_id = a.entry_id) AS track_count
      FROM playback_queue_entries a
      LEFT JOIN playback_queue_entry_tracks t ON t.session_id = a.session_id
        AND t.entry_id = a.entry_id AND t.sort_order = 0
      WHERE a.session_id = ? AND a.sort_order >= ?
      ORDER BY a.sort_order LIMIT ?
    ''',
        [sessionId, start, limit],
      ),
    );
    return compute(
      (rows) => [
        for (final row in rows)
          (
            id: row['entry_id'] as String,
            kind: row['kind'] as String,
            title: row['title'] as String,
            trackCount: row['track_count'] as int,
            firstTrack: row['track_path'] == null
                ? null
                : _queueTrackFromRow(row),
          ),
      ],
      rows,
      debugLabel: 'read_queue_entry_previews',
    );
  }

  Future<Set<String>> loadQueueContentUris() => _runDatabaseRead((db) async {
    final rows = await db.rawQuery('''
      SELECT DISTINCT track_path FROM playback_queue_entry_tracks
      WHERE track_path >= 'content://' AND track_path < 'content:/0'
    ''');
    return {for (final row in rows) row['track_path'] as String};
  });

  Future<Set<String>> findQueuesReferencingPath(String path) async {
    final rows = await _runDatabaseRead(
      (db) => db.rawQuery('''
      SELECT session_id, track_path AS path FROM playback_queue_entry_tracks
      UNION
      SELECT session_id, work_root_path AS path FROM playback_queue_entries
      WHERE work_root_path IS NOT NULL
    '''),
    );
    return compute(
      (input) => {
        for (final row in input.$1)
          if (PathMatcher.isWithinOrEqual(row['path'] as String, input.$2))
            row['session_id'] as String,
      },
      (rows, path),
      debugLabel: 'find_queue_path_references',
    );
  }

  Future<void> updateSessionOrder(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      const rowsPerStatement = _sqliteInClauseBatchSize ~/ 2;
      for (
        var start = 0;
        start < sessionIds.length;
        start += rowsPerStatement
      ) {
        final end = (start + rowsPerStatement).clamp(0, sessionIds.length);
        final values = List.filled(end - start, '(?, ?)').join(', ');
        batch.rawUpdate(
          '''
          WITH positions(id, position) AS (VALUES $values)
          UPDATE sessions SET sort_order = (SELECT position FROM positions WHERE id = sessions.id)
          WHERE sessions.id IN (SELECT id FROM positions)
            AND sort_order != (SELECT position FROM positions WHERE id = sessions.id)
        ''',
          [
            for (var index = start; index < end; index++) ...[
              sessionIds[index],
              index,
            ],
          ],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertSession(
    PlaybackSessionRecord session, {
    bool includeQueue = true,
    bool includeEffects = true,
    bool includeSessionState = true,
    Map<String, int>? queueEntryPositions,
    PlaybackQueueDeltaRecord? queueDelta,
  }) async {
    assert(!includeQueue || queueEntryPositions == null);
    assert(!includeQueue || queueDelta == null);
    final queueRows = includeQueue
        ? await compute(_playbackQueueRows, session)
        : null;
    final deltaRows = queueDelta == null
        ? null
        : await compute(_playbackQueueDeltaRows, (session.id, queueDelta));
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      if (includeSessionState) {
        final row = _sessionCoreRow(session, session.sortOrder);
        batch.insert(
          'sessions',
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        batch.update('sessions', row, where: 'id = ?', whereArgs: [session.id]);
      }
      _writeSessionDetailsToBatch(
        batch,
        session,
        includeQueue: includeQueue,
        includeEffects: includeEffects,
        includeSessionState: includeSessionState,
        queueRows: queueRows,
      );
      if (queueEntryPositions != null) {
        for (final MapEntry(key: id, value: index)
            in queueEntryPositions.entries) {
          batch.update(
            'playback_queue_entries',
            {'sort_order': index},
            where: 'session_id = ? AND entry_id = ?',
            whereArgs: [session.id, id],
          );
        }
      }
      if (queueDelta != null) {
        _writePlaybackQueueDelta(batch, session.id, queueDelta, deltaRows!);
      }
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

  Future<void> upsertSessionPlaybackStates(
    Iterable<PlaybackSessionRecord> sessions,
  ) async {
    if (sessions.isEmpty) return;
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      for (final session in sessions) {
        // A late progress write must not recreate state for a deleted session.
        batch.rawInsert(
          '''
          INSERT OR REPLACE INTO session_playback_state
            (session_id, volume, speed, position_ms, duration_ms, current_queue_index, channel_swap)
          SELECT id, ?, ?, ?, ?, ?, ? FROM sessions WHERE id = ?
        ''',
          [
            session.volume,
            session.speed,
            session.positionMs,
            session.durationMs,
            session.currentQueueIndex,
            session.channelSwapEnabled ? 1 : 0,
            session.id,
          ],
        );
      }
      await batch.commit(noResult: true);
    });
  }
}

List<PlaybackSessionRecord> _sessionsFromRows(_SessionRestoreRows data) => [
  for (final row in data.sessions) _restoreSessionFromRows(row, data),
];

PlaybackSessionRecord _restoreSessionFromRows(
  Map<String, dynamic> row,
  _SessionRestoreRows data,
) {
  final id = row['id'] as String;
  final queue = _playbackQueueForSession(
    id,
    row,
    data.queueEntries,
    data.queueTracks,
  );
  final custom = _customQueueTracksForSession(id, data.queueTracks);
  return _sessionFromRow(
    row,
    customQueueTracks: queue == null || custom == null
        ? custom
        : [custom.first, for (final entry in queue.entries) ...entry.tracks],
    playbackQueue: queue,
    audioEffects: _sessionAudioEffectsFromRow(
      row,
      data.eqBands[row['id']] ?? const <int, double>{},
    ),
  );
}
