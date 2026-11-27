class SyncTrackStateEntry {
  const SyncTrackStateEntry({
    required this.workKey,
    required this.relativePath,
    required this.positionMs,
    this.lastPlayedAtMs,
    required this.isFavorite,
    required this.favoriteUpdatedAtMs,
    required this.updatedAtMs,
  });

  final String workKey;
  final String relativePath;
  final int positionMs;
  final int? lastPlayedAtMs;
  final bool isFavorite;
  final int favoriteUpdatedAtMs;
  final int updatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'workKey': workKey,
    'relativePath': relativePath,
    'positionMs': positionMs,
    if (lastPlayedAtMs != null) 'lastPlayedAtMs': lastPlayedAtMs,
    'isFavorite': isFavorite,
    'favoriteUpdatedAtMs': favoriteUpdatedAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory SyncTrackStateEntry.fromJson(Map<String, Object?> json) {
    final workKey = json['workKey']?.toString().trim() ?? '';
    final relativePath = json['relativePath']?.toString().trim() ?? '';
    if (workKey.isEmpty || relativePath.isEmpty) {
      throw const FormatException('invalid_sync_payload');
    }
    return SyncTrackStateEntry(
      workKey: workKey,
      relativePath: relativePath,
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      lastPlayedAtMs: (json['lastPlayedAtMs'] as num?)?.toInt(),
      isFavorite: json['isFavorite'] == true,
      favoriteUpdatedAtMs: (json['favoriteUpdatedAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class SyncHistoryWorkEntry {
  const SyncHistoryWorkEntry({
    required this.workKey,
    required this.title,
    required this.subtitle,
    this.remoteCoverUrl,
    required this.lastPlayedAtMs,
  });

  final String workKey;
  final String title;
  final String subtitle;
  final String? remoteCoverUrl;
  final int lastPlayedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'workKey': workKey,
    'title': title,
    'subtitle': subtitle,
    if (remoteCoverUrl != null) 'remoteCoverUrl': remoteCoverUrl,
    'lastPlayedAtMs': lastPlayedAtMs,
  };

  factory SyncHistoryWorkEntry.fromJson(Map<String, Object?> json) =>
      SyncHistoryWorkEntry(
        workKey: json['workKey']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        subtitle: json['subtitle']?.toString() ?? '',
        remoteCoverUrl: json['remoteCoverUrl']?.toString(),
        lastPlayedAtMs: (json['lastPlayedAtMs'] as num?)?.toInt() ?? 0,
      );
}

class SyncTimeSegmentEntry {
  const SyncTimeSegmentEntry({
    required this.id,
    required this.workKey,
    required this.relativePath,
    required this.name,
    required this.startMs,
    required this.endMs,
    required this.colorValue,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String workKey;
  final String relativePath;
  final String name;
  final int startMs;
  final int endMs;
  final int colorValue;
  final int createdAtMs;
  final int updatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'workKey': workKey,
    'relativePath': relativePath,
    'name': name,
    'startMs': startMs,
    'endMs': endMs,
    'colorValue': colorValue,
    'createdAtMs': createdAtMs,
    'updatedAtMs': updatedAtMs,
  };

  factory SyncTimeSegmentEntry.fromJson(Map<String, Object?> json) {
    final id = json['id']?.toString().trim() ?? '';
    final workKey = json['workKey']?.toString().trim() ?? '';
    final relativePath = json['relativePath']?.toString().trim() ?? '';
    if (id.isEmpty || workKey.isEmpty || relativePath.isEmpty) {
      throw const FormatException('invalid_sync_payload');
    }
    return SyncTimeSegmentEntry(
      id: id,
      workKey: workKey,
      relativePath: relativePath,
      name: json['name']?.toString() ?? '',
      startMs: (json['startMs'] as num?)?.toInt() ?? 0,
      endMs: (json['endMs'] as num?)?.toInt() ?? 0,
      colorValue: (json['colorValue'] as num?)?.toInt() ?? 0xFF64B5F6,
      createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class SyncWorkStateEntry {
  const SyncWorkStateEntry({
    required this.workKey,
    required this.rjCode,
    this.workTitle = '',
    this.circleName = '',
    this.voiceActors = const <String>[],
    this.tags = const <String>[],
    this.releaseDateMs,
    this.salesCount,
    this.rating,
    this.detailUpdatedAtMs = 0,
    this.listenStatus,
    this.userRating,
    this.reviewText = '',
    this.reviewUpdatedAtMs = 0,
  });

  final String workKey;
  final String rjCode;
  final String workTitle;
  final String circleName;
  final List<String> voiceActors;
  final List<String> tags;
  final int? releaseDateMs;
  final int? salesCount;
  final double? rating;
  final int detailUpdatedAtMs;
  final String? listenStatus;
  final int? userRating;
  final String reviewText;
  final int reviewUpdatedAtMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'workKey': workKey,
    'rjCode': rjCode,
    'workTitle': workTitle,
    'circleName': circleName,
    'voiceActors': voiceActors,
    'tags': tags,
    if (releaseDateMs != null) 'releaseDateMs': releaseDateMs,
    if (salesCount != null) 'salesCount': salesCount,
    if (rating != null) 'rating': rating,
    'detailUpdatedAtMs': detailUpdatedAtMs,
    'listenStatus': listenStatus,
    'userRating': userRating,
    'reviewText': reviewText,
    'reviewUpdatedAtMs': reviewUpdatedAtMs,
  };

  factory SyncWorkStateEntry.fromJson(Map<String, Object?> json) {
    final workKey = json['workKey']?.toString().trim() ?? '';
    if (workKey.isEmpty) {
      throw const FormatException('invalid_sync_payload');
    }
    return SyncWorkStateEntry(
      workKey: workKey,
      rjCode: json['rjCode']?.toString().trim() ?? '',
      workTitle: json['workTitle']?.toString() ?? '',
      circleName: json['circleName']?.toString() ?? '',
      voiceActors: (json['voiceActors'] as List? ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      tags: (json['tags'] as List? ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      releaseDateMs: (json['releaseDateMs'] as num?)?.toInt(),
      salesCount: (json['salesCount'] as num?)?.toInt(),
      rating: (json['rating'] as num?)?.toDouble(),
      detailUpdatedAtMs: (json['detailUpdatedAtMs'] as num?)?.toInt() ?? 0,
      listenStatus: json['listenStatus']?.toString(),
      userRating: (json['userRating'] as num?)?.toInt(),
      reviewText: json['reviewText']?.toString() ?? '',
      reviewUpdatedAtMs: (json['reviewUpdatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class CrossPlatformSyncBundle {
  const CrossPlatformSyncBundle({
    required this.formatVersion,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.exportedAt,
    required this.tracks,
    required this.deviceDayLedger,
    required this.deviceWorkDayLedger,
    required this.history,
    required this.timeSegments,
    required this.deletedTimeSegments,
    required this.interests,
    this.workStates = const <SyncWorkStateEntry>[],
  });

  static const String formatMagic = 'doujin_audio_sync';
  static const int currentFormatVersion = 1;

  final int formatVersion;
  final String deviceId;
  final String deviceName;
  final String platform;
  final DateTime exportedAt;
  final List<SyncTrackStateEntry> tracks;
  final Map<String, Map<String, int>> deviceDayLedger;
  final Map<String, Map<String, Map<String, int>>> deviceWorkDayLedger;
  final List<SyncHistoryWorkEntry> history;
  final List<SyncTimeSegmentEntry> timeSegments;
  final Map<String, int> deletedTimeSegments;
  final Map<String, Map<String, Object?>> interests;
  final List<SyncWorkStateEntry> workStates;

  Map<String, Object?> toPayloadJson() => <String, Object?>{
    'format': formatMagic,
    'formatVersion': formatVersion,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'platform': platform,
    'exportedAt': exportedAt.toUtc().toIso8601String(),
    'tracks': tracks.map((e) => e.toJson()).toList(growable: false),
    'deviceDayLedger': deviceDayLedger,
    'deviceWorkDayLedger': deviceWorkDayLedger,
    'history': history.map((e) => e.toJson()).toList(growable: false),
    'timeSegments': timeSegments.map((e) => e.toJson()).toList(growable: false),
    'deletedTimeSegments': deletedTimeSegments,
    'interests': interests,
    if (workStates.isNotEmpty)
      'workStates': workStates.map((e) => e.toJson()).toList(growable: false),
  };

  factory CrossPlatformSyncBundle.fromPayloadJson(Map<String, Object?> json) {
    if (json['format'] != formatMagic) {
      throw const FormatException('invalid_sync_format');
    }
    final version = (json['formatVersion'] as num?)?.toInt() ?? -1;
    if (version < 1 || version > currentFormatVersion) {
      throw const FormatException('unsupported_sync_version');
    }
    final deviceId = json['deviceId']?.toString().trim() ?? '';
    final exportedAt = DateTime.tryParse(json['exportedAt']?.toString() ?? '');
    if (deviceId.isEmpty || exportedAt == null) {
      throw const FormatException('invalid_sync_payload');
    }

    final tracks = (json['tracks'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((m) => SyncTrackStateEntry.fromJson(Map<String, Object?>.from(m)))
        .toList(growable: false);

    final dayLedger = <String, Map<String, int>>{};
    if (json['deviceDayLedger'] is Map) {
      for (final dev in (json['deviceDayLedger'] as Map).entries) {
        if (dev.value is! Map) continue;
        dayLedger[dev.key.toString()] = (dev.value as Map).map(
          (k, v) => MapEntry(k.toString(), (v as num).toInt()),
        );
      }
    }

    final workDayLedger = <String, Map<String, Map<String, int>>>{};
    if (json['deviceWorkDayLedger'] is Map) {
      for (final dev in (json['deviceWorkDayLedger'] as Map).entries) {
        if (dev.value is! Map) continue;
        final dates = <String, Map<String, int>>{};
        for (final dateEntry in (dev.value as Map).entries) {
          if (dateEntry.value is! Map) continue;
          dates[dateEntry.key.toString()] = (dateEntry.value as Map).map(
            (k, v) => MapEntry(k.toString(), (v as num).toInt()),
          );
        }
        workDayLedger[dev.key.toString()] = dates;
      }
    }

    final history = (json['history'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((m) => SyncHistoryWorkEntry.fromJson(Map<String, Object?>.from(m)))
        .where((h) => h.workKey.isNotEmpty)
        .toList(growable: false);

    final segments = (json['timeSegments'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((m) => SyncTimeSegmentEntry.fromJson(Map<String, Object?>.from(m)))
        .toList(growable: false);

    final deletedSegments = <String, int>{};
    if (json['deletedTimeSegments'] is Map) {
      for (final entry in (json['deletedTimeSegments'] as Map).entries) {
        if (entry.value is num) {
          deletedSegments[entry.key.toString()] = (entry.value as num).toInt();
        }
      }
    }

    final interests = <String, Map<String, Object?>>{};
    if (json['interests'] is Map) {
      for (final entry in (json['interests'] as Map).entries) {
        if (entry.value is Map) {
          interests[entry.key.toString()] = Map<String, Object?>.from(
            entry.value as Map,
          );
        }
      }
    }

    final workStates = (json['workStates'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((m) => SyncWorkStateEntry.fromJson(Map<String, Object?>.from(m)))
        .toList(growable: false);

    return CrossPlatformSyncBundle(
      formatVersion: version,
      deviceId: deviceId,
      deviceName: json['deviceName']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      exportedAt: exportedAt,
      tracks: tracks,
      deviceDayLedger: dayLedger,
      deviceWorkDayLedger: workDayLedger,
      history: history,
      timeSegments: segments,
      deletedTimeSegments: deletedSegments,
      interests: interests,
      workStates: workStates,
    );
  }
}

class WebDavSyncSettings {
  const WebDavSyncSettings({
    this.url = '',
    this.username = '',
    this.passwordConfigured = false,
    this.autoSyncEnabled = false,
    this.lastSyncedAtMs,
  });

  final String url;
  final String username;
  final bool passwordConfigured;
  final bool autoSyncEnabled;
  final int? lastSyncedAtMs;

  bool get hasLegacyEndpoint => url.trim().isNotEmpty;

  WebDavSyncSettings copyWith({bool? autoSyncEnabled, int? lastSyncedAtMs}) =>
      WebDavSyncSettings(
        url: url,
        username: username,
        passwordConfigured: passwordConfigured,
        autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
        lastSyncedAtMs: lastSyncedAtMs ?? this.lastSyncedAtMs,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'username': username,
    'passwordConfigured': passwordConfigured,
    'autoSyncEnabled': autoSyncEnabled,
    if (lastSyncedAtMs != null) 'lastSyncedAtMs': lastSyncedAtMs,
  };

  factory WebDavSyncSettings.fromJson(Map<String, Object?> json) {
    // A former media-source binding had already superseded the standalone URL.
    final wasBound = (json['sourceId']?.toString() ?? '').isNotEmpty;
    return WebDavSyncSettings(
      url: wasBound ? '' : json['url']?.toString() ?? '',
      username: wasBound ? '' : json['username']?.toString() ?? '',
      passwordConfigured: !wasBound && json['passwordConfigured'] == true,
      autoSyncEnabled: json['autoSyncEnabled'] == true,
      lastSyncedAtMs: (json['lastSyncedAtMs'] as num?)?.toInt(),
    );
  }
}

class CrossPlatformSyncSummary {
  const CrossPlatformSyncSummary({
    required this.trackStatesMerged,
    required this.listeningDaysUpdated,
    required this.timeSegmentsMerged,
    required this.interestsChanged,
    required this.peersMerged,
    this.workStatesMerged = 0,
  });

  final int trackStatesMerged;
  final int listeningDaysUpdated;
  final int timeSegmentsMerged;
  final bool interestsChanged;
  final int peersMerged;
  final int workStatesMerged;

  bool get hasChanges =>
      trackStatesMerged > 0 ||
      listeningDaysUpdated > 0 ||
      timeSegmentsMerged > 0 ||
      interestsChanged ||
      workStatesMerged > 0;
}

class CrossPlatformSyncApplyOutcome {
  const CrossPlatformSyncApplyOutcome({
    required this.updatedTrackPaths,
    required this.trackStatesMerged,
    required this.listeningDaysUpdated,
    required this.timeSegmentsMerged,
    this.updatedDetailTargets = const <(String, String)>{},
    this.workStatesMerged = 0,
  });

  final Set<String> updatedTrackPaths;
  final int trackStatesMerged;
  final int listeningDaysUpdated;
  final int timeSegmentsMerged;
  final Set<(String, String)> updatedDetailTargets;
  final int workStatesMerged;
}

abstract interface class CrossPlatformSyncRepository {
  Future<String> ensureDeviceId(String Function() generateDeviceId);

  Future<SyncTrackStateEntry?> findSyncedTrackState({
    required String workKey,
    required String relativePath,
  });

  Future<SyncWorkStateEntry?> findSyncedWorkState(String workKey);

  Future<Set<(String, String)>> upsertSyncedWorkState(SyncWorkStateEntry entry);

  Future<
    ({
      String deviceId,
      List<SyncTrackStateEntry> tracks,
      Map<String, Map<String, int>> deviceDayLedger,
      Map<String, Map<String, Map<String, int>>> deviceWorkDayLedger,
      List<SyncHistoryWorkEntry> history,
      List<SyncTimeSegmentEntry> timeSegments,
      Map<String, int> deletedTimeSegments,
      Map<String, String?> interestSettings,
      List<SyncWorkStateEntry> workStates,
    })
  >
  exportSnapshot({
    required String Function() generateDeviceId,
    required Iterable<String> interestSettingKeys,
  });

  Future<CrossPlatformSyncApplyOutcome> applyMergedSnapshot({
    required String Function() generateDeviceId,
    required List<SyncTrackStateEntry> incomingTracks,
    required Map<String, Map<String, int>> incomingDeviceDayLedger,
    required Map<String, Map<String, Map<String, int>>> incomingDeviceWorkDayLedger,
    required List<SyncHistoryWorkEntry> incomingHistory,
    required List<SyncTimeSegmentEntry> incomingTimeSegments,
    required Map<String, int> incomingDeletedTimeSegments,
    required Map<String, String?> mergedInterestSettings,
    List<SyncWorkStateEntry> incomingWorkStates = const <SyncWorkStateEntry>[],
  });
}

class NoopCrossPlatformSyncRepository implements CrossPlatformSyncRepository {
  const NoopCrossPlatformSyncRepository();

  @override
  Future<String> ensureDeviceId(String Function() generateDeviceId) async =>
      'noop-device';

  @override
  Future<SyncTrackStateEntry?> findSyncedTrackState({
    required String workKey,
    required String relativePath,
  }) async => null;

  @override
  Future<SyncWorkStateEntry?> findSyncedWorkState(String workKey) async => null;

  @override
  Future<Set<(String, String)>> upsertSyncedWorkState(
    SyncWorkStateEntry entry,
  ) async => const <(String, String)>{};

  @override
  Future<
    ({
      String deviceId,
      List<SyncTrackStateEntry> tracks,
      Map<String, Map<String, int>> deviceDayLedger,
      Map<String, Map<String, Map<String, int>>> deviceWorkDayLedger,
      List<SyncHistoryWorkEntry> history,
      List<SyncTimeSegmentEntry> timeSegments,
      Map<String, int> deletedTimeSegments,
      Map<String, String?> interestSettings,
      List<SyncWorkStateEntry> workStates,
    })
  >
  exportSnapshot({
    required String Function() generateDeviceId,
    required Iterable<String> interestSettingKeys,
  }) async => (
    deviceId: 'noop-device',
    tracks: const <SyncTrackStateEntry>[],
    deviceDayLedger: const <String, Map<String, int>>{},
    deviceWorkDayLedger: const <String, Map<String, Map<String, int>>>{},
    history: const <SyncHistoryWorkEntry>[],
    timeSegments: const <SyncTimeSegmentEntry>[],
    deletedTimeSegments: const <String, int>{},
    interestSettings: const <String, String?>{},
    workStates: const <SyncWorkStateEntry>[],
  );

  @override
  Future<CrossPlatformSyncApplyOutcome> applyMergedSnapshot({
    required String Function() generateDeviceId,
    required List<SyncTrackStateEntry> incomingTracks,
    required Map<String, Map<String, int>> incomingDeviceDayLedger,
    required Map<String, Map<String, Map<String, int>>> incomingDeviceWorkDayLedger,
    required List<SyncHistoryWorkEntry> incomingHistory,
    required List<SyncTimeSegmentEntry> incomingTimeSegments,
    required Map<String, int> incomingDeletedTimeSegments,
    required Map<String, String?> mergedInterestSettings,
    List<SyncWorkStateEntry> incomingWorkStates = const <SyncWorkStateEntry>[],
  }) async => const CrossPlatformSyncApplyOutcome(
    updatedTrackPaths: <String>{},
    trackStatesMerged: 0,
    listeningDaysUpdated: 0,
    timeSegmentsMerged: 0,
  );
}
