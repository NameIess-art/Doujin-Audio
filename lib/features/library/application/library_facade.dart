import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../../../core/app_language.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/media_file_support.dart';
import '../../../core/media/path_display.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/persistence/json_document_store.dart';
import '../../asmr/application/asmr_metadata_service.dart';
import '../../settings/application/app_preferences.dart';
import '../../settings/application/app_cache_service.dart';
import 'audio_detail_cache_service.dart';
import 'audio_detail_repository.dart';
import 'cover_artwork_cache_service.dart';
import 'dlsite_metadata_query.dart';
import 'dlsite_metadata_service.dart';
import 'library_snapshot_cache_service.dart';
import 'library_startup_maintenance_coordinator.dart';
import 'library_catalog.dart';
import 'library_entry_editor_service.dart';
import 'library_scan_models.dart';
import 'library_organizer.dart';
import 'library_service.dart';
import '../domain/audio_library_category.dart';
import '../domain/audio_detail_store.dart';
import '../domain/library_node.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'library_state_models.dart';

/// Owns the library-side services used by the compatibility audio facade.
///
/// Mutable library state remains owned exclusively by [LibraryService].
final class LibraryFacade implements LibraryCatalog {
  static const _watchedFoldersPreferenceKey = 'watched_folders_v1';
  static const _watchedLibrariesPreferenceKey = 'watched_libraries_v1';
  static const _groupOrderPreferenceKey = 'group_order_v1';
  static const _libraryExclusionsPreferenceKey = 'library_exclusions_v1';
  Future<void> _preferenceWriteTail = Future<void>.value();
  LibraryFacade({
    required this.databaseRepository,
    required this.detailCacheService,
    required this.metadataService,
    required this.asmrMetadataService,
    required LibraryService service,
    required this.snapshotCacheService,
    LibraryEntryEditorService? entryEditorService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) : _service = service,
       entryEditorService = entryEditorService ?? LibraryEntryEditorService(),
       _coverArtworkCacheService = coverArtworkCacheService;

  factory LibraryFacade.create({
    required LibraryPersistenceRepository databaseRepository,
    AudioDetailStore? audioDetailStore,
    JsonDocumentStore? jsonDocumentStore,
    AudioDetailRepository? detailRepository,
    AudioDetailCacheService? detailCacheService,
    DlsiteMetadataService? metadataService,
    AsmrMetadataService? asmrMetadataService,
    LibraryService? service,
    LibrarySnapshotCacheService? snapshotCacheService,
    LibraryEntryEditorService? entryEditorService,
    CoverArtworkCacheService? coverArtworkCacheService,
  }) {
    final resolvedDatabase = databaseRepository;
    final resolvedAudioDetailStore =
        audioDetailStore ??
        (resolvedDatabase is AudioDetailStore
            ? resolvedDatabase as AudioDetailStore
            : throw ArgumentError.value(
                resolvedDatabase,
                'databaseRepository',
                'must also implement AudioDetailStore',
              ));
    final resolvedDetailCache =
        detailCacheService ??
        AudioDetailCacheService(
          repository:
              detailRepository ??
              AudioDetailRepository(
                databaseRepository: resolvedAudioDetailStore,
                jsonDocumentStore: jsonDocumentStore,
              ),
        );
    final resolvedService = service ?? LibraryService();
    return LibraryFacade(
      databaseRepository: resolvedDatabase,
      detailCacheService: resolvedDetailCache,
      metadataService: metadataService ?? DlsiteMetadataService(),
      asmrMetadataService: asmrMetadataService ?? AsmrMetadataService(),
      service: resolvedService,
      snapshotCacheService:
          snapshotCacheService ??
          LibrarySnapshotCacheService(
            libraryService: resolvedService,
            detailCacheService: resolvedDetailCache,
          ),
      entryEditorService: entryEditorService ?? LibraryEntryEditorService(),
      coverArtworkCacheService: coverArtworkCacheService,
    );
  }

  final LibraryPersistenceRepository databaseRepository;
  final AudioDetailCacheService detailCacheService;
  final DlsiteMetadataService metadataService;
  final AsmrMetadataService asmrMetadataService;
  final LibraryService _service;
  final LibrarySnapshotCacheService snapshotCacheService;
  final LibraryEntryEditorService entryEditorService;
  CoverArtworkCacheService? _coverArtworkCacheService;
  Future<void>? _missingDurationBackfill;
  bool _missingDurationBackfillRequestedAgain = false;
  int _maintenanceEpoch = 0;
  bool _persistenceEnabled = true;
  bool _disposed = false;
  bool _interactionPaused = false;
  void Function(List<String> removedPaths)? _trackRemovalHandler;
  void Function()? _coverChangeHandler;
  late final LibraryStartupMaintenanceCoordinator
  _startupMaintenanceCoordinator = LibraryStartupMaintenanceCoordinator(
    waitForUiIdle: _waitForContinuousUiIdle,
    cleanupOrphanedImports: (retainedPaths) =>
        AppCacheService.cleanupOrphanedPersistentImports(retainedPaths),
    ensureEntries: _ensureEntriesForLoadedTracks,
    migrateAudioDetails: _importAudioDetailDocumentsOnce,
  );

  static const _audioDetailDocumentImportKey =
      'audio_detail_document_read_only_import_v2';
  static const _backupRestoreAuthoritativeKey =
      'backup_restore_authoritative_v1';

  LibraryState get state => _service.slice.state;
  Stream<LibraryState> get states => _service.slice.stream;
  List<LibraryNode> get libraryCards => snapshotCacheService.cards;
  @override
  List<MusicTrack> get library =>
      UnmodifiableListView<MusicTrack>(_service.library);
  int get structureRevision => _service.structureRevision;
  int get contentRevision => _service.contentRevision;
  bool get persistedUriReferencesReady => state.isInitialized;
  int get persistedUriReferenceRevision => structureRevision;
  Set<String> get persistedContentUris => <String>{
    ..._service.watchedFolders.where(PathMatcher.isContentUri),
    ..._service.watchedLibraries.where(PathMatcher.isContentUri),
    ..._service.library
        .map((track) => track.path)
        .where(PathMatcher.isContentUri),
  };
  List<String> get sortedLibraryTrackPaths =>
      UnmodifiableListView<String>(_service.sortedLibraryTrackPaths);
  Map<String, List<MusicTrack>> get tracksByGroup =>
      UnmodifiableMapView<String, List<MusicTrack>>(
        _service.tracksByGroup.map(
          (key, value) =>
              MapEntry(key, UnmodifiableListView<MusicTrack>(value)),
        ),
      );
  @override
  List<String> get watchedFolders =>
      UnmodifiableListView<String>(_service.watchedFolders);
  @override
  List<String> get watchedLibraries =>
      UnmodifiableListView<String>(_service.watchedLibraries);
  @override
  bool get isScanning => _service.isScanning;
  bool get isBackgroundScanning => _service.isBackgroundScanning;
  @override
  int get scanFoundCount => _service.scanFoundCount;
  @override
  int get scanDuplicateCount => _service.scanDuplicateCount;
  @override
  int get scanFailureCount => _service.scanFailureCount;
  AudioLibraryCategorySnapshot? get categorySnapshot =>
      snapshotCacheService.categorySnapshotSync;

  Future<void> loadPersistedState() async {
    final tracksFuture = databaseRepository.loadStartupTracks();
    final entriesFuture = databaseRepository.loadAllLibraryEntries();
    final preferences = await Future.wait<Object?>(<Future<Object?>>[
      AppPreferences.readJson<List<String>>(
        _groupOrderPreferenceKey,
        _decodeStringList,
      ),
      AppPreferences.readJson<List<String>>(
        _watchedFoldersPreferenceKey,
        _decodeStringList,
      ),
      AppPreferences.readJson<List<String>>(
        _watchedLibrariesPreferenceKey,
        _decodeStringList,
      ),
      AppPreferences.readJson<Map<String, dynamic>>(
        _libraryExclusionsPreferenceKey,
        _decodeStringMap,
      ),
    ]);
    final tracks = await tracksFuture;
    final entries = await entriesFuture;

    _service
      ..library.addAll(tracks)
      ..groupOrder.addAll((preferences[0] as List<String>?) ?? const <String>[])
      ..groupOrderSet.addAll(
        (preferences[0] as List<String>?) ?? const <String>[],
      )
      ..watchedFolders.addAll(
        (preferences[1] as List<String>?) ?? const <String>[],
      )
      ..watchedLibraries.addAll(
        (preferences[2] as List<String>?) ?? const <String>[],
      );
    final exclusions = preferences[3] as Map<String, dynamic>?;
    _decodeExclusionMap(
      exclusions?['folders'],
      _service.excludedLibraryFolders,
    );
    _decodeExclusionMap(exclusions?['tracks'], _service.excludedLibraryTracks);
    _service
      ..replaceLibraryEntries(entries)
      ..rebuildExclusionsFromEntries(entries);
    _applyExclusionsToLibrary();

    beginLibraryBatch();
    _service.libraryBatchChanged = _service.library.isNotEmpty;
    await endLibraryBatch(notify: false, waitForPersistence: false);
    _service.syncGroupOrderFromLibrary();
    // The startup batch already builds and caches the shallow card tree used
    // by the library page. Build the nested tree lazily when a folder is
    // expanded or a search actually needs it.
    _syncStateSlice(isInitialized: true);
  }

  Future<void> prepareForPersistedStateReset() async {
    _maintenanceEpoch++;
    _missingDurationBackfill = null;
    _missingDurationBackfillRequestedAgain = false;
    cancelScan();
    await _startupMaintenanceCoordinator.cancelAndWait();
    await _preferenceWriteTail;
    await detailCacheService.suspendAndWait();
  }

  Future<void> flushPendingPersistence() async {
    await _preferenceWriteTail;
    await detailCacheService.waitForPendingOperations();
  }

  Future<void> resetPersistedState() async {
    await prepareForPersistedStateReset();
    _service.scanProgressNotifyTimer?.cancel();
    _service
      ..scanProgressNotifyTimer = null
      ..library.clear()
      ..libraryByPath.clear()
      ..libraryIndexByPath.clear()
      ..tracksByGroup.clear()
      ..sortedLibraryTracks = const <MusicTrack>[]
      ..sortedLibraryTrackPaths = const <String>[]
      ..groupOrder.clear()
      ..groupOrderSet.clear()
      ..watchedFolders.clear()
      ..watchedLibraries.clear()
      ..excludedLibraryFolders.clear()
      ..excludedLibraryTracks.clear()
      ..libraryEntriesByLibrary.clear()
      ..isScanning = false
      ..isBackgroundScanning = false
      ..scanCurrentFolder = ''
      ..scanFoundCount = 0
      ..scanDuplicateCount = 0
      ..scanFailureCount = 0
      ..libraryBatchDepth = 0
      ..libraryBatchChanged = false
      ..libraryBatchChangedGroupOrder = false
      ..libraryBatchPersistTracks.clear()
      ..libraryBatchPersistEntriesByKey.clear()
      ..markStructureChanged();
    snapshotCacheService.clear();
    _coverArtworkCacheService?.invalidateAll();
    detailCacheService.resume();
    _syncStateSlice(isInitialized: false);
  }

  List<String> _decodeStringList(Object? value) {
    return (value as List<dynamic>).cast<String>();
  }

  Map<String, dynamic> _decodeStringMap(Object? value) {
    return (value as Map<Object?, Object?>).map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }

  void _decodeExclusionMap(Object? raw, Map<String, Set<String>> target) {
    target.clear();
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      final values = entry.value;
      if (values is! List) continue;
      target[path.normalize(entry.key.toString())] = values
          .map((value) => path.normalize(value.toString()))
          .where((value) => value.isNotEmpty)
          .toSet();
    }
  }

