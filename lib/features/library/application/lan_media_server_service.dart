import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/natural_sort.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/persistence/app_preferences.dart';
import '../../data_support/application/cross_platform_sync_service.dart';
import '../domain/remote_media_source.dart';
import 'lan_discovery_service.dart';
import 'library_facade.dart';

const String _lanServerSettingsPrefKey = 'windows_lan_server_settings_v1';
const String _lanServerIdPrefKey = 'windows_lan_server_id_v1';
const String _lanServerAccessCodeSecretKey = 'windows_lan_server_access_code_v1';

const Set<String> _subtitleExtensions = <String>{
  '.lrc',
  '.vtt',
  '.srt',
  '.ass',
  '.ssa',
};

const Set<String> _imageExtensions = <String>{
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
  '.avif',
  '.heic',
  '.heif',
};

const Set<String> _textExtensions = <String>{
  '.txt',
  '.md',
  '.markdown',
  '.pdf',
};

class LanMediaServerService extends ChangeNotifier {
  LanMediaServerService({
    required LibraryFacade library,
    required CrossPlatformSyncService syncService,
    Set<String> Function()? readPinnedPaths,
    Future<void> Function(List<String> paths)? togglePinnedPaths,
    SyncSecretRead? readSecret,
    SyncSecretWrite? writeSecret,
    InternetAddress? bindAddress,
    bool enableDiscovery = true,
    bool allowNonWindowsForTest = false,
    String? serverName,
  }) : _library = library,
       _syncService = syncService,
       _readPinnedPaths = readPinnedPaths,
       _togglePinnedPaths = togglePinnedPaths,
       _readSecret = readSecret ?? _defaultSecretRead,
       _writeSecret = writeSecret ?? _defaultSecretWrite,
       _bindAddress = bindAddress ?? InternetAddress.anyIPv4,
       _enableDiscovery = enableDiscovery,
       _allowNonWindowsForTest = allowNonWindowsForTest,
       _serverName = serverName ?? _safeHostname();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static Future<String?> _defaultSecretRead(String key) =>
      _secureStorage.read(key: key);
  static Future<void> _defaultSecretWrite(String key, String? value) =>
      value == null || value.isEmpty
      ? _secureStorage.delete(key: key)
      : _secureStorage.write(key: key, value: value);

  final LibraryFacade _library;
  final CrossPlatformSyncService _syncService;
  final Set<String> Function()? _readPinnedPaths;
  final Future<void> Function(List<String> paths)? _togglePinnedPaths;
  final SyncSecretRead _readSecret;
  final SyncSecretWrite _writeSecret;
  final InternetAddress _bindAddress;
  final bool _enableDiscovery;
  final bool _allowNonWindowsForTest;
  final String _serverName;

  LanServerSettings _settings = const LanServerSettings();
  String _serverId = '';
  String _accessCode = '';
  List<String> _localAddresses = const <String>[];
  HttpServer? _httpServer;
  LanDiscoveryResponder? _discoveryResponder;
  bool _initialized = false;
  bool _disposed = false;
  String? _lastStartError;

  final Map<String, String> _groupKeyByWorkId = <String, String>{};
  final Map<String, String> _filePathByFileId = <String, String>{};
  final Map<String, Duration> _trackDurationByPath = <String, Duration>{};
  final Set<String> _fallbackPinnedNormalizedPaths = <String>{};

  LanServerSettings get settings => _settings;
  String get accessCode => _accessCode;
  String get serverName => _serverName;
  String get serverId => _serverId;
  bool get isRunning => _httpServer != null;
  int? get boundPort => _httpServer?.port;
  List<String> get localAddresses => _localAddresses;
  String? get lastStartError => _lastStartError;

