import 'dart:convert';

const Object _copyUnset = Object();

enum AudioDetailTargetType {
  libraryRootFolder('libraryRootFolder', 'library-root-folder'),
  singleAudioFile('singleAudioFile', 'single-audio-file');

  const AudioDetailTargetType(this.dbValue, this.backupValue);

  final String dbValue;
  final String backupValue;

  static AudioDetailTargetType? fromDbValue(String value) {
    for (final type in values) {
      if (type.dbValue == value) return type;
    }
    return null;
  }

  static AudioDetailTargetType? fromBackupValue(String value) {
    for (final type in values) {
      if (type.backupValue == value || type.dbValue == value) return type;
    }
    return null;
  }
}

class AudioDetailTarget {
  const AudioDetailTarget({required this.targetType, required this.targetPath});

  factory AudioDetailTarget.libraryRootFolder(String targetPath) {
    return AudioDetailTarget(
      targetType: AudioDetailTargetType.libraryRootFolder,
      targetPath: targetPath,
    );
  }

  factory AudioDetailTarget.singleAudioFile(String targetPath) {
    return AudioDetailTarget(
      targetType: AudioDetailTargetType.singleAudioFile,
      targetPath: targetPath,
    );
  }

  final AudioDetailTargetType targetType;
  final String targetPath;

  bool get isLibraryRootFolder =>
      targetType == AudioDetailTargetType.libraryRootFolder;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AudioDetailTarget &&
            targetType == other.targetType &&
            targetPath == other.targetPath;
  }

  @override
  int get hashCode => Object.hash(targetType, targetPath);
}

class AudioDetail {
  const AudioDetail({
    required this.target,
    required this.rjCode,
    required this.workTitle,
    required this.circleName,
    required this.voiceActors,
    required this.tags,
    this.cardCoverPath,
    this.releaseDate,
    this.duration,
    this.salesCount,
    this.rating,
    this.createdAt,
    this.updatedAt,
  });

  factory AudioDetail.empty(AudioDetailTarget target) {
    return AudioDetail(
      target: target,
      rjCode: '',
      workTitle: '',
      circleName: '',
      voiceActors: const <String>[],
      tags: const <String>[],
    );
  }

  factory AudioDetail.fromRow(Map<String, dynamic> row) {
    final targetType = AudioDetailTargetType.fromDbValue(
      row['target_type'] as String,
    );
    if (targetType == null) {
      throw StateError('Unknown audio detail target type');
    }
    return AudioDetail(
      target: AudioDetailTarget(
        targetType: targetType,
        targetPath: row['target_path'] as String,
      ),
      rjCode: (row['rj_code'] as String?) ?? '',
      workTitle: (row['work_title'] as String?) ?? '',
      circleName: (row['circle_name'] as String?) ?? '',
      voiceActors: _decodeStringList(row['voice_actors_json']),
      tags: _decodeStringList(row['tags_json']),
      cardCoverPath: row['card_cover_path'] as String?,
      releaseDate: _dateTimeFromMs(row['release_date_ms']),
      duration: _durationFromMs(row['duration_ms']),
      salesCount: _intOrNull(row['sales_count']),
      rating: _doubleOrNull(row['rating']),
      createdAt: _dateTimeFromMs(row['created_at_ms']),
      updatedAt: _dateTimeFromMs(row['updated_at_ms']),
    );
  }

