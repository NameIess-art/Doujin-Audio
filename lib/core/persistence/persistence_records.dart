import '../media/music_track.dart';

final class AudioEffectsRecord {
  AudioEffectsRecord({
    this.skipSilenceEnabled = false,
    this.noiseReductionEnabled = false,
    this.volumeNormalizationEnabled = false,
    this.eqEnabled = false,
    this.eqPresetId,
    Map<int, double> eqBandLevels = const <int, double>{},
    this.panning = 0,
  }) : eqBandLevels = Map<int, double>.unmodifiable(eqBandLevels);

  final bool skipSilenceEnabled;
  final bool noiseReductionEnabled;
  final bool volumeNormalizationEnabled;
  final bool eqEnabled;
  final String? eqPresetId;
  final Map<int, double> eqBandLevels;
  final double panning;
}

final class PlaybackQueueEntryRecord {
  PlaybackQueueEntryRecord({
    required this.id,
    required this.kind,
    required this.title,
    required List<MusicTrack> tracks,
    this.workRootPath,
  }) : tracks = List<MusicTrack>.unmodifiable(tracks);

  final String id;
  final String kind;
  final String title;
  final List<MusicTrack> tracks;
  final String? workRootPath;
}

final class PlaybackQueueRecord {
  PlaybackQueueRecord({
    required this.name,
    required List<PlaybackQueueEntryRecord> entries,
    this.colorValue,
  }) : entries = List<PlaybackQueueEntryRecord>.unmodifiable(entries);

  final String name;
  final int? colorValue;
  final List<PlaybackQueueEntryRecord> entries;
}

final class PlaybackSessionRecord {
  PlaybackSessionRecord({
    required this.id,
    required this.trackPath,
    required this.loopModeIndex,
    required this.volume,
    this.speed = 1,
    required this.positionMs,
    required this.durationMs,
    required List<MusicTrack>? customQueueTracks,
    this.playbackQueue,
    this.currentQueueIndex = 0,
    required this.channelSwapEnabled,
    AudioEffectsRecord? audioEffects,
    required this.sortOrder,
    this.createdAtMs,
    this.updatedAtMs,
    this.lastPlayedAtMs,
  }) : customQueueTracks = customQueueTracks == null
           ? null
           : List<MusicTrack>.unmodifiable(customQueueTracks),
       audioEffects = audioEffects ?? AudioEffectsRecord();

  final String id;
  final String trackPath;
  final int loopModeIndex;
  final double volume;
  final double speed;
  final int positionMs;
  final int durationMs;
  final List<MusicTrack>? customQueueTracks;
  final PlaybackQueueRecord? playbackQueue;
  final int currentQueueIndex;
  final bool channelSwapEnabled;
  final AudioEffectsRecord audioEffects;
  final int sortOrder;
  final int? createdAtMs;
  final int? updatedAtMs;
  final int? lastPlayedAtMs;
}

final class LibraryEntryRecord {
  const LibraryEntryRecord({
    required this.libraryPath,
    required this.path,
    required this.kind,
    required this.state,
    this.parentPath,
    this.displayName = '',
    this.groupKey = '',
    this.groupTitle = '',
    this.groupSubtitle = '',
    this.isSingle = false,
    this.isVideo = false,
    this.scannedAt,
    this.fileSizeBytes,
    this.modifiedAt,
  });

  final String libraryPath;
  final String path;
  final String kind;
  final String state;
  final String? parentPath;
  final String displayName;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final bool isVideo;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;
}

final class AudioDetailRecord {
  AudioDetailRecord({
    required this.targetType,
    required this.targetPath,
    required this.rjCode,
    required this.workTitle,
    required this.circleName,
    required List<String> voiceActors,
    required List<String> tags,
    this.cardCoverPath,
    required this.cardCoverSelected,
    this.releaseDate,
    this.duration,
    this.salesCount,
    this.rating,
    this.createdAt,
    this.updatedAt,
  }) : voiceActors = List<String>.unmodifiable(voiceActors),
       tags = List<String>.unmodifiable(tags);

  final String targetType;
  final String targetPath;
  final String rjCode;
  final String workTitle;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final String? cardCoverPath;
  final bool cardCoverSelected;
  final DateTime? releaseDate;
  final Duration? duration;
  final int? salesCount;
  final double? rating;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

final class AsmrWorkRecord {
  AsmrWorkRecord({
    required this.id,
    required this.title,
    required this.circleName,
    required this.sourceId,
    required this.sourceType,
    required this.sourceUrl,
    required this.coverUrl,
    required this.thumbnailUrl,
    required this.mainCoverUrl,
    required this.releaseDate,
    required this.createDate,
    required this.duration,
    required this.dlCount,
    required this.reviewCount,
    required this.rating,
    required List<String> voiceActors,
    required List<String> tags,
    required this.hasSubtitle,
    required this.isFavorite,
  }) : voiceActors = List<String>.unmodifiable(voiceActors),
       tags = List<String>.unmodifiable(tags);

  final int id;
  final String title;
  final String circleName;
  final String sourceId;
  final String sourceType;
  final String sourceUrl;
  final String coverUrl;
  final String thumbnailUrl;
  final String mainCoverUrl;
  final DateTime? releaseDate;
  final DateTime? createDate;
  final Duration duration;
  final int dlCount;
  final int reviewCount;
  final double rating;
  final List<String> voiceActors;
  final List<String> tags;
  final bool hasSubtitle;
  final bool isFavorite;
}

final class AsmrSyncOperationRecord {
  const AsmrSyncOperationRecord({
    required this.type,
    required this.workId,
    required this.sourceId,
    required this.createdAt,
    required this.retryCount,
  });

  final String type;
  final int workId;
  final String sourceId;
  final DateTime createdAt;
  final int retryCount;
}

final class TimeSegmentLabelRecord {
  const TimeSegmentLabelRecord({
    required this.id,
    required this.trackKey,
    required this.name,
    required this.startMs,
    required this.endMs,
    required this.colorValue,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String trackKey;
  final String name;
  final int startMs;
  final int endMs;
  final int colorValue;
  final int createdAtMs;
  final int updatedAtMs;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'track_key': trackKey,
    'name': name,
    'start_ms': startMs,
    'end_ms': endMs,
    'color_value': colorValue,
    'created_at_ms': createdAtMs,
    'updated_at_ms': updatedAtMs,
  };

  factory TimeSegmentLabelRecord.fromRow(Map<String, Object?> row) {
    return TimeSegmentLabelRecord(
      id: row['id'] as String,
      trackKey: row['track_key'] as String,
      name: row['name'] as String,
      startMs: (row['start_ms'] as num).toInt(),
      endMs: (row['end_ms'] as num).toInt(),
      colorValue: (row['color_value'] as num).toInt(),
      createdAtMs: (row['created_at_ms'] as num).toInt(),
      updatedAtMs: (row['updated_at_ms'] as num).toInt(),
    );
  }
}
