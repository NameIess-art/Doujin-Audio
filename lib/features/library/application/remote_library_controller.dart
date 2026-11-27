import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/cross_platform_media_identity.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/network/remote_source_headers.dart';
import '../../../core/network/webdav_client.dart';
import '../../../core/persistence/app_preferences.dart';
import '../../asmr/domain/asmr_models.dart';
import '../../data_support/application/cross_platform_sync_service.dart';
import '../../data_support/domain/cross_platform_sync_models.dart';
import '../../player/application/playback_session_launcher.dart';
import '../../player/domain/playback_mode.dart';
import '../domain/remote_media_source.dart';
import 'library_facade.dart' show AudioDetailRenameException;
import 'webdav_media_source_adapter.dart';

const String _remoteSourcesPrefKey = 'remote_media_sources_v1';
String _remoteSourceSecretKey(String id) => 'remote_media_source_secret_v1_$id';

class RemoteLibraryController extends ChangeNotifier {
  RemoteLibraryController({
    required CrossPlatformSyncService syncService,
    PlaybackSessionLauncher? playbackLauncher,
    SyncSecretRead? readSecret,
    SyncSecretWrite? writeSecret,
    RemoteSourceHeaderRegistry? headerRegistry,
    HttpClient Function()? httpClientFactory,
    WebDavClient Function({
      required Uri baseUri,
      String? username,
      String? password,
    })?
    webDavClientFactory,
    Future<Directory> Function()? supportDirectoryProvider,
  }) : _syncService = syncService,
       _playbackLauncher = playbackLauncher,
       _readSecret = readSecret ?? _defaultSecretRead,
       _writeSecret = writeSecret ?? _defaultSecretWrite,
       _headerRegistry = headerRegistry ?? RemoteSourceHeaderRegistry.instance,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _webDavClientFactory = webDavClientFactory ?? _defaultWebDavFactory,
       _supportDirectoryProvider =
           supportDirectoryProvider ?? getApplicationSupportDirectory;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static Future<String?> _defaultSecretRead(String key) =>
      _secureStorage.read(key: key);
  static Future<void> _defaultSecretWrite(String key, String? value) =>
      value == null || value.isEmpty
      ? _secureStorage.delete(key: key)
      : _secureStorage.write(key: key, value: value);
  static WebDavClient _defaultWebDavFactory({
    required Uri baseUri,
    String? username,
    String? password,
  }) => WebDavClient(baseUri: baseUri, username: username, password: password);

  final CrossPlatformSyncService _syncService;
  PlaybackSessionLauncher? _playbackLauncher;
  final SyncSecretRead _readSecret;
  final SyncSecretWrite _writeSecret;
  final RemoteSourceHeaderRegistry _headerRegistry;
  final HttpClient Function() _httpClientFactory;
  final WebDavClient Function({
    required Uri baseUri,
    String? username,
    String? password,
  })
  _webDavClientFactory;
  final Future<Directory> Function() _supportDirectoryProvider;
  static const WebDavMediaSourceAdapter _webDavAdapter =
      WebDavMediaSourceAdapter();

  final List<RemoteMediaSource> _sources = <RemoteMediaSource>[];
  final Set<String> _pendingSourceRemovals = <String>{};
  List<RemoteMediaSource> _sourcesView = const <RemoteMediaSource>[];
  final Map<String, String> _secretsBySourceId = <String, String>{};
  final Map<String, List<RemoteLibraryWork>> _worksBySourceId =
      <String, List<RemoteLibraryWork>>{};
  final Map<String, bool> _loadingBySourceId = <String, bool>{};
  final Map<String, Object?> _errorBySourceId = <String, Object?>{};
  final Map<String, bool> _reachabilityBySourceId = <String, bool>{};
  final Map<String, Future<bool>> _inFlightProbes = <String, Future<bool>>{};
  final Map<String, Future<List<RemoteLibraryWork>>> _inFlightRefreshes =
      <String, Future<List<RemoteLibraryWork>>>{};
  final Map<String, List<AsmrTrackFile>> _treesByWorkKey =
      <String, List<AsmrTrackFile>>{};
  final Map<String, MusicTrack> _activeRemoteTracksByUrl =
      <String, MusicTrack>{};

  String? _selectedSourceId;
  bool _credentialsLoaded = false;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _credentialsFuture;
  Future<void>? _initFuture;
  int _directPlayEpoch = 0;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  List<RemoteMediaSource> get sources => _sourcesView;

  void _refreshSourcesView() {
    _sourcesView = List<RemoteMediaSource>.unmodifiable(
      _sources.where((source) => !_pendingSourceRemovals.contains(source.id)),
    );
  }

  String? get selectedSourceId => selectedSource?.id;
  RemoteMediaSource? get selectedSource => _selectedSourceId == null
      ? null
      : sourceById(_selectedSourceId!);

  void bindPlaybackLauncher(PlaybackSessionLauncher launcher) {
    _playbackLauncher = launcher;
  }

  MusicTrack? resolveTrackByPath(String trackPath) =>
      _activeRemoteTracksByUrl[trackPath];

  RemoteMediaSource? sourceById(String id) {
    for (final source in _sourcesView) {
      if (source.id == id) return source;
    }
    return null;
  }

  List<RemoteLibraryWork> worksFor(String sourceId) =>
      _worksBySourceId[sourceId] ?? const <RemoteLibraryWork>[];

  bool isLoading(String sourceId) => _loadingBySourceId[sourceId] == true;

  bool hasLoadedCatalog(String sourceId) =>
      _worksBySourceId.containsKey(sourceId);

  Object? errorFor(String sourceId) => _errorBySourceId[sourceId];

  bool? sourceReachability(String sourceId) =>
      _reachabilityBySourceId[sourceId];

  bool isSourceOffline(String sourceId) =>
      _reachabilityBySourceId[sourceId] == false;

  bool canEnterSource(String sourceId) =>
      _reachabilityBySourceId[sourceId] == true;

  List<AsmrTrackFile>? cachedTreeFor(RemoteLibraryWork work) =>
      _treesByWorkKey[work.uniqueKey];

  Future<void> ensureCredentialsLoaded() {
    if (_credentialsLoaded || _disposed) return Future<void>.value();
    return _credentialsFuture ??= _loadCredentialsInternal();
  }

