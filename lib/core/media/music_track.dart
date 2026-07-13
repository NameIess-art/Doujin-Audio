class MusicTrack {
  const MusicTrack({
    required this.path,
    required this.displayName,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
    this.isVideo = false,
    this.scannedAt,
    this.fileSizeBytes,
    this.modifiedAt,
    this.lastPlayedPosition = Duration.zero,
    this.lastPlayedAt,
    this.isFavorite = false,
    this.tags = const <String>[],
    this.coverCachePath,
    this.lyricsPath,
    this.manualCoverPath,
    this.remoteCoverUrl,
    this.remoteMetadataKind,
    this.remoteMetadata,
    this.duration = Duration.zero,
  });

  final String path;
  final String displayName;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final bool isVideo;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;
  final Duration lastPlayedPosition;
  final DateTime? lastPlayedAt;
  final bool isFavorite;
  final List<String> tags;
  final String? coverCachePath;
  final String? lyricsPath;
  final String? manualCoverPath;
  final String? remoteCoverUrl;
  final String? remoteMetadataKind;
  final Map<String, Object?>? remoteMetadata;
  final Duration duration;

  MusicTrack copyWith({
    Duration? duration,
    Duration? lastPlayedPosition,
    DateTime? lastPlayedAt,
    bool? isFavorite,
    List<String>? tags,
    String? coverCachePath,
    String? lyricsPath,
    String? manualCoverPath,
    String? remoteCoverUrl,
    String? remoteMetadataKind,
    Map<String, Object?>? remoteMetadata,
    bool? isVideo,
  }) => MusicTrack(
    path: path,
    displayName: displayName,
    groupKey: groupKey,
    groupTitle: groupTitle,
    groupSubtitle: groupSubtitle,
    isSingle: isSingle,
    isVideo: isVideo ?? this.isVideo,
    scannedAt: scannedAt,
    fileSizeBytes: fileSizeBytes,
    modifiedAt: modifiedAt,
    lastPlayedPosition: lastPlayedPosition ?? this.lastPlayedPosition,
    lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
    isFavorite: isFavorite ?? this.isFavorite,
    tags: tags ?? this.tags,
    coverCachePath: coverCachePath ?? this.coverCachePath,
    lyricsPath: lyricsPath ?? this.lyricsPath,
    manualCoverPath: manualCoverPath ?? this.manualCoverPath,
    remoteCoverUrl: remoteCoverUrl ?? this.remoteCoverUrl,
    remoteMetadataKind: remoteMetadataKind ?? this.remoteMetadataKind,
    remoteMetadata: remoteMetadata ?? this.remoteMetadata,
    duration: duration ?? this.duration,
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    'displayName': displayName,
    'groupKey': groupKey,
    'groupTitle': groupTitle,
    'groupSubtitle': groupSubtitle,
    'isSingle': isSingle,
    'isVideo': isVideo,
    'scannedAtMs': scannedAt?.millisecondsSinceEpoch,
    'fileSizeBytes': fileSizeBytes,
    'modifiedAtMs': modifiedAt?.millisecondsSinceEpoch,
    'lastPlayedPositionMs': lastPlayedPosition.inMilliseconds,
    'lastPlayedAtMs': lastPlayedAt?.millisecondsSinceEpoch,
    'isFavorite': isFavorite,
    'tags': tags,
    'coverCachePath': coverCachePath,
    'lyricsPath': lyricsPath,
    'manualCoverPath': manualCoverPath,
    'remoteCoverUrl': remoteCoverUrl,
    'remoteMetadataKind': remoteMetadataKind,
    'remoteMetadata': remoteMetadata,
    'durationMs': duration.inMilliseconds,
  };

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
    path: json['path'] as String,
    displayName: json['displayName'] as String,
    groupKey: json['groupKey'] as String,
    groupTitle: json['groupTitle'] as String,
    groupSubtitle: json['groupSubtitle'] as String,
    isSingle: json['isSingle'] as bool? ?? false,
    isVideo: json['isVideo'] as bool? ?? false,
    scannedAt: _dateTimeFromJson(json['scannedAtMs']),
    fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt(),
    modifiedAt: _dateTimeFromJson(json['modifiedAtMs']),
    lastPlayedPosition: Duration(
      milliseconds: (json['lastPlayedPositionMs'] as num?)?.toInt() ?? 0,
    ),
    lastPlayedAt: _dateTimeFromJson(json['lastPlayedAtMs']),
    isFavorite: json['isFavorite'] as bool? ?? false,
    tags: (json['tags'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<String>()
        .toList(growable: false),
    coverCachePath: json['coverCachePath'] as String?,
    lyricsPath: json['lyricsPath'] as String?,
    manualCoverPath: json['manualCoverPath'] as String?,
    remoteCoverUrl: json['remoteCoverUrl'] as String?,
    remoteMetadataKind: json['remoteMetadataKind'] as String?,
    remoteMetadata: json['remoteMetadata'] as Map<String, Object?>?,
    duration: Duration(
      milliseconds: (json['durationMs'] as num?)?.toInt() ?? 0,
    ),
  );
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value is num && value > 0) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return null;
}
