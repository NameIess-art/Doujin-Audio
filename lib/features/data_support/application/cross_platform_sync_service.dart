import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/network/webdav_client.dart';
import '../../../core/persistence/app_preferences.dart';
import '../../asmr/application/asmr_preferences.dart';
import '../../asmr/domain/asmr_tag_interest.dart';
import '../domain/cross_platform_sync_models.dart';

typedef SyncSecretRead = Future<String?> Function(String key);
typedef SyncSecretWrite = Future<void> Function(String key, String? value);
typedef WebDavSyncSource = ({Uri baseUri, String username, String? password});
typedef WebDavSyncSourceResolver = WebDavSyncSource? Function(String sourceId);
typedef SyncAppliedCallback =
    Future<void> Function(
      Set<String> updatedTrackPaths,
      bool interestsChanged, {
      Set<(String, String)> updatedDetailTargets,
    });

const String _webDavSyncConfigPrefKey = 'cross_platform_webdav_sync_v1';
const String _webDavPeerStatePrefKey = 'cross_platform_webdav_peers_v1';
const String _webDavSyncPasswordSecretKey =
    'cross_platform_webdav_sync_password_v1';

const int _maxCompressedSyncBytes = 32 * 1024 * 1024;
const int _maxExpandedSyncBytes = 96 * 1024 * 1024;

class CrossPlatformSyncService extends ChangeNotifier {
  CrossPlatformSyncService({
    CrossPlatformSyncRepository? repository,
    Future<void> Function()? beforeExport,
    SyncAppliedCallback? onSyncApplied,
    SyncSecretRead? readSecret,
    WebDavClient Function({
      required Uri baseUri,
      String? username,
      String? password,
    })?
    webDavClientFactory,
    HttpClient Function()? httpClientFactory,
    DateTime Function()? clock,
    String? platformName,
    String? deviceName,
  }) : _repository = repository ?? const NoopCrossPlatformSyncRepository(),
       _beforeExport = beforeExport,
       _onSyncApplied = onSyncApplied,
       _readSecret = readSecret ?? _defaultSecretRead,
       _webDavClientFactory = webDavClientFactory ?? _defaultWebDavFactory,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _clock = clock ?? DateTime.now,
       _platformName = platformName ?? Platform.operatingSystem,
       _deviceName = deviceName ?? _safeLocalHostname();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static Future<String?> _defaultSecretRead(String key) =>
      _secureStorage.read(key: key);
  static WebDavClient _defaultWebDavFactory({
    required Uri baseUri,
    String? username,
    String? password,
  }) => WebDavClient(baseUri: baseUri, username: username, password: password);

  final CrossPlatformSyncRepository _repository;
  final Future<void> Function()? _beforeExport;
  SyncAppliedCallback? _onSyncApplied;
  final SyncSecretRead _readSecret;
  final WebDavClient Function({
    required Uri baseUri,
    String? username,
    String? password,
  })
  _webDavClientFactory;
  final HttpClient Function() _httpClientFactory;
  final DateTime Function() _clock;
  final String _platformName;
  final String _deviceName;

  WebDavSyncSettings _webDavSettings = const WebDavSyncSettings();
  Future<void>? _initialization;
  bool _syncing = false;
  DateTime? _lastAutoSyncAttempt;
  Future<void> _serialTail = Future<void>.value();

  WebDavSyncSettings get webDavSettings => _webDavSettings;
  bool get isSyncing => _syncing;

  void bindOnSyncApplied(SyncAppliedCallback callback) {
    _onSyncApplied = callback;
  }

  Future<void> initialize() => _initialization ??= _loadWebDavSettings();