  Future<void> _loadCredentialsInternal() async {
    if (_credentialsLoaded) return;
    final raw = await AppPreferences.getString(_remoteSourcesPrefKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          final loadedIds = <String>{for (final s in _sources) s.id};
          for (final item in decoded.whereType<Map<Object?, Object?>>()) {
            final source = RemoteMediaSource.fromJson(
              Map<String, Object?>.from(item),
            );
            if (source.id.isNotEmpty &&
                source.baseUrl.isNotEmpty &&
                loadedIds.add(source.id)) {
              _sources.add(source);
            }
          }
          _refreshSourcesView();
        }
      } on Object catch (error, stack) {
        AppLogService.warning(
          'remote_media_sources_decode_failed',
          error: error,
          stackTrace: stack,
        );
      }
    }

    for (final source in _sources) {
      if (source.secretConfigured &&
          !_secretsBySourceId.containsKey(source.id)) {
        final secret = await _readSecret(_remoteSourceSecretKey(source.id));
        if (secret != null && secret.isNotEmpty) {
          _secretsBySourceId[source.id] = secret;
        }
      }
    }
    _syncHeaderRules();
    _credentialsLoaded = true;
  }

  Future<void> initialize() {
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _initializeInternal();
  }

  Future<void> _initializeInternal() async {
    if (_initialized) return;
    await ensureCredentialsLoaded();
    for (final source in _sources) {
      await _loadCachedWorksFromDisk(source.id);
    }
    _syncHeaderRules();
    _initialized = true;
    notifyListeners();
    if (_sources.isNotEmpty) {
      unawaited(probeAllSourcesConnection());
    }
  }

  Future<bool> probeSourceConnection(
    String sourceId, {
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    await initialize();
    final existing = _inFlightProbes[sourceId];
    if (existing != null) return existing;
    final source = sourceById(sourceId);
    if (source == null) return false;
    final future = _runSourceProbe(source, timeout);
    _inFlightProbes[sourceId] = future;
    return future;
  }

  Future<void> probeAllSourcesConnection({
    Duration timeout = const Duration(milliseconds: 2500),
  }) async {
    await initialize();
    if (_sources.isEmpty) return;
    await Future.wait<bool>(
      _sources
          .toList(growable: false)
          .map((s) => probeSourceConnection(s.id, timeout: timeout)),
    );
  }

  Future<bool> _runSourceProbe(
    RemoteMediaSource source,
    Duration timeout,
  ) async {
    var ok = false;
    try {
      final baseUri = Uri.parse(source.baseUrl);
      final effectiveSecret = _secretsBySourceId[source.id];
      if (source.isLan) {
        final client = _httpClientFactory()..connectionTimeout = timeout;
        try {
          final worksUri = _resolveLanPath(baseUri, '/api/v1/works');
          final request = await client.getUrl(worksUri).timeout(timeout);
          if (effectiveSecret != null && effectiveSecret.trim().isNotEmpty) {
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer ${effectiveSecret.trim()}',
            );
          }
          final response = await request.close().timeout(timeout);
          await response.drain<void>().timeout(timeout);
          ok = response.statusCode >= 200 && response.statusCode < 300;
        } finally {
          client.close();
        }
      } else {
        final client = _webDavClientFactory(
          baseUri: baseUri,
          username: source.username,
          password: effectiveSecret,
        );
        try {
          await client.testConnection().timeout(timeout);
          ok = true;
        } finally {
          client.close();
        }
      }
    } on Object {
      ok = false;
    } finally {
      unawaited(_inFlightProbes.remove(source.id));
      final previous = _reachabilityBySourceId[source.id];
      _reachabilityBySourceId[source.id] = ok;
      if (previous != ok) {
        notifyListeners();
      }
    }
    return ok;
  }

  void selectSource(String? sourceId) {
    if (sourceId != null && sourceById(sourceId) == null) return;
    if (_selectedSourceId == sourceId) return;
    _selectedSourceId = sourceId;
    notifyListeners();
  }

  Future<void> testConnection({
    required RemoteMediaSourceType type,
    required String baseUrl,
    String username = '',
    String? secret,
    String? existingSourceId,
  }) async {
    await initialize();
    final effectiveSecret = (secret != null && secret.isNotEmpty)
        ? secret
        : (existingSourceId == null
              ? null
              : _secretsBySourceId[existingSourceId]);
    final baseUri = _normalizeSourceBaseUri(baseUrl, type);

    if (type == RemoteMediaSourceType.webDav) {
      final client = _webDavClientFactory(
        baseUri: baseUri,
        username: username.trim(),
        password: effectiveSecret,
      );
      try {
        await client.testConnection();
      } finally {
        client.close();
      }
      return;
    }

    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final worksUri = _resolveLanPath(baseUri, '/api/v1/works');
      final request = await client
          .getUrl(worksUri)
          .timeout(const Duration(seconds: 10));
      if (effectiveSecret != null && effectiveSecret.trim().isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${effectiveSecret.trim()}',
        );
      }
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      await response.listen(null).cancel();
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        throw const HttpException('remote_source_unauthorized');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('remote_source_http_${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  Future<RemoteMediaSource> addOrUpdateSource({
    String? id,
    required RemoteMediaSourceType type,
    required String name,
    required String baseUrl,
    String username = '',
    String? secret,
    bool clearSecret = false,
  }) async {
    await initialize();
    final baseUri = _normalizeSourceBaseUri(baseUrl, type);
    final sourceId = (id != null && id.isNotEmpty) ? id : _generateId();
    final existingIndex = _sources.indexWhere((s) => s.id == sourceId);
    final existing = existingIndex >= 0 ? _sources[existingIndex] : null;

    String? effectiveSecret;
    if (clearSecret) {
      effectiveSecret = null;
      _secretsBySourceId.remove(sourceId);
      await _writeSecret(_remoteSourceSecretKey(sourceId), null);
    } else if (secret != null && secret.isNotEmpty) {
      effectiveSecret = secret.trim();
      _secretsBySourceId[sourceId] = effectiveSecret;
      await _writeSecret(_remoteSourceSecretKey(sourceId), effectiveSecret);
    } else {
      effectiveSecret = _secretsBySourceId[sourceId];
    }

    var allowSync =
        existing?.allowSync ?? (type == RemoteMediaSourceType.windowsLan);
    var allowEdit = existing?.allowEdit ?? true;
    if (type == RemoteMediaSourceType.windowsLan) {
      final info = await _probeLanServerInfo(baseUri);
      if (info != null) {
        allowSync = info.allowSync;
        allowEdit = info.allowEdit;
      }
    }

    final saved = RemoteMediaSource(
      id: sourceId,
      type: type,
      name: name.trim().isNotEmpty ? name.trim() : baseUri.host,
      baseUrl: baseUri.toString(),
      username: username.trim(),
      secretConfigured: effectiveSecret != null && effectiveSecret.isNotEmpty,
      allowSync: allowSync,
      allowEdit: allowEdit,
      pinnedWorkIds: existing?.pinnedWorkIds ?? const <String>[],
      excludedWorkIds: existing?.excludedWorkIds ?? const <String>[],
      createdAtMs:
          existing?.createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
    );

    if (existingIndex >= 0) {
      _sources[existingIndex] = saved;
    } else {
      _sources.add(saved);
    }
    _refreshSourcesView();
    await _persistSources();
    _syncHeaderRules();
    notifyListeners();
    unawaited(
      refreshSource(saved.id).catchError((_) => const <RemoteLibraryWork>[]),
    );
    return saved;
  }

  bool stageSourceRemoval(String sourceId) {
    if (sourceById(sourceId) == null) return false;
    _pendingSourceRemovals.add(sourceId);
    _refreshSourcesView();
    notifyListeners();
    return true;
  }

  void cancelSourceRemoval(String sourceId) {
    if (!_pendingSourceRemovals.remove(sourceId)) return;
    _refreshSourcesView();
    notifyListeners();
  }

  Future<void> removeSource(String sourceId) async {
    await initialize();
    final index = _sources.indexWhere((source) => source.id == sourceId);
    if (index < 0) return;
    final source = _sources.removeAt(index);
    _refreshSourcesView();
    try {
      if (!await _persistSources()) {
        throw StateError('Could not save remote media sources');
      }
      await _writeSecret(_remoteSourceSecretKey(sourceId), null);
    } catch (_) {
      _sources.insert(min(index, _sources.length), source);
      _refreshSourcesView();
      await _persistSources();
      rethrow;
    }
    _pendingSourceRemovals.remove(sourceId);
    _secretsBySourceId.remove(sourceId);
    _worksBySourceId.remove(sourceId);
    _loadingBySourceId.remove(sourceId);
    _errorBySourceId.remove(sourceId);
    _reachabilityBySourceId.remove(sourceId);
    unawaited(_inFlightProbes.remove(sourceId));
    unawaited(_inFlightRefreshes.remove(sourceId));
    _treesByWorkKey.removeWhere((key, _) => key.startsWith('$sourceId::'));
    if (_selectedSourceId == sourceId) {
      _selectedSourceId = null;
    }
    await _deleteCachedWorksOnDisk(sourceId);
    _syncHeaderRules();
    notifyListeners();
  }

  Future<List<RemoteLibraryWork>> refreshSource(String sourceId) async {
    await initialize();
    final existing = _inFlightRefreshes[sourceId];
    if (existing != null) return existing;
    final source = sourceById(sourceId);
    if (source == null) return const <RemoteLibraryWork>[];
    final future = _runRefreshSource(source);
    _inFlightRefreshes[sourceId] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightRefreshes[sourceId], future)) {
        unawaited(_inFlightRefreshes.remove(sourceId));
      }
    }
  }

  Future<List<RemoteLibraryWork>> _runRefreshSource(
    RemoteMediaSource source,
  ) async {
    final sourceId = source.id;
    _loadingBySourceId[sourceId] = true;
    _errorBySourceId.remove(sourceId);
    notifyListeners();

    try {
      List<RemoteLibraryWork> works;
      if (source.isLan) {
        works = await _fetchLanWorks(source);
      } else {
        final client = _webDavClientFactory(
          baseUri: Uri.parse(source.baseUrl),
          username: source.username,
          password: _secretsBySourceId[source.id],
        );
        try {
          works = await _webDavAdapter.fetchWorks(
            source: source,
            client: client,
          );
          works = await _overlayLocalSyncWorkStates(works);
        } finally {
          client.close();
        }
      }
      _worksBySourceId[sourceId] = works;
      _reachabilityBySourceId[sourceId] = true;
      _treesByWorkKey.removeWhere((key, _) => key.startsWith('$sourceId::'));
      await _saveCachedWorksToDisk(sourceId, works);
      return works;
    } catch (error, stack) {
      _errorBySourceId[sourceId] = error;
      _reachabilityBySourceId[sourceId] = false;
      AppLogService.warning(
        'remote_source_refresh_failed',
        error: error,
        stackTrace: stack,
      );
      rethrow;
    } finally {
      _loadingBySourceId[sourceId] = false;
      notifyListeners();
    }
  }

  Future<List<AsmrTrackFile>> ensureWorkTree(
    RemoteLibraryWork work, {
    bool forceRefresh = false,
  }) async {
    await initialize();
    if (!forceRefresh) {
      final cached = _treesByWorkKey[work.uniqueKey];
      if (cached != null) return cached;
    }
    final source = sourceById(work.sourceId);
    if (source == null) {
      throw StateError('Remote media source ${work.sourceId} does not exist');
    }

    final List<AsmrTrackFile> tree;
    if (source.isLan) {
      tree = await _fetchLanWorkTree(source, work);
    } else {
      final client = _webDavClientFactory(
        baseUri: Uri.parse(source.baseUrl),
        username: source.username,
        password: _secretsBySourceId[source.id],
      );
      try {
        final loaded = await _webDavAdapter.fetchWorkTree(
          work: work,
          client: client,
        );
        tree = loaded.tree;
        if ((work.coverUrl == null && loaded.discoveredCoverUrl != null) ||
            (!work.hasSubtitle && loaded.hasSubtitle)) {
          _updateCachedWorkMetadata(
            work,
            coverUrl: work.coverUrl ?? loaded.discoveredCoverUrl,
            hasSubtitle: work.hasSubtitle || loaded.hasSubtitle,
          );
        }
      } finally {
        client.close();
      }
    }
    _treesByWorkKey[work.uniqueKey] = tree;
    notifyListeners();
    return tree;
  }

  Future<CrossPlatformSyncSummary> syncWithLanSource(String sourceId) async {
    await initialize();
    final source = sourceById(sourceId);
    if (source == null || !source.isLan) {
      throw StateError('Not a Windows LAN media source');
    }
    return _syncService.syncWithLanServer(
      serverBaseUri: Uri.parse(source.baseUrl),
      bearerToken: _secretsBySourceId[source.id],
    );
  }

  bool get webDavSyncEnabled {
    final settings = _syncService.webDavSettings;
    if (!settings.autoSyncEnabled) return false;
    return settings.sourceId.isEmpty
        ? settings.isConfigured
        : sourceById(settings.sourceId)?.isWebDav == true;
  }

  bool get canEnableWebDavSync =>
      _webDavSyncSourceToEnable != null ||
      _syncService.webDavSettings.url.trim().isNotEmpty;

  RemoteMediaSource? get _webDavSyncSourceToEnable {
    final selected = selectedSource;
    if (selected != null && selected.isWebDav && canEnterSource(selected.id)) {
      return selected;
    }
    final bound = sourceById(_syncService.webDavSettings.sourceId);
    if (bound != null && bound.isWebDav && canEnterSource(bound.id)) {
      return bound;
    }
    RemoteMediaSource? candidate;
    for (final source in sources) {
      if (!source.isWebDav || !canEnterSource(source.id)) continue;
      if (candidate != null) return null;
      candidate = source;
    }
    return candidate;
  }

  Future<void> setWebDavSyncEnabled(bool enabled) async {
    await ensureCredentialsLoaded();
    await _syncService.initialize();
    await _syncService.setWebDavSyncEnabled(
      enabled,
      sourceId: enabled ? _webDavSyncSourceToEnable?.id ?? '' : null,
    );
    if (enabled) {
      unawaited(
        _syncService.maybeAutoSyncInBackground(
          minInterval: Duration.zero,
          resolveSource: _resolveWebDavSyncSource,
        ),
      );
    }
  }

  WebDavSyncSource? _resolveWebDavSyncSource(String sourceId) {
    final source = sourceById(sourceId);
    if (_disposed || source == null || !source.isWebDav) return null;
    return (
      baseUri: WebDavClient.normalizeDirectoryUri(
        Uri.parse(source.baseUrl),
      ).resolve('.dasync/'),
      username: source.username,
      password: _secretsBySourceId[sourceId],
    );
  }

  Future<void> maybeAutoSyncInBackground() async {
    await ensureCredentialsLoaded();
    await _syncService.maybeAutoSyncInBackground(
      resolveSource: _resolveWebDavSyncSource,
    );
  }

  /// Unified pull-to-refresh entry point: exchanges `.dasync` progress/reviews/stats
  /// with the remote source first (best-effort if sync is disabled or read-only),
  /// then refreshes the remote work catalog.
  Future<List<RemoteLibraryWork>> pullRefreshAndSync(
    String sourceId, {
    ValueChanged<CrossPlatformSyncSummary>? onSyncSummary,
  }) async {
    await initialize();
    final source = sourceById(sourceId);
    if (source == null) return const <RemoteLibraryWork>[];

    if (source.isLan) {
      if (source.allowSync) {
        try {
          final summary = await syncWithLanSource(source.id);
          onSyncSummary?.call(summary);
        } on HttpException catch (error) {
          if (error.message.contains('unauthorized')) rethrow;
          AppLogService.warning('remote_lan_pull_sync_skipped', error: error);
        } on Object catch (error) {
          AppLogService.warning('remote_lan_pull_sync_failed', error: error);
        }
      }
    } else {
      await _syncService.initialize();
      final settings = _syncService.webDavSettings;
      if (webDavSyncEnabled &&
          (settings.sourceId.isEmpty || settings.sourceId == sourceId)) {
        try {
          final summary = await _syncService.syncWithWebDav(
            resolveSource: _resolveWebDavSyncSource,
          );
          if (summary != null) onSyncSummary?.call(summary);
        } on Object catch (error) {
          // Read-only WebDAV shares may forbid MKCOL/PUT; still allow catalog refresh.
          AppLogService.warning('remote_webdav_pull_sync_skipped', error: error);
        }
      }
    }

    return refreshSource(source.id);
  }

  /// Triggered in parallel when pulling to refresh the Local Library so progress
  /// and statuses sync silently with configured LAN/WebDAV peers when reachable.
  Future<void> syncAllConfiguredInBackground() async {
    await initialize();
    await _syncService.initialize();
    if (webDavSyncEnabled) {
      try {
        await _syncService.syncWithWebDav(
          resolveSource: _resolveWebDavSyncSource,
        );
      } on Object catch (error) {
        AppLogService.warning('local_refresh_webdav_sync_skipped', error: error);
      }
    }
    for (final source in _sources) {
      if (!source.isLan || !source.allowSync) continue;
      try {
        await syncWithLanSource(source.id);
      } on Object {
        // Offline LAN hosts are expected when away from home Wi-Fi.
      }
    }
  }

  RemoteLibraryWork? workByUniqueKey(String uniqueKey) {
    final sep = uniqueKey.indexOf('::');
    if (sep <= 0) return null;
    final sourceId = uniqueKey.substring(0, sep);
    final workId = uniqueKey.substring(sep + 2);
    final list = _worksBySourceId[sourceId];
    if (list == null) return null;
    for (final w in list) {
      if (w.workId == workId) return w;
    }
    return null;
  }

  RemoteLibraryWork? resolveWorkForTrack(MusicTrack track) {
    if (!track.isRemoteSource) return null;
    final meta = track.remoteMetadata;
    var workKey = meta?['workKey']?.toString().trim() ?? '';
    if (workKey.isEmpty && track.groupKey.startsWith('remote-work:')) {
      workKey = track.groupKey.substring('remote-work:'.length);
    }
    var sourceId = meta?['remoteSourceId']?.toString().trim() ?? '';
    var workId = meta?['remoteWorkId']?.toString().trim() ?? '';
    final sep = workKey.indexOf('::');
    if (sep > 0) {
      if (sourceId.isEmpty) sourceId = workKey.substring(0, sep);
      if (workId.isEmpty) workId = workKey.substring(sep + 2);
    }
    if (sourceId.isEmpty || workId.isEmpty) return null;
    final existing = workByUniqueKey('$sourceId::$workId');
    if (existing != null) return existing;
    return RemoteLibraryWork(
      sourceId: sourceId,
      workId: workId,
      rjCode: meta?['rjCode']?.toString() ?? '',
      title: track.groupTitle.trim().isNotEmpty
          ? track.groupTitle.trim()
          : track.displayName,
      folderName: meta?['folderName']?.toString() ?? '',
      circleName: meta?['circleName']?.toString() ?? '',
      voiceActors: (meta?['voiceActors'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      tags: (meta?['tags'] as List? ?? track.tags)
          .whereType<String>()
          .toList(growable: false),
      hasSubtitle: meta?['hasSubtitle'] == true,
      coverUrl: track.remoteCoverUrl,
      directoryUri: meta?['directoryUri']?.toString(),
    );
  }

  Future<int> launchBatchWorksQueue(List<RemoteLibraryWork> works) async {
    final launcher = _playbackLauncher;
    if (launcher == null || works.isEmpty) return 0;
    var added = 0;
    for (final work in works) {
      try {
        final tracks = await _loadPlayableTracks(work);
        if (tracks.isEmpty) continue;
        final ok = await launcher.launchQueue(
          tracks,
          autoPlay: false,
          loopMode: tracks.length > 1
              ? SessionLoopMode.folderSequential
              : SessionLoopMode.single,
        );
        if (ok) added++;
      } on Object catch (error, stack) {
        AppLogService.warning(
          'remote_batch_add_queue_failed',
          error: error,
          stackTrace: stack,
        );
      }
    }
    return added;
  }

  Future<RemoteLibraryWork> saveWorkDetail(
    RemoteLibraryWork work, {
    required DlsiteMetadata metadata,
    String? newFolderName,
    bool saveCover = false,
    bool preserveDuration = false,
  }) async {
    await initialize();
    final source = sourceById(work.sourceId);
    if (source == null) throw StateError('Remote media source not found');
    if (!source.allowEdit) {
      throw const HttpException('remote_source_edit_disabled');
    }

    Uint8List? downloadedCoverBytes;
    var coverExt = 'jpg';
    if (saveCover &&
        metadata.coverUrl != null &&
        metadata.coverUrl!.trim().isNotEmpty) {
      final fetched = await _tryDownloadCoverBytes(metadata.coverUrl!.trim());
      if (fetched != null) {
        downloadedCoverBytes = fetched.bytes;
        coverExt = fetched.extension;
      }
    }

    final RemoteLibraryWork updatedWork;
    if (source.isLan) {
      final baseUri = Uri.parse(source.baseUrl);
      final uri = _resolveLanPath(
        baseUri,
        '/api/v1/works/${Uri.encodeComponent(work.workId)}/detail',
      );
      final json = await _sendLanJson(
        source,
        'PUT',
        uri,
        <String, Object?>{
          if (newFolderName != null && newFolderName.trim().isNotEmpty)
            'newFolderName': newFolderName.trim(),
          'rjCode': metadata.rjCode.trim(),
          'title': metadata.workTitle.trim(),
          'circleName': metadata.circleName.trim(),
          'voiceActors': AudioDetail.normalizeList(metadata.voiceActors),
          'tags': AudioDetail.normalizeList(metadata.tags),
          'releaseDateMs': metadata.releaseDate?.millisecondsSinceEpoch,
          'durationMs': metadata.duration?.inMilliseconds,
          if (metadata.salesCount != null) 'salesCount': metadata.salesCount,
          'rating': metadata.rating,
          'preserveDuration': preserveDuration,
          if (downloadedCoverBytes != null) ...<String, Object?>{
            'coverBytesBase64': base64Encode(downloadedCoverBytes),
            'coverExtension': coverExt,
          },
        },
      );
      final rawMap = json['work'];
      if (rawMap is! Map) throw const FormatException('invalid_lan_response');
      updatedWork = _lanWorkFromMap(
        source,
        baseUri,
        Map<String, Object?>.from(rawMap),
      );
    } else {
      final client = _webDavClientFactory(
        baseUri: Uri.parse(source.baseUrl),
        username: source.username,
        password: _secretsBySourceId[source.id],
      );
      try {
        updatedWork = await _webDavAdapter.saveWorkDetail(
          source: source,
          work: work,
          client: client,
          metadata: metadata,
          newFolderName: newFolderName,
          coverBytes: downloadedCoverBytes,
          coverExtension: coverExt,
          preserveDuration: preserveDuration,
        );
      } finally {
        client.close();
      }
    }

    await _replaceCachedWork(work, updatedWork);
    await _mirrorWorkToSyncLedger(updatedWork, detailEdited: true);
    return updatedWork;
  }

  Future<RemoteLibraryWork> saveWorkReview(
    RemoteLibraryWork work, {
    required WorkListenStatus? listenStatus,
    required int? userRating,
    required String reviewText,
  }) async {
    await initialize();
    final source = sourceById(work.sourceId);
    if (source == null) throw StateError('Remote media source not found');
    if (!source.allowEdit) {
      throw const HttpException('remote_source_edit_disabled');
    }

    final RemoteLibraryWork updatedWork;
    if (source.isLan) {
      final baseUri = Uri.parse(source.baseUrl);
      final uri = _resolveLanPath(
        baseUri,
        '/api/v1/works/${Uri.encodeComponent(work.workId)}/review',
      );
      final json = await _sendLanJson(
        source,
        'PUT',
        uri,
        <String, Object?>{
          'listenStatus': listenStatus?.wireValue,
          'userRating': userRating,
          'reviewText': reviewText.trim(),
        },
      );
      final rawMap = json['work'];
      if (rawMap is! Map) throw const FormatException('invalid_lan_response');
      updatedWork = _lanWorkFromMap(
        source,
        baseUri,
        Map<String, Object?>.from(rawMap),
      );
    } else {
      final client = _webDavClientFactory(
        baseUri: Uri.parse(source.baseUrl),
        username: source.username,
        password: _secretsBySourceId[source.id],
      );
      try {
        updatedWork = await _webDavAdapter.saveWorkReview(
          work: work,
          client: client,
          listenStatus: listenStatus,
          userRating: userRating,
          reviewText: reviewText,
        );
      } finally {
        client.close();
      }
    }

    await _replaceCachedWork(work, updatedWork);
    await _mirrorWorkToSyncLedger(updatedWork, reviewEdited: true);
    return updatedWork;
  }

  Future<void> renameWorkEntry(
    RemoteLibraryWork work, {
    required String relativePath,
    required String newName,
    required bool isDirectory,
    required bool isMedia,
  }) async {
    await initialize();
    final source = sourceById(work.sourceId);
    if (source == null) throw StateError('Remote media source not found');
    if (!source.allowEdit) {
      throw const HttpException('remote_source_edit_disabled');
    }

    if (source.isLan) {
      final baseUri = Uri.parse(source.baseUrl);
      final uri = _resolveLanPath(
        baseUri,
        '/api/v1/works/${Uri.encodeComponent(work.workId)}/entry-rename',
      );
      await _sendLanJson(source, 'POST', uri, <String, Object?>{
        'relativePath': relativePath,
        'newName': newName.trim(),
        'isDirectory': isDirectory,
        'isMedia': isMedia,
      });
    } else {
      final client = _webDavClientFactory(
        baseUri: Uri.parse(source.baseUrl),
        username: source.username,
        password: _secretsBySourceId[source.id],
      );
      try {
        await _webDavAdapter.renameWorkEntry(
          work: work,
          client: client,
          relativePath: relativePath,
          newName: newName,
          isDirectory: isDirectory,
        );
      } finally {
        client.close();
      }
    }
    _treesByWorkKey.remove(work.uniqueKey);
    await ensureWorkTree(work, forceRefresh: true);
  }

  Future<RemoteLibraryWork> setWorkCoverFromEntry(
    RemoteLibraryWork work, {
    required String relativeImagePath,
  }) async {
    await initialize();
    final source = sourceById(work.sourceId);
    if (source == null) throw StateError('Remote media source not found');
    if (!source.allowEdit) {
      throw const HttpException('remote_source_edit_disabled');
    }

    final RemoteLibraryWork updatedWork;
    if (source.isLan) {
      final baseUri = Uri.parse(source.baseUrl);
      final uri = _resolveLanPath(
        baseUri,
        '/api/v1/works/${Uri.encodeComponent(work.workId)}/cover',
      );
      final json = await _sendLanJson(source, 'POST', uri, <String, Object?>{
        'relativePath': relativeImagePath,
      });
      final rawMap = json['work'];
      if (rawMap is! Map) throw const FormatException('invalid_lan_response');
      updatedWork = _lanWorkFromMap(
        source,
        baseUri,
        Map<String, Object?>.from(rawMap),
      );
    } else {
      final client = _webDavClientFactory(
        baseUri: Uri.parse(source.baseUrl),
        username: source.username,
        password: _secretsBySourceId[source.id],
      );
      try {
        updatedWork = await _webDavAdapter.setWorkCoverFromRelativePath(
          work: work,
          client: client,
          relativeImagePath: relativeImagePath,
        );
      } finally {
        client.close();
      }
    }
    await _replaceCachedWork(work, updatedWork);
    return updatedWork;
  }

  Future<void> toggleWorksPinned(String sourceId, List<String> workIds) async {
    if (workIds.isEmpty) return;
    await initialize();
    final srcIdx = _sources.indexWhere((s) => s.id == sourceId);
    if (srcIdx < 0) return;
    final source = _sources[srcIdx];
    final currentList = _worksBySourceId[sourceId] ?? const <RemoteLibraryWork>[];
    final selectedWorks = currentList
        .where((w) => workIds.contains(w.workId))
        .toList(growable: false);
    if (selectedWorks.isEmpty) return;

    Set<String> nextPinnedIds;
    if (source.isLan && source.allowEdit) {
      final baseUri = Uri.parse(source.baseUrl);
      final json = await _sendLanJson(
        source,
        'POST',
        _resolveLanPath(baseUri, '/api/v1/works/pin'),
        <String, Object?>{'workIds': workIds},
      );
      nextPinnedIds = (json['pinnedWorkIds'] as List? ?? const [])
          .map((e) => e.toString())
          .toSet();
    } else {
      nextPinnedIds = source.pinnedWorkIds.toSet();
      final allPinned = workIds.every(nextPinnedIds.contains);
      if (allPinned) {
        nextPinnedIds.removeAll(workIds);
      } else {
        nextPinnedIds.addAll(workIds);
      }
    }

    _sources[srcIdx] = source.copyWith(
      pinnedWorkIds: nextPinnedIds.toList(growable: false),
    );
    _refreshSourcesView();
    await _persistSources();

    final updatedWorks = currentList
        .map((w) => w.copyWith(isPinned: nextPinnedIds.contains(w.workId)))
        .toList(growable: false);
    _worksBySourceId[sourceId] = updatedWorks;
    await _saveCachedWorksToDisk(sourceId, updatedWorks);
    notifyListeners();
  }

  Future<void> commitRemoveWorks(String sourceId, List<String> workIds) async {
    if (workIds.isEmpty) return;
    await initialize();
    final srcIdx = _sources.indexWhere((s) => s.id == sourceId);
    if (srcIdx < 0) return;
    final source = _sources[srcIdx];

    if (source.isLan) {
      if (!source.allowEdit) {
        throw const HttpException('remote_source_edit_disabled');
      }
      final baseUri = Uri.parse(source.baseUrl);
      await _sendLanJson(
        source,
        'POST',
        _resolveLanPath(baseUri, '/api/v1/works/remove'),
        <String, Object?>{'workIds': workIds},
      );
    } else {
      final excluded = <String>{...source.excludedWorkIds, ...workIds};
      _sources[srcIdx] = source.copyWith(
        excludedWorkIds: excluded.toList(growable: false),
      );
      _refreshSourcesView();
      await _persistSources();
    }

    final removeSet = workIds.toSet();
    final currentList = _worksBySourceId[sourceId];
    if (currentList != null) {
      final nextList = currentList
          .where((w) => !removeSet.contains(w.workId))
          .toList(growable: false);
      _worksBySourceId[sourceId] = nextList;
      await _saveCachedWorksToDisk(sourceId, nextList);
    }
    for (final id in removeSet) {
      _treesByWorkKey.remove('$sourceId::$id');
    }
    notifyListeners();
  }

  Future<bool> playWork(RemoteLibraryWork work) async {
    final launcher = _playbackLauncher;
    if (launcher == null) throw StateError('Playback launcher unavailable');
    _directPlayEpoch++;
    final pending = _loadPlayableTracks(work);
    return launcher.playDirect(pending);
  }

  Future<bool> playTrack(RemoteLibraryWork work, AsmrTrackFile target) async {
    final launcher = _playbackLauncher;
    if (launcher == null) throw StateError('Playback launcher unavailable');
    final epoch = ++_directPlayEpoch;
    final pending = _loadPlayableTracks(work, startAt: target).then((tracks) {
      return epoch == _directPlayEpoch ? tracks : const <MusicTrack>[];
    });
    return launcher.playDirect(pending);
  }

  Future<bool> addTrackToPlaylist(
    RemoteLibraryWork work,
    AsmrTrackFile target,
  ) async {
    final launcher = _playbackLauncher;
    if (launcher == null) throw StateError('Playback launcher unavailable');
    final tracks = await _loadPlayableTracks(work, startAt: target);
    if (tracks.isEmpty) return false;
    return launcher.addTrackToPlaylist(tracks.first, workTracks: tracks);
  }

  Future<void> launchWorkQueue(RemoteLibraryWork work) async {
    final launcher = _playbackLauncher;
    if (launcher == null) throw StateError('Playback launcher unavailable');
    final tracks = await _loadPlayableTracks(work);
    if (tracks.isEmpty) return;
    await launcher.launchQueue(
      tracks,
      autoPlay: true,
      loopMode: tracks.length > 1
          ? SessionLoopMode.folderSequential
          : SessionLoopMode.single,
    );
  }

  Future<List<MusicTrack>> _loadPlayableTracks(
    RemoteLibraryWork work, {
    AsmrTrackFile? startAt,
  }) async {
    final tree = await ensureWorkTree(work);
    final mediaFiles = <AsmrTrackFile>[];
    final subtitleByStem = <String, AsmrTrackFile>{};
    final allSubtitlesInFolder = <String, List<AsmrTrackFile>>{};

    void collect(List<AsmrTrackFile> nodes, String folderKey) {
      for (final node in nodes) {
        if (node.isFolder) {
          collect(node.children, node.relativePath);
          continue;
        }
        if (node.isSubtitle) {
          subtitleByStem.putIfAbsent(node.stemKey, () => node);
          allSubtitlesInFolder
              .putIfAbsent(folderKey, () => <AsmrTrackFile>[])
              .add(node);
          continue;
        }
        if (node.isAudio || node.isVideo) {
          mediaFiles.add(node);
        }
      }
    }

    collect(tree, '');
    if (mediaFiles.isEmpty) return const <MusicTrack>[];

    var ordered = mediaFiles;
    if (startAt != null) {
      final idx = mediaFiles.indexWhere(
        (f) => f.relativePath == startAt.relativePath || f.hash == startAt.hash,
      );
      if (idx > 0) {
        ordered = <AsmrTrackFile>[
          ...mediaFiles.sublist(idx),
          ...mediaFiles.sublist(0, idx),
        ];
      }
    }

    final workSyncKey = CrossPlatformMediaIdentity.resolveWorkKey(
      rjCode: work.rjCode,
      groupTitle: work.title,
      groupKey: work.uniqueKey,
    );

    final built = <MusicTrack>[];
    for (final file in ordered) {
      final streamUrl = file.streamUrl ?? file.downloadUrl ?? '';
      if (streamUrl.isEmpty) continue;

      final pairedSub = _matchSubtitleForMedia(
        file,
        subtitleByStem,
        allSubtitlesInFolder,
      );
      final folderKey = path.posix.dirname(file.relativePath);
      final siblingSubs =
          allSubtitlesInFolder[folderKey == '.' ? '' : folderKey] ??
          const <AsmrTrackFile>[];

      Duration syncedPos = Duration.zero;
      DateTime? syncedAt;
      var syncedFav = false;
      if (workSyncKey.isNotEmpty) {
        final synced = await _syncService.findSyncedTrackState(
          workKey: workSyncKey,
          relativePath: file.relativePath,
        );
        if (synced != null) {
          syncedPos = Duration(milliseconds: synced.positionMs);
          if (synced.lastPlayedAtMs != null && synced.lastPlayedAtMs! > 0) {
            syncedAt = DateTime.fromMillisecondsSinceEpoch(
              synced.lastPlayedAtMs!,
            );
          }
          syncedFav = synced.isFavorite;
        }
      }

      final metadata = <String, Object?>{
        'remoteSourceId': work.sourceId,
        'remoteWorkId': work.workId,
        'workKey': work.uniqueKey,
        'rjCode': work.rjCode,
        'folderName': work.folderName,
        'hasSubtitle': work.hasSubtitle,
        if (work.directoryUri != null && work.directoryUri!.isNotEmpty)
          'directoryUri': work.directoryUri,
        'sourceId': work.rjCode.isNotEmpty ? work.rjCode : work.workId,
        'circleName': work.circleName,
        'voiceActors': work.voiceActors,
        'tags': work.tags,
        'trackRelativePath': file.relativePath,
        'playbackUrls': <String>[streamUrl],
        if (pairedSub?.streamUrl != null) ...<String, Object?>{
          'subtitleUrl': pairedSub!.streamUrl,
          'subtitleTitle': pairedSub.title,
        },
        if (siblingSubs.isNotEmpty)
          'availableSubtitles': [
            for (final sub in siblingSubs)
              if (sub.streamUrl != null)
                <String, String>{
                  'url': sub.streamUrl!,
                  'name': sub.title,
                },
          ],
      };

      final track = MusicTrack(
        path: streamUrl,
        displayName: path.posix.basenameWithoutExtension(file.title),
        groupKey: 'remote-work:${work.uniqueKey}',
        groupTitle: work.title,
        groupSubtitle: work.rjCode.isNotEmpty ? work.rjCode : work.circleName,
        isSingle: false,
        isVideo: file.isVideo,
        lastPlayedPosition: syncedPos,
        lastPlayedAt: syncedAt,
        isFavorite: syncedFav,
        tags: work.tags,
        remoteCoverUrl: work.coverUrl,
        remoteMetadataKind: MusicTrack.remoteMetadataKindRemoteSource,
        remoteMetadata: metadata,
        duration: file.duration,
        fileSizeBytes: file.size > 0 ? file.size : null,
      );
      _activeRemoteTracksByUrl[track.path] = track;
      built.add(track);
    }
    return built;
  }

  AsmrTrackFile? _matchSubtitleForMedia(
    AsmrTrackFile media,
    Map<String, AsmrTrackFile> subtitleByStem,
    Map<String, List<AsmrTrackFile>> subtitlesInFolder,
  ) {
    final direct = subtitleByStem[media.stemKey];
    if (direct != null) return direct;
    final dir = path.posix.dirname(media.relativePath);
    final candidates = subtitlesInFolder[dir == '.' ? '' : dir];
    if (candidates == null) return null;
    final mediaBaseLower = path.posix
        .basenameWithoutExtension(media.title)
        .toLowerCase();
    for (final sub in candidates) {
      final subBaseLower = path.posix
          .basenameWithoutExtension(sub.title)
          .toLowerCase();
      if (subBaseLower == mediaBaseLower ||
          subBaseLower.startsWith('$mediaBaseLower.')) {
        return sub;
      }
    }
    return null;
  }

  Future<List<RemoteLibraryWork>> _fetchLanWorks(
    RemoteMediaSource source,
  ) async {
    final baseUri = Uri.parse(source.baseUrl);
    final json = await _getLanJson(
      source,
      _resolveLanPath(baseUri, '/api/v1/works'),
    );
    final info = await _probeLanServerInfo(baseUri);
    if (info != null &&
        (info.allowSync != source.allowSync ||
            info.allowEdit != source.allowEdit)) {
      final idx = _sources.indexWhere((s) => s.id == source.id);
      if (idx >= 0) {
        _sources[idx] = source.copyWith(
          allowSync: info.allowSync,
          allowEdit: info.allowEdit,
        );
        _refreshSourcesView();
        await _persistSources();
      }
    }
    final rawWorks = json['works'];
    if (rawWorks is! List) return const <RemoteLibraryWork>[];
    final works = <RemoteLibraryWork>[];
    for (final item in rawWorks.whereType<Map<Object?, Object?>>()) {
      works.add(
        _lanWorkFromMap(source, baseUri, Map<String, Object?>.from(item)),
      );
    }
    return works;
  }

  RemoteLibraryWork _lanWorkFromMap(
    RemoteMediaSource source,
    Uri baseUri,
    Map<String, Object?> map,
  ) {
    final coverPath = map['coverPath']?.toString();
    final resolvedCover = coverPath == null || coverPath.isEmpty
        ? null
        : _resolveLanPath(baseUri, coverPath).toString();
    final workId = map['workId']?.toString() ?? '';
    final serverPinned = map['isPinned'] == true;
    final clientPinned = source.pinnedWorkIds.contains(workId);
    return RemoteLibraryWork(
      sourceId: source.id,
      workId: workId,
      rjCode: map['rjCode']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      folderName: map['folderName']?.toString() ?? '',
      circleName: map['circleName']?.toString() ?? '',
      voiceActors: (map['voiceActors'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      tags: (map['tags'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      releaseDateMs: (map['releaseDateMs'] as num?)?.toInt(),
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      trackCount: (map['trackCount'] as num?)?.toInt() ?? 0,
      salesCount: (map['salesCount'] as num?)?.toInt(),
      rating: (map['rating'] as num?)?.toDouble(),
      listenStatus: map['listenStatus']?.toString(),
      userRating: map['userRating'] as int? ?? (map['userRating'] as num?)?.toInt(),
      reviewText: map['reviewText']?.toString() ?? '',
      hasReviewNote: map['hasReviewNote'] == true,
      reviewUpdatedAtMs: (map['reviewUpdatedAtMs'] as num?)?.toInt() ?? 0,
      detailUpdatedAtMs: (map['detailUpdatedAtMs'] as num?)?.toInt() ?? 0,
      isPinned: serverPinned || (!source.allowEdit && clientPinned),
      hasSubtitle: map['hasSubtitle'] == true,
      coverUrl: resolvedCover,
      updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<AsmrTrackFile>> _fetchLanWorkTree(
    RemoteMediaSource source,
    RemoteLibraryWork work,
  ) async {
    final baseUri = Uri.parse(source.baseUrl);
    final json = await _getLanJson(
      source,
      _resolveLanPath(
        baseUri,
        '/api/v1/works/${Uri.encodeComponent(work.workId)}/tree',
      ),
    );
    final rawTree = json['tree'];
    if (rawTree is! List) return const <AsmrTrackFile>[];

    AsmrTrackFile mapNode(Map<String, dynamic> node, String parentPath) {
      final title = node['title']?.toString() ?? '';
      final relPath = parentPath.isEmpty ? title : '$parentPath/$title';
      final rawStream = node['mediaStreamUrl']?.toString();
      final resolvedUrl = rawStream == null || rawStream.isEmpty
          ? null
          : _resolveLanPath(baseUri, rawStream).toString();
      final children = (node['children'] as List? ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map((c) => mapNode(Map<String, dynamic>.from(c), relPath))
          .toList(growable: false);
      final durationSec = (node['duration'] as num?)?.toDouble() ?? 0;
      return AsmrTrackFile(
        hash: node['hash']?.toString() ?? relPath,
        title: title,
        type: node['type']?.toString() ?? 'file',
        streamUrl: resolvedUrl,
        downloadUrl: resolvedUrl,
        lowQualityUrl: null,
        duration: Duration(milliseconds: (durationSec * 1000).round()),
        size: (node['size'] as num?)?.toInt() ?? 0,
        children: children,
        workId: 0,
        workTitle: work.title,
        sourceId: work.rjCode,
        relativePath: relPath,
        workKey: work.uniqueKey,
      );
    }

    return rawTree
        .whereType<Map<Object?, Object?>>()
        .map((m) => mapNode(Map<String, dynamic>.from(m), ''))
        .toList(growable: false);
  }

  Future<Map<String, Object?>> _getLanJson(
    RemoteMediaSource source,
    Uri uri,
  ) async {
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      final token = _secretsBySourceId[source.id];
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode == HttpStatus.unauthorized ||
          response.statusCode == HttpStatus.forbidden) {
        await response.listen(null).cancel();
        throw const HttpException('remote_source_unauthorized');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.listen(null).cancel();
        throw HttpException('remote_source_http_${response.statusCode}');
      }
      final body = await response
          .timeout(const Duration(seconds: 20))
          .transform(utf8.decoder)
          .join();
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('invalid_lan_response');
      return Map<String, Object?>.from(decoded);
    } finally {
      client.close();
    }
  }

  Future<Map<String, Object?>> _sendLanJson(
    RemoteMediaSource source,
    String method,
    Uri uri,
    Map<String, Object?> payload,
  ) async {
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 12));
      final token = _secretsBySourceId[source.id];
      if (token != null && token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      final encoded = utf8.encode(jsonEncode(payload));
      request.contentLength = encoded.length;
      request.add(encoded);

      final response = await request.close().timeout(
        const Duration(seconds: 25),
      );
      final bodyText = await response
          .timeout(const Duration(seconds: 20))
          .transform(utf8.decoder)
          .join();
      Map<String, Object?>? decodedMap;
      if (bodyText.isNotEmpty) {
        try {
          final parsed = jsonDecode(bodyText);
          if (parsed is Map) decodedMap = Map<String, Object?>.from(parsed);
        } on Object {
          decodedMap = null;
        }
      }

      if (response.statusCode == HttpStatus.unauthorized) {
        throw const HttpException('remote_source_unauthorized');
      }
      if (response.statusCode == HttpStatus.forbidden) {
        final code = decodedMap?['error']?.toString() ?? '';
        if (code == 'edit_disabled') {
          throw const HttpException('remote_source_edit_disabled');
        }
        throw const HttpException('remote_source_unauthorized');
      }
      if (response.statusCode == HttpStatus.conflict) {
        final reason = decodedMap?['error']?.toString() ?? 'renameFailed';
        throw AudioDetailRenameException(reason);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('remote_source_http_${response.statusCode}');
      }
      return decodedMap ?? const <String, Object?>{};
    } finally {
      client.close();
    }
  }

  Future<({bool authRequired, bool allowSync, bool allowEdit})?>
  _probeLanServerInfo(Uri baseUri) async {
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await client
          .getUrl(_resolveLanPath(baseUri, '/api/v1/info'))
          .timeout(const Duration(seconds: 5));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.listen(null).cancel();
        return null;
      }
      final decoded = jsonDecode(await resp.transform(utf8.decoder).join());
      if (decoded is! Map) return null;
      return (
        authRequired: decoded['authRequired'] == true,
        allowSync: decoded['allowSync'] == true,
        allowEdit: decoded['allowEdit'] != false,
      );
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  Future<List<RemoteLibraryWork>> _overlayLocalSyncWorkStates(
    List<RemoteLibraryWork> works,
  ) async {
    if (works.isEmpty) return works;
    final out = <RemoteLibraryWork>[];
    for (final w in works) {
      final rj = CrossPlatformMediaIdentity.normalizeRjCode(w.rjCode);
      if (rj == null) {
        out.add(w);
        continue;
      }
      final synced = await _syncService.findSyncedWorkState('rj:$rj');
      if (synced == null) {
        out.add(w);
        continue;
      }
      final takeDetail = synced.detailUpdatedAtMs > w.detailUpdatedAtMs;
      final takeReview = synced.reviewUpdatedAtMs > w.reviewUpdatedAtMs;
      if (!takeDetail && !takeReview) {
        out.add(w);
        continue;
      }
      out.add(
        w.copyWith(
          title: takeDetail && synced.workTitle.isNotEmpty
              ? synced.workTitle
              : w.title,
          circleName: takeDetail && synced.circleName.isNotEmpty
              ? synced.circleName
              : w.circleName,
          voiceActors: takeDetail && synced.voiceActors.isNotEmpty
              ? synced.voiceActors
              : w.voiceActors,
          tags: takeDetail && synced.tags.isNotEmpty ? synced.tags : w.tags,
          releaseDateMs: takeDetail
              ? (synced.releaseDateMs ?? w.releaseDateMs)
              : w.releaseDateMs,
          salesCount: takeDetail
              ? (synced.salesCount ?? w.salesCount)
              : w.salesCount,
          rating: takeDetail ? (synced.rating ?? w.rating) : w.rating,
          detailUpdatedAtMs: takeDetail
              ? synced.detailUpdatedAtMs
              : w.detailUpdatedAtMs,
          listenStatus: takeReview ? synced.listenStatus : w.listenStatus,
          userRating: takeReview ? synced.userRating : w.userRating,
          reviewText: takeReview ? synced.reviewText : w.reviewText,
          hasReviewNote: takeReview
              ? synced.reviewText.trim().isNotEmpty
              : w.hasReviewNote,
          reviewUpdatedAtMs: takeReview
              ? synced.reviewUpdatedAtMs
              : w.reviewUpdatedAtMs,
        ),
      );
    }
    return out;
  }

  Future<void> _replaceCachedWork(
    RemoteLibraryWork previous,
    RemoteLibraryWork updated,
  ) async {
    final list = _worksBySourceId[previous.sourceId];
    if (list != null) {
      final idx = list.indexWhere((w) => w.workId == previous.workId);
      final next = List<RemoteLibraryWork>.of(list);
      if (idx >= 0) {
        next[idx] = updated;
      } else {
        next.add(updated);
      }
      _worksBySourceId[previous.sourceId] = next;
      await _saveCachedWorksToDisk(previous.sourceId, next);
    }
    if (previous.workId != updated.workId) {
      final oldTree = _treesByWorkKey.remove(previous.uniqueKey);
      if (oldTree != null && previous.directoryUri == updated.directoryUri) {
        _treesByWorkKey[updated.uniqueKey] = oldTree;
      }
      final srcIdx = _sources.indexWhere((s) => s.id == previous.sourceId);
      if (srcIdx >= 0 &&
          _sources[srcIdx].pinnedWorkIds.contains(previous.workId)) {
        final nextPins = <String>[
          for (final p in _sources[srcIdx].pinnedWorkIds)
            p == previous.workId ? updated.workId : p,
        ];
        _sources[srcIdx] = _sources[srcIdx].copyWith(pinnedWorkIds: nextPins);
        _refreshSourcesView();
        await _persistSources();
      }
    }
    notifyListeners();
  }

  Future<void> _mirrorWorkToSyncLedger(
    RemoteLibraryWork work, {
    bool detailEdited = false,
    bool reviewEdited = false,
  }) async {
    final rj = CrossPlatformMediaIdentity.normalizeRjCode(work.rjCode);
    if (rj == null) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final existing = await _syncService.findSyncedWorkState('rj:$rj');
    await _syncService.upsertSyncedWorkState(
      SyncWorkStateEntry(
        workKey: 'rj:$rj',
        rjCode: rj,
        workTitle: work.title,
        circleName: work.circleName,
        voiceActors: work.voiceActors,
        tags: work.tags,
        releaseDateMs: work.releaseDateMs,
        salesCount: work.salesCount,
        rating: work.rating,
        detailUpdatedAtMs: detailEdited
            ? nowMs
            : (work.detailUpdatedAtMs > 0
                  ? work.detailUpdatedAtMs
                  : (existing?.detailUpdatedAtMs ?? 0)),
        listenStatus: work.listenStatus,
        userRating: work.userRating,
        reviewText: work.reviewText,
        reviewUpdatedAtMs: reviewEdited
            ? nowMs
            : (work.reviewUpdatedAtMs > 0
                  ? work.reviewUpdatedAtMs
                  : (existing?.reviewUpdatedAtMs ?? 0)),
      ),
    );
  }

  Future<({Uint8List bytes, String extension})?> _tryDownloadCoverBytes(
    String coverUrl,
  ) async {
    final uri = Uri.tryParse(coverUrl);
    if (uri == null || !uri.hasScheme) return null;
    final client = _httpClientFactory()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 12));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        await resp.listen(null).cancel();
        return null;
      }
      const maxBytes = 20 * 1024 * 1024;
      final builder = BytesBuilder(copy: false);
      var total = 0;
      await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
        total += chunk.length;
        if (total > maxBytes) return null;
        builder.add(chunk);
      }
      final rawExt = path.posix
          .extension(uri.path)
          .replaceFirst('.', '')
          .toLowerCase();
      final ext = const {'jpg', 'jpeg', 'png', 'webp'}.contains(rawExt)
          ? rawExt
          : 'jpg';
      return (bytes: builder.takeBytes(), extension: ext);
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  void _updateCachedWorkMetadata(
    RemoteLibraryWork work, {
    String? coverUrl,
    bool? hasSubtitle,
  }) {
    final list = _worksBySourceId[work.sourceId];
    if (list == null) return;
    final idx = list.indexWhere((w) => w.workId == work.workId);
    if (idx < 0) return;
    final updated = List<RemoteLibraryWork>.of(list);
    updated[idx] = RemoteLibraryWork(
      sourceId: work.sourceId,
      workId: work.workId,
      rjCode: work.rjCode,
      title: work.title,
      folderName: work.folderName,
      circleName: work.circleName,
      voiceActors: work.voiceActors,
      tags: work.tags,
      releaseDateMs: work.releaseDateMs,
      durationMs: work.durationMs,
      trackCount: work.trackCount,
      salesCount: work.salesCount,
      rating: work.rating,
      listenStatus: work.listenStatus,
      userRating: work.userRating,
      hasReviewNote: work.hasReviewNote,
      hasSubtitle: hasSubtitle ?? work.hasSubtitle,
      coverUrl: coverUrl ?? work.coverUrl,
      directoryUri: work.directoryUri,
      updatedAtMs: work.updatedAtMs,
    );
    _worksBySourceId[work.sourceId] = updated;
    unawaited(_saveCachedWorksToDisk(work.sourceId, updated));
  }

  void _syncHeaderRules() {
    final rules = <RemoteSourceHeaderRule>[];
    for (final source in _sources) {
      final uri = Uri.tryParse(source.baseUrl);
      if (uri == null || uri.host.isEmpty) continue;
      final secret = _secretsBySourceId[source.id];
      if (source.isLan) {
        if (secret != null && secret.isNotEmpty) {
          rules.add(
            RemoteSourceHeaderRule.bearerToken(
              id: source.id,
              baseUri: uri,
              token: secret,
            ),
          );
        }
      } else if (source.username.isNotEmpty ||
          (secret != null && secret.isNotEmpty)) {
        rules.add(
          RemoteSourceHeaderRule.basicAuth(
            id: source.id,
            baseUri: uri,
            username: source.username,
            password: secret ?? '',
          ),
        );
      }
    }
    _headerRegistry.replaceAll(rules);
  }

  Future<bool> _persistSources() => AppPreferences.setString(
    _remoteSourcesPrefKey,
    jsonEncode(_sources.map((s) => s.toJson()).toList(growable: false)),
  );

  Future<File> _catalogCacheFile(String sourceId) async {
    final support = await _supportDirectoryProvider();
    final dir = Directory(path.join(support.path, 'remote_source_catalogs'));
    await dir.create(recursive: true);
    return File(path.join(dir.path, '$sourceId.json'));
  }

  Future<void> _loadCachedWorksFromDisk(String sourceId) async {
    try {
      final file = await _catalogCacheFile(sourceId);
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _worksBySourceId[sourceId] = decoded
            .whereType<Map<Object?, Object?>>()
            .map((m) => RemoteLibraryWork.fromJson(Map<String, Object?>.from(m)))
            .toList(growable: false);
      }
    } on Object {
      // Ignore corrupt cache files.
    }
  }

  Future<void> _saveCachedWorksToDisk(
    String sourceId,
    List<RemoteLibraryWork> works,
  ) async {
    try {
      final file = await _catalogCacheFile(sourceId);
      await file.writeAsString(
        jsonEncode(works.map((w) => w.toJson()).toList(growable: false)),
        flush: true,
      );
    } on Object {
      // Best-effort cache write.
    }
  }

  Future<void> _deleteCachedWorksOnDisk(String sourceId) async {
    try {
      final file = await _catalogCacheFile(sourceId);
      if (await file.exists()) await file.delete();
    } on Object {
      // Best-effort cleanup.
    }
  }

  static Uri _normalizeSourceBaseUri(
    String rawInput,
    RemoteMediaSourceType type,
  ) {
    var text = rawInput.trim();
    if (text.isEmpty) throw const FormatException('invalid_remote_url');
    if (!text.contains('://')) {
      text = 'http://$text';
    }
    var parsed = Uri.tryParse(text);
    if (parsed == null ||
        !const {'http', 'https'}.contains(parsed.scheme.toLowerCase()) ||
        parsed.host.isEmpty) {
      throw const FormatException('invalid_remote_url');
    }
    if (type == RemoteMediaSourceType.windowsLan && !parsed.hasPort) {
      parsed = parsed.replace(port: LanServerSettings.defaultHttpPort);
    }
    if (type == RemoteMediaSourceType.webDav) {
      return WebDavClient.normalizeDirectoryUri(parsed);
    }
    final cleanPath = parsed.path.endsWith('/') && parsed.path.length > 1
        ? parsed.path.substring(0, parsed.path.length - 1)
        : parsed.path;
    return parsed.replace(path: cleanPath);
  }

  static Uri _resolveLanPath(Uri baseUri, String apiPath) {
    final prefix = baseUri.path == '/' ? '' : baseUri.path;
    return baseUri.replace(path: '$prefix$apiPath');
  }

  static String _generateId() {
    final rng = Random.secure();
    return List<int>.generate(
      12,
      (_) => rng.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
