import '../immutable_collections.dart';

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
  AudioDetail({
    required this.target,
    required this.rjCode,
    required this.workTitle,
    required this.circleName,
    required List<String> voiceActors,
    required List<String> tags,
    this.cardCoverPath,
    this.cardCoverSelected = false,
    this.releaseDate,
    this.duration,
    this.salesCount,
    this.rating,
    this.createdAt,
    this.updatedAt,
  }) : voiceActors = immutableList(voiceActors),
       tags = immutableList(tags);

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

  final AudioDetailTarget target;
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
    bool? cardCoverSelected,
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
      cardCoverSelected: cardCoverSelected ?? this.cardCoverSelected,
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
      cardCoverSelected:
          cardCoverPath?.trim().isNotEmpty == true && cardCoverSelected,
      releaseDate: releaseDate,
      duration: duration,
      salesCount: salesCount,
      rating: rating,
      createdAt: createdAt ?? now,
      updatedAt: now,
    );
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
