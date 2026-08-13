part of 'app_database.dart';

Future<List<Map<String, dynamic>>> _queryFullTrackRows(
  DatabaseExecutor db, {
  String? path,
  int? limit,
}) {
  final where = path == null ? '' : 'WHERE t.path = ?';
  final limitSql = limit == null ? '' : 'LIMIT $limit';
  return db.rawQuery('''
      SELECT
        t.path,
        t.display_name,
        t.group_key,
        t.group_title,
        t.group_subtitle,
        t.is_single,
        t.is_video,
        t.duration_ms,
        scan.scanned_at_ms,
        scan.file_size_bytes,
        scan.modified_at_ms,
        scan.scan_generation,
        playback.last_played_position_ms,
        playback.last_played_at_ms,
        playback.is_favorite,
        assets.cover_cache_path,
        assets.lyrics_path,
        assets.manual_cover_path,
        assets.remote_cover_url,
        remote.remote_metadata_kind,
        remote.remote_metadata_json
      FROM tracks t
      LEFT JOIN track_scan_info scan ON scan.path = t.path
      LEFT JOIN track_playback_state playback ON playback.path = t.path
      LEFT JOIN track_assets assets ON assets.path = t.path
      LEFT JOIN track_remote_metadata remote ON remote.path = t.path
      $where
      $limitSql
    ''', path == null ? null : [path]);
}

Future<List<Map<String, dynamic>>> _queryStartupTrackRows(DatabaseExecutor db) {
  return db.rawQuery('''
      SELECT
        t.path,
        t.display_name,
        t.group_key,
        t.group_title,
        t.group_subtitle,
        t.is_single,
        t.is_video,
        t.duration_ms,
        scan.scanned_at_ms,
        scan.file_size_bytes,
        scan.modified_at_ms,
        playback.last_played_position_ms,
        playback.last_played_at_ms,
        playback.is_favorite,
        assets.cover_cache_path,
        assets.lyrics_path,
        assets.manual_cover_path,
        assets.remote_cover_url,
        remote.remote_metadata_kind
      FROM tracks t
      LEFT JOIN track_scan_info scan ON scan.path = t.path
      LEFT JOIN track_playback_state playback ON playback.path = t.path
      LEFT JOIN track_assets assets ON assets.path = t.path
      LEFT JOIN track_remote_metadata remote ON remote.path = t.path
    ''');
}

Future<Map<String, List<String>>> _loadTrackTags(
  DatabaseExecutor db, {
  Iterable<String>? paths,
}) async {
  final args = paths?.toList(growable: false);
  final where = args == null || args.isEmpty
      ? ''
      : 'WHERE path IN (${List.filled(args.length, '?').join(', ')})';
  final rows = await db.rawQuery(
    'SELECT path, tag FROM track_tags $where ORDER BY sort_order ASC',
    args,
  );
  final tagsByPath = <String, List<String>>{};
  for (final row in rows) {
    final path = row['path'] as String;
    final tag = row['tag'] as String;
    tagsByPath.putIfAbsent(path, () => <String>[]).add(tag);
  }
  return tagsByPath.map(
    (path, tags) => MapEntry(path, List<String>.unmodifiable(tags)),
  );
}

