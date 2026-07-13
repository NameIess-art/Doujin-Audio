part of 'app_database.dart';

extension AppDatabaseSessions on AppDatabase {
  Future<List<PersistedSession>> loadAllSessions() async {
    return _runDatabaseRead((db) async {
      final rows = await db.rawQuery('''
      SELECT
        s.id,
        s.track_path,
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
      if (rows.isEmpty) return const <PersistedSession>[];
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
      final sessions = <PersistedSession>[];
      for (final row in rows) {
        final id = row['id'] as String;
        sessions.add(
          _sessionFromRow(
            row,
            customQueueTracks: _customQueueTracksForSession(
              id,
              queueTracksByEntry,
            ),
            playbackQueue: _playbackQueueForSession(
              id,
              row,
              queueEntriesBySession,
              queueTracksByEntry,
            ),
            audioEffects: _sessionAudioEffectsFromRow(
              row,
              eqBandsBySession[id] ?? const <int, double>{},
            ),
          ),
        );
      }
      return sessions;
    });
  }

  Future<void> saveAllSessions(List<PersistedSession> sessions) async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.delete('playback_queue_entry_tracks');
      batch.delete('playback_queue_entries');
      batch.delete('playback_queues');
      batch.delete('session_eq_bands');
      batch.delete('session_audio_effects');
      batch.delete('session_playback_state');
      batch.delete('sessions');
      for (var i = 0; i < sessions.length; i++) {
        _writeSessionToBatch(batch, sessions[i], i);
      }
      await batch.commit(noResult: true);
    });
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

  Future<void> upsertSessionPlaybackState(PersistedSession session) async {
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

  Future<void> deleteAllSessions() async {
    await _runDatabaseWrite((db) async {
      final batch = db.batch();
      batch.delete('playback_queue_entry_tracks');
      batch.delete('playback_queue_entries');
      batch.delete('playback_queues');
      batch.delete('session_eq_bands');
      batch.delete('session_audio_effects');
      batch.delete('session_playback_state');
      batch.delete('sessions');
      await batch.commit(noResult: true);
    });
  }
}