  void _applyExclusionsToLibrary() {
    final excludedTracks = _service.excludedLibraryTracks.values
        .expand((paths) => paths)
        .toSet();
    final excludedFolders = _service.excludedLibraryFolders.values
        .expand((paths) => paths)
        .toSet();
    if (excludedTracks.isEmpty && excludedFolders.isEmpty) return;
    final trackIndex = PathMembershipIndex(excludedTracks);
    final folderIndex = PathMembershipIndex(excludedFolders);
    removeTracksMatching(
      (track) =>
          trackIndex.containsEquivalent(track.path) ||
          folderIndex.containsAncestorOrEqual(track.path) ||
          folderIndex.containsAncestorOrEqual(track.groupKey),
    );
  }

  List<LibraryNode> get libraryTree {
    if (snapshotCacheService.treeSnapshotRevision !=
        _service.structureRevision) {
      unawaited(loadLibraryTree());
    }
    return snapshotCacheService.tree;
  }

  Future<List<LibraryNode>> loadLibraryTree() async {
    final snapshot = await snapshotCacheService.treeSnapshot(
      onCommitted: _syncStateSlice,
    );
    return snapshot.tree;
  }

  Future<FolderNode?> loadLibraryFolderTree(String folderPath) async {
    final tree = await loadLibraryTree();
    for (final node in tree.whereType<FolderNode>()) {
      if (PathMatcher.equalsNormalized(node.path, folderPath)) return node;
    }
    return null;
  }

  String? libraryRootForPath(String entityPath) {
    for (final libraryPath in _service.watchedLibraries) {
      if (PathMatcher.isWithinOrEqual(entityPath, libraryPath)) {
        return libraryPath;
      }
    }
    for (final folderPath in _service.watchedFolders) {
      if (PathMatcher.isWithinOrEqual(entityPath, folderPath)) {
        return folderPath;
      }
    }
    return null;
  }

  Future<AudioLibraryCategorySnapshot> audioLibraryCategorySnapshot({
    void Function()? onCommitted,
  }) => snapshotCacheService.categorySnapshot(
    onCommitted: () {
      _syncStateSlice();
      onCommitted?.call();
    },
  );

  Future<AudioDetailLoadResult> loadAudioDetail(AudioDetailTarget target) =>
      detailCacheService.load(canonicalAudioDetailTarget(target));

  Future<AudioDetailSaveResult> saveAudioDetail(AudioDetail detail) async {
    final result = await detailCacheService.save(
      detail.copyWith(target: canonicalAudioDetailTarget(detail.target)),
    );
    snapshotCacheService.markDetailChanged(result.detail);
    _syncStateSlice();
    return result;
  }

  Future<void> deleteAudioDetail(AudioDetailTarget target) async {
    await detailCacheService.delete(canonicalAudioDetailTarget(target));
    snapshotCacheService.markDetailChanged();
    _syncStateSlice();
  }

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCode(
    AudioDetailTarget target,
    String text,
  ) async {
    final result = await detailCacheService.prefillRjCodeFromText(
      canonicalAudioDetailTarget(target),
      text,
    );
    if (result != null) {
      snapshotCacheService.markDetailChanged(result.detail);
      _syncStateSlice();
    }
    return result;
  }

  @override
  Future<AudioDetailBackupImportResult> importAudioDetailBackups({
    bool onlyMissing = false,
  }) async {
    final targetsByKey = <String, AudioDetailTarget>{};
    for (final track in _service.library) {
      final target = canonicalAudioDetailTarget(
        audioDetailTargetForTrack(track),
      );
      targetsByKey[AudioLibraryDetailKey.forTarget(target)] = target;
    }
    Iterable<AudioDetailTarget> targets = targetsByKey.values;
    if (onlyMissing && targetsByKey.isNotEmpty) {
      final orderedTargets = targetsByKey.values.toList(growable: false);
      final databaseDetails = await detailCacheService.loadMany(orderedTargets);
      targets = <AudioDetailTarget>[
        for (var index = 0; index < orderedTargets.length; index++)
          if (databaseDetails[index].detail.isEmpty) orderedTargets[index],
      ];
    }
    final result = await detailCacheService.importBackupsMany(targets);
    await databaseRepository.saveAppSetting(
      _backupRestoreAuthoritativeKey,
      '0',
    );
    if (result.changedDetails.isNotEmpty) {
      snapshotCacheService.markDetailChanged();
      _syncStateSlice();
    }
    return result;
  }

  @override
  Future<void> prefillAudioDetailRjCodeFromText(
    String folderPath,
    String displayName,
  ) async {
    await prefillAudioDetailRjCode(
      AudioDetailTarget.libraryRootFolder(folderPath),
      displayName,
    );
  }

  AudioDetailTarget audioDetailTargetForTrack(MusicTrack track) {
    if (track.isSingle) {
      return AudioDetailTarget.singleAudioFile(track.path);
    }
    return AudioDetailTarget.libraryRootFolder(
      const LibraryOrganizer().rootPathForTrack(
        track,
        _service.watchedFolders,
        watchedLibraries: _service.watchedLibraries,
      ),
    );
  }

  AudioDetailTarget canonicalAudioDetailTarget(AudioDetailTarget target) {
    if (!target.isLibraryRootFolder) return target;
    return AudioDetailTarget.libraryRootFolder(
      const LibraryOrganizer().rootFolderPath(
        target.targetPath,
        _service.watchedFolders,
        watchedLibraries: _service.watchedLibraries,
      ),
    );
  }

  AudioDetailTarget audioDetailTargetForPath(String trackPath) {
    final track = trackByPath(trackPath);
    return track == null
        ? AudioDetailTarget.singleAudioFile(trackPath)
        : audioDetailTargetForTrack(track);
  }

  Future<void> backfillMissingLibraryDurations({
    Future<Duration?> Function(String path)? durationReader,
  }) {
    final inFlight = _missingDurationBackfill;
    if (inFlight != null) {
      _missingDurationBackfillRequestedAgain = true;
      return inFlight;
    }

    final epoch = _maintenanceEpoch;
    final task = () async {
      do {
        _missingDurationBackfillRequestedAgain = false;
        await _backfillMissingLibraryDurations(
          epoch: epoch,
          durationReader: durationReader,
        );
      } while (_missingDurationBackfillRequestedAgain &&
          !_disposed &&
          epoch == _maintenanceEpoch);
    }();
    _missingDurationBackfill = task;
    unawaited(
      task.then<void>(
        (_) => _clearMissingDurationBackfill(task),
        onError: (Object error, StackTrace stackTrace) {
          _clearMissingDurationBackfill(task);
        },
      ),
    );
    return task;
  }

  void _clearMissingDurationBackfill(Future<void> task) {
    if (identical(_missingDurationBackfill, task)) {
      _missingDurationBackfill = null;
    }
  }

