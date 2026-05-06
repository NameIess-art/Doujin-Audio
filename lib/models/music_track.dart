class MusicTrack {
  const MusicTrack({
    required this.path,
    required this.displayName,
    required this.groupKey,
    required this.groupTitle,
    required this.groupSubtitle,
    required this.isSingle,
    this.scannedAt,
    this.fileSizeBytes,
    this.modifiedAt,
    this.lastPlayedPosition = Duration.zero,
    this.lastPlayedAt,
    this.isFavorite = false,
    this.tags = const <String>[],
    this.coverCachePath,
    this.lyricsPath,
  });

  final String path;
  final String displayName;
  final String groupKey;
  final String groupTitle;
  final String groupSubtitle;
  final bool isSingle;
  final DateTime? scannedAt;
  final int? fileSizeBytes;
  final DateTime? modifiedAt;
  final Duration lastPlayedPosition;
  final DateTime? lastPlayedAt;
  final bool isFavorite;
  final List<String> tags;
  final String? coverCachePath;
  final String? lyricsPath;

  Map<String, dynamic> toJson() => {
    'path': path,
    'displayName': displayName,
    'groupKey': groupKey,
    'groupTitle': groupTitle,
    'groupSubtitle': groupSubtitle,
    'isSingle': isSingle,
    'scannedAtMs': scannedAt?.millisecondsSinceEpoch,
    'fileSizeBytes': fileSizeBytes,
    'modifiedAtMs': modifiedAt?.millisecondsSinceEpoch,
    'lastPlayedPositionMs': lastPlayedPosition.inMilliseconds,
    'lastPlayedAtMs': lastPlayedAt?.millisecondsSinceEpoch,
    'isFavorite': isFavorite,
    'tags': tags,
    'coverCachePath': coverCachePath,
    'lyricsPath': lyricsPath,
  };

  factory MusicTrack.fromJson(Map<String, dynamic> json) => MusicTrack(
    path: json['path'] as String,
    displayName: json['displayName'] as String,
    groupKey: json['groupKey'] as String,
    groupTitle: json['groupTitle'] as String,
    groupSubtitle: json['groupSubtitle'] as String,
    isSingle: json['isSingle'] as bool? ?? false,
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
  );
}

DateTime? _dateTimeFromJson(Object? value) {
  if (value is num && value > 0) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return null;
}