  Future<void> _loadWebDavSettings() async {
    final raw = await AppPreferences.getString(_webDavSyncConfigPrefKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _webDavSettings = WebDavSyncSettings.fromJson(
            Map<String, Object?>.from(decoded),
          );
        }
      } on Object catch (error, stack) {
        AppLogService.warning(
          'webdav_sync_settings_load_failed',
          error: error,
          stackTrace: stack,
        );
      }
    }
    notifyListeners();
  }

  Future<void> setWebDavSyncEnabled(bool enabled, {String? sourceId}) =>
      _runSerialized(() async {
        await initialize();
        final next = _webDavSettings.copyWith(
          sourceId: sourceId,
          autoSyncEnabled: enabled,
        );
        if (enabled && !next.isConfigured) {
          throw StateError('No WebDAV sync source');
        }
        final saved = await AppPreferences.setString(
          _webDavSyncConfigPrefKey,
          jsonEncode(next.toJson()),
        );
        if (!saved) throw StateError('Could not save WebDAV sync settings');
        _webDavSettings = next;
      });

  Future<Uint8List> exportSyncBytes() => _runSerialized(() => _exportBytesUnlocked());

  Future<CrossPlatformSyncSummary> importSyncBytes(Uint8List bytes) =>
      _runSerialized(() async {
        final bundle = decodeSyncBytes(bytes);
        return _applyBundlesUnlocked(<CrossPlatformSyncBundle>[bundle]);
      });

  Future<CrossPlatformSyncSummary> applySyncBundle(
    CrossPlatformSyncBundle bundle,
  ) => _runSerialized(() => _applyBundlesUnlocked(<CrossPlatformSyncBundle>[bundle]));

  /// Used by Windows `LanMediaServerService` (`POST /api/v1/sync/exchange`) to
  /// merge an Android client's bundle and return Windows's updated bundle in one round-trip.
  Future<Uint8List> exchangeSyncBytes(Uint8List peerBytes) =>
      _runSerialized(() async {
        final peerBundle = decodeSyncBytes(peerBytes);
        await _applyBundlesUnlocked(<CrossPlatformSyncBundle>[peerBundle]);
        return _exportBytesUnlocked();
      });

  Future<CrossPlatformSyncSummary> syncWithLanServer({
    required Uri serverBaseUri,
    String? bearerToken,
  }) => _runSerialized(() async {
    final localBytes = await _exportBytesUnlocked();
    final endpoint = serverBaseUri.replace(
      path: '${serverBaseUri.path.endsWith('/') ? serverBaseUri.path.substring(0, serverBaseUri.path.length - 1) : serverBaseUri.path}/api/v1/sync/exchange',
    );
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client
          .postUrl(endpoint)
          .timeout(const Duration(seconds: 15));
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/octet-stream',
      );
      if (bearerToken != null && bearerToken.trim().isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${bearerToken.trim()}',
        );
      }
      request.contentLength = localBytes.length;
      request.add(localBytes);
      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        await response.listen(null).cancel();
        throw const HttpException('lan_sync_unauthorized');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.listen(null).cancel();
        throw HttpException('lan_sync_failed_${response.statusCode}');
      }
      final builder = BytesBuilder();
      var total = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 25))) {
        total += chunk.length;
        if (total > _maxCompressedSyncBytes) {
          throw const FormatException('sync_file_too_large');
        }
        builder.add(chunk);
      }
      final remoteBundle = decodeSyncBytes(builder.takeBytes());
      return _applyBundlesUnlocked(<CrossPlatformSyncBundle>[remoteBundle]);
    } finally {
      client.close();
    }
  });

  Future<CrossPlatformSyncSummary?> syncWithWebDav({
    WebDavSyncSourceResolver? resolveSource,
  }) => _runSerialized(() async {
    await initialize();
    final settings = _webDavSettings;
    if (!settings.autoSyncEnabled || !settings.isConfigured) return null;
    final source = settings.sourceId.isEmpty
        ? null
        : resolveSource?.call(settings.sourceId);
    // A removed media source must not redirect uploads to a different host.
    if (settings.sourceId.isNotEmpty && source == null) return null;

    final password = source != null
        ? source.password
        : settings.passwordConfigured
        ? await _readSecret(_webDavSyncPasswordSecretKey)
        : null;
    final summary = await _syncWithWebDavUnlocked(
      baseUri: source?.baseUri ?? _parseWebDavUri(settings.url),
      username: source?.username ?? settings.username,
      password: password,
      markerNamespace: settings.sourceId,
      ensureBaseDirectory: source != null,
    );
    _webDavSettings = settings.copyWith(
      lastSyncedAtMs: _clock().millisecondsSinceEpoch,
    );
    await AppPreferences.setString(
      _webDavSyncConfigPrefKey,
      jsonEncode(_webDavSettings.toJson()),
    );
    return summary;
  });

  Future<CrossPlatformSyncSummary> _syncWithWebDavUnlocked({
    required Uri baseUri,
    required String username,
    required String? password,
    required String markerNamespace,
    bool ensureBaseDirectory = false,
  }) async {
    final client = _webDavClientFactory(
      baseUri: baseUri,
      username: username,
      password: password,
    );

    try {
      if (ensureBaseDirectory) {
        await client.ensureDirectory(baseUri);
      }
      final localDeviceId = await _repository.ensureDeviceId(_generateUuidV4);
      final devicesDir = client.resolveRelativePath(
        'devices',
        isDirectory: true,
      );
      await client.ensureDirectory(devicesDir);

      final entries = await client.listDirectory(devicesDir);
      final peerMarkers = await _loadPeerMarkers();
      final peerBundles = <CrossPlatformSyncBundle>[];
      final updatedMarkers = Map<String, String>.of(peerMarkers);
      final prefix = markerNamespace.isEmpty ? '' : '$markerNamespace::';

      for (final entry in entries) {
        if (entry.isDirectory || !entry.name.endsWith('.dasync')) continue;
        final peerFileId = entry.name.substring(
          0,
          entry.name.length - '.dasync'.length,
        );
        if (peerFileId.isEmpty || peerFileId == localDeviceId) continue;

        final markerKey = '$prefix$peerFileId';
        final marker = _entryVersionMarker(entry);
        if (marker != null && peerMarkers[markerKey] == marker) {
          continue;
        }
        final bytes = await client.getBytes(
          entry.uri,
          maxBytes: _maxCompressedSyncBytes,
        );
        peerBundles.add(decodeSyncBytes(bytes));
        if (marker != null) {
          updatedMarkers[markerKey] = marker;
        }
      }

      final summary = peerBundles.isEmpty
          ? const CrossPlatformSyncSummary(
              trackStatesMerged: 0,
              listeningDaysUpdated: 0,
              timeSegmentsMerged: 0,
              interestsChanged: false,
              peersMerged: 0,
            )
          : await _applyBundlesUnlocked(peerBundles);

      final myBytes = await _exportBytesUnlocked();
      final myFileUri = client.resolveRelativePath(
        'devices/$localDeviceId.dasync',
      );
      await client.putBytesAtomic(myFileUri, myBytes);

      await AppPreferences.setString(
        _webDavPeerStatePrefKey,
        jsonEncode(updatedMarkers),
      );
      return summary;
    } finally {
      client.close();
    }
  }

  /// Best-effort background WebDAV sync for startup and app backgrounding.
  Future<void> maybeAutoSyncInBackground({
    Duration minInterval = const Duration(minutes: 2),
    WebDavSyncSourceResolver? resolveSource,
  }) async {
    await initialize();
    if (!_webDavSettings.isConfigured || !_webDavSettings.autoSyncEnabled) {
      return;
    }
    final now = _clock();
    if (_lastAutoSyncAttempt != null &&
        now.difference(_lastAutoSyncAttempt!) < minInterval) {
      return;
    }
    _lastAutoSyncAttempt = now;
    try {
      await syncWithWebDav(resolveSource: resolveSource);
    } on Object catch (error, stackTrace) {
      AppLogService.warning(
        'cross_platform_auto_sync_failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<SyncTrackStateEntry?> findSyncedTrackState({
    required String workKey,
    required String relativePath,
  }) => _repository.findSyncedTrackState(
    workKey: workKey,
    relativePath: relativePath,
  );

  Future<SyncWorkStateEntry?> findSyncedWorkState(String workKey) =>
      _repository.findSyncedWorkState(workKey);

  Future<void> upsertSyncedWorkState(SyncWorkStateEntry entry) async {
    final updatedTargets = await _repository.upsertSyncedWorkState(entry);
    if (_onSyncApplied != null && updatedTargets.isNotEmpty) {
      await _onSyncApplied!(
        const <String>{},
        false,
        updatedDetailTargets: updatedTargets,
      );
    }
  }

  static Uint8List encodeSyncBundle(CrossPlatformSyncBundle bundle) {
    final payloadBytes = utf8.encode(jsonEncode(bundle.toPayloadJson()));
    if (payloadBytes.length > _maxExpandedSyncBytes) {
      throw const FormatException('sync_file_too_large');
    }
    final digest = sha256.convert(payloadBytes).toString();
    final envelope = utf8.encode(
      jsonEncode(<String, Object?>{
        'format': CrossPlatformSyncBundle.formatMagic,
        'sha256': digest,
        'payload': base64.encode(payloadBytes),
      }),
    );
    final compressed = gzip.encode(envelope);
    if (compressed.length > _maxCompressedSyncBytes) {
      throw const FormatException('sync_file_too_large');
    }
    return Uint8List.fromList(compressed);
  }

  static CrossPlatformSyncBundle decodeSyncBytes(Uint8List rawBytes) {
    if (rawBytes.isEmpty) throw const FormatException('invalid_sync_format');
    if (rawBytes.length > _maxCompressedSyncBytes) {
      throw const FormatException('sync_file_too_large');
    }
    List<int> decodedEnvelopeBytes;
    if (rawBytes.length >= 2 && rawBytes[0] == 0x1f && rawBytes[1] == 0x8b) {
      decodedEnvelopeBytes = _decompressGzipLimited(
        rawBytes,
        maxBytes: _maxExpandedSyncBytes,
      );
    } else {
      decodedEnvelopeBytes = rawBytes;
    }
    final dynamic envelopeRaw = jsonDecode(utf8.decode(decodedEnvelopeBytes));
    if (envelopeRaw is! Map) {
      throw const FormatException('invalid_sync_format');
    }
    final envelope = Map<String, Object?>.from(envelopeRaw);
    if (envelope.containsKey('payload') && envelope['payload'] is String) {
      final payloadBytes = base64.decode(envelope['payload']! as String);
      if (payloadBytes.length > _maxExpandedSyncBytes) {
        throw const FormatException('sync_file_too_large');
      }
      final expectedSha = envelope['sha256']?.toString() ?? '';
      final actualSha = sha256.convert(payloadBytes).toString();
      if (expectedSha.isEmpty || expectedSha != actualSha) {
        throw const FormatException('sync_checksum_mismatch');
      }
      final payloadJson = jsonDecode(utf8.decode(payloadBytes));
      if (payloadJson is! Map) {
        throw const FormatException('invalid_sync_payload');
      }
      return CrossPlatformSyncBundle.fromPayloadJson(
        Map<String, Object?>.from(payloadJson),
      );
    }
    return CrossPlatformSyncBundle.fromPayloadJson(envelope);
  }

  Future<T> _runSerialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serialTail = _serialTail.then((_) async {
      _syncing = true;
      notifyListeners();
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _syncing = false;
        notifyListeners();
      }
    });
    return completer.future;
  }

  static Map<String, Map<String, Object?>> buildPortableInterestsJson({
    required String deviceId,
    required Map<String, String?> interestSettings,
  }) {
    final interestsJson = <String, Map<String, Object?>>{};
    for (final entry in AsmrPreferencesStore.interestCatalogKeys.entries) {
      final prefRaw = interestSettings[entry.key];
      if (prefRaw == null || prefRaw.isEmpty) continue;
      final catRaw = interestSettings[entry.value];
      final prefs = AsmrTagPreferences.fromJson(
        jsonDecode(prefRaw) as Map<String, dynamic>,
        catalog: catRaw == null
            ? null
            : jsonDecode(catRaw) as Map<String, dynamic>,
        storedCatalogKey: entry.value,
      );
      prefs.snapshotDeviceLearned(deviceId);
      interestsJson[entry.key] = prefs.toJson();
    }
    return interestsJson;
  }

  Future<Uint8List> _exportBytesUnlocked() async {
    await _beforeExport?.call();
    final interestSettingKeys = <String>[
      for (final entry in AsmrPreferencesStore.interestCatalogKeys.entries) ...[
        entry.key,
        entry.value,
      ],
    ];
    final snapshot = await _repository.exportSnapshot(
      generateDeviceId: _generateUuidV4,
      interestSettingKeys: interestSettingKeys,
    );
    final interestsJson = buildPortableInterestsJson(
      deviceId: snapshot.deviceId,
      interestSettings: snapshot.interestSettings,
    );

    final bundle = CrossPlatformSyncBundle(
      formatVersion: CrossPlatformSyncBundle.currentFormatVersion,
      deviceId: snapshot.deviceId,
      deviceName: _deviceName,
      platform: _platformName,
      exportedAt: _clock(),
      tracks: snapshot.tracks,
      deviceDayLedger: snapshot.deviceDayLedger,
      deviceWorkDayLedger: snapshot.deviceWorkDayLedger,
      history: snapshot.history,
      timeSegments: snapshot.timeSegments,
      deletedTimeSegments: snapshot.deletedTimeSegments,
      interests: interestsJson,
      workStates: snapshot.workStates,
    );
    return encodeSyncBundle(bundle);
  }

  Future<CrossPlatformSyncSummary> _applyBundlesUnlocked(
    List<CrossPlatformSyncBundle> bundles,
  ) async {
    if (bundles.isEmpty) {
      return const CrossPlatformSyncSummary(
        trackStatesMerged: 0,
        listeningDaysUpdated: 0,
        timeSegmentsMerged: 0,
        interestsChanged: false,
        peersMerged: 0,
      );
    }
    final interestSettingKeys = <String>[
      for (final entry in AsmrPreferencesStore.interestCatalogKeys.entries) ...[
        entry.key,
        entry.value,
      ],
    ];
    final current = await _repository.exportSnapshot(
      generateDeviceId: _generateUuidV4,
      interestSettingKeys: interestSettingKeys,
    );
    final localDeviceId = current.deviceId;

    var anyInterestsChanged = false;
    final mergedSettingsToWrite = <String, String?>{};

    for (final catEntry in AsmrPreferencesStore.interestCatalogKeys.entries) {
      final prefKey = catEntry.key;
      final catalogKey = catEntry.value;
      final localRaw = current.interestSettings[prefKey];
      final localCatRaw = current.interestSettings[catalogKey];
      final localPrefs = localRaw == null || localRaw.isEmpty
          ? AsmrTagPreferences()
          : AsmrTagPreferences.fromJson(
              jsonDecode(localRaw) as Map<String, dynamic>,
              catalog: localCatRaw == null
                  ? null
                  : jsonDecode(localCatRaw) as Map<String, dynamic>,
              storedCatalogKey: catalogKey,
            );

      var categoryChanged = false;
      for (final bundle in bundles) {
        final peerInterestJson = bundle.interests[prefKey];
        if (peerInterestJson == null) continue;
        final peerPrefs = AsmrTagPreferences.fromJson(
          Map<String, dynamic>.from(peerInterestJson),
        );
        final peerDeviceLearned = peerPrefs.snapshotDeviceLearned(
          bundle.deviceId,
        );
        final didChange = localPrefs.mergeCrossPlatformSync(
          localDeviceId: localDeviceId,
          incomingTags: peerPrefs.tags.values,
          peerManualInterests: peerPrefs.manualInterests,
          peerExcluded: peerPrefs.excluded,
          peerSelectionUpdatedAt: peerPrefs.selectionUpdatedAt,
          peerUpdatedAtMs: peerPrefs.updatedAtMs,
          peerDeviceLearned: peerDeviceLearned,
        );
        if (didChange) categoryChanged = true;
      }
      if (categoryChanged) {
        anyInterestsChanged = true;
        mergedSettingsToWrite[prefKey] = jsonEncode(
          localPrefs.toPreferenceJson(),
        );
        mergedSettingsToWrite[catalogKey] = jsonEncode(
          localPrefs.toCatalogJson(),
        );
      }
    }

    // Consolidate multiple peer bundles into unified incoming collections.
    final tracksByKey = <String, SyncTrackStateEntry>{};
    final dayLedgers = <String, Map<String, int>>{};
    final workDayLedgers = <String, Map<String, Map<String, int>>>{};
    final historyByWork = <String, SyncHistoryWorkEntry>{};
    final segmentsById = <String, SyncTimeSegmentEntry>{};
    final deletedSegments = <String, int>{};
    final workStatesByKey = <String, SyncWorkStateEntry>{};

    for (final bundle in bundles) {
      for (final w in bundle.workStates) {
        final prev = workStatesByKey[w.workKey];
        if (prev == null) {
          workStatesByKey[w.workKey] = w;
        } else {
          final takeDetail = w.detailUpdatedAtMs > prev.detailUpdatedAtMs;
          final takeReview = w.reviewUpdatedAtMs > prev.reviewUpdatedAtMs;
          if (takeDetail || takeReview) {
            workStatesByKey[w.workKey] = SyncWorkStateEntry(
              workKey: w.workKey,
              rjCode: w.rjCode.isNotEmpty ? w.rjCode : prev.rjCode,
              workTitle: takeDetail ? w.workTitle : prev.workTitle,
              circleName: takeDetail ? w.circleName : prev.circleName,
              voiceActors: takeDetail ? w.voiceActors : prev.voiceActors,
              tags: takeDetail ? w.tags : prev.tags,
              releaseDateMs: takeDetail ? w.releaseDateMs : prev.releaseDateMs,
              salesCount: takeDetail ? w.salesCount : prev.salesCount,
              rating: takeDetail ? w.rating : prev.rating,
              detailUpdatedAtMs: takeDetail
                  ? w.detailUpdatedAtMs
                  : prev.detailUpdatedAtMs,
              listenStatus: takeReview ? w.listenStatus : prev.listenStatus,
              userRating: takeReview ? w.userRating : prev.userRating,
              reviewText: takeReview ? w.reviewText : prev.reviewText,
              reviewUpdatedAtMs: takeReview
                  ? w.reviewUpdatedAtMs
                  : prev.reviewUpdatedAtMs,
            );
          }
        }
      }
      for (final t in bundle.tracks) {
        final key = '${t.workKey}::${t.relativePath.toLowerCase()}';
        final prev = tracksByKey[key];
        if (prev == null ||
            (t.lastPlayedAtMs ?? 0) >= (prev.lastPlayedAtMs ?? 0) ||
            t.updatedAtMs > prev.updatedAtMs) {
          tracksByKey[key] = t;
        }
      }
      for (final dev in bundle.deviceDayLedger.entries) {
        final map = dayLedgers.putIfAbsent(dev.key, () => <String, int>{});
        for (final d in dev.value.entries) {
          if (d.value > (map[d.key] ?? 0)) map[d.key] = d.value;
        }
      }
      for (final dev in bundle.deviceWorkDayLedger.entries) {
        final dates = workDayLedgers.putIfAbsent(
          dev.key,
          () => <String, Map<String, int>>{},
        );
        for (final d in dev.value.entries) {
          final works = dates.putIfAbsent(d.key, () => <String, int>{});
          for (final w in d.value.entries) {
            if (w.value > (works[w.key] ?? 0)) works[w.key] = w.value;
          }
        }
      }
      for (final h in bundle.history) {
        final prev = historyByWork[h.workKey];
        if (prev == null || h.lastPlayedAtMs >= prev.lastPlayedAtMs) {
          historyByWork[h.workKey] = h;
        }
      }
      for (final s in bundle.timeSegments) {
        final prev = segmentsById[s.id];
        if (prev == null || s.updatedAtMs > prev.updatedAtMs) {
          segmentsById[s.id] = s;
        }
      }
      for (final del in bundle.deletedTimeSegments.entries) {
        if (del.value > (deletedSegments[del.key] ?? -1)) {
          deletedSegments[del.key] = del.value;
        }
      }
    }

    final dbResult = await _repository.applyMergedSnapshot(
      generateDeviceId: _generateUuidV4,
      incomingTracks: tracksByKey.values.toList(growable: false),
      incomingDeviceDayLedger: dayLedgers,
      incomingDeviceWorkDayLedger: workDayLedgers,
      incomingHistory: historyByWork.values.toList(growable: false),
      incomingTimeSegments: segmentsById.values.toList(growable: false),
      incomingDeletedTimeSegments: deletedSegments,
      mergedInterestSettings: mergedSettingsToWrite,
      incomingWorkStates: workStatesByKey.values.toList(growable: false),
    );

    if (_onSyncApplied != null &&
        (dbResult.updatedTrackPaths.isNotEmpty ||
            dbResult.updatedDetailTargets.isNotEmpty ||
            dbResult.listeningDaysUpdated > 0 ||
            dbResult.timeSegmentsMerged > 0 ||
            anyInterestsChanged ||
            historyByWork.isNotEmpty)) {
      await _onSyncApplied!(
        dbResult.updatedTrackPaths,
        anyInterestsChanged,
        updatedDetailTargets: dbResult.updatedDetailTargets,
      );
    }

    return CrossPlatformSyncSummary(
      trackStatesMerged: dbResult.trackStatesMerged,
      listeningDaysUpdated: dbResult.listeningDaysUpdated,
      timeSegmentsMerged: dbResult.timeSegmentsMerged,
      interestsChanged: anyInterestsChanged,
      peersMerged: bundles.length,
      workStatesMerged: dbResult.workStatesMerged,
    );
  }

  static Uri _parseWebDavUri(String rawUrl) {
    final trimmed = rawUrl.trim();
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null ||
        !const {'http', 'https'}.contains(parsed.scheme.toLowerCase()) ||
        parsed.host.isEmpty) {
      throw const FormatException('invalid_webdav_url');
    }
    return WebDavClient.normalizeDirectoryUri(parsed);
  }

  static Future<Map<String, String>> _loadPeerMarkers() async {
    final raw = await AppPreferences.getString(_webDavPeerStatePrefKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } on Object {
      // Ignore corrupt marker cache; next sync will re-fetch peer shards.
    }
    return <String, String>{};
  }

  static String? _entryVersionMarker(WebDavEntry entry) {
    if (entry.etag != null && entry.etag!.isNotEmpty) return 'e:${entry.etag}';
    if (entry.lastModified != null) {
      return 'm:${entry.lastModified!.millisecondsSinceEpoch}:${entry.contentLength ?? -1}';
    }
    return null;
  }

  static List<int> _decompressGzipLimited(Uint8List bytes, {required int maxBytes}) {
    final builder = BytesBuilder(copy: false);
    var total = 0;
    final sink = ByteConversionSink.withCallback((chunks) {
      builder.add(chunks);
    });
    final decoder = gzip.decoder.startChunkedConversion(
      _CountingByteSink(sink, (added) {
        total += added;
        if (total > maxBytes) {
          throw const FormatException('sync_file_too_large');
        }
      }),
    );
    decoder.add(bytes);
    decoder.close();
    return builder.takeBytes();
  }

  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  static String _safeLocalHostname() {
    try {
      return Platform.localHostname;
    } on Object {
      return Platform.operatingSystem;
    }
  }
}

class _CountingByteSink extends ByteConversionSinkBase {
  _CountingByteSink(this._inner, this._onCount);

  final ByteConversionSink _inner;
  final void Function(int) _onCount;

  @override
  void add(List<int> chunk) {
    _onCount(chunk.length);
    _inner.add(chunk);
  }

  @override
  void close() => _inner.close();
}
