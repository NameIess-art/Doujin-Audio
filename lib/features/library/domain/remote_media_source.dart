import 'package:flutter/foundation.dart';

import '../../../core/immutable_collections.dart';

enum RemoteMediaSourceType {
  windowsLan('windowsLan'),
  webDav('webDav');

  const RemoteMediaSourceType(this.wireValue);
  final String wireValue;

  static RemoteMediaSourceType fromWire(String? value) => switch (value) {
    'webDav' => RemoteMediaSourceType.webDav,
    _ => RemoteMediaSourceType.windowsLan,
  };
}

enum RemoteMediaSourceConflict implements Exception { duplicate, localServer }

class RemoteMediaSource {
  RemoteMediaSource({
    required this.id,
    required this.type,
    required this.name,
    required this.baseUrl,
    this.username = '',
    this.lanServerId,
    this.secretConfigured = false,
    this.allowSync = false,
    this.allowEdit = true,
    List<String> pinnedWorkIds = const <String>[],
    List<String> excludedWorkIds = const <String>[],
    required this.createdAtMs,
  }) : pinnedWorkIds = immutableList(pinnedWorkIds),
       excludedWorkIds = immutableList(excludedWorkIds);

  final String id;
  final RemoteMediaSourceType type;
  final String name;
  final String baseUrl;
  final String username;
  final String? lanServerId;
  final bool secretConfigured;
  final bool allowSync;
  final bool allowEdit;
  final List<String> pinnedWorkIds;
  final List<String> excludedWorkIds;
  final int createdAtMs;

  bool get isLan => type == RemoteMediaSourceType.windowsLan;
  bool get isWebDav => type == RemoteMediaSourceType.webDav;

  RemoteMediaSource copyWith({
    String? name,
    String? baseUrl,
    String? username,
    String? lanServerId,
    bool? secretConfigured,
    bool? allowSync,
    bool? allowEdit,
    List<String>? pinnedWorkIds,
    List<String>? excludedWorkIds,
  }) => RemoteMediaSource(
    id: id,
    type: type,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    username: username ?? this.username,
    lanServerId: lanServerId ?? this.lanServerId,
    secretConfigured: secretConfigured ?? this.secretConfigured,
    allowSync: allowSync ?? this.allowSync,
    allowEdit: allowEdit ?? this.allowEdit,
    pinnedWorkIds: pinnedWorkIds ?? this.pinnedWorkIds,
    excludedWorkIds: excludedWorkIds ?? this.excludedWorkIds,
    createdAtMs: createdAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'type': type.wireValue,
    'name': name,
    'baseUrl': baseUrl,
    'username': username,
    'lanServerId': ?lanServerId,
    'secretConfigured': secretConfigured,
    'allowSync': allowSync,
    'allowEdit': allowEdit,
    if (pinnedWorkIds.isNotEmpty) 'pinnedWorkIds': pinnedWorkIds,
    if (excludedWorkIds.isNotEmpty) 'excludedWorkIds': excludedWorkIds,
    'createdAtMs': createdAtMs,
  };

