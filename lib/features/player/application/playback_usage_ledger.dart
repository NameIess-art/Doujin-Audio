import 'package:flutter/foundation.dart';

import '../domain/playback_usage.dart';

/// Counts audible wall time, independent of position, playback speed or UI ticks.
class PlaybackUsageLedger {
  PlaybackUsageLedger({required this.elapsed, DateTime Function()? now})
    : now = now ?? DateTime.now;
  final Duration Function() elapsed;
  final DateTime Function() now;
  final _active = <String, ({String key, Map<String, Object?> item})>{};
  final _days = <String, _UsageDay>{};
  final _pending = <PlaybackUsageBatch>[];
  Duration? _anchor;
  DateTime? _wall;
  int _sequence = 0;
  String _epoch = DateTime.now().microsecondsSinceEpoch.toString();
  int _revision = 0;

  int get revision => _revision;

  void update(String sessionId, Map<String, Object?>? playingItem) {
    settle();
    if (playingItem == null) {
      _active.remove(sessionId);
    } else if (!mapEquals(_active[sessionId]?.item, playingItem)) {
      _active[sessionId] = (
        key: playbackUsageWorkKey(playingItem),
        item: Map.of(playingItem),
      );
    }
  }

  void settle() {
    final tick = elapsed();
    final wall = now();
    var remaining = _anchor == null ? 0 : (tick - _anchor!).inMilliseconds;
    var start = _wall ?? wall;
    _anchor = tick;
    _wall = wall;
    if (_active.isEmpty || remaining <= 0) return;
    final works = <String, Map<String, Object?>>{};
    for (final entry in _active.values) {
      works[entry.key] = entry.item;
    }
    while (remaining > 0) {
      final midnight = DateTime(start.year, start.month, start.day + 1);
      final untilMidnight = midnight.difference(start).inMilliseconds;
      final span = remaining < untilMidnight ? remaining : untilMidnight;
      final date =
          '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
      final day = _days.putIfAbsent(date, _UsageDay.new);
      day.total += span;
      for (final entry in works.entries) {
        final old = day.works[entry.key];
        day.works[entry.key] = PlaybackUsageWork(
          key: entry.key,
          milliseconds: (old?.milliseconds ?? 0) + span,
          lastPlayedAtMs: start.millisecondsSinceEpoch + span,
          uri: entry.value['uri'] as String?,
          path: entry.value['path'] as String?,
          title: entry.value['title'] as String?,
          subtitle: entry.value['subtitle'] as String?,
          artUri: entry.value['artUri'] as String?,
          descriptor: (entry.value['usageDescriptor'] as Map?)
              ?.cast<String, Object?>(),
        );
      }
      remaining -= span;
      start = midnight;
    }
  }

  List<PlaybackUsageBatch> read() {
    checkpoint();
    return List.unmodifiable(_pending);
  }

  void checkpoint() {
    settle();
    if (_days.isEmpty) return;
    _pending.add(
      PlaybackUsageBatch(
        id: 'windows:$_epoch:${++_sequence}',
        days: [
          for (final day in _days.entries)
            PlaybackUsageDay(
              date: day.key,
              totalMs: day.value.total,
              works: day.value.works.values.toList(),
            ),
        ],
      ),
    );
    _days.clear();
    _revision++;
  }

  /// Encodes only batches already frozen by a read or checkpoint.
  Map<String, Object?> exportState() => {
    'batches': _pending.map((e) => e.toMap()).toList(),
    'epoch': _epoch,
    'sequence': _sequence,
  };

  void restoreState(Map<String, dynamic> state) {
    _epoch = state['epoch'] as String;
    _sequence = (state['sequence'] as num).toInt();
    _pending.insertAll(
      0,
      (state['batches'] as List)
          .map((e) => PlaybackUsageBatch.fromMap(e as Map))
          .toList(),
    );
    _revision++;
  }

  void acknowledge(List<String> ids) {
    final previousCount = _pending.length;
    final acknowledged = ids.toSet();
    _pending.removeWhere((batch) => acknowledged.contains(batch.id));
    if (_pending.length != previousCount) _revision++;
  }

  void reset() {
    _days.clear();
    if (_pending.isNotEmpty) _revision++;
    _pending.clear();
    _anchor = elapsed();
    _wall = now();
  }
}

class _UsageDay {
  int total = 0;
  final works = <String, PlaybackUsageWork>{};
}