  Future<void> _backfillMissingLibraryDurations({
    required int epoch,
    Future<Duration?> Function(String path)? durationReader,
  }) async {
    final targetsByKey = <String, AudioDetailTarget>{};
    final tracksByTargetKey = <String, List<MusicTrack>>{};
    for (final track in List<MusicTrack>.of(_service.library)) {
      final target = audioDetailTargetForTrack(track);
      final key = <String>[
        target.targetType.dbValue,
        PathMatcher.equivalenceKey(target.targetPath),
      ].join('|');
      targetsByKey.putIfAbsent(key, () => target);
      tracksByTargetKey.putIfAbsent(key, () => <MusicTrack>[]).add(track);
    }
    if (targetsByKey.isEmpty) return;

    final targets = targetsByKey.values.toList(growable: false);
    var loadResults = await detailCacheService.loadMany(targets);
    if (_disposed || epoch != _maintenanceEpoch) return;
    final targetsWithMissingDetails = <AudioDetailTarget>[];
    for (var index = 0; index < loadResults.length; index++) {
      if (loadResults[index].detail.isEmpty) {
        targetsWithMissingDetails.add(targets[index]);
      }
    }
    if (targetsWithMissingDetails.isNotEmpty) {
      // A rescan can expose a track before the explicit backup import finishes.
      // Restore sparse details before automatic duration updates reach SQLite.
      final restoredDatabaseIsAuthoritative =
          await databaseRepository.loadAppSetting(
            _backupRestoreAuthoritativeKey,
          ) ==
          '1';
      final import = restoredDatabaseIsAuthoritative
          ? const AudioDetailBackupImportResult()
          : await detailCacheService.importBackupsMany(
              targetsWithMissingDetails,
            );
      if (import.changedDetails.isNotEmpty) {
        snapshotCacheService.markDetailChanged();
        _syncStateSlice();
      }
      if (_disposed || epoch != _maintenanceEpoch) return;
      loadResults = await detailCacheService.loadMany(targets);
      if (_disposed || epoch != _maintenanceEpoch) return;
    }
    for (var index = 0; index < targets.length; index++) {
      if (_disposed || epoch != _maintenanceEpoch) return;
      final detail = loadResults[index].detail;
      final key = <String>[
        detail.target.targetType.dbValue,
        PathMatcher.equivalenceKey(detail.target.targetPath),
      ].join('|');
      final targetTracks = tracksByTargetKey[key];
      if (targetTracks == null || targetTracks.isEmpty) continue;
      final hasMissingTrack = targetTracks.any(
        (track) => track.duration <= Duration.zero,
      );
      if (detail.duration != null && !hasMissingTrack) continue;

      final probe = await _probeDurationForTracks(
        targetTracks,
        durationReader: durationReader,
      );
      if (_disposed || epoch != _maintenanceEpoch) return;
      final committed = await _commitDurationUpdates(
        probe.updatedTracks,
        epoch: epoch,
      );
      if (!committed) return;
      if (_disposed || epoch != _maintenanceEpoch) return;
      final duration = probe.totalDuration;
      if (duration == null || detail.duration != null) continue;
      final latestDetail =
          detailCacheService.resolvedDetail(detail.target) ?? detail;
      if (latestDetail.duration == null) {
        final updated = await detailCacheService.updateDerivedFields(
          latestDetail.copyWith(duration: duration),
        );
        if (_disposed || epoch != _maintenanceEpoch) return;
        snapshotCacheService.markDetailChanged(updated);
        _syncStateSlice();
      }
    }
  }

  Future<Duration?> calculateMissingLibraryDuration(
    String targetPath, {
    Future<Duration?> Function(String path)? durationReader,
  }) async {
    final epoch = _maintenanceEpoch;
    final singleTracks = _service.library
        .where(
          (track) =>
              track.isSingle &&
              PathMatcher.equalsNormalized(track.path, targetPath),
        )
        .toList(growable: false);
    final targetTracks = singleTracks.isNotEmpty
        ? singleTracks
        : _service.library
              .where(
                (track) =>
                    !track.isSingle &&
                    (PathMatcher.isWithinOrEqual(track.groupKey, targetPath) ||
                        PathMatcher.isWithinOrEqual(track.path, targetPath)),
              )
              .toList(growable: false);
    final probe = await _probeDurationForTracks(
      targetTracks,
      durationReader: durationReader,
    );
    final committed = await _commitDurationUpdates(
      probe.updatedTracks,
      epoch: epoch,
    );
    return committed ? probe.totalDuration : null;
  }

  Future<({Duration? totalDuration, List<MusicTrack> updatedTracks})>
  _probeDurationForTracks(
    List<MusicTrack> targetTracks, {
    Future<Duration?> Function(String path)? durationReader,
  }) async {
    if (targetTracks.isEmpty) {
      return (totalDuration: null, updatedTracks: const <MusicTrack>[]);
    }

    final tracksToUpdate = <MusicTrack>[];
    var totalDuration = Duration.zero;
    var hasUnknownDuration = false;
    final missingTracks = <MusicTrack>[];
    for (final track in targetTracks) {
      if (track.duration > Duration.zero) {
        totalDuration += track.duration;
      } else {
        missingTracks.add(track);
      }
    }

    Future<Duration?> resolveDuration(MusicTrack track) async {
      try {
        if (durationReader != null) return durationReader(track.path);
        final nativeDuration = await FileCachePlatformGateway.instance
            .resolveMediaDuration(track.path);
        if (nativeDuration != null && nativeDuration > Duration.zero) {
          return nativeDuration;
        }
        return null;
      } catch (error, stackTrace) {
        AppLogService.warning(
          'library_duration_probe_failed path=${track.path}',
          error: error,
          stackTrace: stackTrace,
        );
        return null;
      }
    }

    const concurrency = 2;
    for (var start = 0; start < missingTracks.length; start += concurrency) {
      final end = (start + concurrency).clamp(0, missingTracks.length);
      final chunk = missingTracks.sublist(start, end);
      final durations = await Future.wait(chunk.map(resolveDuration));
      for (var index = 0; index < chunk.length; index++) {
        final track = chunk[index];
        final duration = durations[index] ?? Duration.zero;
        if (duration > Duration.zero) {
          totalDuration += duration;
          tracksToUpdate.add(track.copyWith(duration: duration));
        } else {
          hasUnknownDuration = true;
          AppLogService.warning(
            'library_duration_unresolved path=${track.path} video=${track.isVideo}',
          );
        }
      }
    }

    return (
      totalDuration: !hasUnknownDuration && totalDuration > Duration.zero
          ? totalDuration
          : null,
      updatedTracks: List<MusicTrack>.unmodifiable(tracksToUpdate),
    );
  }

  Future<bool> _commitDurationUpdates(
    List<MusicTrack> tracks, {
    required int epoch,
  }) async {
    if (_disposed || epoch != _maintenanceEpoch) return false;
    if (tracks.isEmpty) return true;
    await databaseRepository.upsertTracks(tracks);
    if (_disposed || epoch != _maintenanceEpoch) return false;
    for (final track in tracks) {
      final index = _service.libraryIndexByPath[track.path];
      if (index != null) _service.library[index] = track;
      _service.libraryByPath[track.path] = track;
    }
    _service.rebuildLibraryIndexes();
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
    return true;
  }

  DlsiteMetadataQuery buildDlsiteMetadataQuery(AudioDetail detail) =>
      DlsiteMetadataQuery.fromDetail(detail);

  Future<DlsiteMetadata> fetchPreferredMetadata(
    String rjCode, {
    required AppLanguage language,
  }) async {
    DlsiteMetadata? primary;
    try {
      primary = await asmrMetadataService.fetchByRjCode(
        rjCode,
        language: language,
      );
    } catch (_) {
      return metadataService.fetchByRjCode(rjCode, language: language);
    }
    if (!_metadataHasMissingValue(primary)) return primary;
    try {
      final fallback = await metadataService.fetchByRjCode(
        rjCode,
        language: language,
      );
      return _mergeMetadata(primary, fallback);
    } catch (_) {
      return primary;
    }
  }

  Future<List<DlsiteMetadata>> searchPreferredMetadataByTitles(
    Iterable<String> titles, {
    required AppLanguage language,
  }) async {
    List<DlsiteMetadata> primary;
    try {
      primary = await asmrMetadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
    } catch (_) {
      return metadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
    }
    if (primary.every((metadata) => !_metadataHasMissingValue(metadata))) {
      return primary;
    }
    try {
      final fallback = await metadataService.searchByTitleCandidates(
        titles,
        language: language,
      );
      final fallbackByKey = <String, DlsiteMetadata>{};
      for (final metadata in fallback) {
        final key = _metadataMergeKey(metadata);
        if (key.isNotEmpty) fallbackByKey.putIfAbsent(key, () => metadata);
      }
      final singleFallback = primary.length == 1 && fallback.length == 1
          ? fallback.single
          : null;
      return primary
          .map((metadata) {
            final match =
                fallbackByKey[_metadataMergeKey(metadata)] ?? singleFallback;
            return match == null ? metadata : _mergeMetadata(metadata, match);
          })
          .toList(growable: false);
    } catch (_) {
      return primary;
    }
  }

  bool _metadataHasMissingValue(DlsiteMetadata metadata) {
    return metadata.rjCode.trim().isEmpty ||
        metadata.workTitle.trim().isEmpty ||
        metadata.circleName.trim().isEmpty ||
        metadata.voiceActors.isEmpty ||
        metadata.tags.isEmpty ||
        metadata.releaseDate == null ||
        metadata.duration == null ||
        metadata.salesCount == null ||
        metadata.rating == null;
  }

