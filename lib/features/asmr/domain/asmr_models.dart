import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

import '../../../core/app_language.dart';
import '../../../core/immutable_collections.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';

enum AsmrCategoryType {
  collected,
  recommendation,
  sales,
  rating,
  reviews,
  release,
  favorites,
  history,
}

const List<AsmrCategoryType> kAsmrSelectableCategories = <AsmrCategoryType>[
  AsmrCategoryType.collected,
  AsmrCategoryType.recommendation,
  AsmrCategoryType.sales,
  AsmrCategoryType.rating,
  AsmrCategoryType.reviews,
  AsmrCategoryType.release,
  AsmrCategoryType.favorites,
  AsmrCategoryType.history,
];

const List<AsmrCategoryType> kDefaultVisibleAsmrCategories = <AsmrCategoryType>[
  AsmrCategoryType.collected,
  AsmrCategoryType.recommendation,
  AsmrCategoryType.rating,
  AsmrCategoryType.favorites,
  AsmrCategoryType.history,
];

enum AsmrContentLanguage {
  zh('zh-cn'),
  ja('ja-jp'),
  en('en-us');

  const AsmrContentLanguage(this.locale);

  final String locale;

  AppLanguage get appLanguage => switch (this) {
    AsmrContentLanguage.zh => AppLanguage.zh,
    AsmrContentLanguage.ja => AppLanguage.ja,
    AsmrContentLanguage.en => AppLanguage.en,
  };

  static AsmrContentLanguage fromName(String? name) {
    return AsmrContentLanguage.values.firstWhere(
      (language) => language.name == name || language.locale == name,
      orElse: () => AsmrContentLanguage.zh,
    );
  }

  static AsmrContentLanguage fromAppLanguageName(String name) {
    return switch (name) {
      'ja' => AsmrContentLanguage.ja,
      'en' => AsmrContentLanguage.en,
      _ => AsmrContentLanguage.zh,
    };
  }

  static AsmrContentLanguage fromAppLanguage(AppLanguage language) =>
      switch (language) {
        AppLanguage.zh => AsmrContentLanguage.zh,
        AppLanguage.ja => AsmrContentLanguage.ja,
        AppLanguage.en => AsmrContentLanguage.en,
      };
}

enum AsmrSyncOperationType {
  favoriteAdd,
  favoriteRemove,
  historyListening;

  static AsmrSyncOperationType fromName(String? name) {
    return AsmrSyncOperationType.values.firstWhere(
      (type) => type.name == name,
      orElse: () => AsmrSyncOperationType.favoriteAdd,
    );
  }
}

enum AsmrSyncPhase { idle, syncing, succeeded, failed }

@immutable
class AsmrAuthSession {
  const AsmrAuthSession({required this.token, required this.userName});

  final String token;
  final String userName;

  bool get isValid => token.trim().isNotEmpty;
}

@immutable
class AsmrReviewRecord {
  const AsmrReviewRecord({
    required this.work,
    required this.progress,
    required this.updatedAt,
  });

  final AsmrWork work;
  final String progress;
  final DateTime? updatedAt;

  bool get hasProtectedProgress =>
      progress == 'marked' ||
      progress == 'listened' ||
      progress == 'replay' ||
      progress == 'postponed';

  factory AsmrReviewRecord.fromJson(
    Map<String, dynamic> json, {
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) {
    return AsmrReviewRecord(
      work: AsmrWork.fromJson(json, language: language),
      progress: (json['progress'] as String?) ?? '',
      updatedAt: AsmrWork._dateTimeOrNull(
        json['updated_at'] ?? json['updatedAt'],
      ),
    );
  }
}

@immutable
class AsmrSyncOperation {
  const AsmrSyncOperation({
    required this.type,
    required this.workId,
    required this.sourceId,
    required this.createdAt,
    this.retryCount = 0,
  });

  final AsmrSyncOperationType type;
  final int workId;
  final String sourceId;
  final DateTime createdAt;
  final int retryCount;

  AsmrSyncOperation copyWith({int? retryCount}) {
    return AsmrSyncOperation(
      type: type,
      workId: workId,
      sourceId: sourceId,
      createdAt: createdAt,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.name,
    'workId': workId,
    'sourceId': sourceId,
    'createdAt': createdAt.toIso8601String(),
    'retryCount': retryCount,
  };

  factory AsmrSyncOperation.fromJson(Map<String, dynamic> json) {
    return AsmrSyncOperation(
      type: AsmrSyncOperationType.fromName(json['type'] as String?),
      workId: (json['workId'] as num?)?.toInt() ?? 0,
      sourceId: (json['sourceId'] as String?) ?? '',
      createdAt:
          AsmrWork._dateTimeOrNull(json['createdAt']) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      retryCount: (json['retryCount'] as num?)?.toInt() ?? 0,
    );
  }
}

@immutable
class AsmrWorkPage {
  AsmrWorkPage({
    required List<AsmrWork> works,
    required this.currentPage,
    required this.pageSize,
    required this.totalCount,
  }) : works = immutableList(works);

