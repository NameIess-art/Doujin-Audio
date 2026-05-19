import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'music_track.dart';

enum AsmrCategoryType { sales, rating, release, favorites, history }

@immutable
class AsmrWorkPage {
  const AsmrWorkPage({
    required this.works,
    required this.currentPage,
    required this.pageSize,
    required this.totalCount,
  });

  final List<AsmrWork> works;
  final int currentPage;
  final int pageSize;
  final int totalCount;

  bool get hasMore => currentPage * pageSize < totalCount;

  factory AsmrWorkPage.fromJson(Map<String, dynamic> json) {
    final pagination =
        json['pagination'] as Map<String, dynamic>? ??
        const <String, dynamic>{};
    final works = (json['works'] as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(AsmrWork.fromJson)
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
class AsmrAuthSession {
  const AsmrAuthSession({
    this.token,
    this.userName,
    this.userId,
    this.favoritePlaylistId,
  });

  final String? token;
  final String? userName;
  final int? userId;
  final int? favoritePlaylistId;

  bool get isLoggedIn => token != null && token!.isNotEmpty;

  AsmrAuthSession copyWith({
    String? token,
    String? userName,
    int? userId,
    int? favoritePlaylistId,
    bool clearFavoritePlaylistId = false,
  }) {
    return AsmrAuthSession(
      token: token ?? this.token,
      userName: userName ?? this.userName,
      userId: userId ?? this.userId,
      favoritePlaylistId: clearFavoritePlaylistId
          ? null
          : favoritePlaylistId ?? this.favoritePlaylistId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'token': token,
    'userName': userName,
    'userId': userId,
    'favoritePlaylistId': favoritePlaylistId,
  };

  factory AsmrAuthSession.fromJson(Object? raw) {
    final json = raw is Map<Object?, Object?>
        ? raw
        : const <Object?, Object?>{};
    return AsmrAuthSession(
      token: json['token'] as String?,
      userName: json['userName'] as String?,
      userId: (json['userId'] as num?)?.toInt(),
      favoritePlaylistId: (json['favoritePlaylistId'] as num?)?.toInt(),
    );
  }
}

@immutable
class AsmrWork {
  const AsmrWork({
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
    required this.voiceActors,
    required this.tags,
    this.hasSubtitle = false,
    this.isFavorite = false,
  });

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

  factory AsmrWork.fromJson(Map<String, dynamic> json) {
    final circle = json['circle'];
    final circleName =
        (json['circleName'] as String?) ??
        (json['name'] as String?) ??
        (circle is Map<String, dynamic> ? circle['name'] as String? : null) ??
        '';
    final tags = (json['tags'] as List<dynamic>? ?? const <dynamic>[])
        .map((dynamic item) {
          if (item is Map<String, dynamic>) {
            return (item['name'] as String?) ?? '';
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
      title: (json['title'] as String?) ?? '',
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
  const AsmrWorkDetail({
    required this.work,
    required this.description,
    required this.ageCategory,
    required this.languageEditionLabels,
    required this.userRating,
  });

  final AsmrWork work;
  final String description;
  final String ageCategory;
  final List<String> languageEditionLabels;
  final double? userRating;

  factory AsmrWorkDetail.fromJson(Map<String, dynamic> json) {
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
      work: AsmrWork.fromJson(json),
      description: (json['description'] as String?) ?? '',
      ageCategory: (json['age_category_string'] as String?) ?? '',
      languageEditionLabels: editions,
      userRating: (json['userRating'] as num?)?.toDouble(),
    );
  }
}

@immutable
class AsmrTrackFile {
  const AsmrTrackFile({
    required this.hash,
    required this.title,
    required this.type,
    required this.streamUrl,
    required this.downloadUrl,
    required this.lowQualityUrl,
    required this.duration,
    required this.size,
    required this.children,
    required this.workId,
    required this.workTitle,
    required this.sourceId,
    required this.relativePath,
  });

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
  bool get isAudio => type == 'audio';
  bool get isSubtitle =>
      type == 'text' &&
      _asmrSubtitleExtensions.contains(path.extension(title).toLowerCase());
  String get stemKey => _asmrStemKey(relativePath);
  String get baseNameStem => path.basenameWithoutExtension(title).toLowerCase();

  MusicTrack toMusicTrack({
    String? groupTitleOverride,
    String? remoteCoverUrl,
    String? remoteMetadataKind,
    Map<String, Object?>? remoteMetadata,
  }) {
    final playbackUrl = (lowQualityUrl ?? streamUrl ?? downloadUrl ?? '')
        .trim();
    return MusicTrack(
      path: playbackUrl,
      displayName: title,
      groupKey: 'asmr-work-$workId',
      groupTitle: groupTitleOverride ?? workTitle,
      groupSubtitle: sourceId,
      isSingle: false,
      remoteCoverUrl: remoteCoverUrl,
      remoteMetadataKind: remoteMetadataKind,
      remoteMetadata: remoteMetadata,
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

const Set<String> _asmrSubtitleExtensions = <String>{
  '.vtt',
  '.webvtt',
  '.lrc',
  '.srt',
  '.ass',
  '.ssa',
};

String _asmrStemKey(String relativePath) =>
    path.withoutExtension(relativePath).toLowerCase();