  String _metadataMergeKey(DlsiteMetadata metadata) {
    final rjCode = metadata.rjCode.trim().toUpperCase();
    if (rjCode.isNotEmpty) return 'rj:$rjCode';
    final title = metadata.workTitle.trim().toLowerCase();
    return title.isEmpty ? '' : 'title:$title';
  }

  DlsiteMetadata _mergeMetadata(
    DlsiteMetadata primary,
    DlsiteMetadata fallback,
  ) {
    String fallbackString(String value, String fallbackValue) {
      return value.trim().isNotEmpty ? value : fallbackValue;
    }

    String? fallbackNullableString(String? value, String? fallbackValue) {
      return value != null && value.trim().isNotEmpty ? value : fallbackValue;
    }

    return primary.copyWith(
      rjCode: fallbackString(primary.rjCode, fallback.rjCode),
      workTitle: fallbackString(primary.workTitle, fallback.workTitle),
      circleName: fallbackString(primary.circleName, fallback.circleName),
      voiceActors: primary.voiceActors.isNotEmpty
          ? primary.voiceActors
          : fallback.voiceActors,
      tags: primary.tags.isNotEmpty ? primary.tags : fallback.tags,
      releaseDate: primary.releaseDate ?? fallback.releaseDate,
      duration: primary.duration ?? fallback.duration,
      salesCount: primary.salesCount ?? fallback.salesCount,
      rating: primary.rating ?? fallback.rating,
      coverUrl: fallbackNullableString(primary.coverUrl, fallback.coverUrl),
    );
  }

  AudioDetail? resolvedAudioDetail(AudioDetailTarget target) =>
      detailCacheService.resolvedDetail(canonicalAudioDetailTarget(target));
  @override
  MusicTrack? trackByPath(String trackPath) => _service.trackByPath(trackPath);

  MusicTrack? updatePlaybackHistory({
    required String trackPath,
    required Duration position,
    required DateTime now,
    required bool updatePlayedAt,
  }) {
    final track = _service.libraryByPath[trackPath];
    if (track == null) return null;
    final updated = _copyTrack(
      track,
      lastPlayedPosition: position,
      lastPlayedAt: updatePlayedAt ? now : track.lastPlayedAt,
    );
    _service.libraryByPath[track.path] = updated;
    final index = _service.libraryIndexByPath[track.path];
    if (index != null &&
        index < _service.library.length &&
        _service.library[index].path == track.path) {
      _service.library[index] = updated;
    }
    return updated;
  }