  final List<AsmrWork> works;
  final int currentPage;
  final int pageSize;
  final int totalCount;

  bool get hasMore => currentPage * pageSize < totalCount;

  factory AsmrWorkPage.fromJson(
    Map<String, dynamic> json, {
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) {
    final pagination =
        json['pagination'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    final works = (json['works'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map((json) => AsmrWork.fromJson(json, language: language))
        .toList(growable: false);
    final pageSize = (pagination['pageSize'] as num?)?.toInt() ?? works.length;
    final currentPage = (pagination['currentPage'] as num?)?.toInt() ?? 1;
    final totalCount =
        (pagination['totalCount'] as num?)?.toInt() ?? works.length;
    return AsmrWorkPage(
      works: works,
      currentPage: currentPage,
      pageSize: pageSize,
      totalCount: totalCount,
    );
  }
}

@immutable
class AsmrWork {
  AsmrWork({
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
    this.hasSubtitle = false,
    this.isFavorite = false,
  }) : voiceActors = immutableList(voiceActors),
       tags = immutableList(tags);

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

  String get rjCode => sourceId.trim();
  String get preferredCoverUrl {
    for (final url in <String>[mainCoverUrl, coverUrl, thumbnailUrl]) {
      final trimmed = url.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  AsmrWork copyWith({bool? isFavorite}) {
    return AsmrWork(
      id: id,
      title: title,
      circleName: circleName,
      sourceId: sourceId,
      sourceType: sourceType,
      sourceUrl: sourceUrl,
      coverUrl: coverUrl,
      thumbnailUrl: thumbnailUrl,
      mainCoverUrl: mainCoverUrl,
      releaseDate: releaseDate,
      createDate: createDate,
      duration: duration,
      dlCount: dlCount,
      reviewCount: reviewCount,
      rating: rating,
      voiceActors: voiceActors,
      tags: tags,
      hasSubtitle: hasSubtitle,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'circleName': circleName,
    'sourceId': sourceId,
    'sourceType': sourceType,
    'sourceUrl': sourceUrl,
    'coverUrl': coverUrl,
    'thumbnailUrl': thumbnailUrl,
    'mainCoverUrl': mainCoverUrl,
    'releaseDate': releaseDate?.toIso8601String(),
    'createDate': createDate?.toIso8601String(),
    'durationMs': duration.inMilliseconds,
    'dlCount': dlCount,
    'reviewCount': reviewCount,
    'rating': rating,
    'voiceActors': voiceActors,
    'tags': tags,
    'hasSubtitle': hasSubtitle,
    'isFavorite': isFavorite,
  };

  factory AsmrWork.fromJson(
    Map<String, dynamic> json, {
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) {
    final circle = json['circle'];
    final circleName =
        (json['circleName'] as String?) ??
        (json['name'] as String?) ??
        (circle is Map<String, dynamic> ? circle['name'] as String? : null) ??
        '';
    final tags = (json['tags'] as List<dynamic>? ?? const <dynamic>[])
        .map((dynamic item) {
          if (item is Map<String, dynamic>) {
            return _localizedText(item, language, 'name');
          }
          return item.toString();
        })
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    final voiceActors =
        (json['voiceActors'] as List<dynamic>? ??
                json['vas'] as List<dynamic>? ??
                const <dynamic>[])
            .map((dynamic item) {
              if (item is Map<String, dynamic>) {
                return (item['name'] as String?) ?? '';
              }
              return item.toString();
            })
            .where((item) => item.isNotEmpty)
            .toList(growable: false);
    return AsmrWork(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: _localizedText(json, language, 'title'),
      circleName: circleName,
      sourceId:
          (json['sourceId'] as String?) ?? (json['source_id'] as String?) ?? '',
      sourceType:
          (json['sourceType'] as String?) ??
          (json['source_type'] as String?) ??
          '',
      sourceUrl:
          (json['sourceUrl'] as String?) ??
          (json['source_url'] as String?) ??
          '',
      coverUrl:
          (json['coverUrl'] as String?) ??
          (json['samCoverUrl'] as String?) ??
          '',
      thumbnailUrl:
          (json['thumbnailUrl'] as String?) ??
          (json['thumbnailCoverUrl'] as String?) ??
          '',
      mainCoverUrl: (json['mainCoverUrl'] as String?) ?? '',
      releaseDate: _dateTimeOrNull(json['releaseDate'] ?? json['release']),
      createDate: _dateTimeOrNull(json['createDate'] ?? json['create_date']),
      duration: _durationFromJson(json),
      dlCount:
          (json['dlCount'] as num?)?.toInt() ??
          (json['dl_count'] as num?)?.toInt() ??
          0,
      reviewCount:
          (json['reviewCount'] as num?)?.toInt() ??
          (json['review_count'] as num?)?.toInt() ??
          0,
      rating:
          (json['rating'] as num?)?.toDouble() ??
          (json['rate_average_2dp'] as num?)?.toDouble() ??
          0,
      voiceActors: voiceActors,
      tags: tags,
      hasSubtitle:
          json['hasSubtitle'] as bool? ??
          json['has_subtitle'] as bool? ??
          false,
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }

  static DateTime? _dateTimeOrNull(Object? value) {
    if (value is String && value.isNotEmpty) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  static Duration _durationFromJson(Map<String, dynamic> json) {
    final durationMs = (json['durationMs'] as num?)?.toInt();
    if (durationMs != null && durationMs > 0) {
      return Duration(milliseconds: durationMs);
    }
    return Duration(
      milliseconds: (((json['duration'] as num?)?.toDouble() ?? 0) * 1000)
          .round(),
    );
  }
}

@immutable
class AsmrWorkDetail {
  AsmrWorkDetail({
    required this.work,
    required this.description,
    required this.ageCategory,
    required List<String> languageEditionLabels,
    required this.userRating,
  }) : languageEditionLabels = immutableList(languageEditionLabels);

  final AsmrWork work;
  final String description;
  final String ageCategory;
  final List<String> languageEditionLabels;
  final double? userRating;

  factory AsmrWorkDetail.fromJson(
    Map<String, dynamic> json, {
    AsmrContentLanguage language = AsmrContentLanguage.zh,
  }) {
    final editions =
        (json['language_editions'] as List<dynamic>? ?? const <dynamic>[])
            .map((dynamic item) {
              if (item is Map<String, dynamic>) {
                return (item['label'] as String?) ?? '';
              }
              return '';
            })
            .where((label) => label.isNotEmpty)
            .toList(growable: false);
    return AsmrWorkDetail(
      work: AsmrWork.fromJson(json, language: language),
      description: _localizedText(json, language, 'description'),
      ageCategory: (json['age_category_string'] as String?) ?? '',
      languageEditionLabels: editions,
      userRating: (json['userRating'] as num?)?.toDouble(),
    );
  }
}

String _localizedText(
  Map<String, dynamic> json,
  AsmrContentLanguage language,
  String key,
) {
  final localized = json['i18n'];
  if (localized is Map) {
    final languageJson = localized[language.locale];
    if (languageJson is Map) {
      final value = languageJson[key];
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    }
  }
  final fallback = json[key];
  if (fallback is String) {
    return fallback;
  }
  return '';
}

@immutable
class AsmrTrackFile {
  AsmrTrackFile({
    required this.hash,
    required this.title,
    required this.type,
    required this.streamUrl,
    required this.downloadUrl,
    required this.lowQualityUrl,
    required this.duration,
    required this.size,
    required List<AsmrTrackFile> children,
    required this.workId,
    required this.workTitle,
    required this.sourceId,
    required this.relativePath,
  }) : children = immutableList(children);

  final String hash;
  final String title;
  final String type;
  final String? streamUrl;
  final String? downloadUrl;
  final String? lowQualityUrl;
  final Duration duration;
  final int size;
  final List<AsmrTrackFile> children;
  final int workId;
  final String workTitle;
  final String sourceId;
  final String relativePath;

  bool get isFolder => type == 'folder';
  bool get isAudio =>
      (type == 'audio' || type == 'video') &&
      _asmrAudioExtensions.contains(resolvedExtension);
  bool get isSubtitle =>
      !isFolder && _asmrSubtitleExtensions.contains(resolvedExtension);
  bool get hasBrowsableContent =>
      isAudio || children.any((child) => child.hasBrowsableContent);
  String get stemKey => _asmrMatchingStem(relativePath);
  String get baseNameStem => _asmrMatchingStem(title);
  String get resolvedExtension => _resolvedExtensionForCandidates(<String?>[
    title,
    streamUrl,
    downloadUrl,
    lowQualityUrl,
  ]);
  String get displayTitle =>
      isAudio ? path.basenameWithoutExtension(title) : title;

  MusicTrack toMusicTrack({
    String? groupTitleOverride,
    String? remoteCoverUrl,
    String? remoteMetadataKind,
    Map<String, Object?>? remoteMetadata,
    Iterable<String> preferredPlaybackUrls = const <String>[],
  }) {
    final playbackUrls = <String>[
      ...preferredPlaybackUrls.map((url) => url.trim()),
      streamUrl?.trim() ?? '',
      downloadUrl?.trim() ?? '',
      lowQualityUrl?.trim() ?? '',
    ].where((url) => url.isNotEmpty).toSet().toList(growable: false);
    final playbackUrl = playbackUrls.isEmpty ? '' : playbackUrls.first;
    final metadata = Map<String, Object?>.from(
      remoteMetadata ?? const <String, Object?>{},
    );
    metadata['playbackUrls'] = playbackUrls;
    return MusicTrack(
      path: playbackUrl,
      displayName: displayTitle,
      groupKey: 'asmr-work-$workId',
      groupTitle: groupTitleOverride ?? workTitle,
      groupSubtitle: sourceId,
      isSingle: false,
      remoteCoverUrl: remoteCoverUrl,
      remoteMetadataKind: remoteMetadataKind,
      remoteMetadata: metadata,
      duration: duration,
      fileSizeBytes: size,
    );
  }

  factory AsmrTrackFile.fromJson(
    Map<String, dynamic> json, {
    String parentPath = '',
  }) {
    final title = (json['title'] as String?) ?? '';
    final nextPath = parentPath.isEmpty ? title : '$parentPath/$title';
    final children = (json['children'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map((child) => AsmrTrackFile.fromJson(child, parentPath: nextPath))
        .toList(growable: false);
    final work = json['work'] as Map<String, dynamic>?;
    return AsmrTrackFile(
      hash: (json['hash'] as String?) ?? '',
      title: title,
      type: (json['type'] as String?) ?? '',
      streamUrl: json['mediaStreamUrl'] as String?,
      downloadUrl: json['mediaDownloadUrl'] as String?,
      lowQualityUrl: json['streamLowQualityUrl'] as String?,
      duration: Duration(
        milliseconds: (((json['duration'] as num?)?.toDouble() ?? 0) * 1000)
            .round(),
      ),
      size: (json['size'] as num?)?.toInt() ?? 0,
      children: children,
      workId: (work?['id'] as num?)?.toInt() ?? 0,
      workTitle: (json['workTitle'] as String?) ?? '',
      sourceId: (work?['source_id'] as String?) ?? '',
      relativePath: nextPath,
    );
  }
}

List<AsmrTrackFile> sortAsmrTrackTreeNaturally(Iterable<AsmrTrackFile> nodes) {
  final sorted = nodes.map((node) {
    if (node.children.isEmpty) return node;
    return AsmrTrackFile(
      hash: node.hash,
      title: node.title,
      type: node.type,
      streamUrl: node.streamUrl,
      downloadUrl: node.downloadUrl,
      lowQualityUrl: node.lowQualityUrl,
      duration: node.duration,
      size: node.size,
      children: sortAsmrTrackTreeNaturally(node.children),
      workId: node.workId,
      workTitle: node.workTitle,
      sourceId: node.sourceId,
      relativePath: node.relativePath,
    );
  }).toList();
  sorted.sort((left, right) {
    return compareNaturalTreeEntries(
      leftIsFolder: left.isFolder,
      leftName: left.title,
      leftPath: left.relativePath,
      rightIsFolder: right.isFolder,
      rightName: right.title,
      rightPath: right.relativePath,
    );
  });
  return List<AsmrTrackFile>.unmodifiable(sorted);
}

const Set<String> _asmrAudioExtensions = <String>{
  '.mp3',
  '.aac',
  '.m4a',
  '.ogg',
  '.oga',
  '.opus',
  '.wav',
  '.flac',
  '.mp4',
  '.m4v',
  '.webm',
  '.mkv',
  '.avi',
  '.mov',
  '.wmv',
};

const Set<String> _asmrSubtitleExtensions = <String>{
  '.vtt',
  '.webvtt',
  '.lrc',
  '.srt',
  '.ass',
  '.ssa',
};

String _asmrMatchingStem(String value) {
  var current = value.toLowerCase();
  while (current.isNotEmpty) {
    final extension = path.extension(current);
    if (extension.isEmpty) break;
    if (!_asmrSubtitleExtensions.contains(extension) &&
        !_asmrAudioExtensions.contains(extension)) {
      break;
    }
    current = path.withoutExtension(current);
  }
  return current;
}

String _resolvedExtensionForCandidates(List<String?> candidates) {
  for (final candidate in candidates) {
    final extension = _pathExtensionFromCandidate(candidate);
    if (extension.isNotEmpty) {
      return extension;
    }
  }
  return '';
}

String _pathExtensionFromCandidate(String? candidate) {
  if (candidate == null) return '';
  final trimmed = candidate.trim();
  if (trimmed.isEmpty) return '';
  final uri = Uri.tryParse(trimmed);
  final sourcePath = uri != null && uri.hasScheme ? uri.path : trimmed;
  return path.extension(sourcePath).toLowerCase();
}
