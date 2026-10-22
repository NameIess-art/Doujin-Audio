import '../../../core/media/music_track.dart';
import 'listening_activity.dart';

/// Durable batches are imported transactionally before acknowledgement.
abstract interface class PlaybackUsageSource {
  Future<List<PlaybackUsageBatch>> readUsage();
  Future<void> acknowledgeUsage(List<String> batchIds);
  Future<void> resetUsage();
}

class PlaybackUsageBatch {
  const PlaybackUsageBatch({required this.id, required this.days});
  final String id;
  final List<PlaybackUsageDay> days;
  Map<String, Object?> toMap() => {
    'id': id,
    'days': days.map((e) => e.toMap()).toList(),
  };

  factory PlaybackUsageBatch.fromMap(Map<dynamic, dynamic> map) =>
      PlaybackUsageBatch(
        id: map['id'] as String,
        days: (map['days'] as List)
            .map((e) => PlaybackUsageDay.fromMap(e as Map))
            .toList(),
      );
}

class PlaybackUsageDay {
  const PlaybackUsageDay({
    required this.date,
    required this.totalMs,
    required this.works,
  });
  final String date;
  final int totalMs;
  final List<PlaybackUsageWork> works;
  Map<String, Object?> toMap() => {
    'date': date,
    'totalMs': totalMs,
    'works': works.map((e) => e.toMap()).toList(),
  };

  factory PlaybackUsageDay.fromMap(Map<dynamic, dynamic> map) =>
      PlaybackUsageDay(
        date: map['date'] as String,
        totalMs: (map['totalMs'] as num).toInt(),
        works: (map['works'] as List)
            .map((e) => PlaybackUsageWork.fromMap(e as Map))
            .toList(),
      );
}

class PlaybackUsageWork {
  const PlaybackUsageWork({
    required this.key,
    required this.milliseconds,
    required this.lastPlayedAtMs,
    this.uri,
    this.path,
    this.title,
    this.subtitle,
    this.artUri,
    this.descriptor,
  });
  final String key;
  final int milliseconds;
  final int lastPlayedAtMs;
  final String? uri, path, title, subtitle, artUri;
  final Map<String, Object?>? descriptor;
  Map<String, Object?> toMap() => {
    'key': key,
    'milliseconds': milliseconds,
    'lastPlayedAtMs': lastPlayedAtMs,
    'uri': uri,
    'path': path,
    'title': title,
    'subtitle': subtitle,
    'artUri': artUri,
    'descriptor': descriptor,
  };

  factory PlaybackUsageWork.fromMap(Map<dynamic, dynamic> map) =>
      PlaybackUsageWork(
        key: map['key'] as String,
        milliseconds: (map['milliseconds'] as num).toInt(),
        lastPlayedAtMs: (map['lastPlayedAtMs'] as num).toInt(),
        uri: map['uri'] as String?,
        path: map['path'] as String?,
        title: map['title'] as String?,
        subtitle: map['subtitle'] as String?,
        artUri: map['artUri'] as String?,
        descriptor: (map['descriptor'] as Map?)?.cast<String, Object?>(),
      );
}

String playbackUsageWorkKey(Map<String, Object?> item) {
  final descriptor = item['usageDescriptor'] as Map?;
  if (descriptor != null) {
    return listeningWorkKey(
      MusicTrack.fromJson(descriptor.cast<String, dynamic>()),
    );
  }
  final text = [
    item['path'],
    item['subtitle'],
    item['title'],
    item['uri'],
    descriptor?['groupKey'],
  ].join(' ');
  final rj = RegExp(r'RJ\d+', caseSensitive: false).firstMatch(text);
  if (rj != null) return 'rj:${rj.group(0)!.toUpperCase()}';
  final group = item['groupKey'] ?? descriptor?['groupKey'];
  if (group is String && group.isNotEmpty) return group;
  final path = item['path'] as String?;
  if (path != null && path.isNotEmpty && !path.startsWith('http')) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return 'local:${slash > 0 ? normalized.substring(0, slash) : normalized}';
  }
  return 'uri:${item['uri']}';
}
