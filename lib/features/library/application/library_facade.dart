import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../../core/app_language.dart';
import '../../../core/logging/app_log_service.dart';
import '../../../core/media/audio_detail.dart';
import '../../../core/media/dlsite_metadata.dart';
import '../../../core/media/music_track.dart';
import '../../../core/media/path_matcher.dart';
import '../../../core/platform/file_cache_platform_gateway.dart';
import '../../../core/persistence/json_document_store.dart';
import '../../asmr/application/asmr_metadata_service.dart';
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
import 'library_metadata_coordinator.dart';
import 'library_mutation_coordinator.dart';
import 'library_persistence_coordinator.dart';
import 'library_service.dart';
import '../domain/audio_library_category.dart';
import '../domain/audio_detail_store.dart';
import '../domain/library_node.dart';
import '../domain/library_entry.dart';
import '../domain/library_persistence_repository.dart';
import 'library_state_models.dart';

enum LibraryRemovalKind {
  standaloneAudioPermanent,
  standaloneFolderPermanent,
  folderAudioPermanent,
  libraryPermanent,
  libraryFolderRecoverable,
  libraryAudioRecoverable,
}

/// Coordinates library services while mutable state stays in [LibraryService].
final class LibraryFacade implements LibraryCatalog {
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
  late final LibraryPersistenceCoordinator _persistenceCoordinator =
      LibraryPersistenceCoordinator(
        repository: databaseRepository,
        service: _service,
      );
  late final LibraryMetadataCoordinator _metadataCoordinator =
      LibraryMetadataCoordinator(
        databaseRepository: databaseRepository,
        detailCacheService: detailCacheService,
        metadataService: metadataService,
        asmrMetadataService: asmrMetadataService,
        service: _service,
        snapshotCacheService: snapshotCacheService,
        coverArtwork: () => coverArtworkCacheService,
        syncState: _syncStateSlice,
        notifyCoverChanged: () => _coverChangeHandler?.call(),
      );
  late final LibraryMutationCoordinator _mutationCoordinator =
      LibraryMutationCoordinator(
        databaseRepository: databaseRepository,
        detailCacheService: detailCacheService,
        service: _service,
        snapshotCacheService: snapshotCacheService,
        entryEditorService: entryEditorService,
        persistenceCoordinator: _persistenceCoordinator,
        coverArtwork: () => coverArtworkCacheService,
        isScanning: () => isScanning,
        cancelScan: cancelScan,
        beginLibraryBatch: beginLibraryBatch,
        endLibraryBatch: endLibraryBatch,
        removeTracksMatching: removeTracksMatching,
        addOrReplaceTracks: addOrReplaceTracks,
        deleteAudioDetail: _metadataCoordinator.deleteAudioDetail,
        syncState: _syncStateSlice,
      );
  CoverArtworkCacheService? _coverArtworkCacheService;
  bool _disposed = false;
  bool _interactionPaused = false;
  void Function(List<String> removedPaths)? _trackRemovalHandler;
  void Function()? _coverChangeHandler;
  late final LibraryStartupMaintenanceCoordinator
  _startupMaintenanceCoordinator = LibraryStartupMaintenanceCoordinator(
    waitForUiIdle: _waitForContinuousUiIdle,
    cleanupOrphanedImports: (retainedPaths) =>
        AppCacheService.cleanupOrphanedPersistentImports(retainedPaths),
    migrateCoverCache: _migrateCoverCacheOnce,
    ensureEntries: _ensureEntriesForLoadedTracks,
    migrateAudioDetails: _importAudioDetailDocumentsOnce,
    backfillDurations: _metadataCoordinator.backfillMissingDurations,
  );

  static const _audioDetailDocumentImportKey =
      'audio_detail_document_read_only_import_v2';
  static const _coverCacheMigrationKey = 'cover_artwork_cache_migration_v1';

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
    final persisted = await _persistenceCoordinator.load();

    _service
      ..library.addAll(persisted.tracks)
      ..groupOrder.addAll(persisted.groupOrder)
      ..groupOrderSet.addAll(persisted.groupOrder)
      ..watchedFolders.addAll(persisted.watchedFolders)
      ..watchedLibraries.addAll(persisted.watchedLibraries)
      ..excludedLibraryFolders.addAll(persisted.folderExclusions)
      ..excludedLibraryTracks.addAll(persisted.trackExclusions);
    _service
      ..replaceLibraryEntries(persisted.entries)
      ..rebuildExclusionsFromEntries(persisted.entries);
    for (final entry in persisted.legacyFolderExclusions.entries) {
      _service.excludedLibraryFolders
          .putIfAbsent(entry.key, () => <String>{})
          .addAll(entry.value);
    }
    _applyExclusionsToLibrary();

