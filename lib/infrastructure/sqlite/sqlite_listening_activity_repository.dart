import 'dart:convert';

import '../../core/media/music_track.dart';
import '../../core/persistence/app_database.dart';
import '../../core/persistence/persistence_records.dart';
import '../../features/player/domain/listening_activity.dart';

final class SqliteListeningActivityRepository
    implements ListeningActivityRepository {
  SqliteListeningActivityRepository({required AppDatabase database})
    : _database = database;
  final AppDatabase _database;

  @override
  Future<bool> importBatch(
    String batchId,
    List<ListeningDayContribution> days,
  ) => _database.importListeningBatch(batchId, [
    for (final day in days)
      ListeningDayRecord(
        date: day.date,
        totalMs: day.totalMs,
        works: [
          for (final work in day.works)
            ListeningWorkRecord(
              workKey: work.workKey,
              track: work.track,
              milliseconds: work.milliseconds,
              lastPlayedAtMs: work.lastPlayedAtMs,
            ),
        ],
      ),
  ]);

  @override
  Future<List<ListeningDay>> loadDays() async => [
    for (final row in await _database.loadListeningDays())
      ListeningDay(
        date: DateTime.parse(row['date'] as String),
        duration: Duration(milliseconds: row['milliseconds'] as int),
      ),
  ];

  @override
  Future<Map<String, int>> loadWorkTotalMilliseconds(
    Iterable<String> workKeys,
  ) => _database.loadListeningWorkTotalMilliseconds(workKeys);

  @override
  Future<int> countHistory() => _database.countListeningHistory();

  @override
  Future<List<ListeningHistoryEntry>> loadHistory({
    int offset = 0,
    int limit = 40,
  }) async => [
    for (final row in await _database.loadListeningHistory(
      offset: offset,
      limit: limit,
    ))
      _historyEntry(row),
  ];

  @override
  Future<ListeningHistoryEntry?> removeHistoryEntry(String workKey) async {
    final row = await _database.removeListeningHistoryEntry(workKey);
    return row == null ? null : _historyEntry(row);
  }

  @override
  Future<void> restoreHistoryEntry(ListeningHistoryEntry entry) =>
      _database.restoreListeningHistoryEntry(
        _historyRecord(entry),
        legacyOrder: entry.legacyOrder,
      );

  @override
  Future<MusicTrack?> findTrack(String workKey) async {
    final row = await _database.findListeningTrack(workKey);
    return row == null ? null : _track(row);
  }

  @override
  Future<void> seedHistory(List<ListeningHistoryEntry> entries) =>
      _database.seedListeningHistory(entries.map(_historyRecord).toList());
}

ListeningHistoryEntry _historyEntry(Map<String, Object?> row) {
  final playedAtMs = row['last_played_at_ms'] as int;
  return ListeningHistoryEntry(
    workKey: row['work_key'] as String,
    track: _track(row),
    lastPlayedAt: playedAtMs == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(playedAtMs),
    legacyOrder: row['legacy_order'] as int,
  );
}

ListeningWorkRecord _historyRecord(ListeningHistoryEntry entry) =>
    ListeningWorkRecord(
      workKey: entry.workKey,
      track: entry.track,
      milliseconds: 0,
      lastPlayedAtMs: entry.lastPlayedAt?.millisecondsSinceEpoch ?? 0,
    );

MusicTrack _track(Map<String, Object?> row) => MusicTrack.fromJson(
  Map<String, dynamic>.from(jsonDecode(row['track_json'] as String) as Map),
);