  factory RemoteMediaSource.fromJson(Map<String, Object?> json) =>
      RemoteMediaSource(
        id: json['id']?.toString() ?? '',
        type: RemoteMediaSourceType.fromWire(json['type']?.toString()),
        name: json['name']?.toString() ?? '',
        baseUrl: json['baseUrl']?.toString() ?? '',
        username: json['username']?.toString() ?? '',
        lanServerId: json['lanServerId']?.toString(),
        secretConfigured: json['secretConfigured'] == true,
        allowSync: json['allowSync'] == true,
        allowEdit: json['allowEdit'] != false,
        pinnedWorkIds: (json['pinnedWorkIds'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        excludedWorkIds: (json['excludedWorkIds'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      );
}

class LanServerSettings {
  const LanServerSettings({
    this.enabled = false,
    this.port = defaultHttpPort,
    this.requireAccessCode = true,
    this.allowSync = true,
    this.allowRemoteEdit = true,
  });

  static const int defaultHttpPort = 42871;
  static const int defaultDiscoveryPort = 42870;

  final bool enabled;
  final int port;
  final bool requireAccessCode;
  final bool allowSync;
  final bool allowRemoteEdit;

  LanServerSettings copyWith({
    bool? enabled,
    int? port,
    bool? requireAccessCode,
    bool? allowSync,
    bool? allowRemoteEdit,
  }) => LanServerSettings(
    enabled: enabled ?? this.enabled,
    port: port ?? this.port,
    requireAccessCode: requireAccessCode ?? this.requireAccessCode,
    allowSync: allowSync ?? this.allowSync,
    allowRemoteEdit: allowRemoteEdit ?? this.allowRemoteEdit,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'port': port,
    'requireAccessCode': requireAccessCode,
    'allowSync': allowSync,
    'allowRemoteEdit': allowRemoteEdit,
  };

  factory LanServerSettings.fromJson(Map<String, Object?> json) {
    final rawPort = (json['port'] as num?)?.toInt() ?? defaultHttpPort;
    return LanServerSettings(
      enabled: json['enabled'] == true,
      port: (rawPort >= 1024 && rawPort <= 65535) ? rawPort : defaultHttpPort,
      requireAccessCode: json['requireAccessCode'] != false,
      allowSync: json['allowSync'] != false,
      allowRemoteEdit: json['allowRemoteEdit'] != false,
    );
  }
}

class LanDiscoveredServer {
  const LanDiscoveredServer({
    required this.serverId,
    required this.name,
    required this.host,
    required this.port,
    required this.authRequired,
    required this.allowSync,
  });

  final String serverId;
  final String name;
  final String host;
  final int port;
  final bool authRequired;
  final bool allowSync;

  String get baseUrl => 'http://$host:$port';
}

const Object _remoteUnset = Object();

class RemoteLibraryWork {
  RemoteLibraryWork({
    required this.sourceId,
    required this.workId,
    required this.rjCode,
    required this.title,
    this.folderName = '',
    required this.circleName,
    List<String> voiceActors = const <String>[],
    List<String> tags = const <String>[],
    this.releaseDateMs,
    this.durationMs = 0,
    this.trackCount = 0,
    this.salesCount,
    this.rating,
    this.listenStatus,
    this.userRating,
    this.reviewText = '',
    bool hasReviewNote = false,
    this.reviewUpdatedAtMs = 0,
    this.detailUpdatedAtMs = 0,
    this.isPinned = false,
    this.hasSubtitle = false,
    this.coverUrl,
    this.directoryUri,
    this.updatedAtMs = 0,
  }) : _hasReviewNote = hasReviewNote,
       voiceActors = immutableList(voiceActors),
       tags = immutableList(tags);

  final String sourceId;
  final String workId;
  final String rjCode;
  final String title;
  final String folderName;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final int? releaseDateMs;
  final int durationMs;
  final int trackCount;
  final int? salesCount;
  final double? rating;
  final String? listenStatus;
  final int? userRating;
  final String reviewText;
  final bool _hasReviewNote;
  final int reviewUpdatedAtMs;
  final int detailUpdatedAtMs;
  final bool isPinned;
  final bool hasSubtitle;
  final String? coverUrl;
  final String? directoryUri;
  final int updatedAtMs;

  bool get hasReviewNote => _hasReviewNote || reviewText.trim().isNotEmpty;

  String get uniqueKey => '$sourceId::$workId';

  bool hasSameContent(RemoteLibraryWork other) =>
      sourceId == other.sourceId &&
      workId == other.workId &&
      rjCode == other.rjCode &&
      title == other.title &&
      folderName == other.folderName &&
      circleName == other.circleName &&
      listEquals(voiceActors, other.voiceActors) &&
      listEquals(tags, other.tags) &&
      releaseDateMs == other.releaseDateMs &&
      durationMs == other.durationMs &&
      trackCount == other.trackCount &&
      salesCount == other.salesCount &&
      rating == other.rating &&
      listenStatus == other.listenStatus &&
      userRating == other.userRating &&
      reviewText == other.reviewText &&
      hasReviewNote == other.hasReviewNote &&
      reviewUpdatedAtMs == other.reviewUpdatedAtMs &&
      detailUpdatedAtMs == other.detailUpdatedAtMs &&
      isPinned == other.isPinned &&
      hasSubtitle == other.hasSubtitle &&
      coverUrl == other.coverUrl &&
      directoryUri == other.directoryUri &&
      updatedAtMs == other.updatedAtMs;

  RemoteLibraryWork copyWith({
    String? workId,
    String? rjCode,
    String? title,
    String? folderName,
    String? circleName,
    List<String>? voiceActors,
    List<String>? tags,
    Object? releaseDateMs = _remoteUnset,
    int? durationMs,
    int? trackCount,
    Object? salesCount = _remoteUnset,
    Object? rating = _remoteUnset,
    Object? listenStatus = _remoteUnset,
    Object? userRating = _remoteUnset,
    String? reviewText,
    bool? hasReviewNote,
    int? reviewUpdatedAtMs,
    int? detailUpdatedAtMs,
    bool? isPinned,
    bool? hasSubtitle,
    Object? coverUrl = _remoteUnset,
    Object? directoryUri = _remoteUnset,
    int? updatedAtMs,
  }) => RemoteLibraryWork(
    sourceId: sourceId,
    workId: workId ?? this.workId,
    rjCode: rjCode ?? this.rjCode,
    title: title ?? this.title,
    folderName: folderName ?? this.folderName,
    circleName: circleName ?? this.circleName,
    voiceActors: voiceActors ?? this.voiceActors,
    tags: tags ?? this.tags,
    releaseDateMs: releaseDateMs == _remoteUnset
        ? this.releaseDateMs
        : releaseDateMs as int?,
    durationMs: durationMs ?? this.durationMs,
    trackCount: trackCount ?? this.trackCount,
    salesCount: salesCount == _remoteUnset
        ? this.salesCount
        : salesCount as int?,
    rating: rating == _remoteUnset ? this.rating : rating as double?,
    listenStatus: listenStatus == _remoteUnset
        ? this.listenStatus
        : listenStatus as String?,
    userRating: userRating == _remoteUnset
        ? this.userRating
        : userRating as int?,
    reviewText: reviewText ?? this.reviewText,
    hasReviewNote: hasReviewNote ?? _hasReviewNote,
    reviewUpdatedAtMs: reviewUpdatedAtMs ?? this.reviewUpdatedAtMs,
    detailUpdatedAtMs: detailUpdatedAtMs ?? this.detailUpdatedAtMs,
    isPinned: isPinned ?? this.isPinned,
    hasSubtitle: hasSubtitle ?? this.hasSubtitle,
    coverUrl: coverUrl == _remoteUnset ? this.coverUrl : coverUrl as String?,
    directoryUri: directoryUri == _remoteUnset
        ? this.directoryUri
        : directoryUri as String?,
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'workId': workId,
    'rjCode': rjCode,
    'title': title,
    if (folderName.isNotEmpty) 'folderName': folderName,
    'circleName': circleName,
    'voiceActors': voiceActors,
    'tags': tags,
    if (releaseDateMs != null) 'releaseDateMs': releaseDateMs,
    'durationMs': durationMs,
    if (trackCount > 0) 'trackCount': trackCount,
    if (salesCount != null) 'salesCount': salesCount,
    if (rating != null) 'rating': rating,
    if (listenStatus != null && listenStatus!.isNotEmpty)
      'listenStatus': listenStatus,
    if (userRating != null) 'userRating': userRating,
    if (reviewText.isNotEmpty) 'reviewText': reviewText,
    if (hasReviewNote) 'hasReviewNote': true,
    if (reviewUpdatedAtMs > 0) 'reviewUpdatedAtMs': reviewUpdatedAtMs,
    if (detailUpdatedAtMs > 0) 'detailUpdatedAtMs': detailUpdatedAtMs,
    if (isPinned) 'isPinned': true,
    'hasSubtitle': hasSubtitle,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (directoryUri != null) 'directoryUri': directoryUri,
    'updatedAtMs': updatedAtMs,
  };

  factory RemoteLibraryWork.fromJson(Map<String, Object?> json) =>
      RemoteLibraryWork(
        sourceId: json['sourceId']?.toString() ?? '',
        workId: json['workId']?.toString() ?? '',
        rjCode: json['rjCode']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        folderName: json['folderName']?.toString() ?? '',
        circleName: json['circleName']?.toString() ?? '',
        voiceActors: (json['voiceActors'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        tags: (json['tags'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        releaseDateMs: (json['releaseDateMs'] as num?)?.toInt(),
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
        salesCount: (json['salesCount'] as num?)?.toInt(),
        rating: (json['rating'] as num?)?.toDouble(),
        listenStatus: json['listenStatus']?.toString(),
        userRating: (json['userRating'] as num?)?.toInt(),
        reviewText: json['reviewText']?.toString() ?? '',
        hasReviewNote: json['hasReviewNote'] == true,
        reviewUpdatedAtMs: (json['reviewUpdatedAtMs'] as num?)?.toInt() ?? 0,
        detailUpdatedAtMs: (json['detailUpdatedAtMs'] as num?)?.toInt() ?? 0,
        isPinned: json['isPinned'] == true,
        hasSubtitle: json['hasSubtitle'] == true,
        coverUrl: json['coverUrl']?.toString(),
        directoryUri: json['directoryUri']?.toString(),
        updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
      );
}