    beginLibraryBatch();
    _service.libraryBatchChanged = _service.library.isNotEmpty;
    await endLibraryBatch(notify: false, waitForPersistence: false);
    _service.syncGroupOrderFromLibrary();
    // Startup caches shallow cards; nested trees stay lazy until requested.
    _syncStateSlice(isInitialized: true);
  }

  Future<void> prepareForPersistedStateReset() async {
    _metadataCoordinator.prepareForReset();
    cancelScan();
    await _startupMaintenanceCoordinator.cancelAndWait();
    await _persistenceCoordinator.prepareForReset();
    await detailCacheService.suspendAndWait();
  }

  Future<void> flushPendingPersistence() async {
    await _persistenceCoordinator.flush();
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

  String? libraryRootForPath(String entityPath) =>
      _service.libraryRootForPath(entityPath);

  Future<AudioLibraryCategorySnapshot> audioLibraryCategorySnapshot({
    void Function()? onCommitted,
  }) => snapshotCacheService.categorySnapshot(
    onCommitted: () {
      _syncStateSlice();
      onCommitted?.call();
    },
  );

  Future<AudioDetailLoadResult> loadAudioDetail(AudioDetailTarget target) =>
      _metadataCoordinator.loadAudioDetail(target);

  Future<AudioDetailSaveResult> saveAudioDetail(AudioDetail detail) =>
      _metadataCoordinator.saveAudioDetail(detail);

  Future<void> deleteAudioDetail(AudioDetailTarget target) =>
      _metadataCoordinator.deleteAudioDetail(target);

  Future<AudioDetailSaveResult?> prefillAudioDetailRjCode(
    AudioDetailTarget target,
    String text,
  ) => _metadataCoordinator.prefillRjCode(target, text);

  @override
  Future<AudioDetailBackupImportResult> importAudioDetailBackups({
    bool onlyMissing = false,
  }) => _metadataCoordinator.importBackups(onlyMissing: onlyMissing);

  @override
  Future<void> prefillAudioDetailRjCodeFromText(
    String folderPath,
    String displayName,
  ) => _metadataCoordinator.prefillRjCode(
    AudioDetailTarget.libraryRootFolder(folderPath),
    displayName,
  );

  AudioDetailTarget audioDetailTargetForTrack(MusicTrack track) =>
      _metadataCoordinator.targetForTrack(track);

  AudioDetailTarget canonicalAudioDetailTarget(AudioDetailTarget target) =>
      _metadataCoordinator.canonicalTarget(target);

  AudioDetailTarget audioDetailTargetForPath(String trackPath) =>
      _metadataCoordinator.targetForPath(trackPath);

  Future<void> backfillMissingLibraryDurations({
    Future<Duration?> Function(String path)? durationReader,
  }) => _metadataCoordinator.backfillMissingDurations(
    durationReader: durationReader,
  );

  Future<Duration?> calculateMissingLibraryDuration(
    String targetPath, {
    Future<Duration?> Function(String path)? durationReader,
  }) => _metadataCoordinator.calculateMissingDuration(
    targetPath,
    durationReader: durationReader,
  );

  DlsiteMetadataQuery buildDlsiteMetadataQuery(AudioDetail detail) =>
      _metadataCoordinator.buildQuery(detail);

  Future<DlsiteMetadata> fetchPreferredMetadata(
    String rjCode, {
    required AppLanguage language,
  }) => _metadataCoordinator.fetchPreferredMetadata(rjCode, language: language);

  Future<List<DlsiteMetadata>> searchPreferredMetadataByTitles(
    Iterable<String> titles, {
    required AppLanguage language,
  }) =>
      _metadataCoordinator.searchPreferredMetadata(titles, language: language);

  AudioDetail? resolvedAudioDetail(AudioDetailTarget target) =>
      _metadataCoordinator.resolvedDetail(target);

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
    final updated = track.copyWith(
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
      _metadataCoordinator.resolvedCoverForTrack(track, trackPath: trackPath);

  String? resolvedPlaybackCoverPathForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _metadataCoordinator.resolvedPlaybackCoverForTrack(
    track,
    trackPath: trackPath,
  );

  String? resolvedCoverPathForRemoteCover(String url) =>
      _metadataCoordinator.resolvedRemoteCover(url);

  String? resolvedCoverPathForFolder(String folderPath) =>
      _metadataCoordinator.resolvedFolderCover(folderPath);

  Future<String?> coverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _metadataCoordinator.coverForTrack(track, trackPath: trackPath);

  Future<String?> playbackCoverPathFutureForTrack(
    MusicTrack? track, {
    String? trackPath,
  }) => _metadataCoordinator.playbackCoverForTrack(track, trackPath: trackPath);

  Future<String?> coverPathFutureForFolder(String folderPath) =>
      _metadataCoordinator.coverForFolder(folderPath);

  Future<String?> coverPathFutureForRemoteCover(String url) =>
      _metadataCoordinator.coverForRemote(url);

  Future<List<String>> discoverCoverCandidatesInFolder(
    String folderPath, {
    String? selectedCoverPath,
  }) => _metadataCoordinator.discoverCoverCandidates(
    folderPath,
    selectedCoverPath: selectedCoverPath,
  );

  Future<String?> setFolderManualCover(
    String folderPath,
    String imagePath, {
    bool newlySaved = false,
    String? sourcePath,
  }) => _metadataCoordinator.setFolderManualCover(
    folderPath,
    imagePath,
    newlySaved: newlySaved,
    sourcePath: sourcePath,
  );

  void invalidateCoverArtwork() =>
      _metadataCoordinator.invalidateCoverArtwork();

  Future<DlsiteMetadataApplyResult> applyDlsiteMetadata(
    AudioDetail detail,
    DlsiteMetadata metadata, {
    required bool saveCover,
    required AppLanguage language,
    bool missingOnly = false,
  }) => _metadataCoordinator.applyMetadata(
    detail,
    metadata,
    saveCover: saveCover,
    language: language,
    missingOnly: missingOnly,
  );

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
      onPersist: () => unawaited(_persistenceCoordinator.saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  @override
  void addWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _service.addWatchedLibrary(
      folderPath,
      onPersist: () =>
          unawaited(_persistenceCoordinator.saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  @override
  void removeWatchedFolder(String folderPath, {bool notify = true}) {
    final changed = _service.removeWatchedFolder(
      folderPath,
      onPersist: () => unawaited(_persistenceCoordinator.saveWatchedFolders()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void removeWatchedLibrary(String folderPath, {bool notify = true}) {
    final changed = _service.removeWatchedLibrary(
      folderPath,
      onPersist: () =>
          unawaited(_persistenceCoordinator.saveWatchedLibraries()),
    );
    if (changed && notify) _syncStateSlice();
  }

  void configurePersistence({required bool enabled}) {
    _persistenceCoordinator.configure(enabled: enabled);
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
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder) {
        unawaited(_persistenceCoordinator.saveGroupOrder());
      }
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
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.upsertTracks(mutation.tracks));
      if (mutation.didChangeGroupOrder || mutation.didReplaceGroup) {
        unawaited(_persistenceCoordinator.saveGroupOrder());
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
    if (persist && _persistenceCoordinator.enabled) {
      unawaited(databaseRepository.deleteTracks(removedPaths));
    }
    if (!mutation.batched) {
      _markLibraryStructureChanged();
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
    if (removedPaths.isNotEmpty && _persistenceCoordinator.enabled) {
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
    if (removedPaths.isNotEmpty && _persistenceCoordinator.enabled) {
      unawaited(
        databaseRepository.deleteLibraryEntries(libraryPath, removedPaths),
      );
    }
  }

  @override
  void clearLibraryExclusions(String libraryPath) =>
      _mutationCoordinator.clearLibraryExclusions(libraryPath);

  Future<LibraryRemovalKind?> removeTrack(String trackPath) async =>
      _publicRemovalKind(await _mutationCoordinator.removeTrack(trackPath));

  Future<LibraryRemovalKind?> removeFolder(String folderPath) async =>
      _publicRemovalKind(await _mutationCoordinator.removeFolder(folderPath));

  void excludeLibraryFolder(String libraryPath, String folderPath) =>
      _mutationCoordinator.excludeLibraryFolder(libraryPath, folderPath);

  void excludeLibraryTrack(String libraryPath, String trackPath) =>
      _mutationCoordinator.excludeLibraryTrack(libraryPath, trackPath);

  void setLibraryFolderExcluded(
    String libraryPath,
    String folderPath,
    bool excluded,
  ) => _mutationCoordinator.setLibraryFolderExcluded(
    libraryPath,
    folderPath,
    excluded,
  );

  void setLibraryTrackExcluded(
    String libraryPath,
    String trackPath,
    bool excluded,
  ) => _mutationCoordinator.setLibraryTrackExcluded(
    libraryPath,
    trackPath,
    excluded,
  );

  Future<AudioDetailRenameResult> renameAudioDetailTarget(AudioDetail detail) =>
      renameAudioDetailTargetToName(detail, detail.workTitle);

  Future<AudioDetailRenameResult> renameAudioDetailTargetToName(
    AudioDetail detail,
    String targetName,
  ) async {
    try {
      final result = await _mutationCoordinator.renameAudioDetailTargetToName(
        detail,
        targetName,
      );
      return AudioDetailRenameResult(
        detail: result.detail,
        renamed: result.renamed,
        backupFailed: result.backupFailed,
      );
    } on LibraryMutationRenameException catch (error) {
      throw AudioDetailRenameException(error.reason);
    }
  }

  static LibraryRemovalKind? _publicRemovalKind(
    LibraryMutationRemovalKind? kind,
  ) => switch (kind) {
    null => null,
    LibraryMutationRemovalKind.standaloneAudioPermanent =>
      LibraryRemovalKind.standaloneAudioPermanent,
    LibraryMutationRemovalKind.standaloneFolderPermanent =>
      LibraryRemovalKind.standaloneFolderPermanent,
    LibraryMutationRemovalKind.folderAudioPermanent =>
      LibraryRemovalKind.folderAudioPermanent,
    LibraryMutationRemovalKind.libraryPermanent =>
      LibraryRemovalKind.libraryPermanent,
    LibraryMutationRemovalKind.libraryFolderRecoverable =>
      LibraryRemovalKind.libraryFolderRecoverable,
    LibraryMutationRemovalKind.libraryAudioRecoverable =>
      LibraryRemovalKind.libraryAudioRecoverable,
  };

  @override
  void beginLibraryBatch() {
    if (_service.libraryBatchDepth == 0) {
      _service.libraryDerivedGeneration++;
    }
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
    if (_persistenceCoordinator.enabled) {
      if (tracksToPersist.isNotEmpty) {
        persistenceTasks.add(databaseRepository.upsertTracks(tracksToPersist));
      }
      if (entriesToPersist.isNotEmpty) {
        persistenceTasks.add(
          databaseRepository.upsertLibraryEntries(entriesToPersist),
        );
      }
      if (didChangeLibrary && didChangeGroupOrder) {
        persistenceTasks.add(_persistenceCoordinator.saveGroupOrder());
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
    if (entries.isEmpty || !persist || !_persistenceCoordinator.enabled) {
      return;
    }
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
    bool Function()? preferEmbeddedAudioCover,
  }) {
    _coverArtworkCacheService ??= CoverArtworkCacheService(
      libraryService: _service,
      databaseRepository: databaseRepository,
      audioDetailCacheService: detailCacheService,
      isActiveCoverKey: isActiveCoverKey,
      onActiveCoverChanged: onActiveCoverChanged,
      preferEmbeddedAudioCover: preferEmbeddedAudioCover,
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
    if (_persistenceCoordinator.enabled) {
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

  Future<void> _migrateCoverCacheOnce(int epoch) async {
    if (_disposed || !_startupMaintenanceCoordinator.isCurrent(epoch)) return;
    final completed = await databaseRepository.loadAppSetting(
      _coverCacheMigrationKey,
    );
    if (completed == '1') return;
    await coverArtworkCacheService.migrateLegacyCaches(
      shouldCancel: () =>
          _disposed || !_startupMaintenanceCoordinator.isCurrent(epoch),
    );
    if (_disposed || !_startupMaintenanceCoordinator.isCurrent(epoch)) return;
    await databaseRepository.saveAppSetting(_coverCacheMigrationKey, '1');
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
    _metadataCoordinator.dispose();
    await _startupMaintenanceCoordinator.dispose();
    await detailCacheService.suspendAndWait();
    cancelPendingScanProgressNotification();
    await _coverArtworkCacheService?.dispose();
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
