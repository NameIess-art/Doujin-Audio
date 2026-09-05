import '../../../core/media/path_matcher.dart';
import '../../../core/media/music_track.dart';

class TimeSegmentLabel {
  const TimeSegmentLabel({
    required this.id,
    required this.trackKey,
    required this.name,
    required this.start,
    required this.end,
    required this.colorValue,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String trackKey;
  final String name;
  final Duration start;
  final Duration end;
  final int colorValue;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool contains(Duration position) => position >= start && position <= end;

  TimeSegmentLabel copyWith({
    String? id,
    String? trackKey,
    String? name,
    Duration? start,
    Duration? end,
    int? colorValue,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TimeSegmentLabel(
      id: id ?? this.id,
      trackKey: trackKey ?? this.trackKey,
      name: name ?? this.name,
      start: start ?? this.start,
      end: end ?? this.end,
      colorValue: colorValue ?? this.colorValue,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'track_key': trackKey,
    'name': name,
    'start_ms': start.inMilliseconds,
    'end_ms': end.inMilliseconds,
    'color_value': colorValue,
    'created_at_ms': createdAt.millisecondsSinceEpoch,
    'updated_at_ms': updatedAt.millisecondsSinceEpoch,
  };

  factory TimeSegmentLabel.fromRow(Map<String, Object?> row) {
    return TimeSegmentLabel(
      id: row['id'] as String,
      trackKey: row['track_key'] as String,
      name: row['name'] as String,
      start: Duration(milliseconds: (row['start_ms'] as num).toInt()),
      end: Duration(milliseconds: (row['end_ms'] as num).toInt()),
      colorValue: (row['color_value'] as num).toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at_ms'] as num).toInt(),
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['updated_at_ms'] as num).toInt(),
      ),
    );
  }

  static String trackKeyFor(MusicTrack track) {
    if (track.isRemoteAsmr) {
      final metadata = track.remoteMetadata ?? const <String, Object?>{};
      final sourceId = (metadata['sourceId'] as String? ?? track.groupSubtitle)
          .trim();
      final relativePath = (metadata['trackRelativePath'] as String? ?? '')
          .trim();
      if (sourceId.isNotEmpty && relativePath.isNotEmpty) {
        return 'asmr.one:$sourceId:$relativePath';
      }
    }
    return PathMatcher.normalize(track.path);
  }
}

const List<int> kTimeSegmentLabelPalette = <int>[
  0xFFE57373,
  0xFFF06292,
  0xFFBA68C8,
  0xFF7986CB,
  0xFF64B5F6,
  0xFF4DB6AC,
  0xFF81C784,
  0xFFFFB74D,
  0xFFFF8A65,
  0xFFA1887F,
];
