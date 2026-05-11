import 'dart:convert';

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
}

class AudioDetail {
  const AudioDetail({
    required this.target,
    required this.rjCode,
    required this.workTitle,
    required this.circleName,
    required this.voiceActors,
    required this.tags,
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
      createdAt: _dateTimeFromIso(json['createdAt']),
      updatedAt: _dateTimeFromIso(json['updatedAt']),
    );
  }

  final AudioDetailTarget target;
  final String rjCode;
  final String workTitle;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  bool get isEmpty =>
      rjCode.isEmpty &&
      workTitle.isEmpty &&
      circleName.isEmpty &&
      voiceActors.isEmpty &&
      tags.isEmpty;

  AudioDetail copyWith({
    String? rjCode,
    String? workTitle,
    String? circleName,
    List<String>? voiceActors,
    List<String>? tags,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AudioDetail(
      target: target,
      rjCode: rjCode ?? this.rjCode,
      workTitle: workTitle ?? this.workTitle,
      circleName: circleName ?? this.circleName,
      voiceActors: voiceActors ?? this.voiceActors,
      tags: tags ?? this.tags,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  AudioDetail normalizedForSave(DateTime now) {
    return AudioDetail(
      target: target,
      rjCode: rjCode.trim().toUpperCase(),
      workTitle: workTitle.trim(),
      circleName: circleName.trim(),
      voiceActors: normalizeList(voiceActors),
      tags: normalizeList(tags),
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

DateTime? _dateTimeFromIso(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}
