import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';

enum PlaybackQueueEntryKind { track, work }

class PlaybackQueueEntry {
  PlaybackQueueEntry({
    required this.id,
    required this.kind,
    required this.title,
    required List<MusicTrack> tracks,
    this.workRootPath,
  }) : tracks = immutableList(tracks);

  final String id;
  final PlaybackQueueEntryKind kind;
  final String title;
  final List<MusicTrack> tracks;
  final String? workRootPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'title': title,
    'workRootPath': workRootPath,
    'tracks': tracks.map((track) => track.toJson()).toList(growable: false),
  };

  factory PlaybackQueueEntry.fromJson(Map<String, dynamic> json) {
    return PlaybackQueueEntry(
      id: json['id'] as String,
      kind: PlaybackQueueEntryKind.values.firstWhere(
        (kind) => kind.name == json['kind'],
        orElse: () => PlaybackQueueEntryKind.track,
      ),
      title: json['title'] as String? ?? '',
      workRootPath: json['workRootPath'] as String?,
      tracks: (json['tracks'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(MusicTrack.fromJson)
          .toList(growable: false),
    );
  }
}

class PlaybackQueueDefinition {
  PlaybackQueueDefinition({
    required this.name,
    required List<PlaybackQueueEntry> entries,
    this.colorValue,
  }) : entries = immutableList(entries);

  final String name;
  final int? colorValue;
  final List<PlaybackQueueEntry> entries;

  List<MusicTrack> get expandedTracks =>
      immutableList(entries.expand((entry) => entry.tracks));

  PlaybackQueueDefinition copyWith({
    String? name,
    int? colorValue,
    bool clearColor = false,
    List<PlaybackQueueEntry>? entries,
  }) {
    return PlaybackQueueDefinition(
      name: name ?? this.name,
      colorValue: clearColor ? null : (colorValue ?? this.colorValue),
      entries: entries ?? this.entries,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'colorValue': colorValue,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  };

  factory PlaybackQueueDefinition.fromJson(Map<String, dynamic> json) {
    return PlaybackQueueDefinition(
      name: json['name'] as String? ?? '',
      colorValue: (json['colorValue'] as num?)?.toInt(),
      entries: (json['entries'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(PlaybackQueueEntry.fromJson)
          .toList(growable: false),
    );
  }
}