  List<MusicTrack> tracksInGroup(String groupKey) =>
      List<MusicTrack>.unmodifiable(
        _service.tracksByGroup[groupKey] ?? const <MusicTrack>[],
      );
  int compareTracks(MusicTrack first, MusicTrack second) =>
      _service.compareTracks(first, second);
  String? resolvedCoverPathForTrack(MusicTrack? track, {String? trackPath}) =>
      coverArtworkCacheService.resolvedForTrack(track, trackPath: trackPath);
  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => coverArtworkCacheService.resolvedForPlaybackTrack(
    track,
    trackPath: trackPath,
  );
  String? resolvedCoverPathForRemoteCover(String url) =>
      coverArtworkCacheService.resolvedForRemoteCover(url);
  String? resolvedCoverPathForFolder(String folderPath) =>
      coverArtworkCacheService.resolvedForFolder(folderPath);
  Future<String?> coverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => coverArtworkCacheService.futureForTrack(track, trackPath: trackPath);
  Future<String?> playbackCoverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => coverArtworkCacheService.futureForPlaybackTrack(
    track,
    trackPath: trackPath,
  );
  Future<String?> coverPathFutureForFolder(String folderPath) =>
      coverArtworkCacheService.futureForFolder(folderPath);
  Future<String?> coverPathFutureForRemoteCover(String url) =>
      coverArtworkCacheService.futureForRemoteCover(url);
  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
  }) => coverArtworkCacheService.discoverCoverCandidatesInFolder(
    folderPath,
    selectedCoverPath: selectedCoverPath,
  );

  Future<String?> setFolderManualCover(
    String folderPath,
    String imagePath, {
    bool newlySaved = false,
    String? sourcePath,
  }) async {
    final storedCoverPath = await coverArtworkCacheService
        .setFolderCoverSelection(
          folderPath,
          imagePath,
          newlySaved: newlySaved,
          sourcePath: sourcePath,
        );
    _coverChangeHandler?.call();
    return storedCoverPath;
  }

  Future<DlsiteMetadataApplyResult> applyDlsiteMetadata(
    AudioDetail detail,
    DlsiteMetadata metadata, {
    required bool saveCover,
    required AppLanguage language,
    bool missingOnly = false,
  }) async {
    String metadataStringValue(String current, String fetched) {
      return missingOnly && current.trim().isNotEmpty ? current : fetched;
    }

    List<String> metadataListValue(List<String> current, List<String> fetched) {
      return missingOnly && current.isNotEmpty ? current : fetched;
    }

    final nextDetail = detail.copyWith(
      rjCode: metadataStringValue(detail.rjCode, metadata.rjCode),
      workTitle: metadataStringValue(detail.workTitle, metadata.workTitle),
      circleName: metadataStringValue(detail.circleName, metadata.circleName),
      voiceActors: metadataListValue(detail.voiceActors, metadata.voiceActors),
      tags: metadataListValue(detail.tags, metadata.tags),
      releaseDate: missingOnly && detail.releaseDate != null
          ? detail.releaseDate
          : metadata.releaseDate,
      duration: missingOnly && detail.duration != null
          ? detail.duration
          : metadata.duration,
      salesCount: missingOnly && detail.salesCount != null
          ? detail.salesCount
          : metadata.salesCount,
      rating: missingOnly && detail.rating != null
          ? detail.rating
          : metadata.rating,
    );
    final saveResult = await saveAudioDetail(nextDetail);

    String? coverPath;
    Object? coverError;
    final coverUrl = metadata.coverUrl;
    if (saveCover &&
        nextDetail.target.isLibraryRootFolder &&
        coverUrl != null) {
      try {
        final downloadedCover = await metadataService.downloadCover(
          coverUrl: coverUrl,
          folderPath: nextDetail.target.targetPath,
          rjCode: metadata.rjCode,
          language: language,
        );
        coverPath = downloadedCover.displayPath;
        await setFolderManualCover(
          nextDetail.target.targetPath,
          coverPath,
          newlySaved: true,
          sourcePath: downloadedCover.sourcePath,
        );
      } catch (error) {
        coverError = error;
      }
    }

    return DlsiteMetadataApplyResult(
      detail: saveResult.detail,
      coverPath: coverPath,
      coverError: coverError,
    );
  }

  void setInteractionPaused(bool paused) {
    if (_interactionPaused == paused) return;
    _interactionPaused = paused;
  }

  String? libraryEntryDisplayNameForPath(
    String libraryPath,
    String entryPath,
  ) => _service.libraryEntryDisplayNameForPath(libraryPath, entryPath);
  List<String> excludedTracksForLibrary(String libraryPath) =>
      _service.excludedTracksForLibrary(libraryPath);
  List<String> excludedFoldersForLibrary(String libraryPath) =>
      _service.excludedFoldersForLibrary(libraryPath);
  List<String> childFoldersForLibrary(String libraryPath) =>
      _service.childFoldersForLibrary(libraryPath);
  @override
  List<LibraryEntry> libraryEntriesForLibrary(String libraryPath) =>
      _service.libraryEntriesForLibrary(libraryPath);
  @override
  LibraryEntrySnapshot libraryEntrySnapshotForLibrary(String libraryPath) =>
      _service.libraryEntrySnapshotForLibrary(libraryPath);
  @override
  LibraryExclusionMatcher libraryExclusionMatcherForLibrary(
    String libraryPath,
  ) => _service.libraryExclusionMatcherForLibrary(libraryPath);
  @override
  bool hasLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    return (_service
                .excludedLibraryFolders[normalizedLibraryPath]
                ?.isNotEmpty ??
            false) ||
        (_service.excludedLibraryTracks[normalizedLibraryPath]?.isNotEmpty ??
            false);
  }

  bool isLibraryTrackExplicitlyExcluded(String libraryPath, String trackPath) =>
      _service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath);
  bool isLibraryFolderExplicitlyExcluded(
    String libraryPath,
    String folderPath,
  ) => _service.isLibraryFolderExplicitlyExcluded(libraryPath, folderPath);
  @override
  bool isLibraryPathExcluded(String libraryPath, String entityPath) =>
      _service.isLibraryPathExcluded(libraryPath, entityPath);
  bool isLibraryPathInheritedExcluded(String libraryPath, String entityPath) =>
      _service.isLibraryPathInheritedExcluded(libraryPath, entityPath);

  @override
  bool isScanGenerationActive(int generation) =>
      _service.isScanning &&
      generation != 0 &&
      generation == _service.scanGeneration;

  @override
  void addWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _service.addWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  @override
  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _service.addWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  @override
  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _service.removeWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _service.removeWatchedLibrary(
      folderPath,
      onPersist: () => unawaited(_saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  Future<void> _saveWatchedFolders() async {
    final value = json.encode(_service.watchedFolders);
    await _queuePreferenceWrite(
      () => AppPreferences.setString(_watchedFoldersPreferenceKey, value),
    );
  }

  Future<void> _saveWatchedLibraries() async {
    final value = json.encode(_service.watchedLibraries);
    await _queuePreferenceWrite(
      () => AppPreferences.setString(_watchedLibrariesPreferenceKey, value),
    );
  }

  void configurePersistence({required bool enabled}) {
    _persistenceEnabled = enabled;
  }

  void attachTrackRemovalHandler(
    void Function(List<String> removedPaths) handler,
  ) {
    _trackRemovalHandler ??= handler;
  }

  void attachCoverChangeHandler(void Function() handler) {
    _coverChangeHandler ??= handler;
  }

  void detachRuntimeHandlers() {
    _trackRemovalHandler = null;
    _coverChangeHandler = null;
  }

  @override
  void recordLibraryEntriesForTracks(
    String libraryPath,
    List<MusicTrack> tracks, {
    Iterable<String> folderPaths = const <String>[],
    bool persist = true,
    LibraryExclusionMatcher? exclusionMatcher,
    LibraryEntrySnapshot? entrySnapshot,
  }) {
    var entries = _service.buildLibraryEntries(
      libraryPath,
      tracks,
      folderPaths: folderPaths,
      exclusionMatcher: exclusionMatcher,
    );
    if (entrySnapshot != null) {
      entries = entries
          .where(entrySnapshot.entryNeedsRefresh)
          .toList(growable: false);
    }
    if (entries.isEmpty) return;
    _service.replaceLibraryEntries(entries);
    entrySnapshot?.remember(entries);
    _queueOrPersistLibraryEntries(entries, persist: persist);
  }

  void recordEntriesForTracks(List<MusicTrack> tracks, {bool persist = true}) {
    final entries = <LibraryEntry>[];
    final tracksByLibrary = <String, List<MusicTrack>>{};
    for (final track in tracks) {
      final libraryPath = _service.libraryPathForTrack(track);
      if (libraryPath == null || libraryPath.isEmpty) continue;
      tracksByLibrary.putIfAbsent(libraryPath, () => <MusicTrack>[]).add(track);
    }
    for (final entry in tracksByLibrary.entries) {
      entries.addAll(_service.buildLibraryEntries(entry.key, entry.value));
    }
    if (entries.isEmpty) return;
    _service.replaceLibraryEntries(entries);
    _queueOrPersistLibraryEntries(entries, persist: persist);
  }

  @override
  void addTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (tracks.isEmpty) return;
    final mutation = _service.addTracks(tracks, persist: persist);
    if (mutation.tracks.isEmpty) return;
    recordEntriesForTracks(mutation.tracks, persist: persist);
    if (mutation.batched) return;
    _markLibraryStructureChanged();
    if (persist && _persistenceEnabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder) unawaited(_saveGroupOrder());
    }
  }

  @override
  void addOrReplaceTracks(
    List<MusicTrack> tracks, {
    bool notify = true,
    bool persist = true,
  }) {
    if (tracks.isEmpty) return;
    final mutation = _service.addOrReplaceTracks(tracks, persist: persist);
    if (mutation.tracks.isEmpty) return;
    recordEntriesForTracks(mutation.tracks, persist: persist);
    if (mutation.batched) return;
    _markLibraryStructureChanged();
    if (persist && _persistenceEnabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder || mutation.didReplaceGroup) {
        unawaited(_saveGroupOrder());
      }
    }
  }

  void _markLibraryStructureChanged() {
    _coverArtworkCacheService?.invalidateAll();
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
  }

  List<String> removeTracksMatching(
    bool Function(MusicTrack track) test, {
    bool persist = true,
  }) {
    final mutation = _service.removeTracksWhere(test);
    final removedPaths = mutation.tracks
        .map((track) => track.path)
        .toList(growable: false);
    if (removedPaths.isEmpty) return const <String>[];
    _trackRemovalHandler?.call(removedPaths);
    if (persist && _persistenceEnabled) {
      unawaited(databaseRepository.deleteTracks(removedPaths));
    }
    if (!mutation.batched) {
      _markLibraryStructureChanged();
      if (persist && _persistenceEnabled) {}
    }
    return removedPaths;
  }

  @override
  void removeTracksByPath(Iterable<String> trackPaths) {
    final paths = trackPaths.toSet();
    if (paths.isEmpty) return;
    removeTracksMatching((track) => paths.contains(track.path));
  }

  @override
  void removeTracksDeletedFromFolder(
    String folderPath,
    Set<String> scannedPaths,
  ) {
    final normalizedFolder = PathMatcher.normalize(folderPath);
    final scannedPathIndex = PathMembershipIndex(scannedPaths);
    removeTracksMatching((track) {
      if (!PathMatcher.isWithinOrEqualNormalized(
        track.path,
        normalizedFolder,
      )) {
        return false;
      }
      return !scannedPathIndex.containsEquivalent(track.path);
    });
  }

  @override
  void removeLibraryEntriesDeletedFromFolder(
    String libraryPath,
    String folderPath,
    Set<String> retainedPaths,
  ) {
    final removedPaths = _service.removeLibraryEntriesMissingFromFolderScan(
      libraryPath,
      folderPath,
      retainedPaths,
    );
    if (removedPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  @override
  void removeLibraryEntriesByPaths(
    String libraryPath,
    Iterable<String> entryPaths,
  ) {
    final removedPaths = _service.removeLibraryEntriesByPaths(
      libraryPath,
      entryPaths,
    );
    if (removedPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  @override
  void clearLibraryExclusions(String libraryPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final result = _service.clearLibraryExclusions(normalizedLibraryPath);
    if (!result.changed) return;
    if (result.restoredTracks.isNotEmpty) {
      addOrReplaceTracks(result.restoredTracks, notify: false);
    } else {
      _syncStateSlice();
    }
    if (_persistenceEnabled) {
      if (result.restoredEntryPaths.isNotEmpty) {
        unawaited(
          databaseRepository.setLibraryEntriesState(
            normalizedLibraryPath,
            result.restoredEntryPaths,
            LibraryEntryState.active,
          ),
        );
      }
      unawaited(_saveLibraryExclusions());
    }
  }

  Future<void> removeTrackFromLibrary(String trackPath) async {
    final removedTrack = _service.trackByPath(trackPath);
    if (removedTrack == null) return;
    final removedPaths = removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, trackPath),
      persist: false,
    );
    if (removedPaths.isEmpty) return;
    _service.syncGroupOrderFromLibrary();
    if (_persistenceEnabled) {
      await Future.wait(<Future<void>>[
        databaseRepository.deleteTracks(removedPaths),
        _saveGroupOrder(),
      ]);
    }
  }

  Future<void> removeFolderFromLibrary(String folderPath) async {
    final normalizedFolderPath = PathMatcher.normalize(folderPath);
    final wasWatched = _service.watchedFolders.any(
      (folder) => PathMatcher.equalsNormalized(folder, normalizedFolderPath),
    );
    final removedPaths = removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, normalizedFolderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, normalizedFolderPath),
      persist: false,
    );
    if (removedPaths.isEmpty && !wasWatched) return;

    final removedWatchedFolder = _service.removeWatchedFolder(
      normalizedFolderPath,
    );
    _service
      ..libraryEntriesByLibrary.remove(normalizedFolderPath)
      ..syncGroupOrderFromLibrary();
    _markLibraryStructureChanged();
    final persistenceTasks = <Future<void>>[
      deleteAudioDetail(
        AudioDetailTarget.libraryRootFolder(normalizedFolderPath),
      ),
    ];
    if (_persistenceEnabled) {
      if (removedPaths.isNotEmpty) {
        persistenceTasks.add(databaseRepository.deleteTracks(removedPaths));
      }
      persistenceTasks.add(
        databaseRepository.deleteLibraryEntriesForLibrary(normalizedFolderPath),
      );
      if (removedWatchedFolder) {
        persistenceTasks.add(_saveWatchedFolders());
      }
      persistenceTasks.add(_saveGroupOrder());
    }
    await Future.wait(persistenceTasks);
  }

  Future<void> removeLibrary(String libraryPath) async {
    if (isScanning) cancelScan();
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    beginLibraryBatch();
    final removal = _service.removeLibrary(normalizedLibraryPath);
    final removedTrackPaths = removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, normalizedLibraryPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, normalizedLibraryPath),
      persist: false,
    );
    final changed = removal.changed || removedTrackPaths.isNotEmpty;
    if (changed) _syncStateSlice();

    final detailTargets = <AudioDetailTarget>{
      AudioDetailTarget.libraryRootFolder(normalizedLibraryPath),
      for (final folderPath in removal.removedFolderPaths)
        AudioDetailTarget.libraryRootFolder(folderPath),
    };
    final persistenceTasks = <Future<void>>[
      endLibraryBatch(),
      _deleteRemovedLibraryPersistence(normalizedLibraryPath, detailTargets),
    ];
    if (_persistenceEnabled) {
      if (removedTrackPaths.isNotEmpty) {
        persistenceTasks.add(
          databaseRepository.deleteTracks(removedTrackPaths),
        );
      }
      if (removal.changed) {
        persistenceTasks
          ..add(_saveWatchedFolders())
          ..add(_saveWatchedLibraries())
          ..add(_saveLibraryExclusions());
      }
    }
    await Future.wait(persistenceTasks);
  }

  Future<void> _deleteRemovedLibraryPersistence(
    String libraryPath,
    Set<AudioDetailTarget> detailTargets,
  ) async {
    await detailCacheService.deleteMany(detailTargets);
    snapshotCacheService.markDetailChanged();
    if (_persistenceEnabled) {
      await databaseRepository.deleteLibraryEntriesForLibrary(libraryPath);
    }
    _syncStateSlice();
  }

  void excludeLibraryFolder(String libraryPath, String folderPath) {
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = _service.canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final mutation = _service.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      true,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.excluded,
        ),
      );
    }
    _syncStateSlice();
    unawaited(
      _removeExcludedFolderFromActiveLibrary(
        normalizedLibraryPath,
        normalizedFolderPath,
      ),
    );
  }

  void excludeLibraryTrack(String libraryPath, String trackPath) {
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final mutation = _service.setLibraryTrackExcluded(
      libraryPath,
      normalizedTrackPath,
      true,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          libraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.excluded,
        ),
      );
    }
    _syncStateSlice();
    unawaited(
      _removeExcludedTrackFromActiveLibrary(libraryPath, normalizedTrackPath),
    );
  }

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) {
    if (excluded) {
      excludeLibraryFolder(libraryPath, folderPath);
      return;
    }
    final normalizedLibraryPath = PathMatcher.normalize(libraryPath);
    final normalizedFolderPath = _service.canonicalLibraryFolderPath(
      normalizedLibraryPath,
      folderPath,
    );
    final mutation = _service.setLibraryFolderExcluded(
      normalizedLibraryPath,
      normalizedFolderPath,
      false,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          normalizedLibraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.active,
        ),
      );
    }
    unawaited(
      _restoreExcludedFolder(normalizedLibraryPath, normalizedFolderPath),
    );
    _syncStateSlice();
  }

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) {
    if (excluded) {
      excludeLibraryTrack(libraryPath, trackPath);
      return;
    }
    final normalizedTrackPath = PathMatcher.normalize(trackPath);
    final mutation = _service.setLibraryTrackExcluded(
      libraryPath,
      normalizedTrackPath,
      false,
      onPersist: () {
        if (_persistenceEnabled) unawaited(_saveLibraryExclusions());
      },
    );
    if (!mutation.changed) return;
    if (mutation.affectedEntryPaths.isNotEmpty && _persistenceEnabled) {
      unawaited(
        databaseRepository.setLibraryEntriesState(
          libraryPath,
          mutation.affectedEntryPaths,
          LibraryEntryState.active,
        ),
      );
    }
    unawaited(_restoreExcludedTrack(libraryPath, normalizedTrackPath));
    _syncStateSlice();
  }

  Future<void> _removeExcludedFolderFromActiveLibrary(
    String libraryPath,
    String folderPath,
  ) async {
    await Future<void>.value();
    if (!_service.isLibraryFolderExplicitlyExcluded(libraryPath, folderPath)) {
      return;
    }
    beginLibraryBatch();
    removeTracksMatching(
      (track) =>
          PathMatcher.isWithinOrEqual(track.path, folderPath) ||
          PathMatcher.isWithinOrEqual(track.groupKey, folderPath),
    );
    await endLibraryBatch(waitForPersistence: false);
  }

  Future<void> _removeExcludedTrackFromActiveLibrary(
    String libraryPath,
    String trackPath,
  ) async {
    await Future<void>.value();
    if (!_service.isLibraryTrackExplicitlyExcluded(libraryPath, trackPath)) {
      return;
    }
    beginLibraryBatch();
    removeTracksMatching(
      (track) => PathMatcher.equalsNormalized(track.path, trackPath),
    );
    await endLibraryBatch(waitForPersistence: false);
  }

  Future<void> _restoreExcludedTrack(
    String libraryPath,
    String trackPath,
  ) async {
    await Future<void>.value();
    if (_service.isLibraryPathExcluded(libraryPath, trackPath)) return;
    if (_service.libraryByPath.containsKey(trackPath)) return;
    final entry = _service.libraryEntryForPath(libraryPath, trackPath);
    if (entry != null && entry.isTrack && entry.isActive) {
      await _addRestoredTracks(<MusicTrack>[entry.toTrack()]);
      return;
    }
    final isContentUri = PathMatcher.isContentUri(trackPath);
    FileStat? stat;
    if (!isContentUri) {
      try {
        final file = File(trackPath);
        if (!await file.exists()) return;
        stat = await file.stat();
      } catch (_) {
        return;
      }
    }
    final parentFolder = path.dirname(trackPath);
    final folderName = path.basename(parentFolder);
    if (_service.isLibraryPathExcluded(libraryPath, trackPath)) return;
    await _addRestoredTracks(<MusicTrack>[
      MusicTrack(
        path: trackPath,
        displayName: PathDisplay.fileName(trackPath, withoutExtension: true),
        groupKey: parentFolder,
        groupTitle: folderName.isEmpty
            ? PathDisplay.folderName(parentFolder)
            : PathDisplay.normalizeDisplaySegment(folderName),
        groupSubtitle: parentFolder,
        isSingle: false,
        isVideo: isVideoMediaFile(trackPath),
        scannedAt: DateTime.now(),
        fileSizeBytes: stat?.size,
        modifiedAt: stat?.modified,
      ),
    ]);
  }

  Future<void> _restoreExcludedFolder(
    String libraryPath,
    String folderPath,
  ) async {
    await Future<void>.value();
    if (_service.isLibraryPathExcluded(libraryPath, folderPath)) return;
    final persistedTracks = _service
        .libraryEntriesForLibrary(libraryPath)
        .where(
          (entry) =>
              entry.isTrack &&
              entry.isActive &&
              PathMatcher.isWithinOrEqual(entry.path, folderPath) &&
              !_service.isLibraryPathExcluded(libraryPath, entry.path),
        )
        .map((entry) => entry.toTrack())
        .where((track) => !_service.libraryByPath.containsKey(track.path))
        .toList(growable: false);
    if (persistedTracks.isNotEmpty) {
      await _addRestoredTracks(persistedTracks);
      return;
    }

    final restoredTracks = await entryEditorService.loadRestorableTracks(
      folderPath,
    );
    final candidates = restoredTracks
        .where(
          (track) => !_service.isLibraryPathExcluded(libraryPath, track.path),
        )
        .toList(growable: false);
    if (candidates.isNotEmpty) {
      await _addRestoredTracks(candidates);
    }
  }

  Future<void> _addRestoredTracks(List<MusicTrack> tracks) async {
    if (tracks.isEmpty) return;
    beginLibraryBatch();
    addOrReplaceTracks(tracks, notify: false);
    await endLibraryBatch(waitForPersistence: false);
  }

  Future<AudioDetailRenameResult> renameAudioDetailTarget(
    AudioDetail detail,
  ) async {
    return renameAudioDetailTargetToName(detail, detail.workTitle);
  }

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    final name = targetName.trim();
    if (name.isEmpty) {
      throw const AudioDetailRenameException('missingTitle');
    }
    final oldTarget = detail.target;

    final safeName = PathDisplay.safeFileName(name);
    if (safeName.isEmpty) {
      throw const AudioDetailRenameException('invalidTitle');
    }

    final oldPath = PathMatcher.normalize(oldTarget.targetPath);
    final renamedPath = await entryEditorService.renameAudioDetailTarget(
      oldTarget,
      safeName,
    );
    if (renamedPath == null) {
      throw const AudioDetailRenameException('renameFailed');
    }
    final newPath = PathMatcher.normalize(renamedPath);
    if (PathMatcher.equalsNormalized(oldPath, newPath)) {
      return AudioDetailRenameResult(detail: detail, renamed: false);
    }

    final newTarget = AudioDetailTarget(
      targetType: oldTarget.targetType,
      targetPath: newPath,
    );
    if (oldTarget.isLibraryRootFolder) {
      await _retargetLibraryFolder(oldPath, newPath, safeName);
    } else {
      await _retargetSingleTrack(oldPath, newPath, safeName);
    }

    final renamedDetail = detail.copyWith(
      target: newTarget,
      cardCoverPath: _retargetNullablePath(
        detail.cardCoverPath,
        oldPath,
        newPath,
      ),
    );
    final saveResult = await detailCacheService.retarget(
      oldTarget,
      renamedDetail,
    );
    snapshotCacheService.markDetailChanged(saveResult.detail);
    _syncStateSlice();
    final backupFailed = saveResult.documentFailed;
    await deleteAudioDetail(oldTarget);
    return AudioDetailRenameResult(
      detail: saveResult.detail,
      renamed: true,
      backupFailed: backupFailed,
    );
  }

  Future<void> _retargetLibraryFolder(
    String oldFolderPath,
    String newFolderPath,
    String folderName,
  ) async {
    await coverArtworkCacheService.retargetFolderCoverSelection(
      oldFolderPath,
      newFolderPath,
    );
    await databaseRepository.retargetTimeSegmentLabelsWithinPath(
      oldRoot: oldFolderPath,
      newRoot: newFolderPath,
    );
    final retargetResult = _service.retargetLibraryFolder(
      oldFolderPath,
      newFolderPath,
      folderName,
    );
    coverArtworkCacheService.invalidateFolders([oldFolderPath, newFolderPath]);
    snapshotCacheService.markStructureChanged();
    _syncStateSlice();
    await databaseRepository.replaceTrackPaths(retargetResult.retargetedTracks);
    await databaseRepository.deleteLibraryEntriesForLibrary(oldFolderPath);
    if (retargetResult.retargetedEntries.isNotEmpty) {
      await databaseRepository.upsertLibraryEntries(
        retargetResult.retargetedEntries,
      );
    }
    await _saveWatchedFolders();
    await _saveWatchedLibraries();
    await _saveLibraryExclusions();
    await _saveGroupOrder();
  }

  Future<void> _retargetSingleTrack(
    String oldTrackPath,
    String newTrackPath,
    String displayName,
  ) async {
    await databaseRepository.retargetTimeSegmentLabels(
      oldTrackKey: PathMatcher.normalize(oldTrackPath),
      newTrackKey: PathMatcher.normalize(newTrackPath),
    );
    final updatedTrack = _service.retargetSingleTrack(
      oldTrackPath,
      newTrackPath,
      displayName,
    );
    if (updatedTrack != null) {
      coverArtworkCacheService.invalidateAll();
      snapshotCacheService.markStructureChanged();
      _syncStateSlice();
      await databaseRepository.deleteTracks([oldTrackPath]);
      await databaseRepository.upsertTracks([updatedTrack]);
    }
  }

  String? _retargetNullablePath(String? value, String oldRoot, String newRoot) {
    if (value == null || !PathMatcher.isWithinOrEqual(value, oldRoot)) {
      return value;
    }
    return PathMatcher.replaceWithinOrEqual(value, oldRoot, newRoot);
  }

  MusicTrack _copyTrack(
    MusicTrack track, {
    String? path,
    String? displayName,
    String? groupKey,
    String? groupTitle,
    String? groupSubtitle,
    String? coverCachePath,
    String? lyricsPath,
    String? manualCoverPath,
    Duration? lastPlayedPosition,
    DateTime? lastPlayedAt,
  }) {
    return MusicTrack(
      path: path ?? track.path,
      displayName: displayName ?? track.displayName,
      groupKey: groupKey ?? track.groupKey,
      groupTitle: groupTitle ?? track.groupTitle,
      groupSubtitle: groupSubtitle ?? track.groupSubtitle,
      isSingle: track.isSingle,
      isVideo: track.isVideo,
      scannedAt: track.scannedAt,
      fileSizeBytes: track.fileSizeBytes,
      modifiedAt: track.modifiedAt,
      lastPlayedPosition: lastPlayedPosition ?? track.lastPlayedPosition,
      lastPlayedAt: lastPlayedAt ?? track.lastPlayedAt,
      isFavorite: track.isFavorite,
      tags: track.tags,
      coverCachePath: coverCachePath ?? track.coverCachePath,
      lyricsPath: lyricsPath ?? track.lyricsPath,
      manualCoverPath: manualCoverPath ?? track.manualCoverPath,
      duration: track.duration,
    );
  }

  Future<void> _saveLibraryExclusions() {
    Map<String, List<String>> encode(Map<String, Set<String>> source) {
      return source.map(
        (key, value) => MapEntry(key, value.toList(growable: false)..sort()),
      );
    }

    final value = json.encode(<String, Object?>{
      'folders': encode(_service.excludedLibraryFolders),
      'tracks': encode(_service.excludedLibraryTracks),
    });
    return _queuePreferenceWrite(
      () => AppPreferences.setString(_libraryExclusionsPreferenceKey, value),
    );
  }

  Future<void> _saveGroupOrder() {
    final value = json.encode(_service.groupOrder);
    return _queuePreferenceWrite(
      () => AppPreferences.setString(_groupOrderPreferenceKey, value),
    );
  }

  Future<void> _queuePreferenceWrite(Future<void> Function() write) {
    final task = _preferenceWriteTail.then((_) => write());
    _preferenceWriteTail = task.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      AppLogService.error(
        'library_preference_write_failed',
        error: error,
        stackTrace: stackTrace,
      );
    });
    return task;
  }

  @override
  void beginLibraryBatch() {
    _service.libraryBatchDepth++;
  }

  @override
  void beginStagedLibraryRefresh() {
    beginLibraryBatch();
  }

  @override
  int applyStagedLibraryRefreshChunk({
    required String sourceFolderPath,
    required String libraryRoot,
    List<MusicTrack> tracks = const <MusicTrack>[],
    Iterable<String> folderPaths = const <String>[],
    Iterable<String> removeWatchedFolders = const <String>[],
    Iterable<String> addWatchedFolders = const <String>[],
    Iterable<String> removeTrackPaths = const <String>[],
    Iterable<String> removeEntryPaths = const <String>[],
    bool persist = true,
  }) {
    for (final folderPath in removeWatchedFolders) {
      removeWatchedFolder(folderPath, notify: false);
    }
    if (tracks.isNotEmpty || folderPaths.isNotEmpty) {
      recordLibraryEntriesForTracks(
        libraryRoot,
        tracks,
        folderPaths: folderPaths,
        persist: persist,
      );
    }
    for (final folderPath in addWatchedFolders) {
      addWatchedFolder(folderPath, notify: false);
    }
    final beforeCount = _service.library.length;
    if (tracks.isNotEmpty) {
      addOrReplaceTracks(tracks, notify: false, persist: persist);
    }
    final tracksToRemove = removeTrackPaths.toList(growable: false);
    if (tracksToRemove.isNotEmpty) removeTracksByPath(tracksToRemove);
    final entriesToRemove = removeEntryPaths.toList(growable: false);
    if (entriesToRemove.isNotEmpty) {
      removeLibraryEntriesByPaths(libraryRoot, entriesToRemove);
    }
    return _service.library.length - beforeCount;
  }

  @override
  Future<void> finishStagedLibraryRefresh({bool waitForPersistence = false}) {
    return endLibraryBatch(waitForPersistence: waitForPersistence);
  }

  @override
  Future<void> endLibraryBatch({
    bool notify = true,
    bool waitForPersistence = true,
  }) async {
    if (_service.libraryBatchDepth <= 0) return;
    _service.libraryBatchDepth--;
    if (_service.libraryBatchDepth > 0) return;

    final didChangeLibrary = _service.libraryBatchChanged;
    final entriesToPersist = List<LibraryEntry>.from(
      _service.libraryBatchPersistEntriesByKey.values,
    );
    if (!didChangeLibrary && entriesToPersist.isEmpty) return;
    final tracksToPersist = List<MusicTrack>.from(
      _service.libraryBatchPersistTracks,
    );
    final didChangeGroupOrder = _service.libraryBatchChangedGroupOrder;
    _service
      ..libraryBatchChanged = false
      ..libraryBatchChangedGroupOrder = false
      ..libraryBatchPersistTracks.clear()
      ..libraryBatchPersistEntriesByKey.clear();

    if (didChangeLibrary) {
      _coverArtworkCacheService?.invalidateAll();
      _service.syncGroupOrderFromLibrary();
      final derivedGeneration = ++_service.libraryDerivedGeneration;
      final derivedSnapshot = await AppLogService.measureAsync(
        'library_derived_snapshot_build',
        () => compute(
          buildLibraryDerivedSnapshot,
          LibraryDerivedSnapshotPayload(
            tracks: List<MusicTrack>.unmodifiable(_service.library),
            watchedFolders: List<String>.unmodifiable(_service.watchedFolders),
            watchedLibraries: List<String>.unmodifiable(
              _service.watchedLibraries,
            ),
          ),
        ),
        details: <String, Object?>{'tracks': _service.library.length},
      );
      if (derivedGeneration == _service.libraryDerivedGeneration) {
        _service
          ..library = List<MusicTrack>.of(derivedSnapshot.library)
          ..libraryByPath = Map<String, MusicTrack>.of(
            derivedSnapshot.libraryByPath,
          )
          ..libraryIndexByPath = Map<String, int>.of(
            derivedSnapshot.libraryIndexByPath,
          )
          ..tracksByGroup = Map<String, List<MusicTrack>>.of(
            derivedSnapshot.tracksByGroup,
          )
          ..sortedLibraryTracks = derivedSnapshot.sortedLibraryTracks
          ..sortedLibraryTrackPaths = derivedSnapshot.sortedLibraryTrackPaths
          ..markStructureChanged();
        snapshotCacheService
          ..markStructureChanged()
          ..adoptCardSnapshot(derivedSnapshot.cardSnapshot);
        _syncStateSlice();
      }
    }

    final persistenceTasks = <Future<void>>[];
    if (_persistenceEnabled) {
      if (tracksToPersist.isNotEmpty) {
        persistenceTasks.add(databaseRepository.upsertTracks(tracksToPersist));
      }
      if (entriesToPersist.isNotEmpty) {
        persistenceTasks.add(
          databaseRepository.upsertLibraryEntries(entriesToPersist),
        );
      }
      if (didChangeLibrary && didChangeGroupOrder) {
        persistenceTasks.add(_saveGroupOrder());
      }
    }
    if (waitForPersistence) {
      await Future.wait(persistenceTasks);
    } else {
      for (final task in persistenceTasks) {
        unawaited(task);
      }
    }
  }

  void _queueOrPersistLibraryEntries(
    List<LibraryEntry> entries, {
    required bool persist,
  }) {
    if (entries.isEmpty || !persist || !_persistenceEnabled) return;
    if (_service.libraryBatchDepth > 0) {
      for (final entry in entries) {
        final key = <String>[
          PathMatcher.normalize(entry.libraryPath),
          PathMatcher.normalize(entry.path),
          entry.kind.dbValue,
        ].join('\x1F');
        _service.libraryBatchPersistEntriesByKey[key] = entry;
      }
      return;
    }
    unawaited(databaseRepository.upsertLibraryEntries(entries));
  }

  @override
  int tryBeginScan({required String source, bool background = false}) {
    if (_service.isScanning) return 0;
    _service.scanGenerationSeed++;
    final generation = _service.scanGenerationSeed;
    _setScanning(true, background: background);
    _service
      ..scanGeneration = generation
      ..scanCurrentFolder = source
      ..scanStage = FolderScanStage.preparing
      ..scanProcessed = 0
      ..scanTotal = null;
    _syncStateSlice();
    return generation;
  }

  @override
  void cancelScan() {
    if (!_service.isScanning) return;
    _setScanning(false);
    unawaited(FileCachePlatformGateway.instance.cancelActiveFolderScan());
  }

  @override
  void finishScan(int generation) {
    if (!isScanGenerationActive(generation)) return;
    _setScanning(false);
  }

  @override
  void setScanProgress({
    String? currentFolder,
    int? foundCount,
    int? duplicateCount,
    int? failureCount,
    int? generation,
    FolderScanStage? stage,
    int? processed,
    int? total,
  }) {
    if (generation != null && generation != _service.scanGeneration) return;
    final nextFolder = currentFolder ?? _service.scanCurrentFolder;
    final nextFoundCount = foundCount ?? _service.scanFoundCount;
    final nextDuplicateCount = duplicateCount ?? _service.scanDuplicateCount;
    final nextFailureCount = failureCount ?? _service.scanFailureCount;
    final nextStage = stage ?? _service.scanStage;
    final nextProcessed = processed ?? _service.scanProcessed;
    final nextTotal = total ?? _service.scanTotal;
    final changed =
        nextFolder != _service.scanCurrentFolder ||
        nextFoundCount != _service.scanFoundCount ||
        nextDuplicateCount != _service.scanDuplicateCount ||
        nextFailureCount != _service.scanFailureCount ||
        nextStage != _service.scanStage ||
        nextProcessed != _service.scanProcessed ||
        nextTotal != _service.scanTotal;
    if (!changed) return;
    if (currentFolder != null) _service.scanCurrentFolder = currentFolder;
    if (foundCount != null) _service.scanFoundCount = foundCount;
    if (duplicateCount != null) {
      _service.scanDuplicateCount = duplicateCount;
    }
    if (failureCount != null) _service.scanFailureCount = failureCount;
    if (stage != null) _service.scanStage = stage;
    if (processed != null) _service.scanProcessed = processed;
    if (total != null) _service.scanTotal = total;
    if (_service.isBackgroundScanning) return;
    _scheduleScanProgressSync();
  }

  void _setScanning(bool scanning, {bool background = false}) {
    if (_service.isScanning == scanning &&
        _service.isBackgroundScanning == background) {
      return;
    }
    _service
      ..isScanning = scanning
      ..isBackgroundScanning = scanning && background;
    _service.scanProgressNotifyTimer?.cancel();
    _service.scanProgressNotifyTimer = null;
    if (scanning) {
      _service
        ..scanCurrentFolder = ''
        ..scanFoundCount = 0
        ..scanDuplicateCount = 0
        ..scanFailureCount = 0
        ..scanStage = FolderScanStage.preparing
        ..scanProcessed = 0
        ..scanTotal = null;
    } else {
      _service
        ..scanGeneration = 0
        ..scanStage = FolderScanStage.idle
        ..scanTotal = null;
    }
    _syncStateSlice();
  }

  void _scheduleScanProgressSync() {
    if (!_service.isScanning) {
      _syncStateSlice();
      return;
    }
    if (_service.scanProgressNotifyTimer != null) return;
    _service.scanProgressNotifyTimer = Timer(
      const Duration(milliseconds: 160),
      () {
        _service.scanProgressNotifyTimer = null;
        if (_service.isScanning) _syncStateSlice();
      },
    );
  }

  CoverArtworkCacheService get coverArtworkCacheService {
    final coverService = _coverArtworkCacheService;
    if (coverService == null) {
      throw StateError('LibraryFacade cover service has not been attached.');
    }
    return coverService;
  }

  void attachCoverArtworkCacheService(
    CoverArtworkCacheService Function() create,
  ) {
    _coverArtworkCacheService ??= create();
  }

  void configureCoverArtworkRuntime({
    required bool Function(String key) isActiveCoverKey,
    required void Function() onActiveCoverChanged,
  }) {
    _coverArtworkCacheService ??= CoverArtworkCacheService(
      libraryService: _service,
      databaseRepository: databaseRepository,
      audioDetailCacheService: detailCacheService,
      isActiveCoverKey: isActiveCoverKey,
      onActiveCoverChanged: onActiveCoverChanged,
    );
  }

  void cancelPendingScanProgressNotification() {
    _service.scanProgressNotifyTimer?.cancel();
    _service.scanProgressNotifyTimer = null;
  }

  void syncPresentationState({bool? isInitialized}) {
    _syncStateSlice(isInitialized: isInitialized);
  }

  void updateTrackSnapshot(MusicTrack updatedTrack) {
    final currentTrack = _service.libraryByPath[updatedTrack.path];
    if (currentTrack == null) return;
    _service.libraryByPath[updatedTrack.path] = updatedTrack;
    final index = _service.library.indexOf(currentTrack);
    if (index >= 0) _service.library[index] = updatedTrack;
    if (_persistenceEnabled) {
      unawaited(databaseRepository.upsertTracks(<MusicTrack>[updatedTrack]));
    }
  }

  Future<LibraryTreeSnapshot> ensureCardSnapshot() {
    return snapshotCacheService.cardSnapshot(onCommitted: _syncStateSlice);
  }

  void schedulePostStartupMaintenance() {
    final retainedPaths = _service.library
        .map((track) => track.path)
        .toList(growable: false);
    _startupMaintenanceCoordinator.schedule(retainedPaths);
  }

  Future<bool> _waitForContinuousUiIdle(Duration quietWindow) async {
    DateTime? idleSince;
    while (!_disposed) {
      if (_interactionPaused) {
        idleSince = null;
      } else {
        idleSince ??= DateTime.now();
        if (DateTime.now().difference(idleSince) >= quietWindow) return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 160));
    }
    return false;
  }

  Future<void> _ensureEntriesForLoadedTracks(int epoch) async {
    if (_disposed || !_startupMaintenanceCoordinator.isCurrent(epoch)) return;
    final knownLibraries = <String>{
      ..._service.watchedLibraries,
      ..._service.watchedFolders,
    };
    if (knownLibraries.isEmpty || _service.library.isEmpty) return;
    final entriesToPersist = <LibraryEntry>[];
    for (final libraryPath in knownLibraries) {
      if (_service.hasLibraryEntriesForLibrary(libraryPath)) continue;
      final tracks = _service.library
          .where(
            (track) =>
                PathMatcher.isWithinOrEqual(track.path, libraryPath) ||
                PathMatcher.isWithinOrEqual(track.groupKey, libraryPath),
          )
          .toList(growable: false);
      if (tracks.isEmpty) continue;
      entriesToPersist.addAll(
        _service.buildLibraryEntries(libraryPath, tracks),
      );
    }
    if (entriesToPersist.isEmpty) return;
    if (_disposed || !_startupMaintenanceCoordinator.isCurrent(epoch)) return;
    _service.replaceLibraryEntries(entriesToPersist);
    await databaseRepository.upsertLibraryEntries(entriesToPersist);
  }

  Future<void> _importAudioDetailDocumentsOnce(int epoch) async {
    if (_disposed || !_startupMaintenanceCoordinator.isCurrent(epoch)) return;
    final completed = await databaseRepository.loadAppSetting(
      _audioDetailDocumentImportKey,
    );
    if (completed == '1') return;
    await importAudioDetailBackups();
    if (_disposed || !_startupMaintenanceCoordinator.isCurrent(epoch)) return;
    await databaseRepository.saveAppSetting(_audioDetailDocumentImportKey, '1');
  }

  void _syncStateSlice({bool? isInitialized}) {
    final current = _service.slice.state;
    _service.syncSlice(
      isInitialized: isInitialized ?? current.isInitialized,
      detailRevision: detailCacheService.revision,
      treeSnapshotRevision: snapshotCacheService.cardSnapshotRevision,
      categorySnapshotRevision: snapshotCacheService.categorySnapshotRevision,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _maintenanceEpoch++;
    await _startupMaintenanceCoordinator.dispose();
    await detailCacheService.suspendAndWait();
    cancelPendingScanProgressNotification();
    _coverArtworkCacheService?.dispose();
    await _service.dispose();
  }
}

class AudioDetailRenameResult {
  const AudioDetailRenameResult({
    required this.detail,
    required this.renamed,
    this.backupFailed = false,
  });

  final AudioDetail detail;
  final bool renamed;
  final bool backupFailed;
}

class AudioDetailRenameException implements Exception {
  const AudioDetailRenameException(this.reason);

  final String reason;
}