void _writeTrackToBatch(Batch batch, MusicTrack track, {int? scanGeneration}) {
  batch.insert(
    'tracks',
    _trackCoreRow(track),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  batch.insert(
    'track_scan_info',
    _trackScanRow(track, scanGeneration: scanGeneration),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  batch.insert(
    'track_playback_state',
    _trackPlaybackRow(track),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  batch.insert(
    'track_assets',
    _trackAssetsRow(track),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  batch.insert(
    'track_remote_metadata',
    _trackRemoteMetadataRow(track),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  batch.delete('track_tags', where: 'path = ?', whereArgs: [track.path]);
  for (var i = 0; i < track.tags.length; i++) {
    batch.insert('track_tags', {
      'path': track.path,
      'tag': track.tags[i],
      'sort_order': i,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

Map<String, dynamic> _trackCoreRow(MusicTrack t) => {
  'path': t.path,
  'display_name': t.displayName,
  'group_key': t.groupKey,
  'group_title': t.groupTitle,
  'group_subtitle': t.groupSubtitle,
  'is_single': t.isSingle ? 1 : 0,
  'is_video': t.isVideo ? 1 : 0,
  'duration_ms': t.duration.inMilliseconds,
};

Map<String, dynamic> _trackScanRow(MusicTrack t, {int? scanGeneration}) => {
  'path': t.path,
  'scanned_at_ms': t.scannedAt?.millisecondsSinceEpoch,
  'file_size_bytes': t.fileSizeBytes,
  'modified_at_ms': t.modifiedAt?.millisecondsSinceEpoch,
  'scan_generation': scanGeneration ?? 0,
};

Map<String, dynamic> _trackPlaybackRow(MusicTrack t) => {
  'path': t.path,
  'last_played_position_ms': t.lastPlayedPosition.inMilliseconds,
  'last_played_at_ms': t.lastPlayedAt?.millisecondsSinceEpoch,
  'is_favorite': t.isFavorite ? 1 : 0,
};

Map<String, dynamic> _trackAssetsRow(MusicTrack t) => {
  'path': t.path,
  'cover_cache_path': t.coverCachePath,
  'lyrics_path': t.lyricsPath,
  'manual_cover_path': t.manualCoverPath,
  'remote_cover_url': t.remoteCoverUrl,
};

Map<String, dynamic> _trackRemoteMetadataRow(MusicTrack t) => {
  'path': t.path,
  'remote_metadata_kind': t.remoteMetadataKind,
  'remote_metadata_json': _encodeJsonMap(t.remoteMetadata),
};

MusicTrack _trackSummaryFromRow(Map<String, dynamic> row) => MusicTrack(
  path: row['path'] as String,
  displayName: row['display_name'] as String,
  groupKey: row['group_key'] as String,
  groupTitle: row['group_title'] as String,
  groupSubtitle: row['group_subtitle'] as String,
  isSingle: (row['is_single'] as int) == 1,
  isVideo: (row['is_video'] as int? ?? 0) == 1,
  duration: Duration(milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0),
);

MusicTrack _trackStartupFromRow(Map<String, dynamic> row) => MusicTrack(
  path: row['path'] as String,
  displayName: row['display_name'] as String,
  groupKey: row['group_key'] as String,
  groupTitle: row['group_title'] as String,
  groupSubtitle: row['group_subtitle'] as String,
  isSingle: (row['is_single'] as int) == 1,
  isVideo: (row['is_video'] as int? ?? 0) == 1,
  scannedAt: _dateTimeFromMs(row['scanned_at_ms']),
  fileSizeBytes: (row['file_size_bytes'] as num?)?.toInt(),
  modifiedAt: _dateTimeFromMs(row['modified_at_ms']),
  lastPlayedPosition: Duration(
    milliseconds: (row['last_played_position_ms'] as num?)?.toInt() ?? 0,
  ),
  lastPlayedAt: _dateTimeFromMs(row['last_played_at_ms']),
  isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
  coverCachePath: row['cover_cache_path'] as String?,
  lyricsPath: row['lyrics_path'] as String?,
  manualCoverPath: row['manual_cover_path'] as String?,
  remoteCoverUrl: row['remote_cover_url'] as String?,
  remoteMetadataKind: row['remote_metadata_kind'] as String?,
  duration: Duration(milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0),
);

MusicTrack _trackFromRow(Map<String, dynamic> row, List<String>? tags) =>
    MusicTrack(
      path: row['path'] as String,
      displayName: row['display_name'] as String,
      groupKey: row['group_key'] as String,
      groupTitle: row['group_title'] as String,
      groupSubtitle: row['group_subtitle'] as String,
      isSingle: (row['is_single'] as int) == 1,
      isVideo: (row['is_video'] as int? ?? 0) == 1,
      scannedAt: _dateTimeFromMs(row['scanned_at_ms']),
      fileSizeBytes: (row['file_size_bytes'] as num?)?.toInt(),
      modifiedAt: _dateTimeFromMs(row['modified_at_ms']),
      lastPlayedPosition: Duration(
        milliseconds: (row['last_played_position_ms'] as num?)?.toInt() ?? 0,
      ),
      lastPlayedAt: _dateTimeFromMs(row['last_played_at_ms']),
      isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
      tags: tags ?? const <String>[],
      coverCachePath: row['cover_cache_path'] as String?,
      lyricsPath: row['lyrics_path'] as String?,
      manualCoverPath: row['manual_cover_path'] as String?,
      remoteCoverUrl: row['remote_cover_url'] as String?,
      remoteMetadataKind: row['remote_metadata_kind'] as String?,
      remoteMetadata: _decodeJsonMap(row['remote_metadata_json']),
      duration: Duration(
        milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0,
      ),
    );

Map<String, dynamic> _libraryEntryToRow(
  LibraryEntryRecord entry, {
  int? scanGeneration,
}) => {
  'library_path': PathMatcher.normalize(entry.libraryPath),
  'path': PathMatcher.normalize(entry.path),
  'kind': entry.kind,
  'state': entry.state,
  'parent_path': entry.parentPath == null
      ? null
      : PathMatcher.normalize(entry.parentPath!),
  'display_name': entry.displayName,
  'group_key': entry.groupKey,
  'group_title': entry.groupTitle,
  'group_subtitle': entry.groupSubtitle,
  'is_single': entry.isSingle ? 1 : 0,
  'is_video': entry.isVideo ? 1 : 0,
  'scanned_at_ms': entry.scannedAt?.millisecondsSinceEpoch,
  'file_size_bytes': entry.fileSizeBytes,
  'modified_at_ms': entry.modifiedAt?.millisecondsSinceEpoch,
  'scan_generation': scanGeneration ?? 0,
};

LibraryEntryRecord _libraryEntryFromRow(Map<String, dynamic> row) {
  return LibraryEntryRecord(
    libraryPath: row['library_path'] as String,
    path: row['path'] as String,
    kind: row['kind'] as String,
    state: row['state'] as String,
    parentPath: row['parent_path'] as String?,
    displayName: row['display_name'] as String? ?? '',
    groupKey: row['group_key'] as String? ?? '',
    groupTitle: row['group_title'] as String? ?? '',
    groupSubtitle: row['group_subtitle'] as String? ?? '',
    isSingle: (row['is_single'] as int? ?? 0) == 1,
    isVideo: (row['is_video'] as int? ?? 0) == 1,
    scannedAt: _dateTimeFromMs(row['scanned_at_ms']),
    fileSizeBytes: (row['file_size_bytes'] as num?)?.toInt(),
    modifiedAt: _dateTimeFromMs(row['modified_at_ms']),
  );
}

Future<Map<int, List<String>>> _loadAsmrWorkTextValues(
  DatabaseExecutor db, {
  required String table,
  required String idColumn,
  required String valueColumn,
  required List<int> ids,
}) async {
  if (ids.isEmpty) return const <int, List<String>>{};
  final placeholders = List.filled(ids.length, '?').join(', ');
  final rows = await db.rawQuery(
    'SELECT $idColumn, $valueColumn FROM $table '
    'WHERE $idColumn IN ($placeholders) ORDER BY sort_order ASC',
    ids,
  );
  final valuesById = <int, List<String>>{};
  for (final row in rows) {
    final id = (row[idColumn] as num?)?.toInt();
    final value = row[valueColumn] as String?;
    if (id == null || value == null) continue;
    valuesById.putIfAbsent(id, () => <String>[]).add(value);
  }
  return valuesById.map(
    (id, values) => MapEntry(id, List<String>.unmodifiable(values)),
  );
}

void _writeAsmrWorkToBatch(
  Batch batch,
  AsmrWorkRecord work, {
  bool? isFavorite,
}) {
  batch.insert('asmr_works', {
    'id': work.id,
    'title': work.title,
    'circle_name': work.circleName,
    'source_id': work.sourceId,
    'source_type': work.sourceType,
    'source_url': work.sourceUrl,
    'cover_url': work.coverUrl,
    'thumbnail_url': work.thumbnailUrl,
    'main_cover_url': work.mainCoverUrl,
    'release_date_ms': work.releaseDate?.millisecondsSinceEpoch,
    'create_date_ms': work.createDate?.millisecondsSinceEpoch,
    'duration_ms': work.duration.inMilliseconds,
    'dl_count': work.dlCount,
    'review_count': work.reviewCount,
    'rating': work.rating,
    'has_subtitle': work.hasSubtitle ? 1 : 0,
    'is_favorite': (isFavorite ?? work.isFavorite) ? 1 : 0,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  batch.delete(
    'asmr_work_voice_actors',
    where: 'work_id = ?',
    whereArgs: [work.id],
  );
  for (var i = 0; i < work.voiceActors.length; i++) {
    batch.insert('asmr_work_voice_actors', {
      'work_id': work.id,
      'name': work.voiceActors[i],
      'sort_order': i,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  batch.delete('asmr_work_tags', where: 'work_id = ?', whereArgs: [work.id]);
  for (var i = 0; i < work.tags.length; i++) {
    batch.insert('asmr_work_tags', {
      'work_id': work.id,
      'tag': work.tags[i],
      'sort_order': i,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

void _replaceAsmrWorkListInBatch(
  Batch batch,
  String listType,
  List<AsmrWorkRecord> works,
) {
  for (final work in works) {
    _writeAsmrWorkToBatch(batch, work);
  }
  _replaceAsmrWorkListMembershipInBatch(batch, listType, works);
}

void _replaceAsmrWorkListMembershipInBatch(
  Batch batch,
  String listType,
  List<AsmrWorkRecord> works,
) {
  batch.delete(
    'asmr_work_lists',
    where: 'list_type = ?',
    whereArgs: [listType],
  );
  for (var i = 0; i < works.length; i++) {
    batch.insert('asmr_work_lists', {
      'list_type': listType,
      'work_id': works[i].id,
      'sort_order': i,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

void _replaceAsmrSyncOperationsInBatch(
  Batch batch,
  List<AsmrSyncOperationRecord> operations,
) {
  batch.delete('asmr_sync_operations');
  for (var i = 0; i < operations.length; i++) {
    final operation = operations[i];
    batch.insert('asmr_sync_operations', {
      'type': operation.type,
      'work_id': operation.workId,
      'source_id': operation.sourceId,
      'created_at_ms': operation.createdAt.millisecondsSinceEpoch,
      'retry_count': operation.retryCount,
      'sort_order': i,
    });
  }
}

AsmrWorkRecord _asmrWorkFromRow(
  Map<String, dynamic> row, {
  List<String>? voiceActors,
  List<String>? tags,
}) {
  return AsmrWorkRecord(
    id: (row['id'] as num?)?.toInt() ?? 0,
    title: row['title'] as String? ?? '',
    circleName: row['circle_name'] as String? ?? '',
    sourceId: row['source_id'] as String? ?? '',
    sourceType: row['source_type'] as String? ?? '',
    sourceUrl: row['source_url'] as String? ?? '',
    coverUrl: row['cover_url'] as String? ?? '',
    thumbnailUrl: row['thumbnail_url'] as String? ?? '',
    mainCoverUrl: row['main_cover_url'] as String? ?? '',
    releaseDate: _dateTimeFromMs(row['release_date_ms']),
    createDate: _dateTimeFromMs(row['create_date_ms']),
    duration: Duration(
      milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0,
    ),
    dlCount: (row['dl_count'] as num?)?.toInt() ?? 0,
    reviewCount: (row['review_count'] as num?)?.toInt() ?? 0,
    rating: (row['rating'] as num?)?.toDouble() ?? 0,
    voiceActors: voiceActors ?? const <String>[],
    tags: tags ?? const <String>[],
    hasSubtitle: (row['has_subtitle'] as int? ?? 0) == 1,
    isFavorite: (row['is_favorite'] as int? ?? 0) == 1,
  );
}

Map<String, dynamic> _sessionCoreRow(
  PlaybackSessionRecord session,
  int sortOrder,
) => {
  'id': session.id,
  'track_path': session.trackPath,
  'loop_mode': session.loopModeIndex,
  'created_at_ms': session.createdAtMs,
  'updated_at_ms': session.updatedAtMs,
  'last_played_at_ms': session.lastPlayedAtMs,
  'sort_order': sortOrder,
};

Map<String, dynamic> _sessionPlaybackStateRow(PlaybackSessionRecord session) =>
    {
      'session_id': session.id,
      'volume': session.volume,
      'speed': session.speed,
      'position_ms': session.positionMs,
      'duration_ms': session.durationMs,
      'current_queue_index': session.currentQueueIndex,
      'channel_swap': session.channelSwapEnabled ? 1 : 0,
    };

Map<String, dynamic> _sessionAudioEffectsRow(PlaybackSessionRecord session) => {
  'session_id': session.id,
  'skip_silence_enabled': session.audioEffects.skipSilenceEnabled ? 1 : 0,
  'noise_reduction_enabled': session.audioEffects.noiseReductionEnabled ? 1 : 0,
  'volume_normalization_enabled':
      session.audioEffects.volumeNormalizationEnabled ? 1 : 0,
  'eq_enabled': session.audioEffects.eqEnabled ? 1 : 0,
  'eq_preset_id': session.audioEffects.eqPresetId,
  'panning': session.audioEffects.panning,
};

void _writeSessionToBatch(
  Batch batch,
  PlaybackSessionRecord session,
  int sortOrder,
) {
  batch.insert(
    'sessions',
    _sessionCoreRow(session, sortOrder),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  _writeSessionDetailsToBatch(batch, session);
}

void _writeSessionDetailsToBatch(Batch batch, PlaybackSessionRecord session) {
  batch.insert(
    'session_playback_state',
    _sessionPlaybackStateRow(session),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  batch.insert(
    'session_audio_effects',
    _sessionAudioEffectsRow(session),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  batch.delete(
    'session_eq_bands',
    where: 'session_id = ?',
    whereArgs: [session.id],
  );
  for (final entry in session.audioEffects.eqBandLevels.entries) {
    batch.insert('session_eq_bands', {
      'session_id': session.id,
      'frequency_hz': entry.key,
      'gain_db': entry.value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  _writePlaybackQueueToBatch(batch, session);
}

void _writePlaybackQueueToBatch(Batch batch, PlaybackSessionRecord session) {
  batch.delete(
    'playback_queue_entry_tracks',
    where: 'session_id = ?',
    whereArgs: [session.id],
  );
  batch.delete(
    'playback_queue_entries',
    where: 'session_id = ?',
    whereArgs: [session.id],
  );
  batch.delete(
    'playback_queues',
    where: 'session_id = ?',
    whereArgs: [session.id],
  );
  final queue = session.playbackQueue;
  if (queue == null) {
    final customTracks = session.customQueueTracks;
    if (customTracks == null) return;
    for (var i = 0; i < customTracks.length; i++) {
      batch.insert(
        'playback_queue_entry_tracks',
        _queueTrackRow(
          sessionId: session.id,
          entryId: '__custom_queue__',
          track: customTracks[i],
          duplicateIndex: i,
          sortOrder: i,
        ),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    return;
  }
  batch.insert('playback_queues', {
    'session_id': session.id,
    'name': queue.name,
    'color_value': queue.colorValue,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  for (var entryIndex = 0; entryIndex < queue.entries.length; entryIndex++) {
    final entry = queue.entries[entryIndex];
    batch.insert('playback_queue_entries', {
      'session_id': session.id,
      'entry_id': entry.id,
      'kind': entry.kind,
      'title': entry.title,
      'work_root_path': entry.workRootPath,
      'sort_order': entryIndex,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (var trackIndex = 0; trackIndex < entry.tracks.length; trackIndex++) {
      batch.insert(
        'playback_queue_entry_tracks',
        _queueTrackRow(
          sessionId: session.id,
          entryId: entry.id,
          track: entry.tracks[trackIndex],
          duplicateIndex: trackIndex,
          sortOrder: trackIndex,
        ),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
}

Map<String, dynamic> _queueTrackRow({
  required String sessionId,
  required String entryId,
  required MusicTrack track,
  required int duplicateIndex,
  required int sortOrder,
}) => {
  'session_id': sessionId,
  'entry_id': entryId,
  'track_path': track.path,
  'display_name': track.displayName,
  'group_key': track.groupKey,
  'group_title': track.groupTitle,
  'group_subtitle': track.groupSubtitle,
  'is_single': track.isSingle ? 1 : 0,
  'is_video': track.isVideo ? 1 : 0,
  'duration_ms': track.duration.inMilliseconds,
  'file_size_bytes': track.fileSizeBytes,
  'remote_cover_url': track.remoteCoverUrl,
  'remote_metadata_kind': track.remoteMetadataKind,
  'remote_metadata_json': _encodeJsonMap(track.remoteMetadata),
  'duplicate_index': duplicateIndex,
  'sort_order': sortOrder,
};

PlaybackSessionRecord _sessionFromRow(
  Map<String, dynamic> row, {
  required List<MusicTrack>? customQueueTracks,
  required PlaybackQueueRecord? playbackQueue,
  required AudioEffectsRecord audioEffects,
}) => PlaybackSessionRecord(
  id: row['id'] as String,
  trackPath: row['track_path'] as String,
  loopModeIndex: row['loop_mode'] as int,
  volume: (row['volume'] as num?)?.toDouble() ?? 1.0,
  speed: (row['speed'] as num?)?.toDouble() ?? 1.0,
  positionMs: (row['position_ms'] as num?)?.toInt() ?? 0,
  durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
  customQueueTracks: customQueueTracks,
  playbackQueue: playbackQueue,
  currentQueueIndex: (row['current_queue_index'] as num?)?.toInt() ?? 0,
  channelSwapEnabled: (row['channel_swap'] as int? ?? 0) == 1,
  audioEffects: audioEffects,
  createdAtMs: (row['created_at_ms'] as num?)?.toInt(),
  updatedAtMs: (row['updated_at_ms'] as num?)?.toInt(),
  lastPlayedAtMs: (row['last_played_at_ms'] as num?)?.toInt(),
  sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
);

Future<Map<String, Map<int, double>>> _loadSessionEqBandsBySession(
  DatabaseExecutor db,
  List<String> sessionIds,
) async {
  final levelsBySession = <String, Map<int, double>>{};
  for (final ids in _sessionIdChunks(sessionIds)) {
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await db.rawQuery('''
        SELECT session_id, frequency_hz, gain_db
        FROM session_eq_bands
        WHERE session_id IN ($placeholders)
        ORDER BY session_id ASC, frequency_hz ASC
      ''', ids);
    for (final row in rows) {
      final sessionId = row['session_id'] as String?;
      final frequency = (row['frequency_hz'] as num?)?.toInt();
      final gain = (row['gain_db'] as num?)?.toDouble();
      if (sessionId == null || frequency == null || gain == null) continue;
      levelsBySession.putIfAbsent(sessionId, () => <int, double>{})[frequency] =
          gain;
    }
  }
  return levelsBySession;
}

Future<Map<String, List<Map<String, dynamic>>>>
_loadPlaybackQueueEntriesBySession(
  DatabaseExecutor db,
  List<String> sessionIds,
) async {
  final entriesBySession = <String, List<Map<String, dynamic>>>{};
  for (final ids in _sessionIdChunks(sessionIds)) {
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await db.rawQuery('''
        SELECT session_id, entry_id, kind, title, work_root_path, sort_order
        FROM playback_queue_entries
        WHERE session_id IN ($placeholders)
        ORDER BY session_id ASC, sort_order ASC
      ''', ids);
    for (final row in rows) {
      final sessionId = row['session_id'] as String?;
      if (sessionId == null) continue;
      entriesBySession
          .putIfAbsent(sessionId, () => <Map<String, dynamic>>[])
          .add(row);
    }
  }
  return entriesBySession;
}

Future<Map<String, List<Map<String, dynamic>>>> _loadQueueTracksByEntry(
  DatabaseExecutor db,
  List<String> sessionIds,
) async {
  final tracksByEntry = <String, List<Map<String, dynamic>>>{};
  for (final ids in _sessionIdChunks(sessionIds)) {
    final placeholders = List.filled(ids.length, '?').join(', ');
    final rows = await db.rawQuery('''
        SELECT
          session_id,
          entry_id,
          track_path,
          display_name,
          group_key,
          group_title,
          group_subtitle,
          is_single,
          is_video,
          duration_ms,
          file_size_bytes,
          remote_cover_url,
          remote_metadata_kind,
          remote_metadata_json,
          duplicate_index,
          sort_order
        FROM playback_queue_entry_tracks
        WHERE session_id IN ($placeholders)
        ORDER BY session_id ASC, entry_id ASC, sort_order ASC
      ''', ids);
    for (final row in rows) {
      final sessionId = row['session_id'] as String?;
      final entryId = row['entry_id'] as String?;
      if (sessionId == null || entryId == null) continue;
      tracksByEntry
          .putIfAbsent(
            _queueEntryKey(sessionId, entryId),
            () => <Map<String, dynamic>>[],
          )
          .add(row);
    }
  }
  return tracksByEntry;
}

AudioEffectsRecord _sessionAudioEffectsFromRow(
  Map<String, dynamic> row,
  Map<int, double> levels,
) {
  return AudioEffectsRecord(
    skipSilenceEnabled: (row['skip_silence_enabled'] as int? ?? 0) == 1,
    noiseReductionEnabled: (row['noise_reduction_enabled'] as int? ?? 0) == 1,
    volumeNormalizationEnabled:
        (row['volume_normalization_enabled'] as int? ?? 0) == 1,
    eqEnabled: (row['eq_enabled'] as int? ?? 0) == 1,
    eqPresetId: (row['eq_preset_id'] as String?)?.trim().isEmpty ?? true
        ? null
        : row['eq_preset_id'] as String?,
    eqBandLevels: Map<int, double>.unmodifiable(levels),
    panning: (row['panning'] as num?)?.toDouble() ?? 0.0,
  );
}

List<MusicTrack>? _customQueueTracksForSession(
  String sessionId,
  Map<String, List<Map<String, dynamic>>> queueTracksByEntry,
) {
  final rows =
      queueTracksByEntry[_queueEntryKey(sessionId, '__custom_queue__')];
  if (rows == null) return null;
  if (rows.isEmpty) return null;
  return rows.map(_queueTrackFromRow).toList(growable: false);
}

PlaybackQueueRecord? _playbackQueueForSession(
  String sessionId,
  Map<String, dynamic> sessionRow,
  Map<String, List<Map<String, dynamic>>> queueEntriesBySession,
  Map<String, List<Map<String, dynamic>>> queueTracksByEntry,
) {
  final queueName = sessionRow['queue_name'] as String?;
  if (queueName == null) return null;
  final entryRows =
      queueEntriesBySession[sessionId] ?? const <Map<String, dynamic>>[];
  final entries = <PlaybackQueueEntryRecord>[];
  for (final entryRow in entryRows) {
    final entryId = entryRow['entry_id'] as String;
    final trackRows =
        queueTracksByEntry[_queueEntryKey(sessionId, entryId)] ??
        const <Map<String, dynamic>>[];
    entries.add(
      PlaybackQueueEntryRecord(
        id: entryId,
        kind: entryRow['kind'] as String? ?? 'track',
        title: entryRow['title'] as String? ?? '',
        workRootPath: entryRow['work_root_path'] as String?,
        tracks: trackRows.map(_queueTrackFromRow).toList(growable: false),
      ),
    );
  }
  return PlaybackQueueRecord(
    name: queueName,
    colorValue: (sessionRow['queue_color_value'] as num?)?.toInt(),
    entries: entries,
  );
}

Iterable<List<String>> _sessionIdChunks(List<String> sessionIds) sync* {
  for (
    var start = 0;
    start < sessionIds.length;
    start += _sqliteInClauseBatchSize
  ) {
    final end = (start + _sqliteInClauseBatchSize).clamp(0, sessionIds.length);
    yield sessionIds.sublist(start, end);
  }
}

String _queueEntryKey(String sessionId, String entryId) =>
    '$sessionId\n$entryId';

MusicTrack _queueTrackFromRow(Map<String, dynamic> row) => MusicTrack(
  path: row['track_path'] as String,
  displayName: row['display_name'] as String? ?? '',
  groupKey: row['group_key'] as String? ?? '',
  groupTitle: row['group_title'] as String? ?? '',
  groupSubtitle: row['group_subtitle'] as String? ?? '',
  isSingle: (row['is_single'] as int? ?? 0) == 1,
  isVideo: (row['is_video'] as int? ?? 0) == 1,
  duration: Duration(milliseconds: (row['duration_ms'] as num?)?.toInt() ?? 0),
  fileSizeBytes: (row['file_size_bytes'] as num?)?.toInt(),
  remoteCoverUrl: row['remote_cover_url'] as String?,
  remoteMetadataKind: row['remote_metadata_kind'] as String?,
  remoteMetadata: _decodeJsonMap(row['remote_metadata_json']),
);

DateTime? _dateTimeFromMs(Object? value) {
  if (value is num && value > 0) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return null;
}

String? _encodeJsonMap(Map<String, Object?>? value) {
  if (value == null || value.isEmpty) return null;
  return json.encode(value);
}

Map<String, Object?>? _decodeJsonMap(Object? value) {
  if (value is! String || value.isEmpty) return null;
  try {
    final raw = json.decode(value);
    if (raw is! Map) return null;
    return raw.cast<String, Object?>();
  } catch (_) {
    return null;
  }
}

List<MusicTrack> _startupTracksFromRows(List<Map<String, Object?>> rows) {
  return rows.map(_trackStartupFromRow).toList(growable: false);
}