  factory AudioDetail.fromBackupJson(
    AudioDetailTarget fallbackTarget,
    Map<String, dynamic> json,
  ) {
    if (json['schemaVersion'] != 1 || json['type'] != 'audio-detail') {
      throw const FormatException('Unsupported audio detail backup');
    }
    final rawTargetType = json['targetType'] as String?;
    final targetType = rawTargetType == null
        ? fallbackTarget.targetType
        : AudioDetailTargetType.fromBackupValue(rawTargetType);
    if (targetType == null) {
      throw const FormatException('Unknown audio detail target type');
    }
    return AudioDetail(
      target: AudioDetailTarget(
        targetType: targetType,
        targetPath:
            (json['targetPath'] as String?) ?? fallbackTarget.targetPath,
      ),
      rjCode: (json['rjCode'] as String?) ?? '',
      workTitle: (json['workTitle'] as String?) ?? '',
      circleName: (json['circleName'] as String?) ?? '',
      voiceActors: normalizeList(
        (json['voiceActors'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>(),
      ),
      tags: normalizeList(
        (json['tags'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<String>(),
      ),
      cardCoverPath: json['cardCoverPath'] as String?,
      releaseDate: _backupDate(json, 'releaseDate'),
      duration: _backupDuration(json),
      salesCount: _backupSalesCount(json),
      rating: _backupRating(json),
      createdAt: _backupDate(json, 'createdAt'),
      updatedAt: _backupDate(json, 'updatedAt'),
    );
  }

  final AudioDetailTarget target;
  final String rjCode;
  final String workTitle;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final String? cardCoverPath;
  final DateTime? releaseDate;
  final Duration? duration;
  final int? salesCount;
  final double? rating;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isEmpty =>
      rjCode.isEmpty &&
      workTitle.isEmpty &&
      circleName.isEmpty &&
      voiceActors.isEmpty &&
      tags.isEmpty;

  bool get hasMissingMetadata =>
      rjCode.trim().isEmpty ||
      circleName.trim().isEmpty ||
      voiceActors.isEmpty ||
      tags.isEmpty ||
      releaseDate == null ||
      salesCount == null ||
      rating == null;

  bool get hasNoMetadata =>
      rjCode.trim().isEmpty &&
      circleName.trim().isEmpty &&
      voiceActors.isEmpty &&
      tags.isEmpty &&
      releaseDate == null &&
      duration == null &&
      salesCount == null &&
      rating == null;

  bool get hasRjCode => rjCode.trim().isNotEmpty;

  AudioDetail copyWith({
    AudioDetailTarget? target,
    String? rjCode,
    String? workTitle,
    String? circleName,
    List<String>? voiceActors,
    List<String>? tags,
    Object? cardCoverPath = _copyUnset,
    Object? releaseDate = _copyUnset,
    Object? duration = _copyUnset,
    Object? salesCount = _copyUnset,
    Object? rating = _copyUnset,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AudioDetail(
      target: target ?? this.target,
      rjCode: rjCode ?? this.rjCode,
      workTitle: workTitle ?? this.workTitle,
      circleName: circleName ?? this.circleName,
      voiceActors: voiceActors ?? this.voiceActors,
      tags: tags ?? this.tags,
      cardCoverPath: cardCoverPath == _copyUnset
          ? this.cardCoverPath
          : cardCoverPath as String?,
      releaseDate: releaseDate == _copyUnset
          ? this.releaseDate
          : releaseDate as DateTime?,
      duration: duration == _copyUnset ? this.duration : duration as Duration?,
      salesCount: salesCount == _copyUnset
          ? this.salesCount
          : salesCount as int?,
      rating: rating == _copyUnset ? this.rating : rating as double?,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  AudioDetail normalizedForSave(DateTime now) {
    if (salesCount != null && salesCount! < 0) {
      throw const FormatException('Invalid audio detail field: salesCount');
    }
    if (rating != null && (!rating!.isFinite || rating! < 0 || rating! > 5)) {
      throw const FormatException('Invalid audio detail field: rating');
    }
    if (duration != null && duration! <= Duration.zero) {
      throw const FormatException('Invalid audio detail field: duration');
    }
    return AudioDetail(
      target: target,
      rjCode: rjCode.trim().toUpperCase(),
      workTitle: workTitle.trim(),
      circleName: circleName.trim(),
      voiceActors: normalizeList(voiceActors),
      tags: normalizeList(tags),
      cardCoverPath: cardCoverPath?.trim().isEmpty == true
          ? null
          : cardCoverPath?.trim(),
      releaseDate: releaseDate,
      duration: duration,
      salesCount: salesCount,
      rating: rating,
      createdAt: createdAt ?? now,
      updatedAt: now,
    );
  }

  Map<String, dynamic> toRow() {
    return {
      'target_type': target.targetType.dbValue,
      'target_path': target.targetPath,
      'rj_code': rjCode,
      'work_title': workTitle,
      'circle_name': circleName,
      'voice_actors_json': json.encode(voiceActors),
      'tags_json': json.encode(tags),
      'card_cover_path': cardCoverPath,
      'release_date_ms': releaseDate?.millisecondsSinceEpoch ?? 0,
      'duration_ms': duration?.inMilliseconds ?? 0,
      'sales_count': salesCount,
      'rating': rating,
      'created_at_ms': createdAt?.millisecondsSinceEpoch ?? 0,
      'updated_at_ms': updatedAt?.millisecondsSinceEpoch ?? 0,
    };
  }

  Map<String, dynamic> toBackupJson() {
    return {
      'schemaVersion': 1,
      'type': 'audio-detail',
      'targetType': target.targetType.backupValue,
      'targetPath': target.targetPath,
      'rjCode': rjCode,
      'workTitle': workTitle,
      'circleName': circleName,
      'voiceActors': voiceActors,
      'tags': tags,
      'cardCoverPath': cardCoverPath,
      'releaseDate': releaseDate?.toIso8601String(),
      'durationMs': duration?.inMilliseconds,
      'salesCount': salesCount,
      'rating': rating,
      'createdAt': createdAt?.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  static List<String> normalizeList(Iterable<String> values) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      result.add(trimmed);
    }
    return List<String>.unmodifiable(result);
  }

  static String? findRjCodeInText(String text) {
    final match = RegExp(r'RJ\d{6,}', caseSensitive: false).firstMatch(text);
    return match?.group(0)?.toUpperCase();
  }
}

List<String> _decodeStringList(Object? value) {
  if (value is! String || value.isEmpty) return const <String>[];
  try {
    return AudioDetail.normalizeList(
      (json.decode(value) as List<dynamic>).whereType<String>(),
    );
  } catch (_) {
    return const <String>[];
  }
}

DateTime? _dateTimeFromMs(Object? value) {
  if (value is num && value > 0) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  }
  return null;
}

Duration? _durationFromMs(Object? value) {
  final milliseconds = _intOrNull(value);
  if (milliseconds == null || milliseconds <= 0) return null;
  return Duration(milliseconds: milliseconds);
}

DateTime? _backupDate(Map<String, dynamic> json, String field) {
  if (!json.containsKey(field) || json[field] == null) return null;
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid audio detail field: $field');
  }
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) {
    throw FormatException('Invalid audio detail field: $field');
  }
  return parsed;
}

Duration? _backupDuration(Map<String, dynamic> json) {
  const field = 'durationMs';
  if (!json.containsKey(field) || json[field] == null) return null;
  final milliseconds = _intOrNull(json[field]);
  if (milliseconds == null || milliseconds <= 0) {
    throw const FormatException('Invalid audio detail field: durationMs');
  }
  return Duration(milliseconds: milliseconds);
}

int? _backupSalesCount(Map<String, dynamic> json) {
  const field = 'salesCount';
  if (!json.containsKey(field) || json[field] == null) return null;
  final value = json[field];
  final parsed = switch (value) {
    int number => number,
    num number when number == number.toInt() => number.toInt(),
    String text => int.tryParse(text.trim()),
    _ => null,
  };
  if (parsed == null || parsed < 0) {
    throw const FormatException('Invalid audio detail field: salesCount');
  }
  return parsed;
}

double? _backupRating(Map<String, dynamic> json) {
  const field = 'rating';
  if (!json.containsKey(field) || json[field] == null) return null;
  final value = json[field];
  final parsed = switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text.trim()),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite || parsed < 0 || parsed > 5) {
    throw const FormatException('Invalid audio detail field: rating');
  }
  return parsed;
}

int? _intOrNull(Object? value) {
  if (value is num) return value.toInt();
  if (value is String && value.trim().isNotEmpty) {
    return int.tryParse(value.trim());
  }
  return null;
}

double? _doubleOrNull(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String && value.trim().isNotEmpty) {
    return double.tryParse(value.trim());
  }
  return null;
}