  bool get isSupportedPlatform =>
      _allowNonWindowsForTest || (!kIsWeb && Platform.isWindows);

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    if (!isSupportedPlatform) {
      _initialized = true;
      return;
    }
    _serverId = (await AppPreferences.getString(_lanServerIdPrefKey)) ?? '';
    if (_serverId.isEmpty) {
      _serverId = _generateRandomHex(16);
      await AppPreferences.setString(_lanServerIdPrefKey, _serverId);
    }
    final rawSettings = await AppPreferences.getString(_lanServerSettingsPrefKey);
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSettings);
        if (decoded is Map) {
          _settings = LanServerSettings.fromJson(
            Map<String, Object?>.from(decoded),
          );
        }
      } on Object catch (error, stack) {
        AppLogService.warning(
          'lan_server_settings_decode_failed',
          error: error,
          stackTrace: stack,
        );
      }
    }
    _accessCode = (await _readSecret(_lanServerAccessCodeSecretKey)) ?? '';
    if (_accessCode.isEmpty) {
      _accessCode = _generateSixDigitPin();
      await _writeSecret(_lanServerAccessCodeSecretKey, _accessCode);
    }
    _localAddresses = await LanDiscoveryClient.listLocalLanIpv4Addresses();
    _initialized = true;
    if (_settings.enabled) {
      await _startServer();
    }
    notifyListeners();
  }

  Future<void> refreshLocalAddresses() async {
    if (!isSupportedPlatform || _disposed) return;
    _localAddresses = await LanDiscoveryClient.listLocalLanIpv4Addresses();
    notifyListeners();
  }

  Future<String> regenerateAccessCode() async {
    await initialize();
    final nextCode = _generateSixDigitPin();
    await _writeSecret(_lanServerAccessCodeSecretKey, nextCode);
    _accessCode = nextCode;
    notifyListeners();
    return nextCode;
  }

  Future<void> updateSettings(LanServerSettings next) async {
    if (!isSupportedPlatform || _disposed) return;
    await initialize();
    if (next.port < 1024 && next.port != 0 || next.port > 65535) {
      throw const FormatException('invalid_lan_port');
    }
    final portChanged = next.port != _settings.port;
    final enabledChanged = next.enabled != _settings.enabled;
    _settings = next;

    await AppPreferences.setString(
      _lanServerSettingsPrefKey,
      jsonEncode(_settings.toJson()),
    );

    if (!_settings.enabled) {
      await _stopServer(force: false);
    } else if (enabledChanged || portChanged || _httpServer == null) {
      await _stopServer(force: false);
      await _startServer();
    }
    notifyListeners();
  }

  Future<void> stopForShutdown({bool fastShutdown = false}) async {
    _disposed = true;
    await _stopServer(force: fastShutdown);
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_stopServer(force: true));
    super.dispose();
  }

  Future<void> _startServer() async {
    if (_disposed || _httpServer != null) return;
    _lastStartError = null;
    try {
      _localAddresses = await LanDiscoveryClient.listLocalLanIpv4Addresses();
      final server = await HttpServer.bind(
        _bindAddress,
        _settings.port,
      );
      server.idleTimeout = const Duration(seconds: 30);
      _httpServer = server;
      server.listen(
        (request) {
          unawaited(_handleRequest(request));
        },
        onError: (Object error, StackTrace stack) {
          AppLogService.warning(
            'lan_media_server_stream_error',
            error: error,
            stackTrace: stack,
          );
        },
      );
      if (_enableDiscovery) {
        final responder = LanDiscoveryResponder(
          serverInfoBuilder: () => <String, Object?>{
            'serverId': _serverId,
            'name': _serverName,
            'port': server.port,
            'authRequired': _settings.requireAccessCode,
            'allowSync': _settings.allowSync,
            'allowEdit': _settings.allowRemoteEdit,
          },
        );
        try {
          await responder.start();
          _discoveryResponder = responder;
        } on Object catch (error, stack) {
          AppLogService.warning(
            'lan_discovery_responder_bind_failed',
            error: error,
            stackTrace: stack,
          );
        }
      }
    } on Object catch (error, stack) {
      _lastStartError = error.toString();
      AppLogService.error(
        'lan_media_server_start_failed',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    }
  }

  Future<void> _stopServer({required bool force}) async {
    _discoveryResponder?.stop();
    _discoveryResponder = null;
    final server = _httpServer;
    _httpServer = null;
    if (server != null) {
      try {
        await server.close(force: force);
      } on Object {
        // Ignore socket teardown races during shutdown.
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      final segments = request.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (segments.length >= 3 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'info' &&
          request.method == 'GET') {
        _writeJson(response, HttpStatus.ok, <String, Object?>{
          'serverId': _serverId,
          'name': _serverName,
          'port': _httpServer?.port ?? _settings.port,
          'authRequired': _settings.requireAccessCode,
          'allowSync': _settings.allowSync,
          'allowEdit': _settings.allowRemoteEdit,
          'protocolVersion': 1,
        });
        return;
      }

      if (_settings.requireAccessCode && !_isAuthorized(request)) {
        response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Bearer realm="DoujinAudioLAN"',
        );
        _writeJson(response, HttpStatus.unauthorized, const <String, Object?>{
          'error': 'unauthorized',
        });
        return;
      }

      if (segments.length == 3 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works') {
        if (request.method == 'HEAD') {
          response.statusCode = HttpStatus.noContent;
          await response.close();
          return;
        }
        if (request.method == 'GET') {
          await _handleListWorks(request);
          return;
        }
      }

      if (segments.length == 5 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works' &&
          segments[4] == 'tree' &&
          request.method == 'GET') {
        await _handleWorkTree(request, segments[3]);
        return;
      }

      if (segments.length == 5 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works' &&
          segments[4] == 'detail' &&
          request.method == 'PUT') {
        await _handleUpdateWorkDetail(request, segments[3]);
        return;
      }

      if (segments.length == 5 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works' &&
          segments[4] == 'review' &&
          request.method == 'PUT') {
        await _handleUpdateWorkReview(request, segments[3]);
        return;
      }

      if (segments.length == 5 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works' &&
          segments[4] == 'entry-rename' &&
          request.method == 'POST') {
        await _handleRenameWorkEntry(request, segments[3]);
        return;
      }

      if (segments.length == 5 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works' &&
          segments[4] == 'cover' &&
          request.method == 'POST') {
        await _handleSetWorkCover(request, segments[3]);
        return;
      }

      if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works' &&
          segments[3] == 'pin' &&
          request.method == 'POST') {
        await _handleTogglePinWorks(request);
        return;
      }

      if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'works' &&
          segments[3] == 'remove' &&
          request.method == 'POST') {
        await _handleRemoveWorks(request);
        return;
      }

      if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'covers' &&
          (request.method == 'GET' || request.method == 'HEAD')) {
        await _handleCover(request, segments[3]);
        return;
      }

      if ((segments.length == 4 || segments.length == 5) &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'stream' &&
          (request.method == 'GET' || request.method == 'HEAD')) {
        await _handleStreamFile(request, segments[3]);
        return;
      }

      if (segments.length == 4 &&
          segments[0] == 'api' &&
          segments[1] == 'v1' &&
          segments[2] == 'sync' &&
          segments[3] == 'exchange' &&
          request.method == 'POST') {
        await _handleSyncExchange(request);
        return;
      }

      _writeJson(response, HttpStatus.notFound, const <String, Object?>{
        'error': 'not_found',
      });
    } on Object catch (error, stack) {
      AppLogService.warning(
        'lan_media_server_request_failed',
        error: error,
        stackTrace: stack,
      );
      try {
        _writeJson(
          response,
          HttpStatus.internalServerError,
          const <String, Object?>{'error': 'internal_error'},
        );
      } on Object {
        // Response headers may have already been flushed mid-stream.
        try {
          await response.close();
        } on Object {
          // Ignore secondary socket close failure after client disconnect.
        }
      }
    }
  }

  Set<String> _currentPinnedNormalizedPaths() {
    final external = _readPinnedPaths?.call();
    if (external != null) {
      return external.map(PathMatcher.normalize).toSet();
    }
    return _fallbackPinnedNormalizedPaths;
  }

  Future<Map<String, Object?>?> _serializeWork(
    String groupKey, {
    Set<String>? pinnedPaths,
  }) async {
    final tracks = _library.tracksInGroup(groupKey);
    if (tracks.isEmpty) return null;
    final firstTrack = tracks.first;
    if (firstTrack.isRemoteMedia) return null;

    final target = firstTrack.isSingle
        ? AudioDetailTarget.singleAudioFile(firstTrack.path)
        : AudioDetailTarget.libraryRootFolder(groupKey);
    var detail = _library.resolvedAudioDetail(target);
    if (detail == null) {
      try {
        detail = (await _library.loadAudioDetail(target)).detail;
      } on Object {
        detail = null;
      }
    }

    final rjCode =
        AudioDetail.findRjCodeInText(detail?.rjCode ?? '') ??
        AudioDetail.findRjCodeInText(firstTrack.groupSubtitle) ??
        AudioDetail.findRjCodeInText(firstTrack.groupTitle) ??
        AudioDetail.findRjCodeInText(groupKey) ??
        '';
    final title = (detail?.workTitle.trim().isNotEmpty == true)
        ? detail!.workTitle.trim()
        : (firstTrack.groupTitle.trim().isNotEmpty
              ? firstTrack.groupTitle.trim()
              : path.basename(groupKey));
    final circle = detail?.circleName.trim() ?? '';
    final totalDurationMs =
        detail?.duration != null && detail!.duration! > Duration.zero
        ? detail.duration!.inMilliseconds
        : tracks.fold<int>(0, (sum, t) => sum + t.duration.inMilliseconds);

    final workId = _registerWorkGroup(groupKey);
    for (final t in tracks) {
      if (t.duration > Duration.zero) {
        _trackDurationByPath[PathMatcher.normalize(t.path)] = t.duration;
      }
    }

    final hasCover =
        !firstTrack.isSingle ||
        (detail?.cardCoverPath?.trim().isNotEmpty == true) ||
        (firstTrack.manualCoverPath?.trim().isNotEmpty == true) ||
        (firstTrack.coverCachePath?.trim().isNotEmpty == true) ||
        _tryResolvedCoverForTrack(firstTrack) != null;

    final pinnedSet = pinnedPaths ?? _currentPinnedNormalizedPaths();
    final checkPath = firstTrack.isSingle ? firstTrack.path : groupKey;
    final isPinned = pinnedSet.contains(PathMatcher.normalize(checkPath));
    final reviewText = detail?.reviewText ?? '';

    return <String, Object?>{
      'workId': workId,
      'rjCode': rjCode,
      'title': title,
      'folderName': path.basename(checkPath),
      'circleName': circle,
      'voiceActors': detail?.voiceActors ?? const <String>[],
      'tags': detail?.tags.isNotEmpty == true ? detail!.tags : firstTrack.tags,
      if (detail?.releaseDate != null)
        'releaseDateMs': detail!.releaseDate!.millisecondsSinceEpoch,
      'durationMs': totalDurationMs,
      'trackCount': tracks.length,
      if (detail?.salesCount != null) 'salesCount': detail!.salesCount,
      if (detail?.rating != null) 'rating': detail!.rating,
      if (detail?.listenStatus != null)
        'listenStatus': detail!.listenStatus!.wireValue,
      if (detail?.userRating != null) 'userRating': detail!.userRating,
      if (reviewText.trim().isNotEmpty) ...<String, Object?>{
        'reviewText': reviewText,
        'hasReviewNote': true,
      },
      'reviewUpdatedAtMs': detail?.reviewUpdatedAt?.millisecondsSinceEpoch ?? 0,
      'detailUpdatedAtMs': detail?.updatedAt?.millisecondsSinceEpoch ?? 0,
      if (isPinned) 'isPinned': true,
      'hasSubtitle': tracks.any(
        (t) => t.lyricsPath != null && t.lyricsPath!.trim().isNotEmpty,
      ),
      if (hasCover) 'coverPath': '/api/v1/covers/$workId',
      'updatedAtMs': detail?.updatedAt?.millisecondsSinceEpoch ?? 0,
    };
  }

  Future<void> _handleListWorks(HttpRequest request) async {
    final works = <Map<String, Object?>>[];
    final groupKeys = _library.activeGroupKeys;
    final pinnedPaths = _currentPinnedNormalizedPaths();

    for (final groupKey in groupKeys) {
      final serialized = await _serializeWork(
        groupKey,
        pinnedPaths: pinnedPaths,
      );
      if (serialized != null) {
        works.add(serialized);
      }
    }

    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'works': works,
    });
  }

  bool _ensureEditEnabled(HttpResponse response) {
    if (_settings.allowRemoteEdit) return true;
    _writeJson(response, HttpStatus.forbidden, const <String, Object?>{
      'error': 'edit_disabled',
    });
    return false;
  }

  Future<Map<String, Object?>?> _readJsonBody(
    HttpRequest request, {
    int maxBytes = 8 * 1024 * 1024,
  }) async {
    if (request.contentLength > maxBytes) {
      _writeJson(
        request.response,
        HttpStatus.requestEntityTooLarge,
        const <String, Object?>{'error': 'payload_too_large'},
      );
      return null;
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request.timeout(const Duration(seconds: 20))) {
      total += chunk.length;
      if (total > maxBytes) {
        _writeJson(
          request.response,
          HttpStatus.requestEntityTooLarge,
          const <String, Object?>{'error': 'payload_too_large'},
        );
        return null;
      }
      builder.add(chunk);
    }
    final rawText = utf8.decode(builder.takeBytes());
    if (rawText.trim().isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(rawText);
    if (decoded is! Map) {
      _writeJson(request.response, HttpStatus.badRequest, const <String, Object?>{
        'error': 'invalid_json',
      });
      return null;
    }
    return Map<String, Object?>.from(decoded);
  }

  Future<String?> _resolveActiveGroupKey(String workId) async {
    var groupKey = _groupKeyByWorkId[workId];
    if (groupKey == null) {
      await _populateWorkIndex();
      groupKey = _groupKeyByWorkId[workId];
    }
    return groupKey;
  }

  Future<void> _handleUpdateWorkDetail(
    HttpRequest request,
    String workId,
  ) async {
    if (!_ensureEditEnabled(request.response)) return;
    final body = await _readJsonBody(request, maxBytes: 32 * 1024 * 1024);
    if (body == null) return;

    var groupKey = await _resolveActiveGroupKey(workId);
    if (groupKey == null) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_not_found',
      });
      return;
    }
    final initialTracks = _library.tracksInGroup(groupKey);
    if (initialTracks.isEmpty) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_empty',
      });
      return;
    }
    final first = initialTracks.first;
    final target = first.isSingle
        ? AudioDetailTarget.singleAudioFile(first.path)
        : AudioDetailTarget.libraryRootFolder(groupKey);
    var detail = (await _library.loadAudioDetail(target)).detail;

    final newFolderName = body['newFolderName']?.toString().trim() ?? '';
    final currentName = path.basename(detail.target.targetPath);
    if (newFolderName.isNotEmpty && newFolderName != currentName) {
      try {
        final renameResult = await _library.renameAudioDetailTargetToName(
          detail,
          newFolderName,
        );
        detail = renameResult.detail;
        _groupKeyByWorkId.remove(workId);
        groupKey = detail.target.isLibraryRootFolder
            ? detail.target.targetPath
            : (_library
                      .trackByPath(detail.target.targetPath)
                      ?.groupKey ??
                  detail.target.targetPath);
        _registerWorkGroup(groupKey);
      } on AudioDetailRenameException catch (error) {
        _writeJson(request.response, HttpStatus.conflict, <String, Object?>{
          'error': error.reason,
        });
        return;
      } on FileSystemException {
        _writeJson(request.response, HttpStatus.conflict, const <String, Object?>{
          'error': 'renameFailed',
        });
        return;
      }
    }

    final coverBase64 = body['coverBytesBase64']?.toString() ?? '';
    if (coverBase64.isNotEmpty && detail.target.isLibraryRootFolder) {
      try {
        final coverBytes = base64Decode(coverBase64);
        final rawExt = body['coverExtension']?.toString() ?? 'jpg';
        final safeExt = rawExt.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
        final coverFile = File(
          path.join(
            detail.target.targetPath,
            'cover.${safeExt.isEmpty ? 'jpg' : safeExt.toLowerCase()}',
          ),
        );
        if (_library.isActiveAllowedFileSystemPath(coverFile.path)) {
          await coverFile.writeAsBytes(coverBytes, flush: true);
          final savedCover = await _library.setFolderManualCover(
            detail.target.targetPath,
            coverFile.path,
            newlySaved: true,
          );
          if (savedCover != null) {
            detail = detail.copyWith(
              cardCoverPath: savedCover,
              cardCoverSelected: true,
            );
          }
        }
      } on Object catch (error, stack) {
        AppLogService.warning(
          'lan_server_save_cover_failed',
          error: error,
          stackTrace: stack,
        );
      }
    }

    final rjCode = body['rjCode']?.toString().trim() ?? detail.rjCode;
    final workTitle = body['title']?.toString().trim() ?? detail.workTitle;
    final circleName =
        body['circleName']?.toString().trim() ?? detail.circleName;
    final voiceActors = body.containsKey('voiceActors')
        ? (body['voiceActors'] as List? ?? const [])
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : detail.voiceActors;
    final tags = body.containsKey('tags')
        ? (body['tags'] as List? ?? const [])
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : detail.tags;
    final releaseDate = body.containsKey('releaseDateMs')
        ? (body['releaseDateMs'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (body['releaseDateMs'] as num).toInt(),
                ))
        : detail.releaseDate;
    final duration = body.containsKey('durationMs')
        ? (body['durationMs'] == null || (body['durationMs'] as num) <= 0
              ? null
              : Duration(milliseconds: (body['durationMs'] as num).toInt()))
        : detail.duration;
    final salesCount = body.containsKey('salesCount')
        ? (body['salesCount'] as num?)?.toInt()
        : detail.salesCount;
    final rating = body.containsKey('rating')
        ? (body['rating'] as num?)?.toDouble()
        : detail.rating;
    final preserveDuration = body['preserveDuration'] == true;

    await _library.saveAudioDetail(
      detail.copyWith(
        rjCode: rjCode,
        workTitle: workTitle,
        circleName: circleName,
        voiceActors: voiceActors,
        tags: tags,
        releaseDate: releaseDate,
        duration: duration,
        salesCount: salesCount,
        rating: rating,
      ),
      preserveExistingDuration: preserveDuration,
    );

    final serialized = await _serializeWork(groupKey);
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'work': serialized,
    });
  }

  Future<void> _handleUpdateWorkReview(
    HttpRequest request,
    String workId,
  ) async {
    if (!_ensureEditEnabled(request.response)) return;
    final body = await _readJsonBody(request);
    if (body == null) return;

    final groupKey = await _resolveActiveGroupKey(workId);
    if (groupKey == null) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_not_found',
      });
      return;
    }
    final tracks = _library.tracksInGroup(groupKey);
    if (tracks.isEmpty) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_empty',
      });
      return;
    }
    final first = tracks.first;
    final target = first.isSingle
        ? AudioDetailTarget.singleAudioFile(first.path)
        : AudioDetailTarget.libraryRootFolder(groupKey);

    final listenStatus = WorkListenStatus.tryFromWireValue(
      body['listenStatus']?.toString(),
    );
    final userRating = (body['userRating'] as num?)?.toInt();
    final reviewText = body['reviewText']?.toString() ?? '';

    await _library.saveAudioUserReview(
      target,
      listenStatus: listenStatus,
      userRating: userRating,
      reviewText: reviewText,
    );

    final serialized = await _serializeWork(groupKey);
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'work': serialized,
    });
  }

  Future<void> _handleRenameWorkEntry(
    HttpRequest request,
    String workId,
  ) async {
    if (!_ensureEditEnabled(request.response)) return;
    final body = await _readJsonBody(request);
    if (body == null) return;

    final groupKey = await _resolveActiveGroupKey(workId);
    if (groupKey == null) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_not_found',
      });
      return;
    }
    final relRaw = body['relativePath']?.toString().trim() ?? '';
    final newName = body['newName']?.toString().trim() ?? '';
    final isDirectory = body['isDirectory'] == true;
    final isMedia = body['isMedia'] == true;
    if (relRaw.isEmpty || newName.isEmpty) {
      _writeJson(request.response, HttpStatus.badRequest, const <String, Object?>{
        'error': 'invalid_argument',
      });
      return;
    }

    final relSegments = relRaw
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (relSegments.isEmpty ||
        relSegments.any((s) => s == '.' || s == '..')) {
      _writeJson(request.response, HttpStatus.badRequest, const <String, Object?>{
        'error': 'invalid_argument',
      });
      return;
    }
    final entryPath = PathMatcher.normalize(
      path.joinAll(<String>[groupKey, ...relSegments]),
    );
    if (!PathMatcher.isWithinOrEqual(entryPath, groupKey) ||
        PathMatcher.equalsNormalized(entryPath, groupKey) ||
        !_library.isActiveAllowedFileSystemPath(entryPath)) {
      _writeJson(request.response, HttpStatus.forbidden, const <String, Object?>{
        'error': 'forbidden_path',
      });
      return;
    }

    final libraryRoot = _library.libraryRootForPath(entryPath) ?? groupKey;
    try {
      await _library.renameWorkEntryToName(
        libraryRootPath: libraryRoot,
        entryPath: entryPath,
        targetName: newName,
        isMedia: isMedia,
        isDirectory: isDirectory,
      );
      _writeJson(request.response, HttpStatus.ok, const <String, Object?>{
        'ok': true,
      });
    } on AudioDetailRenameException catch (error) {
      _writeJson(request.response, HttpStatus.conflict, <String, Object?>{
        'error': error.reason,
      });
    } on FileSystemException {
      _writeJson(request.response, HttpStatus.conflict, const <String, Object?>{
        'error': 'renameFailed',
      });
    }
  }

  Future<void> _handleSetWorkCover(HttpRequest request, String workId) async {
    if (!_ensureEditEnabled(request.response)) return;
    final body = await _readJsonBody(request);
    if (body == null) return;

    final groupKey = await _resolveActiveGroupKey(workId);
    if (groupKey == null) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_not_found',
      });
      return;
    }
    final relRaw = body['relativePath']?.toString().trim() ?? '';
    final relSegments = relRaw
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (relSegments.isEmpty ||
        relSegments.any((s) => s == '.' || s == '..')) {
      _writeJson(request.response, HttpStatus.badRequest, const <String, Object?>{
        'error': 'invalid_argument',
      });
      return;
    }
    final imagePath = PathMatcher.normalize(
      path.joinAll(<String>[groupKey, ...relSegments]),
    );
    if (!PathMatcher.isWithinOrEqual(imagePath, groupKey) ||
        !_library.isActiveAllowedFileSystemPath(imagePath) ||
        !_imageExtensions.contains(path.extension(imagePath).toLowerCase())) {
      _writeJson(request.response, HttpStatus.forbidden, const <String, Object?>{
        'error': 'forbidden_path',
      });
      return;
    }

    await _library.setFolderManualCover(groupKey, imagePath);
    final serialized = await _serializeWork(groupKey);
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'work': serialized,
    });
  }

  Future<void> _handleTogglePinWorks(HttpRequest request) async {
    if (!_ensureEditEnabled(request.response)) return;
    final body = await _readJsonBody(request);
    if (body == null) return;

    final workIds = (body['workIds'] as List? ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (workIds.isEmpty) {
      _writeJson(request.response, HttpStatus.badRequest, const <String, Object?>{
        'error': 'invalid_argument',
      });
      return;
    }

    await _populateWorkIndex();
    final targetPaths = <String>[];
    for (final id in workIds) {
      final gk = _groupKeyByWorkId[id];
      if (gk == null) continue;
      final tracks = _library.tracksInGroup(gk);
      if (tracks.isEmpty) continue;
      targetPaths.add(tracks.first.isSingle ? tracks.first.path : gk);
    }
    if (targetPaths.isNotEmpty) {
      if (_togglePinnedPaths != null) {
        await _togglePinnedPaths(targetPaths);
      } else {
        final normalizedTargets = targetPaths.map(PathMatcher.normalize).toList();
        final allPinned = normalizedTargets.every(
          _fallbackPinnedNormalizedPaths.contains,
        );
        if (allPinned) {
          _fallbackPinnedNormalizedPaths.removeAll(normalizedTargets);
        } else {
          _fallbackPinnedNormalizedPaths.addAll(normalizedTargets);
        }
      }
    }

    final pinnedPaths = _currentPinnedNormalizedPaths();
    final pinnedWorkIds = <String>[
      for (final entry in _groupKeyByWorkId.entries)
        if (pinnedPaths.contains(PathMatcher.normalize(entry.value)))
          entry.key,
    ];
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'pinnedWorkIds': pinnedWorkIds,
    });
  }

  Future<void> _handleRemoveWorks(HttpRequest request) async {
    if (!_ensureEditEnabled(request.response)) return;
    final body = await _readJsonBody(request);
    if (body == null) return;

    final workIds = (body['workIds'] as List? ?? const [])
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (workIds.isEmpty) {
      _writeJson(request.response, HttpStatus.badRequest, const <String, Object?>{
        'error': 'invalid_argument',
      });
      return;
    }

    await _populateWorkIndex();
    var removedCount = 0;
    for (final id in workIds) {
      final gk = _groupKeyByWorkId[id];
      if (gk == null) continue;
      final tracks = _library.tracksInGroup(gk);
      if (tracks.isEmpty) continue;
      final first = tracks.first;
      final result = first.isSingle
          ? await _library.removeTrack(first.path)
          : await _library.removeFolder(gk);
      if (result != null) {
        _groupKeyByWorkId.remove(id);
        removedCount++;
      }
    }
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'removedCount': removedCount,
    });
  }

  Future<void> _handleWorkTree(HttpRequest request, String workId) async {
    final groupKey = _groupKeyByWorkId[workId];
    if (groupKey == null) {
      await _populateWorkIndex();
    }
    final resolvedGroup = _groupKeyByWorkId[workId];
    if (resolvedGroup == null) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_not_found',
      });
      return;
    }

    final tracks = _library.tracksInGroup(resolvedGroup);
    if (tracks.isEmpty) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'work_empty',
      });
      return;
    }
    for (final t in tracks) {
      if (t.duration > Duration.zero) {
        _trackDurationByPath[PathMatcher.normalize(t.path)] = t.duration;
      }
    }

    final first = tracks.first;
    if (first.isSingle) {
      final file = File(first.path);
      if (!_library.isActiveAllowedFileSystemPath(file.path) ||
          !await file.exists()) {
        _writeJson(
          request.response,
          HttpStatus.notFound,
          const <String, Object?>{'error': 'file_unavailable'},
        );
        return;
      }
      final node = await _buildFileNode(file);
      _writeJson(request.response, HttpStatus.ok, <String, Object?>{
        'tree': node == null ? const <Object?>[] : <Object?>[node],
      });
      return;
    }

    final rootDir = Directory(resolvedGroup);
    if (!_library.isActiveAllowedFileSystemPath(rootDir.path) ||
        !await rootDir.exists()) {
      _writeJson(request.response, HttpStatus.notFound, const <String, Object?>{
        'error': 'folder_unavailable',
      });
      return;
    }

    final tree = await _enumerateDirectoryNodes(rootDir, depth: 0);
    _writeJson(request.response, HttpStatus.ok, <String, Object?>{
      'tree': tree,
    });
  }

  Future<List<Map<String, Object?>>> _enumerateDirectoryNodes(
    Directory directory, {
    required int depth,
  }) async {
    if (depth > 16) return const <Map<String, Object?>>[];
    List<FileSystemEntity> entities;
    try {
      entities = await directory.list(followLinks: false).toList();
    } on Object {
      return const <Map<String, Object?>>[];
    }
    entities.sort((a, b) {
      final aDir = a is Directory;
      final bDir = b is Directory;
      if (aDir != bDir) return aDir ? -1 : 1;
      return compareNatural(path.basename(a.path), path.basename(b.path));
    });

    final nodes = <Map<String, Object?>>[];
    for (final entity in entities) {
      final entityPath = PathMatcher.normalize(entity.path);
      if (!_library.isActiveAllowedFileSystemPath(entityPath)) continue;
      final baseName = path.basename(entityPath);
      if (baseName.startsWith('.')) continue;

      if (entity is Directory) {
        final children = await _enumerateDirectoryNodes(
          entity,
          depth: depth + 1,
        );
        if (children.isEmpty) continue;
        nodes.add(<String, Object?>{
          'hash': _idForPath('dir', entityPath),
          'title': baseName,
          'type': 'folder',
          'children': children,
        });
      } else if (entity is File) {
        final node = await _buildFileNode(entity);
        if (node != null) nodes.add(node);
      }
    }
    return nodes;
  }

  Future<Map<String, Object?>?> _buildFileNode(File file) async {
    final normalizedPath = PathMatcher.normalize(file.path);
    final fileName = path.basename(normalizedPath);
    final ext = path.extension(fileName).toLowerCase();

    final String? nodeType;
    if (isVideoMediaFile(normalizedPath)) {
      nodeType = 'video';
    } else if (isSupportedMediaFile(normalizedPath)) {
      nodeType = 'audio';
    } else if (_subtitleExtensions.contains(ext) ||
        _textExtensions.contains(ext)) {
      nodeType = ext == '.pdf' ? 'pdf' : 'text';
    } else if (_imageExtensions.contains(ext)) {
      nodeType = 'image';
    } else {
      nodeType = null;
    }
    if (nodeType == null) return null;

    FileStat stat;
    try {
      stat = await file.stat();
    } on Object {
      return null;
    }

    final fileId = _registerAllowedFile(normalizedPath);
    final streamPath = '/api/v1/stream/$fileId/${Uri.encodeComponent(fileName)}';
    final duration = _trackDurationByPath[normalizedPath] ?? Duration.zero;
    return <String, Object?>{
      'hash': fileId,
      'title': fileName,
      'type': nodeType,
      'mediaStreamUrl': streamPath,
      'mediaDownloadUrl': streamPath,
      'duration': duration.inMilliseconds / 1000.0,
      'size': stat.size,
      'children': const <Object?>[],
    };
  }

  Future<void> _handleCover(HttpRequest request, String workId) async {
    if (!_groupKeyByWorkId.containsKey(workId)) {
      await _populateWorkIndex();
    }
    final groupKey = _groupKeyByWorkId[workId];
    if (groupKey == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final tracks = _library.tracksInGroup(groupKey);
    final first = tracks.firstOrNull;
    String? coverPath;
    try {
      if (first != null && first.isSingle) {
        coverPath =
            _library.resolvedCoverPathForTrack(first) ??
            await _library.coverPathFutureForTrack(first);
      } else {
        coverPath =
            _library.resolvedCoverPathForFolder(groupKey) ??
            await _library.coverPathFutureForFolder(groupKey);
      }
    } on Object {
      // Fall back to direct filesystem cover lookup if artwork cache is not ready yet.
      coverPath = null;
    }
    if ((coverPath == null || coverPath.isEmpty) &&
        (first == null || !first.isSingle)) {
      coverPath = await _findDirectFolderCover(groupKey);
    }
    if (coverPath == null ||
        coverPath.isEmpty ||
        PathMatcher.isRemoteUri(coverPath) ||
        PathMatcher.isContentUri(coverPath)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final file = File(coverPath);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    await _serveFileWithRange(request, file);
  }

  Future<void> _handleStreamFile(HttpRequest request, String fileId) async {
    var filePath = _filePathByFileId[fileId];
    filePath ??= await _recoverAllowedFileById(fileId);
    if (filePath == null || !_library.isActiveAllowedFileSystemPath(filePath)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final file = File(filePath);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    await _serveFileWithRange(request, file);
  }

  Future<String?> _recoverAllowedFileById(String fileId) async {
    for (final track in _library.library) {
      if (track.isRemoteMedia) continue;
      final normalizedTrackPath = PathMatcher.normalize(track.path);
      if (_library.isActiveAllowedFileSystemPath(normalizedTrackPath)) {
        _registerAllowedFile(normalizedTrackPath);
      }
      final lyricsPath = track.lyricsPath?.trim();
      if (lyricsPath != null && lyricsPath.isNotEmpty) {
        final normalizedLyrics = PathMatcher.normalize(lyricsPath);
        if (_library.isActiveAllowedFileSystemPath(normalizedLyrics)) {
          _registerAllowedFile(normalizedLyrics);
        }
      }
      final hit = _filePathByFileId[fileId];
      if (hit != null) return hit;
    }

    await _populateWorkIndex();
    for (final groupKey in _library.activeGroupKeys) {
      final tracks = _library.tracksInGroup(groupKey);
      if (tracks.isEmpty || tracks.first.isRemoteMedia) continue;
      final first = tracks.first;
      if (first.isSingle) continue;
      final rootDir = Directory(groupKey);
      if (!_library.isActiveAllowedFileSystemPath(rootDir.path) ||
          !await rootDir.exists()) {
        continue;
      }
      await _enumerateDirectoryNodes(rootDir, depth: 0);
      final hit = _filePathByFileId[fileId];
      if (hit != null) return hit;
    }
    return _filePathByFileId[fileId];
  }

  Future<void> _serveFileWithRange(HttpRequest request, File file) async {
    final response = request.response;
    final stat = await file.stat();
    final totalLength = stat.size;
    final mimeType =
        lookupMimeType(file.path) ?? 'application/octet-stream';
    final etag =
        '"${totalLength.toRadixString(16)}-${stat.modified.millisecondsSinceEpoch.toRadixString(16)}"';

    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, mimeType);
    response.headers.set(HttpHeaders.etagHeader, etag);
    response.headers.set(
      HttpHeaders.lastModifiedHeader,
      HttpDate.format(stat.modified.toUtc()),
    );

    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    if (rangeHeader == null || !rangeHeader.startsWith('bytes=')) {
      response.statusCode = HttpStatus.ok;
      response.contentLength = totalLength;
      if (request.method == 'HEAD' || totalLength == 0) {
        await response.close();
        return;
      }
      await response.addStream(file.openRead());
      await response.close();
      return;
    }

    final parsedRange = _parseByteRange(rangeHeader, totalLength);
    if (parsedRange == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes */$totalLength',
      );
      await response.close();
      return;
    }

    final (start, endInclusive) = parsedRange;
    final sliceLength = endInclusive - start + 1;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$endInclusive/$totalLength',
    );
    response.contentLength = sliceLength;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    await response.addStream(file.openRead(start, endInclusive + 1));
    await response.close();
  }

  Future<void> _handleSyncExchange(HttpRequest request) async {
    if (!_settings.allowSync) {
      _writeJson(request.response, HttpStatus.forbidden, const <String, Object?>{
        'error': 'sync_disabled',
      });
      return;
    }
    const maxSyncBytes = 32 * 1024 * 1024;
    if (request.contentLength > maxSyncBytes) {
      _writeJson(
        request.response,
        HttpStatus.requestEntityTooLarge,
        const <String, Object?>{'error': 'payload_too_large'},
      );
      return;
    }
    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in request.timeout(const Duration(seconds: 25))) {
      total += chunk.length;
      if (total > maxSyncBytes) {
        _writeJson(
          request.response,
          HttpStatus.requestEntityTooLarge,
          const <String, Object?>{'error': 'payload_too_large'},
        );
        return;
      }
      builder.add(chunk);
    }
    final responseBytes = await _syncService.exchangeSyncBytes(
      builder.takeBytes(),
    );
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/octet-stream')
      ..contentLength = responseBytes.length
      ..add(responseBytes);
    await request.response.close();
  }

  Future<void> _populateWorkIndex() async {
    for (final groupKey in _library.activeGroupKeys) {
      final tracks = _library.tracksInGroup(groupKey);
      if (tracks.isEmpty || tracks.first.isRemoteMedia) continue;
      _registerWorkGroup(groupKey);
    }
  }

  String _registerWorkGroup(String groupKey) {
    final normalized = PathMatcher.normalize(groupKey);
    final workId = _idForPath('work', normalized);
    _groupKeyByWorkId[workId] = normalized;
    return workId;
  }

  String _registerAllowedFile(String normalizedFilePath) {
    final fileId = _idForPath('file', normalizedFilePath);
    _filePathByFileId[fileId] = normalizedFilePath;
    return fileId;
  }

  String _idForPath(String namespace, String value) {
    final digest = sha256.convert(
      utf8.encode('$_serverId:$namespace:${PathMatcher.equivalenceKey(value)}'),
    );
    return digest.toString().substring(0, 24);
  }

  bool _isAuthorized(HttpRequest request) {
    if (_accessCode.isEmpty) return true;
    final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!auth.startsWith('Bearer ')) return false;
    final candidate = auth.substring('Bearer '.length).trim();
    return _constantTimeEquals(candidate, _accessCode);
  }

  String? _tryResolvedCoverForTrack(MusicTrack track) {
    try {
      return _library.resolvedCoverPathForTrack(track);
    } on Object {
      return null;
    }
  }

  Future<String?> _findDirectFolderCover(String folderPath) async {
    if (!_library.isActiveAllowedFileSystemPath(folderPath)) return null;
    final dir = Directory(folderPath);
    if (!await dir.exists()) return null;
    final images = <File>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File &&
            _imageExtensions.contains(
              path.extension(entity.path).toLowerCase(),
            ) &&
            _library.isActiveAllowedFileSystemPath(entity.path)) {
          images.add(entity);
        }
      }
    } on Object {
      return null;
    }
    if (images.isEmpty) return null;
    images.sort(
      (a, b) => compareNatural(path.basename(a.path), path.basename(b.path)),
    );
    for (final preferred in const <String>[
      'cover',
      'folder',
      'main',
      'jacket',
      'samune',
    ]) {
      for (final img in images) {
        final stem = path.basenameWithoutExtension(img.path).toLowerCase();
        if (stem == preferred || stem.contains(preferred)) {
          return img.path;
        }
      }
    }
    return images.first.path;
  }

  static (int, int)? _parseByteRange(String header, int totalLength) {
    if (totalLength <= 0) return null;
    final spec = header.substring('bytes='.length).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final left = spec.substring(0, dash).trim();
    final right = spec.substring(dash + 1).trim();
    if (left.isEmpty) {
      final suffix = int.tryParse(right);
      if (suffix == null || suffix <= 0) return null;
      final start = suffix >= totalLength ? 0 : totalLength - suffix;
      return (start, totalLength - 1);
    }
    final start = int.tryParse(left);
    if (start == null || start < 0 || start >= totalLength) return null;
    if (right.isEmpty) return (start, totalLength - 1);
    final end = int.tryParse(right);
    if (end == null || end < start) return null;
    return (start, end >= totalLength ? totalLength - 1 : end);
  }

  static bool _constantTimeEquals(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    var diff = aBytes.length ^ bBytes.length;
    final count = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;
    for (var i = 0; i < count; i++) {
      diff |= aBytes[i] ^ bBytes[i];
    }
    return diff == 0;
  }

  static void _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, Object?> body,
  ) {
    final encoded = utf8.encode(jsonEncode(body));
    response
      ..statusCode = statusCode
      ..headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      )
      ..contentLength = encoded.length
      ..add(encoded);
    unawaited(response.close());
  }

  static String _generateSixDigitPin() {
    final rng = Random.secure();
    return (100000 + rng.nextInt(900000)).toString();
  }

  static String _generateRandomHex(int bytesLength) {
    final rng = Random.secure();
    return List<int>.generate(
      bytesLength,
      (_) => rng.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _safeHostname() {
    try {
      return Platform.localHostname;
    } on Object {
      return 'Windows PC';
    }
  }
}
